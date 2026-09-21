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
            discovery: Default::default(),
            settings: RwLock::new(view),
            store,
            snapshot: RwLock::new(None),
            generation,
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
            manage: true,
            vault: Some(vault),
            oauth: Some(manager),
        }),
        dir,
        id,
    )
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
    let account = crate::accounts::proxy::adapters(&auth, &[Provider::Catalog("claude")], None, &[])
        .unwrap()
        .remove(0)
        .account_ref()
        .unwrap();

    assert!(
        management::validate_refresh_account(&state, Provider::Catalog("claude"), &account.id)
            .await
            .is_ok()
    );
    std::fs::remove_dir_all(dir).unwrap();
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
                disabled_proxy_auth_files: vec!["claude.json".into()],
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
        Some("account-id"),
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
        Some("account-id"),
        report,
    ));
    assert!(snapshot.is_some());
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
            .post(format!("{base}/v1/account-sources"))
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
                .post(format!("{base}/v1/account-sources"))
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
        .post(format!("{base}/v1/account-sources"))
        .json(&input)
        .send()
        .await
        .unwrap();
    assert_eq!(unauth.status(), 401);
    let invalid = client
        .post(format!("{base}/v1/account-sources"))
        .bearer_auth(token)
        .header("Idempotency-Key", "bad-source")
        .json(&json!({"kind":"codex_native","path":"/tmp/untrusted"}))
        .send()
        .await
        .unwrap();
    assert_eq!(invalid.status(), 400);
    let request = || {
        client
            .post(format!("{base}/v1/account-sources"))
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
            .patch(format!("{base}/v1/accounts/{id}"))
            .bearer_auth(token)
            .header("Idempotency-Key", format!("codex-enabled-{enabled}"))
            .json(&json!({"enabled":enabled,"label":"Native Codex fixture"}))
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
            .get(format!("{base}/v1/accounts/{id}"))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        let alias = client
            .post(format!("{base}/v1/refresh"))
            .bearer_auth(token)
            .json(&json!({"providers":["codex"],"account_id":"local","force":true}))
            .send()
            .await
            .unwrap();
        assert_eq!(alias.status(), 409);
        assert_eq!(account["enabled"], enabled);
        assert_eq!(account["origin"], "borrowed_native");
        assert_eq!(account["source_kind"], "codex_native");
        assert_eq!(account["label"], "Native Codex fixture");
        assert!(!account.to_string().contains("synthetic-native-secret"));
    }
    let document = state.vault.as_ref().unwrap().begin().unwrap();
    let bytes = serde_json::to_string(&document.document).unwrap();
    assert!(!bytes.contains("synthetic-native-secret"));
    assert!(!bytes.contains("synthetic-owner-refresh"));
    assert_eq!(document.document.version, 4);
    drop(document);
    let response: Value = client
        .delete(format!("{base}/v1/accounts/{id}"))
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
            .get(format!("{base}/v1/accounts/{id}"))
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
fn key(value: &str) -> axum::http::HeaderMap {
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
        let response = usage_response(&state, Some("codex"), None).await;
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), 65536)
            .await
            .unwrap();
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            value["providers"][0].get("reset_credits").is_some(),
            present
        );
        assert_eq!(
            value["providers"][0]["windows"].as_array().unwrap().len(),
            3
        );
        assert_eq!(value["generated_at"], "1970-01-01T00:00:00Z");
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
    let (_, Json(op)) = management::create(
        State(state.clone()),
        key("antigravity-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let (_, Json(retry)) = management::create(
        State(state.clone()),
        key("antigravity-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(retry.id, op.id);
    let Json(accounts) = management::list(State(state.clone()))
        .await
        .unwrap_or_else(|_| panic!());
    assert!(!accounts.to_string().contains("synthetic-"));
    let account = accounts["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["provider"] == "antigravity")
        .unwrap();
    assert_eq!(account["origin"], "owned");
    for field in ["path", "endpoint", "provider", "owned"] {
        let mut invalid = body.clone();
        invalid[field] = "fixture".into();
        assert!(matches!(
            management::create(
                State(state.clone()),
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
    let (_, Json(op)) = management::create(
        State(state.clone()),
        key("kiro-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let (_, Json(retry)) = management::create(
        State(state.clone()),
        key("kiro-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(retry.id, op.id);
    let Json(accounts) = management::list(State(state.clone()))
        .await
        .unwrap_or_else(|_| panic!());
    assert!(!accounts.to_string().contains("synthetic-kiro"));
    let account = accounts["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["provider"] == "kiro")
        .unwrap();
    assert_eq!(account["origin"], "owned");
    for field in ["path", "endpoint", "provider", "owned", "machine"] {
        let mut invalid = body.clone();
        invalid[field] = "fixture".into();
        assert!(matches!(
            management::create(State(state.clone()), key("invalid-kiro"), ApiJson(invalid)).await,
            Err(ApiError(StatusCode::BAD_REQUEST, _))
        ));
    }
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn factory_owned_intake_is_explicit_and_idempotent() {
    let (state, dir, _) = fixture().await;
    let body = json!({"kind":"factory_owned","label":"Owned Factory","access_token":"synthetic-factory-access","refresh_token":"synthetic-factory-refresh","organization_id":"org"});
    let (_, Json(op)) = management::create(
        State(state.clone()),
        key("factory-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let (_, Json(retry)) = management::create(
        State(state.clone()),
        key("factory-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(retry.id, op.id);
    let Json(accounts) = management::list(State(state.clone()))
        .await
        .unwrap_or_else(|_| panic!());
    assert!(!accounts.to_string().contains("synthetic-factory"));
    let account = accounts["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["provider"] == "factory")
        .unwrap();
    assert_eq!(account["origin"], "owned");
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
            management::create(
                State(state.clone()),
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
    let (_, Json(op)) = management::create(
        State(state.clone()),
        key("grok-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    let (_, Json(retry)) = management::create(
        State(state.clone()),
        key("grok-intake"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(retry.id, op.id);
    let Json(accounts) = management::list(State(state.clone()))
        .await
        .unwrap_or_else(|_| panic!());
    assert!(!accounts.to_string().contains("synthetic-grok"));
    let rows = accounts["accounts"].as_array().unwrap();
    let account = rows.iter().find(|a| a["provider"] == "grok").unwrap();
    assert_eq!(account["origin"], "owned");
    let id = account["id"].as_str().unwrap().to_owned();
    for field in ["path", "entry_key", "owned", "provider"] {
        let mut invalid = body.clone();
        invalid[field] = "fixture".into();
        assert!(matches!(
            management::create(State(state.clone()), key("invalid-grok"), ApiJson(invalid)).await,
            Err(ApiError(StatusCode::BAD_REQUEST, _))
        ));
    }
    assert!(matches!(management::reference(State(state.clone()), key("invalid-source"), ApiJson(json!({"kind":"grok_native","entry_key":"https://auth.x.ai::fixture","path":"/tmp/auth.json"}))).await, Err(ApiError(StatusCode::BAD_REQUEST, _))));
    let (_, Json(disable)) = management::patch(
        State(state.clone()),
        Path(id.clone()),
        key("disable-grok"),
        ApiJson(json!({"enabled":false})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &disable.id).await.status, "completed");
    let (_, Json(remove)) = management::remove(State(state.clone()), Path(id), key("remove-grok"))
        .await
        .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &remove.id).await.status, "completed");
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn account_http_services_are_secret_free_idempotent_and_fenced() {
    let (state, dir, id) = fixture().await;
    let Json(accounts) = management::list(State(state.clone()))
        .await
        .unwrap_or_else(|_| panic!());
    assert!(!accounts.to_string().contains("synthetic-vault-secret"));
    assert!(!accounts.to_string().contains("credential"));
    let body = json!({"label":"new label","active":true});
    let (_, Json(op)) = management::patch(
        State(state.clone()),
        Path(id.clone()),
        key("change-1"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &op.id).await.status, "completed");
    assert_eq!(state.generation.load(Ordering::SeqCst), 1);
    let (_, Json(retry)) = management::patch(
        State(state.clone()),
        Path(id.clone()),
        key("change-1"),
        ApiJson(body),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(op.id, retry.id);
    assert!(matches!(
        management::patch(
            State(state.clone()),
            Path(id.clone()),
            key("change-1"),
            ApiJson(json!({"label":"different"}))
        )
        .await,
        Err(ApiError(StatusCode::CONFLICT, _))
    ));
    let (_, Json(invalid)) = management::create(
        State(state.clone()),
        key("create-1"),
        ApiJson(json!({"provider":"amp","api_key":""})),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(
        done(&state, &invalid.id).await.error,
        Some("invalid_credential")
    );
    let (_, Json(remove)) =
        management::remove(State(state.clone()), Path(id.clone()), key("remove-1"))
            .await
            .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &remove.id).await.status, "completed");
    assert!(matches!(
        management::get_account(State(state.clone()), Path(id)).await,
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
    assert_eq!(
        usage_response(&state, None, None).await.status(),
        StatusCode::SERVICE_UNAVAILABLE
    );
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
    let (_, Json(first)) = manual_refresh(State(state.clone()), ApiJson(request()))
        .await
        .unwrap_or_else(|_| panic!());
    let (_, Json(second)) = manual_refresh(State(state.clone()), ApiJson(request()))
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
    assert_eq!(
        usage_response(&state, None, None).await.status(),
        StatusCode::SERVICE_UNAVAILABLE
    );
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
async fn account_retry_survives_loss_of_in_memory_operations() {
    let (state, dir, id) = fixture().await;
    let body = json!({"label":"first change"});
    let (_, Json(first)) = management::patch(
        State(state.clone()),
        Path(id.clone()),
        key("durable-key"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_eq!(done(&state, &first.id).await.status, "completed");
    // Another intent can change the account before the original caller retries.
    crate::accounts::service::patch(
        state.vault.clone().unwrap(),
        id.clone(),
        Some("later change".into()),
        None,
        None,
    )
    .await
    .unwrap();
    *state.operations.lock().await = Operations::default();
    let (_, Json(retry)) = management::patch(
        State(state.clone()),
        Path(id.clone()),
        key("durable-key"),
        ApiJson(body),
    )
    .await
    .unwrap_or_else(|_| panic!());
    assert_ne!(first.id, retry.id);
    assert_eq!(done(&state, &retry.id).await.status, "completed");
    let Json(account) = management::get_account(State(state.clone()), Path(id.clone()))
        .await
        .unwrap_or_else(|_| panic!());
    assert_eq!(account.label, "later change");
    *state.operations.lock().await = Operations::default();
    let conflict = management::patch(
        State(state.clone()),
        Path(id),
        key("durable-key"),
        ApiJson(json!({"label":"different intent"})),
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
        let (_, Json(op)) =
            management::migrate(State(state.clone()), key(&key_value), ApiJson(body.clone()))
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
        let (_, Json(retry)) =
            management::migrate(State(state.clone()), key(&key_value), ApiJson(body))
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
        let (_, Json(op)) = management::migrate(State(state.clone()), key(name), ApiJson(body))
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
