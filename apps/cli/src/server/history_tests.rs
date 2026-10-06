use super::*;
struct Clock(time::OffsetDateTime);
impl crate::providers::Clock for Clock {
    fn now(&self) -> time::OffsetDateTime {
        self.0
    }
}
async fn enabled_fixture() -> (Arc<ApiState>, std::path::PathBuf, String) {
    let (mut state, dir, source) = tests::fixture().await;
    {
        let state = Arc::get_mut(&mut state).unwrap();
        state.no_saved_accounts = false;
        state.context.clock = Arc::new(Clock(time::macros::datetime!(2026-01-01 0:00:10 UTC)));
        state.history = Some(
            crate::history::History::open(
                state.vault.as_ref().unwrap().history_path(),
                state.context.clock.now(),
            )
            .await
            .unwrap(),
        );
    }
    std::fs::write(
        dir.join("config.toml"),
        "enabled_providers = [\"mock\"]\nrefresh_interval = 0\n",
    )
    .unwrap();
    *state.settings.write().await = state.store.load().unwrap();
    (state, dir, source)
}
#[tokio::test]
async fn history_capability_requires_authenticated_owner_and_owner_management() {
    let (state, dir, _) = enabled_fixture().await;
    let owner = security::owner().0;
    assert!(history::restriction(&state, &owner, false).is_none());
    assert!(history::restriction(&state, &owner, true).is_none());
    let mut delegated = owner.clone();
    delegated.owner = false;
    delegated.manage = true;
    assert_eq!(
        history::restriction(&state, &delegated, false),
        Some("insufficient_scope")
    );
    assert_eq!(
        history::restriction(&state, &delegated, true),
        Some("insufficient_scope")
    );
    assert!(
        history::catalog(
            State(state.clone()),
            Extension(delegated),
            Path("anything".into())
        )
        .await
        .is_err()
    );
    drop(state);
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn cache_restore_and_snapshot_reads_do_not_record_stale_provider_observations() {
    let (state, dir, _) = enabled_fixture().await;
    collect_usage(&state, None, true).await.unwrap();
    let Json(snapshot) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap();
    if let Some(account) = snapshot.accounts.iter().find(|a| a.provider_id == "mock") {
        let Json(catalog) = history::catalog(
            State(state.clone()),
            security::owner(),
            Path(account.id.clone()),
        )
        .await
        .unwrap();
        assert!(catalog.first_observed_at.is_none());
    }
    refresh(
        &state,
        Some(RefreshRequest {
            providers: vec![Provider::Mock],
            account_id: None,
            force: true,
            include_owned: true,
            disabled_proxy_auth_files: vec![],
        }),
    )
    .await
    .unwrap();
    let Json(snapshot) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap();
    let account = snapshot
        .accounts
        .iter()
        .find(|a| a.provider_id == "mock")
        .unwrap();
    let Json(before) = history::catalog(
        State(state.clone()),
        security::owner(),
        Path(account.id.clone()),
    )
    .await
    .unwrap();
    assert_eq!(
        before.last_observed_at,
        Some(time::macros::datetime!(2026-01-01 0:00 UTC))
    );
    let _ = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap();
    collect_usage(&state, None, true).await.unwrap();
    let Json(after) = history::catalog(
        State(state.clone()),
        security::owner(),
        Path(account.id.clone()),
    )
    .await
    .unwrap();
    assert_eq!(before.last_observed_at, after.last_observed_at);
    drop(state);
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn verified_external_identity_survives_restart_but_unverified_epoch_does_not() {
    let (state, dir, _) = enabled_fixture().await;
    refresh(&state, None).await.unwrap();
    let report = state.snapshot.read().await.as_ref().unwrap().1.clone();
    let view = history::snapshot(&state, report.clone()).await.unwrap();
    let id = view
        .accounts
        .iter()
        .find(|a| a.provider_id == "mock")
        .unwrap()
        .id
        .clone();
    let first = history::account_context(&state, &view, &report, &id)
        .await
        .unwrap();
    state.history_epochs.lock().await.clear();
    let second = history::account_context(&state, &view, &report, &id)
        .await
        .unwrap();
    assert_ne!(first.epoch, second.epoch);
    let mut verified = report;
    verified.providers[0].account.verified = Some(crate::domain::VerifiedIdentity {
        subject: "same-subject".into(),
        tenant: Some("tenant-a".into()),
    });
    let first = history::account_context(&state, &view, &verified, &id)
        .await
        .unwrap();
    state.history_epochs.lock().await.clear();
    let second = history::account_context(&state, &view, &verified, &id)
        .await
        .unwrap();
    assert_eq!(first.epoch, second.epoch);
    verified.providers[0]
        .account
        .verified
        .as_mut()
        .unwrap()
        .tenant = Some("tenant-b".into());
    let third = history::account_context(&state, &view, &verified, &id)
        .await
        .unwrap();
    assert_ne!(first.epoch, third.epoch);
    drop(state);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn history_only_pause_resume_preserves_immediate_external_catalog_and_current_quota() {
    let (state, dir, _) = enabled_fixture().await;
    refresh(&state, None).await.unwrap();
    let Json(before) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap();
    let account = before
        .accounts
        .iter()
        .find(|account| account.provider_id == "mock")
        .unwrap()
        .id
        .clone();
    let generation = state.generation.load(Ordering::SeqCst);
    for enabled in [false, true] {
        let revision = state.settings.read().await.revision.clone();
        let patch: SettingsPatch =
            serde_json::from_value(json!({"revision":revision,"quota_history_enabled":enabled}))
                .unwrap();
        let Json(settings) =
            patch_settings(State(state.clone()), security::owner(), ApiJson(patch))
                .await
                .unwrap();
        assert_eq!(settings.values.quota_history_enabled, enabled);
        assert_eq!(state.generation.load(Ordering::SeqCst), generation);
        let Json(catalog) = history::catalog(
            State(state.clone()),
            security::owner(),
            Path(account.clone()),
        )
        .await
        .unwrap();
        assert_eq!(catalog.recording_enabled, enabled);
        let Json(after) = resolved_snapshot(State(state.clone()), security::owner())
            .await
            .unwrap();
        assert_eq!(
            serde_json::to_value(&before.usage).unwrap(),
            serde_json::to_value(&after.usage).unwrap()
        );
        assert_eq!(
            history::clear_account(
                State(state.clone()),
                security::owner(),
                Path(account.clone())
            )
            .await
            .unwrap(),
            StatusCode::NO_CONTENT
        );
    }
    drop(state);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn live_host_history_smoke() {
    let (state, dir, _) = enabled_fixture().await;
    let token = "history-smoke-owner-01234567890123456789";
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let policy =
        Arc::new(security::Policy::new(address, true, None, &[], Some(token.into())).unwrap());
    let service = tokio::spawn(axum::serve(listener, router(state.clone(), policy)).into_future());
    let client = reqwest::Client::new();
    let base = format!("http://{address}");
    assert_eq!(
        client
            .get(format!("{base}/v2/quota-history"))
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::UNAUTHORIZED
    );
    let operation: Value = client
        .post(format!("{base}/v2/refresh"))
        .bearer_auth(token)
        .json(&json!({"force":true}))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let id = operation["id"].as_str().unwrap();
    let mut completed = false;
    for _ in 0..100 {
        let operation: Value = client
            .get(format!("{base}/v2/operations/{id}"))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        if operation["status"] == "completed" {
            completed = true;
            break;
        }
        assert_ne!(operation["status"], "failed", "{operation}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(completed);
    // Test-only normalized samples supplement the real Collector/cache/host observation.
    let seeded_report = state.snapshot.read().await.as_ref().unwrap().1.clone();
    let seeded_view = history::snapshot(&state, seeded_report.clone())
        .await
        .unwrap();
    let seeded_account = seeded_view
        .accounts
        .iter()
        .find(|account| account.provider_id == "mock")
        .unwrap()
        .id
        .clone();
    let context = history::account_context(&state, &seeded_view, &seeded_report, &seeded_account)
        .await
        .unwrap();
    let session = context.metrics[0].clone();
    let latest = state
        .history
        .as_ref()
        .unwrap()
        .chart(
            context.clone(),
            session.id.clone(),
            "24h".into(),
            true,
            state.context.clock.now(),
        )
        .await
        .unwrap()
        .latest
        .unwrap();
    let base_time = time::macros::datetime!(2025-12-31 18:00 UTC);
    let samples = [
        (0, Some(90.0)),
        (20, Some(82.0)),
        (40, Some(70.0)),
        (60, None),
        (120, Some(40.0)),
        (140, Some(10.0)),
        (160, Some(0.0)),
        (180, Some(100.0)),
        (200, Some(95.0)),
        (240, Some(75.0)),
        (260, Some(90.0)),
        (300, Some(75.0)),
    ];
    let points = samples
        .into_iter()
        .map(|(minute, value)| {
            let fetched = base_time + time::Duration::minutes(minute);
            crate::history::Point {
                account: context.clone(),
                metric: session.clone(),
                basis: if value.is_none() {
                    "fixture-unknown-basis".into()
                } else {
                    latest.basis_id.clone()
                },
                observation: crate::history::Observation {
                    series_id: String::new(),
                    basis_id: String::new(),
                    fetched_at: fetched,
                    expires_at: Some(fetched + time::Duration::minutes(5)),
                    quota: crate::domain::Quota::from_remaining(value),
                    amounts: None,
                    resets_at: Some(if minute < 180 {
                        base_time + time::Duration::minutes(170)
                    } else {
                        time::macros::datetime!(2026-01-08 0:00 UTC)
                    }),
                    reset_description: None,
                    provenance: crate::domain::Provenance {
                        source: "mock_fixture".into(),
                        confidence: if minute == 40 {
                            crate::domain::Confidence::Estimated
                        } else {
                            crate::domain::Confidence::Exact
                        },
                    },
                },
            }
        })
        .collect();
    state
        .history
        .as_ref()
        .unwrap()
        .record(
            points,
            state.history.as_ref().unwrap().revision(),
            state.context.clock.now(),
        )
        .await
        .unwrap();
    let snapshot: Value = client
        .get(format!("{base}/v2/snapshot"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let account = snapshot["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["provider_id"] == "mock")
        .unwrap()["id"]
        .as_str()
        .unwrap();
    assert_eq!(
        snapshot["host"]["capabilities"]["quota_history"]["available"],
        true
    );
    let catalog: Value = client
        .get(format!("{base}/v2/accounts/{account}/quota-history"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let metric = catalog["metrics"][0]["id"].as_str().unwrap();
    let chart: Value = client
        .get(format!(
            "{base}/v2/accounts/{account}/quota-history/{metric}/24h"
        ))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(chart["latest"]["quota"]["remaining_percent"], 75.0);
    assert_eq!(chart["lowest_remaining_percent"], 0.0);
    assert!(chart["bins"].as_array().unwrap().iter().any(|bin| {
        bin["states"]
            .as_array()
            .unwrap()
            .iter()
            .any(|state| state == "unknown")
    }));
    for kind in ["reset_inferred", "quota_increased", "basis_changed"] {
        assert!(
            chart["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|event| event["kind"] == kind)
        );
    }
    let Json(document) = openapi::document().await;
    for (name, value) in [
        ("QuotaHistoryCatalog", &catalog),
        ("QuotaHistoryChart", &chart),
    ] {
        let mut schema = document["components"]["schemas"][name].clone();
        schema["components"] = document["components"].clone();
        let validator = jsonschema::draft202012::options()
            .should_validate_formats(true)
            .build(&schema)
            .unwrap();
        let errors: Vec<_> = validator
            .iter_errors(value)
            .map(|error| error.to_string())
            .collect();
        assert!(errors.is_empty(), "{name}: {}", errors.join("; "));
    }
    println!(
        "HISTORY_SMOKE {}",
        json!({"base_url":base,"owner_token":token,"data_directory":dir,"account_id":account,"metric_id":metric,"fixed_clock":"2026-01-01T00:00:10Z"})
    );
    if let Ok(seconds) = std::env::var("QUOTIO_HISTORY_SMOKE_SECONDS") {
        tokio::time::sleep(Duration::from_secs(seconds.parse().unwrap())).await;
    }
    assert_eq!(
        client
            .delete(format!("{base}/v2/accounts/{account}/quota-history"))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
            .status(),
        StatusCode::NO_CONTENT
    );
    let chart: Value = client
        .get(format!(
            "{base}/v2/accounts/{account}/quota-history/{metric}/24h"
        ))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert!(chart["bins"].as_array().unwrap().is_empty());
    service.abort();
    drop(state);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn clear_rejects_late_accepted_report_without_suppressing_current_quota() {
    let (state, dir, _) = enabled_fixture().await;
    refresh(&state, None).await.unwrap();
    let generation = state.generation.load(Ordering::SeqCst);
    let revision = state.history.as_ref().unwrap().revision();
    let mut report = state.snapshot.read().await.as_ref().unwrap().1.clone();
    let view = history::snapshot(&state, report.clone()).await.unwrap();
    let id = view
        .accounts
        .iter()
        .find(|a| a.provider_id == "mock")
        .unwrap()
        .id
        .clone();
    let account = history::account_context(&state, &view, &report, &id)
        .await
        .unwrap();
    history::clear_account(State(state.clone()), security::owner(), Path(id.clone()))
        .await
        .unwrap();
    for provider in &mut report.providers {
        provider.fresh_observation = true;
        for window in &mut provider.windows {
            window.fetched_at = state.context.clock.now() + time::Duration::seconds(1);
        }
    }
    let selected = [Provider::Mock];
    accept_report(
        &state,
        report,
        AcceptedRefresh {
            generation,
            history_revision: revision,
            cache_only: false,
            selected: &selected,
            enabled: &selected,
            source_scope: None,
            cache_ttl_seconds: 300,
        },
    )
    .await
    .unwrap();
    let catalog = state
        .history
        .as_ref()
        .unwrap()
        .catalog(account.clone(), true, state.context.clock.now())
        .await
        .unwrap();
    assert!(catalog.last_observed_at.is_none());
    let chart = state
        .history
        .as_ref()
        .unwrap()
        .chart(
            account.clone(),
            account.metrics[0].id.clone(),
            "24h".into(),
            true,
            state.context.clock.now(),
        )
        .await
        .unwrap();
    assert!(chart.bins.is_empty());
    assert!(chart.events.is_empty());
    let Json(snapshot) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap();
    assert!(snapshot.usage.iter().any(|usage| usage.account_id == id));
    drop(state);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn storage_recording_failure_is_visible_but_current_quota_remains_available() {
    let (state, dir, _) = enabled_fixture().await;
    refresh(&state, None).await.unwrap();
    let report = state.snapshot.read().await.as_ref().unwrap().1.clone();
    let view = history::snapshot(&state, report.clone()).await.unwrap();
    let id = view
        .accounts
        .iter()
        .find(|a| a.provider_id == "mock")
        .unwrap()
        .id
        .clone();
    let path = state.vault.as_ref().unwrap().history_path();
    let db = rusqlite::Connection::open(path).unwrap();
    db.execute_batch("ALTER TABLE history_observations RENAME TO fixture_unavailable")
        .unwrap();
    refresh(
        &state,
        Some(RefreshRequest {
            providers: vec![Provider::Mock],
            account_id: None,
            force: true,
            include_owned: true,
            disabled_proxy_auth_files: vec![],
        }),
    )
    .await
    .unwrap();
    db.execute_batch("ALTER TABLE fixture_unavailable RENAME TO history_observations")
        .unwrap();
    drop(db);
    let Json(catalog) = history::catalog(State(state.clone()), security::owner(), Path(id.clone()))
        .await
        .unwrap();
    assert!(catalog.recording_error.is_some());
    let Json(snapshot) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap();
    assert!(snapshot.usage.iter().any(|usage| usage.account_id == id));
    drop(state);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn unlink_preserves_verified_account_until_explicit_or_last_source_removal() {
    for delete_account in [false, true] {
        let (state, dir, first) = enabled_fixture().await;
        let vault = state.vault.clone().unwrap();
        let second = {
            let mut tx = vault.begin().unwrap();
            let second = tx
                .document
                .add(
                    Provider::Amp,
                    "Second source",
                    "second-history-source".into(),
                    crate::accounts::Credential::ApiKey {
                        token: "test-only-history-key".into(),
                        region: None,
                        organization: None,
                    },
                )
                .unwrap();
            tx.document.enable_resolved_accounts().unwrap();
            let registry = tx.document.resolved.as_mut().unwrap();
            let proof = crate::domain::VerifiedIdentity {
                subject: "history-same-person".into(),
                tenant: Some("tenant-a".into()),
            };
            registry.observe(&first, &proof).unwrap();
            registry.observe(&second, &proof).unwrap();
            tx.commit().unwrap();
            second
        };
        let report = UsageReport {
            schema_version: 1,
            generated_at: state.context.clock.now(),
            providers: vec![],
            failures: vec![],
        };
        let view = history::snapshot(&state, report.clone()).await.unwrap();
        let id = view
            .accounts
            .iter()
            .find(|account| account.sources.iter().any(|source| source.id == first))
            .unwrap()
            .id
            .clone();
        let context = history::account_context(&state, &view, &report, &id)
            .await
            .unwrap();
        assert_eq!(
            view.accounts
                .iter()
                .find(|account| account.id == id)
                .unwrap()
                .sources
                .len(),
            2
        );
        let fetched = state.context.clock.now() - time::Duration::seconds(1);
        let history_store = state.history.as_ref().unwrap().clone();
        history_store
            .record(
                vec![crate::history::Point {
                    account: context.clone(),
                    metric: crate::history::Metric {
                        id: "session".into(),
                        display_name: "Session".into(),
                        group: None,
                        current: true,
                        has_percentage: true,
                    },
                    basis: "test-percentage-basis".into(),
                    observation: crate::history::Observation {
                        series_id: String::new(),
                        basis_id: String::new(),
                        fetched_at: fetched,
                        expires_at: Some(fetched + time::Duration::minutes(5)),
                        quota: crate::domain::Quota::from_remaining(Some(40.0)),
                        amounts: None,
                        resets_at: None,
                        reset_description: None,
                        provenance: crate::domain::Provenance {
                            source: "test_fixture".into(),
                            confidence: crate::domain::Confidence::Exact,
                        },
                    },
                }],
                history_store.revision(),
                state.context.clock.now(),
            )
            .await
            .unwrap();
        let (_, Json(operation)) = management::source_remove(
            State(state.clone()),
            security::owner(),
            Path(second),
            tests::key("history-unlink-one"),
        )
        .await
        .unwrap();
        assert_eq!(tests::done(&state, &operation.id).await.status, "completed");
        let Json(catalog) =
            history::catalog(State(state.clone()), security::owner(), Path(id.clone()))
                .await
                .unwrap();
        assert_eq!(catalog.last_observed_at, Some(fetched));
        let generation = state.generation.load(Ordering::SeqCst);
        let revision = history_store.revision();
        let (_, Json(operation)) = if delete_account {
            management::resolved_remove(
                State(state.clone()),
                security::owner(),
                Path(id.clone()),
                tests::key("history-remove-account"),
            )
            .await
            .unwrap()
        } else {
            management::source_remove(
                State(state.clone()),
                security::owner(),
                Path(first),
                tests::key("history-remove-last-source"),
            )
            .await
            .unwrap()
        };
        assert_eq!(tests::done(&state, &operation.id).await.status, "completed");
        assert!(
            history_store
                .catalog(context, true, state.context.clock.now())
                .await
                .unwrap()
                .last_observed_at
                .is_none()
        );
        assert!(matches!(
            history::catalog(State(state.clone()), security::owner(), Path(id)).await,
            Err(ApiError(StatusCode::NOT_FOUND, _))
        ));
        let selected = [Provider::Amp];
        assert_eq!(
            accept_report(
                &state,
                report,
                AcceptedRefresh {
                    generation,
                    history_revision: revision,
                    cache_only: false,
                    selected: &selected,
                    enabled: &selected,
                    source_scope: None,
                    cache_ttl_seconds: 300
                }
            )
            .await
            .unwrap_err(),
            "state_changed"
        );
        drop(history_store);
        drop(state);
        drop(vault);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
