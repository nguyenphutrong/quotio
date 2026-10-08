use super::*;
use crate::accounts::{
    self, AccountError, Credential,
    vault::{Backend, Vault},
};
#[derive(Default)]
struct Memory(std::sync::Mutex<Option<Vec<u8>>>);
impl Backend for Memory {
    fn read(&self) -> Result<Option<Vec<u8>>, AccountError> {
        Ok(self.0.lock().unwrap().clone())
    }
    fn write(&self, bytes: &[u8]) -> Result<(), AccountError> {
        *self.0.lock().unwrap() = Some(bytes.into());
        Ok(())
    }
}
pub(super) async fn fixture() -> (Arc<ApiState>, std::path::PathBuf, String) {
    let dir = std::env::temp_dir().join(format!(
        "quotio-api-test-{}",
        accounts::random_string().unwrap()
    ));
    std::fs::create_dir(&dir).unwrap();
    let vault = Vault::new(Arc::new(Memory::default()), dir.join("vault.lock"));
    let id = accounts::service::add(
        vault.clone(),
        Provider::Amp,
        "old label".into(),
        Credential::ApiKey {
            token: "synthetic-vault-secret".into(),
            region: None,
            organization: None,
        },
        "fake-identity".into(),
    )
    .await
    .unwrap();
    let store = SettingsStore::new(dir.join("config.toml"), Overrides::default());
    let view = store.load().unwrap();
    let context = ProviderContext {
        http: reqwest::Client::builder()
            .timeout(Duration::from_secs(1))
            .build()
            .unwrap(),
        clock: Arc::new(SystemClock),
        credentials: Arc::new(EnvironmentCredentials),
    };
    let generation = Arc::new(AtomicU64::new(0));
    let guard = Arc::new(Mutex::new(()));
    let manager = accounts::oauth::OAuthSessionManager::new(
        context.clone(),
        vault.clone(),
        guard.clone(),
        generation.clone(),
    );
    (
        Arc::new(ApiState {
            history: None,
            history_epochs: Mutex::new(HashMap::new()),
            sharing: Mutex::new(sharing::Sharing::default()),
            discovery: Default::default(),
            native_scan_lock: Mutex::new(()),
            settings: RwLock::new(view),
            store,
            snapshot: RwLock::new(None),
            transient_snapshot: Mutex::new(None),
            generation,
            restore_pending: AtomicBool::new(true),
            commit_guard: guard,
            refresh_lock: Mutex::new(()),
            pending: Mutex::new(HashMap::new()),
            wake: Notify::new(),
            operations: Mutex::new(Operations::default()),
            jobs: std::sync::Mutex::new(vec![]),
            status: Mutex::new(RefreshStatus::default()),
            context,
            no_saved_accounts: true,
            proxy_auth_directory: None,
            proxy_configuration: None,
            manage: true,
            vault: Some(vault),
            oauth: Some(manager),
        }),
        dir,
        id,
    )
}

