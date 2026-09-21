use serde_json::{Value, json};
use std::{path::PathBuf, process::Stdio, time::Duration};
use tokio::io::{AsyncBufReadExt, BufReader};
const TOKEN: &str = "synthetic-management-api-token-1234567890";
struct Server {
    child: tokio::process::Child,
    dir: PathBuf,
    base: String,
    client: reqwest::Client,
    logs: std::sync::Arc<std::sync::Mutex<String>>,
    log_reader: tokio::task::JoinHandle<()>,
}
impl Server {
    async fn start(extra: &[&str]) -> Self {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "quotio-management-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join("config.toml"), "enabled_providers = []\n").unwrap();
        let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_quotio"))
            .args([
                "serve",
                "--listen",
                "127.0.0.1:0",
                "--no-saved-accounts",
                "--config",
            ])
            .arg(dir.join("config.toml"))
            .args(extra)
            .env("QUOTIO_SERVER_TOKEN", TOKEN)
            .env("QUOTIO_CACHE_DIR", dir.join("cache"))
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let mut lines = BufReader::new(child.stderr.take().unwrap()).lines();
        let line = tokio::time::timeout(Duration::from_secs(10), lines.next_line())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let base = line
            .strip_prefix("Quotio API listening on ")
            .unwrap()
            .into();
        let logs = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
        let captured = logs.clone();
        let log_reader = tokio::spawn(async move {
            while let Ok(Some(line)) = lines.next_line().await {
                captured.lock().unwrap().push_str(&line);
            }
        });
        Self {
            child,
            logs,
            log_reader,
            dir,
            base,
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(5))
                .build()
                .unwrap(),
        }
    }
    fn request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        self.client
            .request(method, format!("{}{path}", self.base))
            .bearer_auth(TOKEN)
    }
    async fn get(&self, path: &str) -> Value {
        let r = self
            .request(reqwest::Method::GET, path)
            .send()
            .await
            .unwrap();
        assert_eq!(r.status(), 200);
        r.json().await.unwrap()
    }
    async fn done(&self, id: &str) -> Value {
        for _ in 0..100 {
            let op = self.get(&format!("/v1/operations/{id}")).await;
            if op["status"] != "running" {
                return op;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("operation timed out")
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
        self.log_reader.abort();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}
#[tokio::test]
async fn empty_onboarding_settings_refresh_and_revision_conflicts() {
    let server = Server::start(&["--manage"]).await;
    let settings = server.get("/v1/settings").await;
    assert_eq!(settings["enabled_providers"], json!([]));
    assert_eq!(settings["cache_ttl_seconds"], 300);
    let body = json!({"revision":settings["revision"],"enabled_providers":["mock"],"refresh_interval":3600,"cache_ttl_seconds":45});
    let response = server
        .request(reqwest::Method::PATCH, "/v1/settings")
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    let changed: Value = response.json().await.unwrap();
    assert_ne!(settings["revision"], changed["revision"]);
    assert_eq!(
        server
            .request(reqwest::Method::PATCH, "/v1/settings")
            .json(&body)
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
    assert!(
        std::fs::read_to_string(server.dir.join("config.toml"))
            .unwrap()
            .contains("45")
    );
    let response = server
        .request(reqwest::Method::POST, "/v1/refresh")
        .json(&json!({"providers":["mock"],"force":true}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 202);
    let op: Value = response.json().await.unwrap();
    let done = server.done(op["id"].as_str().unwrap()).await;
    assert_eq!(done["status"], "completed");
    assert_eq!(done["result"]["report"]["providers"][0]["provider"], "mock");
    assert_eq!(
        done["result"]["report"]["providers"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(done["result"]["report"]["failures"], json!([]));
    let usage = server.get("/v1/usage/mock").await;
    assert_eq!(usage["providers"][0]["provider"], "mock");
    assert_eq!(
        server
            .request(reqwest::Method::POST, "/v1/refresh")
            .json(&json!({"providers":["codex"]}))
            .send()
            .await
            .unwrap()
            .status(),
        400
    );
    assert_eq!(
        server
            .request(reqwest::Method::PATCH, "/v1/settings")
            .json(&json!({"revision":changed["revision"],"secret_field":"sentinel"}))
            .send()
            .await
            .unwrap()
            .status(),
        422
    );
}
#[tokio::test]
async fn remote_policy_preflight_limits_and_read_only() {
    let server = Server::start(&[
        "--manage",
        "--public-url",
        "https://quotio.example",
        "--allow-origin",
        "https://dashboard.example",
    ])
    .await;
    let response = server
        .client
        .request(
            reqwest::Method::OPTIONS,
            format!("{}/v1/settings", server.base),
        )
        .header("host", "quotio.example")
        .header("origin", "https://dashboard.example")
        .header("access-control-request-method", "PATCH")
        .header(
            "access-control-request-headers",
            "authorization,content-type",
        )
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 204);
    assert_eq!(
        response.headers()["access-control-allow-origin"],
        "https://dashboard.example"
    );
    assert_eq!(
        server
            .client
            .get(format!("{}/health", server.base))
            .header("origin", "https://dashboard.example")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        server
            .request(reqwest::Method::GET, "/health")
            .header("host", "quotio.example")
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    assert_eq!(
        server
            .request(reqwest::Method::GET, "/health")
            .header("host", "attacker.example")
            .header("x-forwarded-host", "quotio.example")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    let large = server
        .request(reqwest::Method::POST, "/v1/refresh")
        .header("content-type", "application/json")
        .body(" ".repeat(65537))
        .send()
        .await
        .unwrap();
    assert_eq!(large.status(), 413);
    assert_eq!(
        large.json::<Value>().await.unwrap()["error"],
        "body_too_large"
    );
    let readonly = Server::start(&[]).await;
    assert_eq!(
        readonly
            .request(reqwest::Method::POST, "/v1/refresh")
            .json(&json!({}))
            .send()
            .await
            .unwrap()
            .status(),
        405
    );
    let overridden = Server::start(&["--manage", "--provider", "mock"]).await;
    let settings = overridden.get("/v1/settings").await;
    assert_eq!(settings["overridden"], json!(["enabled_providers"]));
    assert_eq!(
        overridden
            .request(reqwest::Method::PATCH, "/v1/settings")
            .json(&json!({"revision":settings["revision"],"enabled_providers":[]}))
            .send()
            .await
            .unwrap()
            .status(),
        409
    );
}

#[tokio::test]
async fn completed_refresh_history_does_not_exhaust_operation_capacity() {
    let server = Server::start(&[
        "--manage",
        "--provider",
        "mock",
        "--refresh-interval",
        "3600",
    ])
    .await;
    for _ in 0..140 {
        let response = server
            .request(reqwest::Method::POST, "/v1/refresh")
            .json(&json!({"force": false}))
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 202);
        let op: Value = response.json().await.unwrap();
        assert_eq!(
            server.done(op["id"].as_str().unwrap()).await["status"],
            "completed"
        );
    }
}

#[tokio::test]
async fn server_events_exclude_request_secrets() {
    let server = Server::start(&["--manage", "--provider", "mock"]).await;
    let rejected = server
        .request(reqwest::Method::POST, "/v1/refresh")
        .json(&json!({"private-body":"private-sentinel"}))
        .send()
        .await
        .unwrap();
    assert_eq!(rejected.status(), 422);
    let response = server
        .request(reqwest::Method::POST, "/v1/refresh")
        .header("idempotency-key", "private-retry-key")
        .json(&json!({"force":false}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 202);
    let op: Value = response.json().await.unwrap();
    server.done(op["id"].as_str().unwrap()).await;
    for _ in 0..100 {
        if server.logs.lock().unwrap().contains("operation finished") {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let logs = server.logs.lock().unwrap();
    assert!(logs.contains("operation finished"));
    assert!(logs.contains("refresh completed"));
    assert!(!logs.contains("private-"));
    assert!(!logs.contains(TOKEN));
}

#[tokio::test]
async fn explicit_usage_queries_require_management_and_validate_before_provider_io() {
    for (arguments, expected) in [(vec![], 405), (vec!["--manage"], 400)] {
        let server = Server::start(&arguments).await;
        let response = server.request(reqwest::Method::POST, "/v1/usage/queries")
            .json(&json!({"provider":"openrouter","client_account_id":"client","label":"work","access_token":"fixture-invalid\n"}))
            .send().await.unwrap();
        assert_eq!(response.status().as_u16(), expected);
        let body = response.text().await.unwrap();
        assert!(!body.contains("fixture-invalid"));
        assert!(!server.logs.lock().unwrap().contains("fixture-invalid"));
    }
}

#[tokio::test]
async fn source_registration_uses_existing_management_and_storage_guards() {
    let read_only = Server::start(&[]).await;
    let body = json!({"kind":"quotio_custom_provider","source":{"domain":"production","record_id":"01234567-89ab-cdef-0123-456789abcdef"}});
    let denied = read_only
        .request(reqwest::Method::POST, "/v1/account-sources")
        .header("Idempotency-Key", "source-fixture")
        .json(&body)
        .send()
        .await
        .unwrap();
    assert_eq!(denied.status(), 405);
    let managed = Server::start(&["--manage"]).await;
    let invalid = managed.request(reqwest::Method::POST, "/v1/account-sources")
        .header("Idempotency-Key", "source-fixture").json(&json!({"kind":"quotio_custom_provider","source":{"domain":"../other.app","record_id":"01234567-89ab-cdef-0123-456789abcdef"}})).send().await.unwrap();
    assert_eq!(invalid.status(), 400);
    let mut custom_domain = body.clone();
    custom_domain["source"]["domain"] = "com.other.app".into();
    let disabled = managed
        .request(reqwest::Method::POST, "/v1/account-sources")
        .header("Idempotency-Key", "source-fixture")
        .json(&custom_domain)
        .send()
        .await
        .unwrap();
    assert_eq!(disabled.status(), 503);
    assert!(
        disabled
            .text()
            .await
            .unwrap()
            .contains("account_storage_disabled")
    );
}

#[tokio::test]
async fn legacy_migration_requires_authentication_management_and_storage() {
    let body = json!({"legacy_id":"legacy-test", "provider":"claude", "label":"Work", "enabled":false,
        "credential":{"access_token":"synthetic-migration-access", "refresh_token":"synthetic-migration-refresh"}});
    for (arguments, expected) in [(vec![], 405), (vec!["--manage"], 503)] {
        let server = Server::start(&arguments).await;
        let unauthorized = server
            .client
            .post(format!("{}/v1/accounts/migrate", server.base))
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(unauthorized.status(), 401);
        let response = server
            .request(reqwest::Method::POST, "/v1/accounts/migrate")
            .header("Idempotency-Key", "legacy-fixture")
            .json(&body)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status().as_u16(), expected);
        assert!(
            !response
                .text()
                .await
                .unwrap()
                .contains("synthetic-migration")
        );
        assert!(!server.logs.lock().unwrap().contains("synthetic-migration"));
    }
}
