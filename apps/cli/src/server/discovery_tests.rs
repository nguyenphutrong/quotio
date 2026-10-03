use super::*;
use crate::accounts::{self, sources::QuotioDomain};

fn preferences(_: QuotioDomain) -> Result<Vec<u8>, accounts::AccountError> {
    Ok(br#"[{"id":"11111111-1111-1111-1111-111111111111","name":"planted-secret","type":"clinepass","is-enabled":true,"api-keys":[{"api-key":"planted-secret"}]},{"id":"22222222-2222-2222-2222-222222222222","name":"other","type":"glm-api-key","api-keys":[{"api-key":"not-selected"}]}]"#.to_vec())
}
#[tokio::test]
async fn discovery_rest_registers_opaque_exact_entries_without_credentials() {
    let (state, dir, _) = tests::fixture().await;
    let home = dir.canonicalize().unwrap();
    for (relative, contents) in [
        (
            ".grok/auth.json",
            r#"{"https://auth.x.ai::planted-secret":{"key":"planted-secret","expires_at":"2099-01-01T00:00:00Z"},"https://auth.x.ai::second":{"key":"second-fixture","expires_at":"2099-01-01T00:00:00Z"}}"#,
        ),
        (
            ".config/github-copilot/apps.json",
            r#"{"github.com:planted-secret":{"oauth_token":"planted-secret"}}"#,
        ),
        (
            ".config/gh/hosts.yml",
            "github.com:\n  oauth_token: planted-secret\n",
        ),
    ] {
        let path = home.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, contents).unwrap();
    }
    {
        let mut discovery = state.discovery.lock().unwrap();
        discovery.home = Some(home.clone());
        discovery.preferences = preferences;
    }
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
    let endpoint = format!("{base}/v1/account-sources/discover");
    assert_eq!(
        client
            .post(&endpoint)
            .json(&json!({"provider":"grok","kind":"grok_native","inspect":true}))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    for (index, request) in [
        json!({"provider":"grok","kind":"grok_native","inspect":true}),
        json!({"provider":"copilot","kind":"copilot_native","inspect":true}),
        json!({"provider":"clinepass","kind":"quotio_custom_provider","domain":"production","inspect":true}),
    ].into_iter().enumerate() {
        let response = client.post(&endpoint).bearer_auth(token).json(&request).send().await.unwrap();
        assert_eq!(response.status(), 200);
        let discovered: Value = response.json().await.unwrap();
        assert_eq!(discovered["status"], "checked", "{discovered}");
        assert_eq!(discovered["candidates"].as_array().unwrap().len(), if index < 2 { 2 } else { 1 });
        assert_eq!(discovered["candidates"][0]["status"], "available");
        for forbidden in ["planted-secret", "11111111", "oauth_token", "entry_key", home.to_str().unwrap()] {
            assert!(!discovered.to_string().contains(forbidden));
        }
        for (candidate_index, candidate) in discovered["candidates"].as_array().unwrap().iter().enumerate() {
        let response = client.post(format!("{base}/v1/account-sources"))
            .bearer_auth(token).header("Idempotency-Key", format!("discovery-{index}-{candidate_index}"))
            .json(&candidate["source"]).send().await.unwrap();
        assert_eq!(response.status(), 202);
        let operation: Value = response.json().await.unwrap();
        let completed = serde_json::to_value(tests::done(&state, operation["id"].as_str().unwrap()).await).unwrap();
        assert_eq!(completed["status"], "completed", "{completed}");
        let id = completed["result"]["account_id"].as_str().unwrap();
        let account: Value = client.get(format!("{base}/v1/accounts/{id}")).bearer_auth(token).send().await.unwrap().json().await.unwrap();
        assert_eq!(account["provider"], request["provider"]);
        assert!(!account.to_string().contains("planted-secret"));
        if request["kind"] == "quotio_custom_provider" {
            assert_eq!(account["source_id"].as_str().unwrap().len(), 64);
        }
        }
    }
    for request in [
        json!({"provider":"grok","kind":"copilot_native","inspect":true}),
        json!({"provider":"grok","kind":"grok_native","path":"/.cli-proxy-api","inspect":true}),
        json!({"provider":"clinepass","kind":"quotio_custom_provider","inspect":true}),
    ] {
        assert_eq!(
            client
                .post(&endpoint)
                .bearer_auth(token)
                .json(&request)
                .send()
                .await
                .unwrap()
                .status(),
            400
        );
    }
    for (request, status) in [
        (
            json!({"provider":"claude","kind":"claude_native"}),
            "not_checked",
        ),
        (
            json!({"provider":"copilot","kind":"copilot_native","location":"gh_keychain","inspect":true}),
            "unsupported",
        ),
    ] {
        let value: Value = client
            .post(&endpoint)
            .bearer_auth(token)
            .json(&request)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(value["status"], status);
    }
    // A read-only server rejects inspection even with its valid bearer token.
    let readonly = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = readonly.local_addr().unwrap();
    let app = router(
        state.clone(),
        Arc::new(security::Policy::new(address, false, None, &[], Some(token.into())).unwrap()),
    );
    let read_server = tokio::spawn(async move { axum::serve(readonly, app).await.unwrap() });
    assert_eq!(
        client
            .post(format!("http://{address}/v1/account-sources/discover"))
            .bearer_auth(token)
            .json(&json!({"provider":"grok","kind":"grok_native","inspect":true}))
            .send()
            .await
            .unwrap()
            .status(),
        405
    );
    read_server.abort();
    server.abort();
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn oauth_begin_rest_returns_conflict_for_changed_idempotent_body() {
    let (state, dir, _) = tests::fixture().await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let token = "synthetic-management-token-1234567890";
    let app = router(
        state,
        Arc::new(security::Policy::new(address, true, None, &[], Some(token.into())).unwrap()),
    );
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    for (label, status) in [("Fixture", 201), ("Changed", 409)] {
        let response = client
            .post(format!("http://{address}/v1/auth/sessions"))
            .bearer_auth(token)
            .header("Idempotency-Key", "oauth-conflict")
            .json(&json!({"provider":"codex","label":label,"callback_mode":"relay"}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), status);
        if status == 409 {
            assert!(
                response
                    .text()
                    .await
                    .unwrap()
                    .contains("idempotency_conflict")
            );
        }
    }
    server.abort();
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn discovery_retry_survives_expiry_and_restart_without_reading_source() {
    use accounts::vault::{Backend, Vault};
    #[derive(Default)]
    struct Memory(std::sync::Mutex<Option<Vec<u8>>>);
    impl Backend for Memory {
        fn read(&self) -> Result<Option<Vec<u8>>, accounts::AccountError> {
            Ok(self.0.lock().unwrap().clone())
        }
        fn write(&self, bytes: &[u8]) -> Result<(), accounts::AccountError> {
            *self.0.lock().unwrap() = Some(bytes.into());
            Ok(())
        }
    }
    fn headers(key: &str) -> axum::http::HeaderMap {
        let mut headers = axum::http::HeaderMap::new();
        headers.insert("idempotency-key", key.parse().unwrap());
        headers
    }
    let backend = Arc::new(Memory::default());
    let (mut state, dir, _) = tests::fixture().await;
    let path = dir.join("receipt.lock");
    Arc::get_mut(&mut state).unwrap().vault = Some(Vault::new(backend.clone(), path.clone()));
    let body = {
        let mut registry = state.discovery.lock().unwrap();
        registry.home = Some(dir.clone());
        registry.preferences = preferences;
        registry.inspect(serde_json::from_value(json!({"provider":"clinepass","kind":"quotio_custom_provider","domain":"production","inspect":true})).unwrap()).unwrap()["candidates"][0]["source"].clone()
    };
    let (_, Json(first)) = management::reference(
        State(state.clone()),
        headers("receipt-retry"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|e| panic!("{} {}", e.0, e.1));
    let completed = tests::done(&state, &first.id).await;
    assert_eq!(completed.status, "completed");
    let account_id = completed.result.unwrap()["account_id"]
        .as_str()
        .unwrap()
        .to_owned();
    state.discovery.lock().unwrap().expire_all();
    assert!(
        state
            .discovery
            .lock()
            .unwrap()
            .get(body["discovery_ref"].as_str().unwrap())
            .is_err()
    );
    let (_, Json(retry)) = management::reference(
        State(state.clone()),
        headers("receipt-retry"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|e| panic!("{} {}", e.0, e.1));
    assert_eq!(retry.id, first.id);
    assert_eq!(retry.result.unwrap()["account_id"], account_id);

    // Fresh registry, operations, and Vault object over the committed backend.
    let (mut restarted, restart_dir, _) = tests::fixture().await;
    Arc::get_mut(&mut restarted).unwrap().vault = Some(Vault::new(backend, path));
    restarted.discovery.lock().unwrap().home = Some(restart_dir.clone());
    restarted.discovery.lock().unwrap().preferences =
        |_| panic!("receipt recovery must not read preferences");
    let (_, Json(retry)) = management::reference(
        State(restarted.clone()),
        headers("receipt-retry"),
        ApiJson(body.clone()),
    )
    .await
    .unwrap_or_else(|e| panic!("{} {}", e.0, e.1));
    let completed = tests::done(&restarted, &retry.id).await;
    assert_eq!(completed.status, "completed");
    assert_eq!(completed.result.unwrap()["account_id"], account_id);
    let conflict = management::reference(
        State(restarted.clone()),
        headers("receipt-retry"),
        ApiJson(json!({"kind":"discovered","discovery_ref":"different-fixture"})),
    )
    .await
    .err()
    .unwrap();
    assert_eq!(conflict.0, StatusCode::CONFLICT);
    assert_eq!(conflict.1, "idempotency_conflict");
    // A different key is a new mutation and must validate its live reference.
    let (_, Json(new)) = management::reference(
        State(restarted.clone()),
        headers("new-mutation"),
        ApiJson(body),
    )
    .await
    .unwrap_or_else(|e| panic!("{} {}", e.0, e.1));
    let failed = tests::done(&restarted, &new.id).await;
    assert_eq!(failed.status, "failed");
    assert_eq!(failed.error, Some("account_not_found"));
    assert_eq!(
        accounts::api::list(restarted.vault.clone().unwrap())
            .await
            .unwrap()
            .len(),
        1
    );
    std::fs::remove_dir_all(dir).unwrap();
    std::fs::remove_dir_all(restart_dir).unwrap();
}