#[tokio::test]
async fn read_only_hosts_do_not_advertise_mutation_or_refresh_actions() {
    let (mut state, dir, id) = fixture().await;
    let writable = Arc::get_mut(&mut state).unwrap();
    writable.manage = false;
    writable.no_saved_accounts = false;
    let Json(catalog) = providers(State(state.clone()), security::owner()).await;
    assert!(
        catalog
            .providers
            .iter()
            .flat_map(|p| &p.actions)
            .all(|action| !action.available)
    );
    let Json(list) = management::resolved_accounts(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    assert!(!list.host.capabilities["account_write_v2"].available);
    assert!(!list.host.capabilities["refresh"].available);
    let Json(account) =
        management::resolved_account(State(state.clone()), Path(id.clone()), security::owner())
            .await
            .unwrap_or_else(|_| panic!());
    assert!(account.actions.iter().all(|action| !action.available));
    assert!(
        account
            .sources
            .iter()
            .flat_map(|s| &s.actions)
            .all(|action| !action.available)
    );
    *state.snapshot.write().await = Some((
        0,
        UsageReport {
            schema_version: 1,
            generated_at: state.context.clock.now(),
            providers: vec![],
            failures: vec![ProviderFailure {
                provider: ProviderId("amp".into()),
                account_ref: Some(crate::domain::AccountRef {
                    id,
                    label: "fixture".into(),
                    origin: Some(crate::domain::AccountOrigin::Owned),
                }),
                code: ProviderError::Transient,
                message: "temporary failure".into(),
            }],
        },
    ));
    let Json(snapshot) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    assert!(!snapshot.host.capabilities["refresh"].available);
    let retry = snapshot.usage[0]
        .issue
        .as_ref()
        .unwrap()
        .action
        .as_ref()
        .unwrap();
    assert!(!retry.available);
    assert_eq!(retry.reason.as_deref(), Some("management_disabled"));
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn revocation_blocks_a_previously_authorized_queued_account_write() {
    let (mut state, dir, account_id) = fixture().await;
    Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
    let vault = state.vault.clone().unwrap();
    let issued = accounts::clients::create(
        vault.clone(),
        accounts::clients::Create {
            label: "Manager".into(),
            scope: accounts::clients::Scope::Manage,
            expires_in_seconds: 3600,
        },
        state.context.clock.now(),
    )
    .await
    .unwrap();
    let guard = state.commit_guard.lock().await;
    let (_, Json(operation)) = management::resolved_patch(
        State(state.clone()),
        Extension(security::Principal {
            id: issued.client.id.clone(),
            owner: false,
            manage: true,
            host_user: false,
        }),
        Path(account_id.clone()),
        key("queued-change"),
        ApiJson(json!({"user_label":"Must not be saved"})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    accounts::clients::revoke(vault.clone(), issued.client.id)
        .await
        .unwrap();
    drop(guard);
    assert_eq!(
        done(&state, &operation.id).await.error,
        Some("client_revoked")
    );
    assert_eq!(
        accounts::service::get(vault, account_id)
            .await
            .unwrap()
            .label,
        "old label"
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn account_scoped_refresh_does_not_require_scheduled_provider() {
    let (state, dir, id) = fixture().await;
    assert!(
        state
            .settings
            .read()
            .await
            .values
            .enabled_providers
            .is_empty()
    );
    let refresh_guard = state.refresh_lock.lock().await;

    let result = manual_refresh(
        State(state.clone()),
        security::owner(),
        ApiJson(RefreshRequest {
            providers: vec![Provider::Amp],
            account_id: Some(id),
            force: true,
            include_owned: true,
            disabled_proxy_auth_files: Vec::new(),
        }),
    )
    .await;

    assert!(matches!(result, Ok((StatusCode::ACCEPTED, _))));
    for job in state.jobs.lock().unwrap().drain(..) {
        job.abort();
    }
    drop(refresh_guard);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn account_scoped_refresh_accepts_borrowed_proxy_account() {
    let (mut state, dir, _) = fixture().await;
    let auth = dir.join("proxy-auth");
    std::fs::create_dir(&auth).unwrap();
    let auth = auth.canonicalize().unwrap();
    std::fs::write(
        auth.join("claude.json"),
        br#"{"type":"claude","access_token":"borrowed-test-token"}"#,
    )
    .unwrap();
    Arc::get_mut(&mut state).unwrap().proxy_auth_directory = Some(auth.clone());
    let account =
        crate::accounts::proxy::adapters(&auth, &[Provider::Catalog("claude")], None, &[])
            .unwrap()
            .remove(0)
            .account_ref()
            .unwrap();

    assert!(
        management::validate_refresh_account(&state, Provider::Catalog("claude"), &account.id)
            .await
            .is_ok()
    );
    let mut usage = Provider::Mock
        .adapter()
        .fetch(&state.context)
        .await
        .unwrap();
    usage.provider = ProviderId("claude".into());
    usage.account_ref = Some(account);
    *state.snapshot.write().await = Some((
        0,
        UsageReport {
            schema_version: 1,
            generated_at: state.context.clock.now(),
            providers: vec![usage],
            failures: vec![],
        },
    ));
    let Json(snapshot) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    let refresh_guard = state.refresh_lock.lock().await;
    let result = manual_refresh(
        State(state.clone()),
        security::owner(),
        ApiJson(RefreshRequest {
            providers: vec![Provider::Catalog("claude")],
            account_id: Some(snapshot.accounts[0].id.clone()),
            force: true,
            include_owned: true,
            disabled_proxy_auth_files: vec![],
        }),
    )
    .await;
    assert!(matches!(result, Ok((StatusCode::ACCEPTED, _))));
    for job in state.jobs.lock().unwrap().drain(..) {
        job.abort();
    }
    drop(refresh_guard);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn borrowed_proxy_refresh_keeps_valid_sources_when_the_other_source_fails() {
    for valid_config in [true, false] {
        let (mut state, dir, _) = fixture().await;
        let dir = dir.canonicalize().unwrap();
        let auth = dir.join("proxy-auth");
        std::fs::create_dir(&auth).unwrap();
        let auth_bytes = br#"{"type":"claude","disabled":true,"access_token":"owner-only"}"#;
        std::fs::write(auth.join("claude.json"), auth_bytes).unwrap();
        let config = dir.join("proxy.yaml");
        let config_bytes = if valid_config {
            b"openai-compatibility:\n  - base-url: https://openrouter.ai/api/v1\n    disabled: true\n    api-key-entries: [{api-key: owner-only}]\n".as_slice()
        } else {
            b"openai-compatibility: [".as_slice()
        };
        std::fs::write(&config, config_bytes).unwrap();
        let inner = Arc::get_mut(&mut state).unwrap();
        inner.proxy_auth_directory = Some(if valid_config {
            config.clone()
        } else {
            auth.clone()
        });
        inner.proxy_configuration = Some(config.clone());
        let provider = if valid_config {
            Provider::OpenRouter
        } else {
            Provider::Catalog("claude")
        };
        state.settings.write().await.values.enabled_providers = vec![provider.id().into()];
        refresh(&state, None).await.unwrap();
        let Json(snapshot) = resolved_snapshot(State(state.clone()), security::owner())
            .await
            .unwrap_or_else(|_| panic!());
        let account = snapshot
            .accounts
            .iter()
            .find(|account| {
                account.provider_id == provider.id()
                    && account
                        .sources
                        .iter()
                        .any(|source| source.origin == crate::domain::AccountOrigin::BorrowedProxy)
            })
            .unwrap();
        assert_eq!(account.state, crate::contract::ConnectionState::Disabled);
        let usage = snapshot
            .usage
            .iter()
            .find(|usage| usage.account_id == account.id)
            .unwrap();
        assert!(usage.metrics.is_empty());
        assert!(usage.issue.is_none());
        assert!(
            state
                .snapshot
                .read()
                .await
                .as_ref()
                .unwrap()
                .1
                .failures
                .iter()
                .any(|failure| {
                    failure.provider.0 == provider.id()
                        && failure.code == ProviderError::SourceDisabled
                        && failure.account_ref.as_ref().is_some_and(|reference| {
                            reference.origin == Some(crate::domain::AccountOrigin::BorrowedProxy)
                        })
                })
        );
        let (_, Json(operation)) = manual_refresh(
            State(state.clone()),
            security::owner(),
            ApiJson(RefreshRequest {
                providers: vec![provider],
                account_id: Some(account.id.clone()),
                force: true,
                include_owned: true,
                disabled_proxy_auth_files: vec![],
            }),
        )
        .await
        .unwrap_or_else(|_| panic!());
        assert_eq!(done(&state, &operation.id).await.status, "completed");
        let Json(scoped) = resolved_snapshot(State(state.clone()), security::owner())
            .await
            .unwrap_or_else(|_| panic!());
        assert!(
            scoped
                .accounts
                .iter()
                .any(|candidate| candidate.id == account.id)
        );
        assert_eq!(std::fs::read(auth.join("claude.json")).unwrap(), auth_bytes);
        assert_eq!(std::fs::read(config).unwrap(), config_bytes);
        std::fs::remove_dir_all(dir).unwrap();
    }
}

#[tokio::test]
async fn disabled_proxy_file_is_not_fetched_in_provider_or_account_scope() {
    use tokio::io::AsyncWriteExt;
    let (mut state, dir, _) = fixture().await;
    let auth = dir.join("proxy-auth");
    std::fs::create_dir(&auth).unwrap();
    let auth = auth.canonicalize().unwrap();
    let bytes = br#"{"type":"claude","access_token":"test-token"}"#;
    std::fs::write(auth.join("claude.json"), bytes).unwrap();
    let provider = Provider::Catalog("claude");
    let id = crate::cache::fingerprint(&["cli_proxy_auth_file", provider.id(), "claude.json"]);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let requests = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let count = requests.clone();
    let proxy = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            count.fetch_add(1, Ordering::SeqCst);
            let _ = stream
                .write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                .await;
        }
    });
    let writable = Arc::get_mut(&mut state).unwrap();
    writable.no_saved_accounts = false;
    writable.proxy_auth_directory = Some(auth.clone());
    writable.context.http = reqwest::Client::builder()
        .proxy(reqwest::Proxy::all(proxy).unwrap())
        .timeout(Duration::from_secs(1))
        .build()
        .unwrap();
    state.settings.write().await.values.enabled_providers = vec!["claude".into()];
    state
        .settings
        .write()
        .await
        .values
        .disabled_proxy_auth_files = vec!["claude.json".into()];
    refresh(&state, None).await.unwrap();
    assert_eq!(requests.load(Ordering::SeqCst), 0);
    // Seed cached usage so scoped exclusion must also remove an old result.
    *state.snapshot.write().await = Some((
        0,
        UsageReport {
            schema_version: 1,
            generated_at: state.context.clock.now(),
            providers: vec![],
            failures: vec![ProviderFailure {
                provider: ProviderId("claude".into()),
                account_ref: Some(crate::domain::AccountRef {
                    origin: Some(crate::domain::AccountOrigin::BorrowedProxy),
                    id: id.clone(),
                    label: "Work".into(),
                }),
                code: ProviderError::Authentication,
                message: "test".into(),
            }],
        },
    ));
    for account_id in [Some(id.clone()), None] {
        refresh(
            &state,
            Some(RefreshRequest {
                providers: vec![provider],
                account_id,
                force: true,
                include_owned: false,
                disabled_proxy_auth_files: vec![],
            }),
        )
        .await
        .unwrap();
        assert_eq!(requests.load(Ordering::SeqCst), 0);
        let snapshot = state.snapshot.read().await;
        let report = &snapshot.as_ref().unwrap().1;
        assert!(
            report
                .providers
                .iter()
                .all(|u| u.account_ref.as_ref().is_none_or(|r| r.id != id))
        );
        assert!(
            report
                .failures
                .iter()
                .all(|f| f.account_ref.as_ref().is_none_or(|r| r.id != id))
        );
    }
    state
        .settings
        .write()
        .await
        .values
        .disabled_proxy_auth_files
        .clear();
    refresh(
        &state,
        Some(RefreshRequest {
            providers: vec![provider],
            account_id: Some(id),
            force: true,
            include_owned: false,
            disabled_proxy_auth_files: vec![],
        }),
    )
    .await
    .unwrap();
    assert!(requests.load(Ordering::SeqCst) > 0);
    assert_eq!(std::fs::read(auth.join("claude.json")).unwrap(), bytes);
    server.abort();
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn account_scoped_refresh_requires_an_explicit_provider() {
    let (state, dir, id) = fixture().await;
    state
        .settings
        .write()
        .await
        .values
        .enabled_providers
        .push("amp".into());

    let result = manual_refresh(
        State(state),
        security::owner(),
        ApiJson(RefreshRequest {
            providers: vec![],
            account_id: Some(id),
            force: true,
            include_owned: true,
            disabled_proxy_auth_files: Vec::new(),
        }),
    )
    .await;

    assert!(matches!(
        result,
        Err(ApiError(StatusCode::BAD_REQUEST, "invalid_refresh_scope"))
    ));
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn account_scoped_refresh_rejects_duplicate_providers() {
    let (state, dir, id) = fixture().await;

    let result = manual_refresh(
        State(state),
        security::owner(),
        ApiJson(RefreshRequest {
            providers: vec![Provider::Amp, Provider::Amp],
            account_id: Some(id),
            force: true,
            include_owned: true,
            disabled_proxy_auth_files: Vec::new(),
        }),
    )
    .await;

    assert!(matches!(
        result,
        Err(ApiError(StatusCode::BAD_REQUEST, "invalid_refresh_scope"))
    ));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn disabled_provider_account_refresh_does_not_replace_the_scheduled_snapshot() {
    let existing = UsageReport {
        schema_version: 1,
        generated_at: time::OffsetDateTime::UNIX_EPOCH,
        providers: vec![],
        failures: vec![],
    };
    let mut snapshot = Some((0, existing));
    let report = UsageReport {
        schema_version: 1,
        generated_at: time::OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(1),
        providers: vec![],
        failures: vec![ProviderFailure {
            provider: ProviderId("amp".into()),
            account_ref: None,
            code: ProviderError::Unavailable,
            message: ProviderError::Unavailable.to_string(),
        }],
    };

    assert!(!merge_refresh_report(
        &mut snapshot,
        0,
        &[Provider::Amp],
        &[],
        Some(&std::collections::HashSet::from(["account-id".into()])),
        report,
    ));
    let retained = snapshot.unwrap().1;
    assert_eq!(retained.generated_at, time::OffsetDateTime::UNIX_EPOCH);
    assert!(retained.providers.is_empty());
    assert!(retained.failures.is_empty());
}

#[test]
fn first_scoped_refresh_seeds_the_snapshot() {
    let report = UsageReport {
        schema_version: 1,
        generated_at: time::OffsetDateTime::UNIX_EPOCH,
        providers: vec![],
        failures: vec![],
    };
    let mut snapshot = None;

    assert!(merge_refresh_report(
        &mut snapshot,
        0,
        &[Provider::Amp],
        &[Provider::Amp, Provider::Codex],
        Some(&std::collections::HashSet::from(["account-id".into()])),
        report,
    ));
    assert!(snapshot.is_some());
}

#[test]
fn scoped_refresh_replaces_snapshot_invalidated_by_oauth() {
    for account in [
        None,
        Some(std::collections::HashSet::from(["new-account".into()])),
    ] {
        let mut snapshot = Some((
            0,
            UsageReport {
                schema_version: 1,
                generated_at: time::OffsetDateTime::UNIX_EPOCH,
                providers: vec![],
                failures: vec![ProviderFailure {
                    provider: ProviderId("amp".into()),
                    account_ref: None,
                    code: ProviderError::Unavailable,
                    message: ProviderError::Unavailable.to_string(),
                }],
            },
        ));
        let report = UsageReport {
            schema_version: 1,
            generated_at: time::OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(1),
            providers: vec![],
            failures: vec![],
        };
        assert!(merge_refresh_report(
            &mut snapshot,
            1,
            &[Provider::Codex],
            &[Provider::Amp, Provider::Codex],
            account.as_ref(),
            report,
        ));
        let (generation, report) = snapshot.unwrap();
        assert_eq!(generation, 1);
        assert!(report.failures.is_empty());
        assert_eq!(
            report.generated_at,
            time::OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(1)
        );
    }
}

#[test]
fn full_refresh_initializes_snapshot_independent_of_provider_order() {
    let report = UsageReport {
        schema_version: 1,
        generated_at: time::OffsetDateTime::UNIX_EPOCH,
        providers: vec![],
        failures: vec![],
    };
    let mut snapshot = None;

    assert!(merge_refresh_report(
        &mut snapshot,
        0,
        &[Provider::Amp, Provider::Codex],
        &[Provider::Codex, Provider::Amp],
        None,
        report,
    ));
    assert!(snapshot.is_some());
}

#[tokio::test]
async fn account_scoped_refresh_reports_account_removed_before_collection() {
    let (mut state, dir, id) = fixture().await;
    Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
    let refresh_guard = state.refresh_lock.lock().await;
    let result = manual_refresh(
        State(state.clone()),
        security::owner(),
        ApiJson(RefreshRequest {
            providers: vec![Provider::Amp],
            account_id: Some(id.clone()),
            force: true,
            include_owned: true,
            disabled_proxy_auth_files: Vec::new(),
        }),
    )
    .await;
    let (_, Json(initial)) = match result {
        Ok(value) => value,
        Err(_) => panic!("account-scoped refresh was rejected"),
    };

    accounts::api::remove(state.vault.clone().unwrap(), id)
        .await
        .unwrap();
    drop(refresh_guard);

    let completed = done(&state, &initial.id).await;
    assert_eq!(completed.status, "failed");
    assert_eq!(completed.error, Some("account_not_found"));
    assert!(completed.result.is_none());
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn unscoped_refresh_still_requires_enabled_provider() {
    let (state, dir, _) = fixture().await;
    assert!(
        state
            .settings
            .read()
            .await
            .values
            .enabled_providers
            .is_empty()
    );

    let result = manual_refresh(
        State(state),
        security::owner(),
        ApiJson(RefreshRequest {
            providers: vec![Provider::Amp],
            account_id: None,
            force: true,
            include_owned: true,
            disabled_proxy_auth_files: Vec::new(),
        }),
    )
    .await;

    assert!(matches!(
        result,
        Err(ApiError(StatusCode::BAD_REQUEST, "invalid_refresh_scope"))
    ));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn grok_local_alias_runs_with_an_isolated_home() {
    let dir = std::env::temp_dir().join(accounts::random_string().unwrap());
    std::fs::create_dir(&dir).unwrap();
    for independent_token in [false, true] {
        let mut command = std::process::Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "server::tests::grok_local_alias_child",
                "--nocapture",
            ])
            .env("HOME", &dir)
            .env("QUOTIO_GROK_ALIAS_FIXTURE", &dir)
            .env_remove("GROK_OAUTH_TOKEN");
        if independent_token {
            command.env("GROK_OAUTH_TOKEN", "synthetic-independent-token");
        }
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn grok_local_alias_child() {
    let Ok(home) = std::env::var("QUOTIO_GROK_ALIAS_FIXTURE") else {
        return;
    };
    assert_eq!(std::env::var("HOME").unwrap(), home);
    assert!(std::path::Path::new(&home).starts_with(std::env::temp_dir()));
    let (mut state, dir, _) = fixture().await;
    Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
    state.settings.write().await.values.enabled_providers = vec!["grok".into()];
    // Deliberately absent: rejection must not resolve the native credential.
    let source = accounts::sources::GrokNativeReference {
        path: dir.join("missing-auth.json"),
        entry_key: "https://auth.x.ai::fixture".into(),
    };
    let vault = state.vault.as_ref().unwrap();
    let mut tx = vault.begin().unwrap();
    let id = tx
        .document
        .add(
            Provider::Catalog("grok"),
            "Native Grok",
            source.identity().unwrap(),
            Credential::GrokNative { source },
        )
        .unwrap();
    tx.document.patch(&id, None, None, Some(false)).unwrap();
    tx.commit().unwrap();
    let result =
        management::validate_refresh_account(&state, Provider::Catalog("grok"), "local").await;
    if std::env::var_os("GROK_OAUTH_TOKEN").is_some() {
        assert!(
            result.is_ok(),
            "independent environment token remains available"
        );
    } else {
        assert!(matches!(
            result,
            Err(ApiError(
                StatusCode::CONFLICT,
                "registered_source_requires_account_id"
            ))
        ));
        let result = manual_refresh(
            State(state.clone()),
            security::owner(),
            ApiJson(RefreshRequest {
                providers: vec![Provider::Catalog("grok")],
                account_id: Some("local".into()),
                force: true,
                include_owned: true,
                disabled_proxy_auth_files: Vec::new(),
            }),
        )
        .await;
        assert!(matches!(
            result,
            Err(ApiError(
                StatusCode::CONFLICT,
                "registered_source_requires_account_id"
            ))
        ));
        assert!(state.pending.lock().await.is_empty());
        assert!(state.jobs.lock().unwrap().is_empty());
    }
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn codex_source_rest_runs_with_an_isolated_home() {
    let dir = std::env::temp_dir().join(accounts::random_string().unwrap());
    std::fs::create_dir_all(dir.join(".codex")).unwrap();
    let original = br#"{"tokens":{"access_token":"synthetic-native-secret","account_id":"fixture-id","refresh_token":"synthetic-owner-refresh"}}"#;
    let path = dir.join(".codex/auth.json");
    std::fs::write(&path, original).unwrap();
    let native_fixtures = [
        (
            ".claude/.credentials.json",
            r#"{"claudeAiOauth":{"accessToken":"synthetic-claude-secret","refreshToken":"owner-refresh"}}"#,
        ),
        (
            ".config/github-copilot/apps.json",
            r#"{"github.com:fixture":{"oauth_token":"synthetic-copilot-secret"}}"#,
        ),
    ];
    for (relative, bytes) in native_fixtures {
        let path = dir.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, bytes).unwrap();
    }
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "server::tests::codex_source_rest_child",
            "--nocapture",
        ])
        .env("HOME", &dir)
        .env("QUOTIO_CODEX_SOURCE_REST_FIXTURE", &dir)
        .env_remove("CODEX_HOME")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(std::fs::read(&path).unwrap(), original);
    for (relative, bytes) in native_fixtures {
        assert_eq!(std::fs::read(dir.join(relative)).unwrap(), bytes.as_bytes());
    }
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn codex_source_rest_child() {
    let Ok(home) = std::env::var("QUOTIO_CODEX_SOURCE_REST_FIXTURE") else {
        return;
    };
    assert_eq!(std::env::var("HOME").unwrap(), home);
    assert!(std::path::Path::new(&home).starts_with(std::env::temp_dir()));
    let (mut state, dir, _) = fixture().await;
    Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
    state.settings.write().await.values.enabled_providers = vec!["codex".into()];
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let token = "synthetic-management-token-1234567890";
    let app = router(
        state.clone(),
        Arc::new(security::Policy::new(address, true, None, &[], Some(token.into())).unwrap()),
    );
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap();
    let base = format!("http://{address}");
    for input in [
        json!({"kind":"copilot_native","location":"proxy","entry_key":"github.com"}),
        json!({"kind":"copilot_native","location":"apps","entry_key":"github.com","path":"/tmp/untrusted"}),
        json!({"kind":"copilot_native","location":"apps","entry_key":"github.com","refresh_token":"fixture"}),
        json!({"kind":"claude_native","location":"desktop"}),
        json!({"kind":"claude_native","location":"code_file","path":"/tmp/untrusted"}),
        json!({"kind":"claude_native","location":"code_file","refresh_token":"fixture"}),
    ] {
        let response = client
            .post(format!("{base}/v2/sources"))
            .bearer_auth(token)
            .header("Idempotency-Key", "invalid-claude-source")
            .json(&input)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 400);
    }
    for input in [
        json!({"kind":"claude_native","location":"code_file"}),
        json!({"kind":"copilot_native","location":"apps","entry_key":"github.com:fixture"}),
    ] {
        let kind = input["kind"].as_str().unwrap();
        let request = || {
            client
                .post(format!("{base}/v2/sources"))
                .bearer_auth(token)
                .header("Idempotency-Key", kind)
                .json(&input)
        };
        let response = request().send().await.unwrap();
        assert_eq!(response.status(), 202);
        let operation: Value = response.json().await.unwrap();
        let completed =
            serde_json::to_value(done(&state, operation["id"].as_str().unwrap()).await).unwrap();
        assert_eq!(completed["status"], "completed", "{completed}");
        assert!(
            !completed.to_string().contains("synthetic-")
                && !completed.to_string().contains("owner-refresh")
        );
        let replay: Value = request().send().await.unwrap().json().await.unwrap();
        assert_eq!(operation["id"], replay["id"]);
    }
    let input = json!({"kind":"codex_native"});
    let unauth = client
        .post(format!("{base}/v2/sources"))
        .json(&input)
        .send()
        .await
        .unwrap();
    assert_eq!(unauth.status(), 401);
    let invalid = client
        .post(format!("{base}/v2/sources"))
        .bearer_auth(token)
        .header("Idempotency-Key", "bad-source")
        .json(&json!({"kind":"codex_native","path":"/tmp/untrusted"}))
        .send()
        .await
        .unwrap();
    assert_eq!(invalid.status(), 400);
    let request = || {
        client
            .post(format!("{base}/v2/sources"))
            .bearer_auth(token)
            .header("Idempotency-Key", "codex-source")
            .json(&input)
    };
    let response = request().send().await.unwrap();
    assert_eq!(response.status(), 202);
    let operation: Value = response.json().await.unwrap();
    let completed = done(&state, operation["id"].as_str().unwrap()).await;
    let completed = serde_json::to_value(completed).unwrap();
    assert_eq!(completed["status"], "completed", "{completed}");
    let id = completed["result"]["account_id"].as_str().unwrap();
    let replay: Value = request().send().await.unwrap().json().await.unwrap();
    assert_eq!(replay["id"], operation["id"]);
    for enabled in [false, true] {
        let response = client
            .patch(format!("{base}/v2/accounts/{id}"))
            .bearer_auth(token)
            .header("Idempotency-Key", format!("codex-enabled-{enabled}"))
            .json(&json!({"enabled":enabled,"user_label":"Native Codex fixture"}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 202);
        let op: Value = response.json().await.unwrap();
        assert_eq!(
            done(&state, op["id"].as_str().unwrap()).await.status,
            "completed"
        );
        let account: Value = client
            .get(format!("{base}/v2/accounts/{id}"))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let alias = client
            .post(format!("{base}/v2/refresh"))
            .bearer_auth(token)
            .json(&json!({"providers":["codex"],"account_id":"local","force":true}))
            .send()
            .await
            .unwrap();
        assert_eq!(alias.status(), 409);
        assert_eq!(account["enabled"], enabled);
        assert_eq!(account["sources"][0]["origin"], "borrowed_native");
        assert_eq!(account["sources"][0]["kind"], "codex_native");
        assert_eq!(account["display_name"], "Native Codex fixture");
        assert!(!account.to_string().contains("synthetic-native-secret"));
    }
    let document = state.vault.as_ref().unwrap().begin().unwrap();
    let bytes = serde_json::to_string(&document.document).unwrap();
    assert!(!bytes.contains("synthetic-native-secret"));
    assert!(!bytes.contains("synthetic-owner-refresh"));
    assert_eq!(document.document.version, 13);
    assert_eq!(
        document
            .document
            .accounts
            .iter()
            .find(|account| account.id == id)
            .unwrap()
            .naming
            .as_ref()
            .unwrap()
            .origin,
        crate::accounts::LabelOrigin::Generated
    );
    drop(document);
    let response: Value = client
        .delete(format!("{base}/v2/accounts/{id}"))
        .bearer_auth(token)
        .header("Idempotency-Key", "codex-remove")
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        done(&state, response["id"].as_str().unwrap()).await.status,
        "completed"
    );
    assert_eq!(
        client
            .get(format!("{base}/v2/accounts/{id}"))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    server.abort();
    for job in state.jobs.lock().unwrap().drain(..) {
        job.abort();
    }
    std::fs::remove_dir_all(dir).unwrap();
}
pub(super) fn key(value: &str) -> axum::http::HeaderMap {
    let mut headers = axum::http::HeaderMap::new();
    headers.insert("idempotency-key", value.parse().unwrap());
    headers
}
pub(super) async fn done(state: &ApiState, id: &str) -> Operation {
    for _ in 0..100 {
        let op = state.operations.lock().await.get(id).unwrap();
        if op.status != "running" {
            return op;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("operation timeout")
}
#[tokio::test]
async fn read_only_reset_credit_snapshots_expire_without_changing_quota() {
    use crate::providers::{Clock, ProviderAdapter};
    struct FixedClock(time::OffsetDateTime);
    impl Clock for FixedClock {
        fn now(&self) -> time::OffsetDateTime {
            self.0
        }
    }
    let (mut state, dir, _) = fixture().await;
    let now = time::OffsetDateTime::UNIX_EPOCH;
    let inner = Arc::get_mut(&mut state).unwrap();
    inner.manage = false;
    inner.context.clock = Arc::new(FixedClock(now));
    let mut usage = crate::providers::mock::MockProvider
        .fetch(&state.context)
        .await
        .unwrap();
    usage.provider = ProviderId("codex".into());
    for window in &mut usage.windows {
        window.fetched_at = now;
    }
    usage.reset_credits = Some(crate::domain::ResetCredits {
        available_count: 2,
        earliest_expires_at: Some(now + time::Duration::seconds(1)),
        fetched_at: now,
        source: "codex_app_server".into(),
    });
    *state.snapshot.write().await = Some((
        0,
        UsageReport {
            schema_version: 1,
            generated_at: now,
            providers: vec![usage],
            failures: vec![],
        },
    ));
    for (seconds, present) in [(0, true), (1, false)] {
        Arc::get_mut(&mut state).unwrap().context.clock =
            Arc::new(FixedClock(now + time::Duration::seconds(seconds)));
        let Json(value) = resolved_snapshot(State(state.clone()), security::owner())
            .await
            .unwrap_or_else(|_| panic!());
        assert_eq!(value.usage[0].reset_credits.is_some(), present);
        assert_eq!(value.usage[0].metrics.len(), 3);
        assert_eq!(value.generated_at, now + time::Duration::seconds(seconds));
    }
    // Read serialization does not mutate the underlying observation.
    assert!(
        state.snapshot.read().await.as_ref().unwrap().1.providers[0]
            .reset_credits
            .is_some()
    );
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn antigravity_owned_intake_is_explicit_and_idempotent() {
    let (state, dir, _) = fixture().await;
    let body = json!({"kind":"antigravity_owned","label":"Owned Antigravity","access_token":"synthetic-antigravity-access","refresh_token":"synthetic-antigravity-refresh","expires_at":0,"client_id":"1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com","client_secret":"synthetic-client-secret"});
    let (_, Json(op)) = management::resolved_create(
        State(state.clone()),
        security::owner(),
        key("antigravity-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let (_, Json(retry)) = management::resolved_create(
        State(state.clone()),
        security::owner(),
        key("antigravity-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(retry.id, op.id);
    let Json(account_list) = management::resolved_accounts(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    let accounts = serde_json::to_value(account_list).unwrap();
    assert!(!accounts.to_string().contains("synthetic-"));
    let account = accounts["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["provider_id"] == "antigravity")
        .unwrap();
    assert_eq!(account["sources"][0]["origin"], "owned");
    for field in ["path", "endpoint", "provider", "owned"] {
        let mut invalid = body.clone();
        invalid[field] = "fixture".into();
        assert!(matches!(
            management::resolved_create(
                State(state.clone()),
                security::owner(),
                key("invalid-antigravity"),
                ApiJson(invalid)
            )
            .await,
            Err(ApiError(StatusCode::BAD_REQUEST, _))
        ));
    }
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn kiro_owned_intake_is_explicit_and_idempotent() {
    let (state, dir, _) = fixture().await;
    let body = json!({"kind":"kiro_owned","label":"Owned Kiro","access_token":"synthetic-kiro-access","refresh_token":"synthetic-kiro-refresh","expires_at":0,"authMethod":"Social","region":"us-east-1"});
    let (_, Json(op)) = management::resolved_create(
        State(state.clone()),
        security::owner(),
        key("kiro-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let (_, Json(retry)) = management::resolved_create(
        State(state.clone()),
        security::owner(),
        key("kiro-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(retry.id, op.id);
    let Json(account_list) = management::resolved_accounts(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    let accounts = serde_json::to_value(account_list).unwrap();
    assert!(!accounts.to_string().contains("synthetic-kiro"));
    let account = accounts["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["provider_id"] == "kiro")
        .unwrap();
    assert_eq!(account["sources"][0]["origin"], "owned");
    for field in ["path", "endpoint", "provider", "owned", "machine"] {
        let mut invalid = body.clone();
        invalid[field] = "fixture".into();
        assert!(matches!(
            management::resolved_create(
                State(state.clone()),
                security::owner(),
                key("invalid-kiro"),
                ApiJson(invalid)
            )
            .await,
            Err(ApiError(StatusCode::BAD_REQUEST, _))
        ));
    }
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn factory_owned_intake_is_explicit_and_idempotent() {
    let (state, dir, _) = fixture().await;
    let body = json!({"kind":"factory_owned","label":"Owned Factory","access_token":"synthetic-factory-access","refresh_token":"synthetic-factory-refresh","organization_id":"org"});
    let (_, Json(op)) = management::resolved_create(
        State(state.clone()),
        security::owner(),
        key("factory-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let (_, Json(retry)) = management::resolved_create(
        State(state.clone()),
        security::owner(),
        key("factory-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(retry.id, op.id);
    let Json(account_list) = management::resolved_accounts(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    let accounts = serde_json::to_value(account_list).unwrap();
    assert!(!accounts.to_string().contains("synthetic-factory"));
    let account = accounts["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["provider_id"] == "factory")
        .unwrap();
    assert_eq!(account["sources"][0]["origin"], "owned");
    for field in [
        "path",
        "owned",
        "provider",
        "client_id",
        "expires_at",
        "region",
        "endpoint",
    ] {
        let mut invalid = body.clone();
        invalid[field] = "fixture".into();
        assert!(matches!(
            management::resolved_create(
                State(state.clone()),
                security::owner(),
                key("invalid-factory"),
                ApiJson(invalid)
            )
            .await,
            Err(ApiError(StatusCode::BAD_REQUEST, _))
        ));
    }
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn grok_owned_intake_is_explicit_secret_free_and_idempotent() {
    let (state, dir, _) = fixture().await;
    let body = json!({"kind":"grok_owned","label":"Owned Grok","access_token":"synthetic-grok-access","refresh_token":"synthetic-grok-refresh","expires_at":0});
    let (_, Json(op)) = management::resolved_create(
        State(state.clone()),
        security::owner(),
        key("grok-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let (_, Json(retry)) = management::resolved_create(
        State(state.clone()),
        security::owner(),
        key("grok-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(retry.id, op.id);
    let Json(account_list) = management::resolved_accounts(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    let accounts = serde_json::to_value(account_list).unwrap();
    assert!(!accounts.to_string().contains("synthetic-grok"));
    let rows = accounts["accounts"].as_array().unwrap();
    let account = rows.iter().find(|a| a["provider_id"] == "grok").unwrap();
    assert_eq!(account["sources"][0]["origin"], "owned");
    let id = account["id"].as_str().unwrap().to_owned();
    for field in ["path", "entry_key", "owned", "provider"] {
        let mut invalid = body.clone();
        invalid[field] = "fixture".into();
        assert!(matches!(
            management::resolved_create(
                State(state.clone()),
                security::owner(),
                key("invalid-grok"),
                ApiJson(invalid)
            )
            .await,
            Err(ApiError(StatusCode::BAD_REQUEST, _))
        ));
    }
    assert!(matches!(management::reference(State(state.clone()), security::owner(), key("invalid-source"), ApiJson(json!({"kind":"grok_native","entry_key":"https://auth.x.ai::fixture","path":"/tmp/auth.json"}))).await, Err(ApiError(StatusCode::BAD_REQUEST, _))));
    let (_, Json(disable)) = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(id.clone()),
        key("disable-grok"),
        ApiJson(json!({"enabled":false})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &disable.id).await.status, "completed");
    let (_, Json(remove)) = management::resolved_remove(
        State(state.clone()),
        security::owner(),
        Path(id),
        key("remove-grok"),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &remove.id).await.status, "completed");
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn account_edits_preserve_unrelated_quota_and_do_not_promote_invalidated_reports() {
    let (mut state, dir, id) = fixture().await;
    Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
    state.restore_pending.store(false, Ordering::SeqCst);
    let mut other = Provider::Mock
        .adapter()
        .fetch(&state.context)
        .await
        .unwrap();
    for window in &mut other.windows {
        window.fetched_at = state.context.clock.now();
    }
    let mut owned = other.clone();
    owned.provider = ProviderId("amp".into());
    owned.account.id = "fake-identity".into();
    owned.account_ref = Some(crate::domain::AccountRef {
        id: id.clone(),
        label: "old label".into(),
        origin: Some(crate::domain::AccountOrigin::Owned),
    });
    *state.snapshot.write().await = Some((
        0,
        UsageReport {
            schema_version: 1,
            generated_at: state.context.clock.now(),
            providers: vec![owned, other],
            failures: vec![],
        },
    ));
    let (_, Json(op)) = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(id.clone()),
        key("rename-preserves-quota"),
        ApiJson(json!({"user_label":"Renamed"})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    assert!(state.restore_pending.load(Ordering::SeqCst));
    state.restore_pending.store(false, Ordering::SeqCst);
    let Json(frame) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    assert_eq!(
        frame
            .accounts
            .iter()
            .find(|a| a.provider_id == "amp")
            .unwrap()
            .display_name,
        "Renamed"
    );
    assert_eq!(
        frame
            .usage
            .iter()
            .filter(|u| u.freshness == crate::contract::Freshness::Fresh)
            .count(),
        2
    );
    let (_, Json(op)) = management::source_patch(
        State(state.clone()),
        security::owner(),
        Path(id.clone()),
        key("disable-one-source"),
        ApiJson(json!({"enabled":false})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    assert!(state.restore_pending.load(Ordering::SeqCst));
    state.restore_pending.store(false, Ordering::SeqCst);
    let snapshot = state.snapshot.read().await;
    let (generation, report) = snapshot.as_ref().unwrap();
    assert_eq!(*generation, state.generation.load(Ordering::SeqCst));
    assert_eq!(report.providers.len(), 1);
    assert_eq!(report.providers[0].provider.0, "mock");
    drop(snapshot);
    let (_, Json(op)) = management::resolved_remove(
        State(state.clone()),
        security::owner(),
        Path(id),
        key("remove-one-account"),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    assert!(state.restore_pending.load(Ordering::SeqCst));
    state.restore_pending.store(false, Ordering::SeqCst);
    let Json(frame) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    assert_eq!(frame.accounts.len(), 1);
    assert_eq!(frame.accounts[0].provider_id, "mock");
    assert_eq!(frame.usage[0].freshness, crate::contract::Freshness::Fresh);
    state.generation.fetch_add(1, Ordering::SeqCst);
    state.invalidate_sources(&[]).await;
    assert!(state.snapshot.read().await.is_none());
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn account_http_services_are_secret_free_idempotent_and_fenced() {
    let (state, dir, id) = fixture().await;
    let Json(account_list) = management::resolved_accounts(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    let accounts = serde_json::to_value(account_list).unwrap();
    assert!(!accounts.to_string().contains("synthetic-vault-secret"));
    assert!(!accounts.to_string().contains("synthetic-vault-secret"));
    let body = json!({"user_label":"new label","active":true});
    let (_, Json(op)) = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(id.clone()),
        key("change-1"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    assert_eq!(state.generation.load(Ordering::SeqCst), 1);
    let (_, Json(retry)) = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(id.clone()),
        key("change-1"),
        ApiJson(body),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(op.id, retry.id);
    assert!(matches!(
        management::resolved_patch(
            State(state.clone()),
            security::owner(),
            Path(id.clone()),
            key("change-1"),
            ApiJson(json!({"user_label":"different"}))
        )
        .await,
        Err(ApiError(StatusCode::CONFLICT, _))
    ));
    let (_, Json(invalid)) = management::resolved_create(
        State(state.clone()),
        security::owner(),
        key("create-1"),
        ApiJson(json!({"provider":"amp","api_key":""})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(
        done(&state, &invalid.id).await.error,
        Some("invalid_credential")
    );
    let (_, Json(remove)) = management::resolved_remove(
        State(state.clone()),
        security::owner(),
        Path(id.clone()),
        key("remove-1"),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &remove.id).await.status, "completed");
    assert!(matches!(
        management::resolved_account(State(state.clone()), Path(id), security::owner()).await,
        Err(ApiError(StatusCode::NOT_FOUND, _))
    ));
    // A late pre-delete refresh cannot be read even if its report arrives afterwards.
    *state.snapshot.write().await = Some((
        0,
        UsageReport {
            schema_version: 1,
            generated_at: state.context.clock.now(),
            providers: vec![],
            failures: vec![],
        },
    ));
    let Json(snapshot) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    assert!(snapshot.usage.is_empty());
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn external_config_conflict_recovers_and_refresh_requests_coalesce() {
    let (state, dir, _) = fixture().await;
    let initial = state.settings.read().await.revision.clone();
    std::fs::write(dir.join("config.toml"), "enabled_providers = [\"mock\"]\n").unwrap();
    let Json(view) = settings(State(state.clone()))
        .await
        .unwrap_or_else(|_| panic!());
    assert_ne!(initial, view.revision);
    assert_eq!(
        state.settings.read().await.values.enabled_providers,
        vec!["mock"]
    );
    let refresh_guard = state.refresh_lock.lock().await;
    let request = || RefreshRequest {
        providers: vec![Provider::Mock],
        account_id: None,
        force: true,
        include_owned: true,
        disabled_proxy_auth_files: Vec::new(),
    };
    let (_, Json(first)) =
        manual_refresh(State(state.clone()), security::owner(), ApiJson(request()))
            .await
            .unwrap_or_else(|_| panic!());
    let (_, Json(second)) =
        manual_refresh(State(state.clone()), security::owner(), ApiJson(request()))
            .await
            .unwrap_or_else(|_| panic!());
    assert_eq!(first.id, second.id);
    // Change enabled scope while a queued refresh waits; it must not publish old scope.
    state
        .settings
        .write()
        .await
        .values
        .enabled_providers
        .clear();
    state.invalidate().await;
    drop(refresh_guard);
    assert_eq!(
        done(&state, &first.id).await.error,
        Some("refresh_scope_changed")
    );
    assert!(state.snapshot.read().await.is_none());
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn blocked_mutation_guard_returns_bounded_errors() {
    let (state, dir, _) = fixture().await;
    let held = state.commit_guard.lock().await;
    tokio::time::pause();
    assert!(matches!(
        resolved_snapshot(State(state.clone()), security::owner()).await,
        Err(ApiError(StatusCode::SERVICE_UNAVAILABLE, _))
    ));
    assert!(matches!(
        settings(State(state.clone())).await,
        Err(ApiError(StatusCode::CONFLICT, "settings_busy"))
    ));
    tokio::time::resume();
    drop(held);
    assert!(settings(State(state)).await.is_ok());
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn manual_refresh_preserves_the_schedulers_deadline() {
    let (state, dir, _) = fixture().await;
    state.settings.write().await.values.enabled_providers = vec!["mock".into()];
    state.status.lock().await.next_refresh_at = Some("scheduled-deadline".into());
    refresh(
        &state,
        Some(RefreshRequest {
            providers: vec![Provider::Mock],
            account_id: None,
            force: false,
            include_owned: true,
            disabled_proxy_auth_files: Vec::new(),
        }),
    )
    .await
    .unwrap();
    assert_eq!(
        state.status.lock().await.next_refresh_at.as_deref(),
        Some("scheduled-deadline")
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn local_mode_refresh_excludes_owned_accounts() {
    let (mut state, dir, owned_id) = fixture().await;
    Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
    state.settings.write().await.values.enabled_providers = vec!["amp".into()];
    refresh(
        &state,
        Some(RefreshRequest {
            providers: vec![Provider::Amp],
            account_id: None,
            force: true,
            include_owned: false,
            disabled_proxy_auth_files: Vec::new(),
        }),
    )
    .await
    .unwrap();
    let snapshot = state.snapshot.read().await;
    let report = &snapshot.as_ref().unwrap().1;
    assert!(report.providers.iter().all(|usage| {
        usage.account_ref.as_ref().is_none_or(|reference| {
            reference.origin != Some(crate::domain::AccountOrigin::Owned)
                && reference.id != owned_id
        })
    }));
    assert!(report.failures.iter().all(|failure| {
        failure.account_ref.as_ref().is_none_or(|reference| {
            reference.origin != Some(crate::domain::AccountOrigin::Owned)
                && reference.id != owned_id
        })
    }));
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn local_mode_warp_refresh_only_collects_mirrors() {
    let (mut state, dir, _) = fixture().await;
    let writable = Arc::get_mut(&mut state).unwrap();
    writable.no_saved_accounts = false;
    // Fail locally rather than contacting a real provider with fixture credentials.
    writable.context.http = reqwest::Client::builder()
        .proxy(reqwest::Proxy::all("http://127.0.0.1:1").unwrap())
        .timeout(Duration::from_secs(1))
        .build()
        .unwrap();
    let provider = Provider::Catalog("warp");
    let mut ids = Vec::new();
    for label in ["Monitor", "__quotio_local_warp__:Local"] {
        ids.push(
            accounts::service::add(
                state.vault.clone().unwrap(),
                provider,
                label.into(),
                Credential::ApiKey {
                    token: "test-token".into(),
                    region: None,
                    organization: None,
                },
                label.into(),
            )
            .await
            .unwrap(),
        );
    }
    state.settings.write().await.values.enabled_providers = vec!["warp".into()];
    for include_owned in [false, true] {
        refresh(
            &state,
            Some(RefreshRequest {
                providers: vec![provider],
                account_id: None,
                force: true,
                include_owned,
                disabled_proxy_auth_files: Vec::new(),
            }),
        )
        .await
        .unwrap();
        let snapshot = state.snapshot.read().await;
        let report = &snapshot.as_ref().unwrap().1;
        let collected: std::collections::HashSet<_> = report
            .providers
            .iter()
            .filter_map(|usage| usage.account_ref.as_ref().map(|a| a.id.clone()))
            .chain(
                report
                    .failures
                    .iter()
                    .filter_map(|failure| failure.account_ref.as_ref().map(|a| a.id.clone())),
            )
            .collect();
        let expected = if include_owned {
            ids.clone()
        } else {
            vec![ids[1].clone()]
        };
        assert_eq!(collected, expected.into_iter().collect());
    }
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn scheduler_clears_deadline_on_timer_and_config_wake() {
    let (state, dir, _) = fixture().await;
    state.settings.write().await.values.refresh_interval = 60;
    tokio::time::pause();
    for wake in [false, true] {
        let worker = state.clone();
        let task = tokio::spawn(async move { wait_for_next_refresh(&worker).await });
        tokio::task::yield_now().await;
        assert!(state.status.lock().await.next_refresh_at.is_some());
        if wake {
            state.wake.notify_one();
        } else {
            tokio::time::advance(Duration::from_secs(60)).await;
        }
        task.await.unwrap();
        assert!(state.status.lock().await.next_refresh_at.is_none());
    }
    tokio::time::resume();
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn zero_refresh_interval_waits_without_scheduling_a_deadline() {
    let (state, dir, _) = fixture().await;
    state.settings.write().await.values.refresh_interval = 0;
    let worker = state.clone();
    let task = tokio::spawn(async move { wait_for_next_refresh(&worker).await });
    tokio::task::yield_now().await;
    assert!(state.status.lock().await.next_refresh_at.is_none());
    assert!(!task.is_finished());
    state.wake.notify_one();
    task.await.unwrap();
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn native_authorization_retry_uses_its_receipt_before_reading_another_keychain_item() {
    let (state, dir, account_id) = fixture().await;
    let body =
        json!({"kind":"copilot_native","location":"gh_keychain","entry_key":"selected-user"});
    let fingerprint =
        crate::cache::fingerprint(&["native_source_authorize", "", &body.to_string()]);
    let intent =
        accounts::service::MutationIntent::new("finished-authorization", fingerprint).unwrap();
    let original_id = account_id.clone();
    accounts::service::commit_once(state.vault.clone().unwrap(), intent, move |_| {
        Ok(original_id)
    })
    .await
    .unwrap();
    let (_, Json(operation)) = management::authorize(
        State(state.clone()),
        security::owner(),
        key("finished-authorization"),
        ApiJson(body),
    )
    .await
    .unwrap_or_else(|_| panic!());
    let completed = done(&state, &operation.id).await;
    assert_eq!(completed.status, "completed");
    assert_eq!(completed.result.unwrap()["account_id"], account_id);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn account_retry_survives_loss_of_in_memory_operations() {
    let (state, dir, id) = fixture().await;
    let body = json!({"user_label":"first change"});
    let (_, Json(first)) = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(id.clone()),
        key("durable-key"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &first.id).await.status, "completed");
    let (_, Json(later)) = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(id.clone()),
        key("later-name"),
        ApiJson(json!({"user_label":"later change"})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &later.id).await.status, "completed");
    *state.operations.lock().await = Operations::default();
    let (_, Json(retry)) = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(id.clone()),
        key("durable-key"),
        ApiJson(body),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_ne!(first.id, retry.id);
    assert_eq!(done(&state, &retry.id).await.status, "completed");
    let Json(account) =
        management::resolved_account(State(state.clone()), Path(id.clone()), security::owner())
            .await
            .unwrap_or_else(|_| panic!());
    assert_eq!(account.display_name, "later change");
    *state.operations.lock().await = Operations::default();
    let conflict = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(id),
        key("durable-key"),
        ApiJson(json!({"user_label":"different intent"})),
    )
    .await
    .err()
    .unwrap();
    assert_eq!(conflict.0, StatusCode::CONFLICT);
    assert_eq!(conflict.1, "idempotency_conflict");
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn legacy_migration_preserves_disabled_credentials_and_survives_restart() {
    let (state, dir, _) = fixture().await;
    for provider in [
        "claude",
        "codex",
        "copilot",
        "kiro",
        "openrouter",
        "factory",
        "warp",
        "amp",
        "zai",
        "clinepass",
        "antigravity",
    ] {
        let oauth = matches!(provider, "claude" | "codex" | "kiro" | "antigravity");
        let extra = match provider {
            "kiro" => {
                json!({"authMethod":"IdC", "clientId":"test-client", "clientSecret":"test-client-secret", "region":"us-east-1"})
            }
            "antigravity" => {
                json!({"clientId":"1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com", "clientSecret":"test-client-secret"})
            }
            _ => json!({}),
        };
        let body = json!({"legacy_id":format!("old-{provider}"), "provider":provider, "label":format!("Legacy {provider}"), "enabled":false,
            "credential":{"access_token":"synthetic-old-access", "refresh_token":oauth.then_some("synthetic-old-refresh"),
                "id_token":(provider == "codex").then_some("synthetic-id-token"), "account_id":"old-user", "expires_at":0, "extra":extra}});
        let key_value = format!("migrate-{provider}");
        let (_, Json(op)) = management::migrate(
            State(state.clone()),
            security::owner(),
            key(&key_value),
            ApiJson(body.clone()),
        )
        .await
        .unwrap_or_else(|_| panic!("intake {provider}"));
        let completed = done(&state, &op.id).await;
        assert_eq!(
            completed.status, "completed",
            "{provider}: {:?}",
            completed.error
        );
        let id = completed.result.unwrap()["account_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let vault = state.vault.clone().unwrap();
        let mut tx = vault.begin().unwrap();
        let account = tx
            .document
            .accounts
            .iter_mut()
            .find(|a| a.id == id)
            .unwrap();
        assert!(!account.enabled);
        // Simulate a later refresh/change: replay must not replace current credentials.
        if let Credential::ClaudeOAuth { access_token, .. } = &mut account.credential {
            *access_token = "rotated-access".into();
        }
        tx.commit().unwrap();
        *state.operations.lock().await = Operations::default();
        let (_, Json(retry)) = management::migrate(
            State(state.clone()),
            security::owner(),
            key(&key_value),
            ApiJson(body),
        )
        .await
        .unwrap_or_else(|_| panic!());
        let repeated = done(&state, &retry.id).await;
        assert_eq!(repeated.result.unwrap()["account_id"], id);
        let tx = vault.begin().unwrap();
        assert_eq!(
            tx.document
                .accounts
                .iter()
                .filter(|a| a.provider.id() == provider && a.label.starts_with("Legacy"))
                .count(),
            1
        );
        if provider == "claude" {
            assert!(
                matches!(&tx.document.accounts.iter().find(|a| a.id == id).unwrap().credential, Credential::ClaudeOAuth { access_token, .. } if access_token == "rotated-access")
            );
        }
        assert!(
            !serde_json::to_string(&repeated.error)
                .unwrap()
                .contains("synthetic")
        );
    }
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn legacy_migration_rejects_invalid_and_conflicting_imports() {
    let (state, dir, _) = fixture().await;
    for (name, body) in [
        (
            "missing-refresh",
            json!({"legacy_id":"old", "provider":"claude", "label":"Work", "enabled":true,"credential":{"access_token":"synthetic"}}),
        ),
        (
            "duplicate-label",
            json!({"legacy_id":"old", "provider":"amp", "label":"old label", "enabled":true,"credential":{"access_token":"synthetic"}}),
        ),
    ] {
        let (_, Json(op)) = management::migrate(
            State(state.clone()),
            security::owner(),
            key(name),
            ApiJson(body),
        )
        .await
        .unwrap_or_else(|_| panic!());
        assert_eq!(done(&state, &op.id).await.status, "failed");
    }
    assert_eq!(
        state
            .vault
            .as_ref()
            .unwrap()
            .begin()
            .unwrap()
            .document
            .accounts
            .len(),
        1
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn resolved_account_read_contract_is_automatic_shared_and_durable() {
    let (state, dir, _) = fixture().await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let token = "fixture-resolved-account-token-123456";
    let app = router(
        state.clone(),
        Arc::new(security::Policy::new(address, true, None, &[], Some(token.into())).unwrap()),
    );
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap();
    let base = format!("http://{address}");
    assert_eq!(
        client
            .get(format!("{base}/v2/snapshot"))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    let snapshot: Value = client
        .get(format!("{base}/v2/snapshot"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let document: Value = serde_json::from_str(include_str!("../../docs/openapi.json")).unwrap();
    jsonschema::draft202012::new(
        &json!({"$ref":"#/components/schemas/V2Snapshot", "components":document["components"]}),
    )
    .unwrap()
    .validate(&snapshot)
    .unwrap();
    assert_eq!(
        client
            .get(format!("{base}/v2/accounts"))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert!(
        state
            .vault
            .as_ref()
            .unwrap()
            .begin()
            .unwrap()
            .document
            .resolved
            .is_none()
    );
    let actual: Value = client
        .get(format!("{base}/v2/accounts"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let mut expected = crate::accounts::api::resolved_list(state.vault.clone().unwrap())
        .await
        .unwrap();
    state.restrict_host(&mut expected.host, &security::owner().0);
    for account in &mut expected.accounts {
        state.restrict_account(account, &security::owner().0);
    }
    assert_eq!(actual, serde_json::to_value(&expected).unwrap());
    assert_eq!(actual["accounts"][0]["display_name"], "old label");
    assert!(!actual.to_string().contains("synthetic-vault-secret"));
    let schema: Value = serde_json::from_str(include_str!("../../docs/openapi.json")).unwrap();
    jsonschema::draft202012::new(
        &json!({"$ref":"#/components/schemas/V2AccountList", "components":schema["components"]}),
    )
    .unwrap()
    .validate(&actual)
    .unwrap();
    *state.operations.lock().await = Operations::default();
    let after = crate::accounts::api::resolved_list(state.vault.clone().unwrap())
        .await
        .unwrap();
    assert_eq!(after.revision, expected.revision);
    assert_eq!(after.host.id, expected.host.id);
    let create_body = json!({"kind":"kiro_owned","label":"Created through v2","access_token":"synthetic-kiro-access","refresh_token":"synthetic-kiro-refresh","expires_at":0,"authMethod":"Social","region":"us-east-1"});
    let created = client
        .post(format!("{base}/v2/accounts"))
        .bearer_auth(token)
        .header("Idempotency-Key", "create-v2")
        .json(&create_body)
        .send()
        .await
        .unwrap();
    assert_eq!(created.status(), 202);
    let created: Value = created.json().await.unwrap();
    let created = done(&state, created["id"].as_str().unwrap()).await;
    assert_eq!(created.status, "completed");
    let id = created.result.unwrap()["account_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let response: Value = client
        .get(format!("{base}/v2/accounts/{id}"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(response["display_name"], "Created through v2");
    assert!(!response.to_string().contains("synthetic-kiro"));
    let rename = client
        .patch(format!("{base}/v2/accounts/{id}"))
        .bearer_auth(token)
        .header("Idempotency-Key", "rename-v2")
        .json(&json!({"user_label":"Renamed"}))
        .send()
        .await
        .unwrap();
    assert_eq!(rename.status(), 202);
    let op: Value = rename.json().await.unwrap();
    assert_eq!(
        done(&state, op["id"].as_str().unwrap()).await.status,
        "completed"
    );
    let response: Value = client
        .get(format!("{base}/v2/accounts/{id}"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(response["display_name"], "Renamed");
    let deleted = client
        .delete(format!("{base}/v2/accounts/{id}"))
        .bearer_auth(token)
        .header("Idempotency-Key", "delete-v2")
        .send()
        .await
        .unwrap();
    assert_eq!(deleted.status(), 202);
    let op: Value = deleted.json().await.unwrap();
    assert_eq!(
        done(&state, op["id"].as_str().unwrap()).await.status,
        "completed"
    );
    assert_eq!(
        client
            .get(format!("{base}/v2/accounts/{id}"))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    server.abort();
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn logical_account_and_source_crud_have_distinct_atomic_scopes() {
    let (state, dir, first) = fixture().await;
    let vault = state.vault.clone().unwrap();
    let (second, unrelated) = {
        let mut tx = vault.begin().unwrap();
        let credential = || accounts::Credential::ApiKey {
            token: "fixture-extra-key".into(),
            region: None,
            organization: None,
        };
        let second = tx
            .document
            .add(
                Provider::Amp,
                "Second source",
                "second".into(),
                credential(),
            )
            .unwrap();
        let unrelated = tx
            .document
            .add(Provider::Amp, "Unrelated", "unrelated".into(), credential())
            .unwrap();
        tx.document.enable_resolved_accounts().unwrap();
        let registry = tx.document.resolved.as_mut().unwrap();
        let proof = crate::domain::VerifiedIdentity {
            subject: "one-user".into(),
            tenant: Some("team".into()),
        };
        registry.observe(&first, &proof).unwrap();
        registry.observe(&second, &proof).unwrap();
        tx.commit().unwrap();
        (second, unrelated)
    };
    let (_, Json(invalid)) = management::source_patch(
        State(state.clone()),
        security::owner(),
        Path(second.clone()),
        key("invalid-source-key"),
        ApiJson(json!({"api_key":"", "enabled":false})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(
        done(&state, &invalid.id).await.error,
        Some("invalid_credential")
    );
    assert!(
        accounts::service::get(vault.clone(), second.clone())
            .await
            .unwrap()
            .enabled()
    );
    let (_, Json(op)) = management::source_patch(
        State(state.clone()),
        security::owner(),
        Path(second.clone()),
        key("disable-source"),
        ApiJson(json!({"enabled":false})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let view = accounts::api::resolved_get(vault.clone(), first.clone())
        .await
        .unwrap();
    assert!(view.enabled);
    assert_eq!(
        view.sources.iter().filter(|source| source.enabled).count(),
        1
    );
    let patch = json!({"user_label":"Team account", "enabled":false});
    let (_, Json(op)) = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(second.clone()),
        key("edit-group"),
        ApiJson(patch.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let view = accounts::api::resolved_get(vault.clone(), first.clone())
        .await
        .unwrap();
    assert_eq!(view.display_name, "Team account");
    assert!(!view.enabled);
    assert!(view.sources.iter().all(|source| !source.enabled));
    assert!(
        accounts::api::resolved_get(vault.clone(), unrelated.clone())
            .await
            .unwrap()
            .enabled
    );
    assert!(
        view.actions
            .iter()
            .any(|action| action.kind == "select" && !action.available)
    );
    let (_, Json(invalid)) = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(first.clone()),
        key("invalid-selection"),
        ApiJson(json!({"user_label":"Must not persist", "enabled":false, "active":true})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(
        done(&state, &invalid.id).await.error,
        Some("source_disabled")
    );
    let unchanged = accounts::api::resolved_get(vault.clone(), first.clone())
        .await
        .unwrap();
    assert_eq!(unchanged.display_name, "Team account");
    assert!(!unchanged.enabled);
    let (_, Json(retry)) = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(second.clone()),
        key("edit-group"),
        ApiJson(patch),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(retry.id, op.id);
    assert!(matches!(
        management::resolved_patch(
            State(state.clone()),
            security::owner(),
            Path(second.clone()),
            key("edit-group"),
            ApiJson(json!({"enabled":true}))
        )
        .await,
        Err(ApiError(StatusCode::CONFLICT, _))
    ));
    let (_, Json(op)) = management::source_remove(
        State(state.clone()),
        security::owner(),
        Path(first.clone()),
        key("unlink-source"),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    assert_eq!(
        accounts::api::resolved_get(vault.clone(), first.clone())
            .await
            .unwrap()
            .display_name,
        "Team account"
    );
    assert!(
        management::validate_refresh_account(&state, Provider::Amp, &first)
            .await
            .is_ok()
    );
    let (_, Json(op)) = management::resolved_patch(
        State(state.clone()),
        security::owner(),
        Path(first.clone()),
        key("reset-name"),
        ApiJson(json!({"user_label":null, "enabled":true, "active":true})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let view = accounts::api::resolved_get(vault.clone(), first.clone())
        .await
        .unwrap();
    assert_eq!(view.user_label, None);
    assert_eq!(view.display_name, "amp account");
    assert!(view.active);
    let observed = "provider-name".repeat(10);
    {
        let mut tx = vault.begin().unwrap();
        let source = tx
            .document
            .accounts
            .iter_mut()
            .find(|account| account.id == second)
            .unwrap();
        assert_eq!(
            source.naming.as_ref().unwrap().origin,
            accounts::LabelOrigin::Generated
        );
        assert!(source.observe_name(&observed).unwrap());
        assert!(source.observe_name(&"x".repeat(513)).is_err());
        tx.commit().unwrap();
    }
    let renamed = accounts::api::resolved_get(vault.clone(), first.clone())
        .await
        .unwrap();
    assert_eq!(renamed.display_name, observed);
    assert_eq!(renamed.user_label, None);
    assert!(matches!(
        management::resolved_patch(
            State(state.clone()),
            security::owner(),
            Path(first.clone()),
            key("invalid-null"),
            ApiJson(json!({"enabled":null}))
        )
        .await,
        Err(ApiError(StatusCode::BAD_REQUEST, _))
    ));
    let (_, Json(op)) = management::resolved_remove(
        State(state.clone()),
        security::owner(),
        Path(first.clone()),
        key("remove-group"),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let remaining = accounts::api::resolved_list(vault).await.unwrap();
    assert_eq!(remaining.accounts.len(), 1);
    assert_eq!(remaining.accounts[0].id, unrelated);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn resolved_snapshots_keep_revisions_and_do_not_resurrect_unlinked_sources() {
    let (state, dir, id) = fixture().await;
    let mut owned_state = Arc::try_unwrap(state).ok().unwrap();
    owned_state.no_saved_accounts = false;
    let state = Arc::new(owned_state);
    let mut value = Provider::Mock
        .adapter()
        .fetch(&state.context)
        .await
        .unwrap();
    value.provider.0 = "amp".into();
    value.account.id = "fake-identity".into();
    for window in &mut value.windows {
        window.fetched_at = state.context.clock.now();
    }
    value.account_ref = Some(crate::domain::AccountRef {
        id: id.clone(),
        label: "source".into(),
        origin: Some(crate::domain::AccountOrigin::Owned),
    });
    *state.snapshot.write().await = Some((
        0,
        UsageReport {
            schema_version: 1,
            generated_at: state.context.clock.now(),
            providers: vec![value],
            failures: vec![],
        },
    ));
    let Json(first) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    assert_eq!(first.usage[0].freshness, crate::contract::Freshness::Fresh);
    let Json(repeated) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    assert_eq!(first.revision, repeated.revision);
    assert_eq!(first.host.id, repeated.host.id);
    let vault = state.vault.clone().unwrap();
    let restarted = accounts::api::resolved_snapshot(
        vault.clone(),
        state.snapshot.read().await.as_ref().unwrap().1.clone(),
        state.context.clock.now(),
        time::Duration::seconds(300),
    )
    .await
    .unwrap();
    assert_eq!(restarted.revision, first.revision);
    {
        let mut tx = vault.begin().unwrap();
        tx.document
            .replace_api_key(
                &id,
                Provider::Amp,
                "new-identity".into(),
                Credential::ApiKey {
                    token: "replacement-fixture".into(),
                    region: None,
                    organization: None,
                },
            )
            .unwrap();
        tx.commit().unwrap();
    }
    let Json(replaced) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    assert!(replaced.usage[0].metrics.is_empty());
    assert_eq!(
        replaced.usage[0].freshness,
        crate::contract::Freshness::NotLoaded
    );
    assert_ne!(replaced.accounts[0].id, first.accounts[0].id);
    accounts::service::remove_resolved(vault, replaced.accounts[0].id.clone())
        .await
        .unwrap();
    let Json(deleted) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    assert!(deleted.accounts.is_empty());
    assert!(deleted.usage.is_empty());
    assert!(deleted.revision > first.revision);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn resolved_snapshot_without_saved_accounts_uses_no_vault() {
    let (state, dir, _) = fixture().await;
    let mut state = Arc::try_unwrap(state).ok().unwrap();
    state.vault = None;
    let state = Arc::new(state);
    *state.snapshot.write().await = Some((
        0,
        UsageReport {
            schema_version: 1,
            generated_at: state.context.clock.now(),
            providers: vec![
                Provider::Mock
                    .adapter()
                    .fetch(&state.context)
                    .await
                    .unwrap(),
            ],
            failures: vec![],
        },
    ));
    let Json(first) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    let Json(second) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    assert_eq!(first.accounts.len(), 1);
    assert_eq!(first.accounts[0].provider_id, "mock");
    assert_eq!(first.host.id, second.host.id);
    assert_eq!(first.revision, second.revision);
    assert!(!first.host.capabilities["account_write_v2"].available);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn external_snapshot_account_can_refresh_without_duplicate_observations() {
    let (state, dir, _) = fixture().await;
    state.settings.write().await.values.enabled_providers = vec!["mock".into()];
    refresh(&state, None).await.unwrap();
    let Json(snapshot) = resolved_snapshot(State(state.clone()), security::owner())
        .await
        .unwrap_or_else(|_| panic!());
    let id = snapshot.accounts[0].id.clone();
    assert!(id.starts_with("external-"));
    // An unrelated source must survive a local account refresh.
    let mut other = Provider::Mock
        .adapter()
        .fetch(&state.context)
        .await
        .unwrap();
    other.account_ref = Some(crate::domain::AccountRef {
        id: "other-source".into(),
        label: "Other".into(),
        origin: None,
    });
    state
        .snapshot
        .write()
        .await
        .as_mut()
        .unwrap()
        .1
        .providers
        .push(other);
    for _ in 0..2 {
        let (_, Json(operation)) = manual_refresh(
            State(state.clone()),
            security::owner(),
            ApiJson(RefreshRequest {
                providers: vec![Provider::Mock],
                account_id: Some(id.clone()),
                force: true,
                include_owned: true,
                disabled_proxy_auth_files: vec![],
            }),
        )
        .await
        .unwrap_or_else(|_| panic!("snapshot account must be refreshable"));
        assert_eq!(done(&state, &operation.id).await.error, None);
        let report = state.snapshot.read().await;
        let usages = &report.as_ref().unwrap().1.providers;
        assert_eq!(usages.len(), 2);
        assert_eq!(usages.iter().filter(|u| u.account_ref.is_none()).count(), 1);
        assert!(usages.iter().any(|u| {
            u.account_ref
                .as_ref()
                .is_some_and(|r| r.id == "other-source")
        }));
    }
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn group_refresh_replaces_all_selected_sources_and_preserves_other_accounts() {
    let fixture: Value =
        serde_json::from_str(include_str!("../../tests/fixtures/contracts/usage-v1.json")).unwrap();
    let value = |id: &str| {
        let mut value: crate::domain::ProviderUsage =
            serde_json::from_value(fixture["providers"][0].clone()).unwrap();
        value.provider = ProviderId("amp".into());
        value.account_ref = Some(crate::domain::AccountRef {
            id: id.into(),
            label: id.into(),
            origin: None,
        });
        value
    };
    let mut stored = Some((
        0,
        UsageReport {
            schema_version: 1,
            generated_at: time::OffsetDateTime::UNIX_EPOCH,
            providers: vec![value("one"), value("two"), value("unrelated")],
            failures: vec![],
        },
    ));
    let report = UsageReport {
        schema_version: 1,
        generated_at: time::OffsetDateTime::UNIX_EPOCH,
        providers: vec![value("one")],
        failures: vec![ProviderFailure {
            provider: ProviderId("amp".into()),
            account_ref: value("two").account_ref,
            code: ProviderError::Timeout,
            message: "timeout".into(),
        }],
    };
    assert!(merge_refresh_report(
        &mut stored,
        0,
        &[Provider::Amp],
        &[Provider::Amp],
        Some(&std::collections::HashSet::from([
            "one".into(),
            "two".into()
        ])),
        report
    ));
    let report = stored.unwrap().1;
    let ids: Vec<_> = report
        .providers
        .iter()
        .map(|value| value.account_ref.as_ref().unwrap().id.as_str())
        .collect();
    assert_eq!(ids, ["unrelated", "one"]);
    assert_eq!(report.failures[0].account_ref.as_ref().unwrap().id, "two");
}

#[tokio::test]
async fn scheduled_discovery_and_refresh_obey_host_tracking() {
    let (state, dir, _) = fixture().await;
    {
        let mut settings = state.settings.write().await;
        settings.values.enabled_providers = vec!["mock".into(), "amp".into()];
        settings.values.disabled_providers = vec!["amp".into()];
        settings.values.automatically_discover_logins = false;
    }
    native::scheduled(&state).await.unwrap();
    assert!(
        crate::accounts::discovery::host::status(state.vault.clone().unwrap())
            .await
            .unwrap()
            .scans
            .is_empty()
    );
    state
        .settings
        .write()
        .await
        .values
        .automatically_discover_logins = true;
    native::scheduled(&state).await.unwrap();
    let report = crate::accounts::discovery::host::status(state.vault.clone().unwrap())
        .await
        .unwrap();
    assert_eq!(report.scans.len(), 1);
    assert_eq!(report.scans[0].provider, Provider::Mock);
    drop(report);
    refresh(&state, None).await.unwrap();
    assert!(
        state
            .snapshot
            .read()
            .await
            .as_ref()
            .unwrap()
            .1
            .providers
            .iter()
            .all(|usage| usage.provider.0 == "mock")
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn native_discovery_is_a_deduplicated_host_operation_with_a_shared_report() {
    let (state, dir, _) = fixture().await;
    let guard = state.native_scan_lock.lock().await;
    let input = || ApiJson(serde_json::from_value(json!({"providers":["mock"]})).unwrap());
    let (_, Json(first)) = native::start(State(state.clone()), security::owner(), input())
        .await
        .unwrap_or_else(|_| panic!());
    let (_, Json(retry)) = native::start(State(state.clone()), security::owner(), input())
        .await
        .unwrap_or_else(|_| panic!());
    assert_eq!(first.id, retry.id);
    drop(guard);
    assert_eq!(done(&state, &first.id).await.status, "completed");
    let Json(report) = native::status(State(state.clone()))
        .await
        .unwrap_or_else(|_| panic!());
    assert_eq!(report.scans.len(), 1);
    assert_eq!(report.scans[0].provider, Provider::Mock);
    let value = serde_json::to_value(report).unwrap();
    let document: Value = serde_json::from_str(include_str!("../../docs/openapi.json")).unwrap();
    jsonschema::draft202012::new(
        &json!({"$ref":"#/components/schemas/V2Discovery", "components":document["components"]}),
    )
    .unwrap()
    .validate(&value)
    .unwrap();
    assert!(!value.to_string().contains("synthetic-vault-secret"));
    assert!(
        state
            .vault
            .as_ref()
            .unwrap()
            .begin()
            .unwrap()
            .document
            .mutation_receipts
            .is_empty()
    );
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn delegated_read_clients_are_revocable_and_cannot_reach_private_or_write_routes() {
    let (mut state, dir, _) = fixture().await;
    Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let root = "synthetic-client-owner-token-123456789";
    let app = router(
        state.clone(),
        Arc::new(security::Policy::new(address, true, None, &[], Some(root.into())).unwrap()),
    );
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let base = format!("http://{address}");
    assert_eq!(
        client
            .post(format!("{base}/v2/clients"))
            .bearer_auth(root)
            .json(&json!({"label":"Not enabled","scope":"manage"}))
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    let response = client
        .post(format!("{base}/v2/clients"))
        .bearer_auth(root)
        .json(&json!({"label":"Phone","scope":"read"}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 201);
    assert_eq!(response.headers()["cache-control"], "no-store");
    let issued: Value = response.json().await.unwrap();
    let document: Value = serde_json::from_str(include_str!("../../docs/openapi.json")).unwrap();
    jsonschema::draft202012::new(
        &json!({"$ref":"#/components/schemas/ClientCreated", "components":document["components"]}),
    )
    .unwrap()
    .validate(&issued)
    .unwrap();
    let token = issued["token"].as_str().unwrap();
    let id = issued["client"]["id"].as_str().unwrap();
    let snapshot: Value = client
        .get(format!("{base}/v2/snapshot"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(snapshot["host"]["id"], issued["host_id"]);
    assert_eq!(
        snapshot["host"]["capabilities"]["account_write_v2"]["available"],
        false
    );
    assert_eq!(
        snapshot["host"]["capabilities"]["refresh"]["available"],
        false
    );
    assert!(
        snapshot["accounts"][0]["actions"]
            .as_array()
            .unwrap()
            .iter()
            .all(|action| action["available"] == false)
    );
    let status: Value = client
        .get(format!("{base}/v2/status"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(status["client_id"], id);
    assert_eq!(status["access_mode"], "read_only");
    for path in [
        "/v2/clients",
        "/v2/auth/sessions/private",
        "/v2/operations/private",
    ] {
        assert_eq!(
            client
                .get(format!("{base}{path}"))
                .bearer_auth(token)
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
    }
    for path in [
        "/v2/refresh",
        "/v2/accounts",
        "/v2/sources/authorize",
        "/v2/clients",
    ] {
        assert_eq!(
            client
                .post(format!("{base}{path}"))
                .bearer_auth(token)
                .json(&json!({}))
                .send()
                .await
                .unwrap()
                .status(),
            403
        );
    }
    let listed: Value = client
        .get(format!("{base}/v2/clients"))
        .bearer_auth(root)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(listed["clients"][0]["id"], id);
    assert!(!listed.to_string().contains(token));
    assert!(listed["clients"][0].get("digest").is_none());
    assert_eq!(
        client
            .delete(format!("{base}/v2/clients/{id}"))
            .bearer_auth(root)
            .send()
            .await
            .unwrap()
            .status(),
        204
    );
    let revoked = client
        .get(format!("{base}/v2/snapshot"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap();
    assert_eq!(revoked.status(), 401);
    assert_eq!(revoked.headers()["cache-control"], "no-store");
    server.abort();
    let _ = server.await;
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn public_hosts_require_local_approval_for_native_access_and_browser_sign_in() {
    let (mut state, dir, _) = fixture().await;
    Arc::get_mut(&mut state).unwrap().no_saved_accounts = false;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let token = "synthetic-public-host-token-123456789";
    let app = router(
        state,
        Arc::new(
            security::Policy::new(
                address,
                true,
                Some("https://host.example"),
                &[],
                Some(token.into()),
            )
            .unwrap(),
        ),
    );
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    let base = format!("http://{address}");
    for (path, body) in [
        ("/v2/account-vault/authorize", json!({})),
        ("/v2/sources/authorize", json!({})),
        ("/v2/auth/sessions", json!({"provider":"codex"})),
    ] {
        let response = client
            .post(format!("{base}{path}"))
            .bearer_auth(token)
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 403);
        assert_eq!(
            response.json::<Value>().await.unwrap()["error"],
            "host_interaction_required"
        );
    }
    let catalog: Value = client
        .get(format!("{base}/v2/providers"))
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let codex = catalog["providers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|provider| provider["id"] == "codex")
        .unwrap();
    assert!(
        codex["actions"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|action| action["kind"] == "start_oauth")
            .all(|action| action["available"] == false)
    );
    server.abort();
    let _ = server.await;
    std::fs::remove_dir_all(dir).unwrap();
}
