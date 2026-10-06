use std::{path::PathBuf, process::Command};

struct Fixture(PathBuf);
impl Fixture {
    fn new(name: &str) -> Self {
        let root =
            std::env::temp_dir().join(format!("quotio-proxy-cli-{}-{name}", std::process::id()));
        std::fs::create_dir_all(root.join("auth")).unwrap();
        let root = root.canonicalize().unwrap();
        std::fs::write(root.join("quotio.toml"), "enabled_providers = []\n").unwrap();
        std::fs::write(root.join("auth/expired.json"), br#"{"type":"codex","account_id":"account-fixture","email":"work@example.test","access_token":"access-secret-sentinel","refresh_token":"refresh-secret-sentinel","expired":"2020-01-01T00:00:00Z"}"#).unwrap();
        std::fs::write(
            root.join("auth/disabled.json"),
            br#"{"type":"claude","disabled":true,"access_token":"disabled-secret-sentinel"}"#,
        )
        .unwrap();
        std::fs::write(
            root.join("proxy.yaml"),
            br#"
api-keys: [proxy-client-secret-sentinel]
openai-compatibility:
  - name: Work
    base-url: https://openrouter.ai/api/v1
    disabled: true
    api-key-entries: [{api-key: provider-secret-sentinel}]
  - name: openrouter
    base-url: https://unrecognized.example/v1
    api-key-entries: [{api-key: unsupported-secret-sentinel}]
"#,
        )
        .unwrap();
        Self(root)
    }

    fn usage(&self, auth_dir: Option<&str>, extra: &[&str]) -> std::process::Output {
        let mut command = Command::new(env!("CARGO_BIN_EXE_quotio"));
        command
            .env_clear()
            .env("HOME", &self.0)
            .env("PATH", &self.0)
            .env("QUOTIO_CACHE_DIR", self.0.join("cache"))
            .args([
                "usage",
                "--no-saved-accounts",
                "--format",
                "json",
                "--force",
                "--timeout",
                "1",
                "--config",
            ])
            .arg(self.0.join("quotio.toml"))
            .arg("--cli-proxy-config")
            .arg(self.0.join("proxy.yaml"));
        if let Some(directory) = auth_dir {
            command
                .arg("--cli-proxy-auth-dir")
                .arg(self.0.join(directory));
        }
        command.args(extra).output().unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn cli_keeps_disabled_and_expired_proxy_accounts_visible_without_writes_or_secret_output() {
    let fixture = Fixture::new("explicit");
    let paths = ["auth/expired.json", "auth/disabled.json", "proxy.yaml"];
    let before = paths.map(|path| std::fs::read(fixture.0.join(path)).unwrap());
    let output = fixture.usage(
        Some("auth"),
        &[
            "--provider",
            "codex",
            "--provider",
            "claude",
            "--provider",
            "openrouter",
        ],
    );
    assert_eq!(output.status.code(), Some(3));
    let snapshot: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    let accounts = snapshot["accounts"].as_array().unwrap();
    assert_eq!(accounts.len(), 3);
    for account in accounts {
        assert_eq!(account["sources"][0]["origin"], "borrowed_proxy");
        assert!(account["actions"].as_array().unwrap().is_empty());
        assert!(
            account["sources"][0]["actions"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }
    let codex = accounts
        .iter()
        .find(|account| account["provider_id"] == "codex")
        .unwrap();
    assert_eq!(codex["state"], "needs_login");
    let usage = snapshot["usage"]
        .as_array()
        .unwrap()
        .iter()
        .find(|usage| usage["account_id"] == codex["id"])
        .unwrap();
    assert_eq!(usage["issue"]["code"], "owner_refresh_required");
    assert_eq!(usage["issue"]["action"]["kind"], "refresh_in_source_app");
    assert!(usage["metrics"].as_array().unwrap().is_empty());
    for account in accounts
        .iter()
        .filter(|account| account["provider_id"] != "codex")
    {
        assert_eq!(account["state"], "disabled");
        assert_eq!(account["enabled"], false);
    }
    assert!(String::from_utf8_lossy(&output.stderr).contains("no supported quota API"));
    assert!(!String::from_utf8_lossy(&output.stdout).contains("secret-sentinel"));
    assert!(!String::from_utf8_lossy(&output.stderr).contains("secret-sentinel"));

    let scoped = fixture.usage(
        Some("auth"),
        &[
            "--provider",
            "codex",
            "--account",
            codex["id"].as_str().unwrap(),
        ],
    );
    assert_eq!(scoped.status.code(), Some(3));
    let scoped: serde_json::Value = serde_json::from_slice(&scoped.stdout).unwrap();
    assert_eq!(scoped["accounts"].as_array().unwrap().len(), 1);
    assert_eq!(scoped["accounts"][0]["id"], codex["id"]);

    let invalid_scope = fixture.usage(
        Some("auth"),
        &[
            "--provider",
            "codex",
            "--provider",
            "claude",
            "--account",
            codex["id"].as_str().unwrap(),
        ],
    );
    assert_eq!(invalid_scope.status.code(), Some(2));
    assert!(invalid_scope.stdout.is_empty());

    std::fs::write(
        fixture.0.join("proxy.yaml"),
        b"openai-compatibility: [ secret-sentinel",
    )
    .unwrap();
    let invalid = fixture.usage(Some("auth"), &["--provider", "openrouter"]);
    assert_eq!(invalid.status.code(), Some(2));
    assert!(!String::from_utf8_lossy(&invalid.stderr).contains("secret-sentinel"));
    std::fs::write(fixture.0.join("proxy.yaml"), &before[2]).unwrap();
    for (path, bytes) in paths.into_iter().zip(before) {
        assert_eq!(std::fs::read(fixture.0.join(path)).unwrap(), bytes);
    }
}

#[test]
fn cli_defaults_to_proxy_auth_directory_and_explicit_paths_replace_it() {
    let fixture = Fixture::new("default");
    let bytes = std::fs::read(fixture.0.join("auth/expired.json")).unwrap();
    std::fs::create_dir(fixture.0.join(".cli-proxy-api")).unwrap();
    let path = fixture.0.join(".cli-proxy-api/default.json");
    std::fs::write(&path, &bytes).unwrap();
    for (directory, filename) in [(None, "default.json"), (Some("auth"), "expired.json")] {
        let output = fixture.usage(directory, &["--provider", "codex"]);
        assert_eq!(output.status.code(), Some(3));
        let snapshot: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(snapshot["accounts"].as_array().unwrap().len(), 1);
        let source = &snapshot["accounts"][0]["sources"][0];
        assert_eq!(source["origin"], "borrowed_proxy");
        let reference = quotio::cache::fingerprint(&["cli_proxy_auth_file", "codex", filename]);
        assert_eq!(
            source["id"],
            format!(
                "external-{}",
                quotio::cache::fingerprint(&["codex", &reference])
            )
        );
        assert_eq!(
            snapshot["usage"][0]["issue"]["code"],
            "owner_refresh_required"
        );
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        assert!(!String::from_utf8_lossy(&output.stdout).contains("secret-sentinel"));
    }
    let missing = fixture.usage(Some("missing"), &["--provider", "codex"]);
    let snapshot: serde_json::Value = serde_json::from_slice(&missing.stdout).unwrap();
    assert!(snapshot["accounts"].as_array().unwrap().is_empty());
    assert_eq!(
        std::fs::read(fixture.0.join("auth/expired.json")).unwrap(),
        bytes
    );
}

#[tokio::test]
async fn serve_defaults_to_proxy_auth_directory_without_owner_writes() {
    use std::{process::Stdio, time::Duration};
    use tokio::io::{AsyncBufReadExt, BufReader};
    let fixture = Fixture::new("serve-default");
    let bytes = std::fs::read(fixture.0.join("auth/expired.json")).unwrap();
    std::fs::create_dir(fixture.0.join(".cli-proxy-api")).unwrap();
    let path = fixture.0.join(".cli-proxy-api/default.json");
    std::fs::write(&path, &bytes).unwrap();
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_quotio"))
        .env_clear()
        .env("HOME", &fixture.0)
        .env("PATH", &fixture.0)
        .env("QUOTIO_CACHE_DIR", fixture.0.join("cache"))
        .args([
            "serve",
            "--provider",
            "codex",
            "--no-saved-accounts",
            "--listen",
            "127.0.0.1:0",
            "--refresh-interval",
            "1",
            "--config",
        ])
        .arg(fixture.0.join("quotio.toml"))
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
    let base = line.strip_prefix("Quotio API listening on ").unwrap();
    let client = reqwest::Client::new();
    let mut last_snapshot = serde_json::Value::Null;
    let snapshot = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let snapshot: serde_json::Value = client
                .get(format!("{base}/v2/snapshot"))
                .send()
                .await
                .unwrap()
                .json()
                .await
                .unwrap();
            last_snapshot = snapshot.clone();
            if snapshot["accounts"]
                .as_array()
                .is_some_and(|accounts| !accounts.is_empty())
            {
                break snapshot;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "proxy snapshot not populated; last snapshot={last_snapshot}; child status={:?}",
            child.try_wait()
        )
    });
    assert_eq!(snapshot["accounts"].as_array().unwrap().len(), 1);
    let source = &snapshot["accounts"][0]["sources"][0];
    assert_eq!(source["origin"], "borrowed_proxy");
    let reference = quotio::cache::fingerprint(&["cli_proxy_auth_file", "codex", "default.json"]);
    assert_eq!(
        source["id"],
        format!(
            "external-{}",
            quotio::cache::fingerprint(&["codex", &reference])
        )
    );
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
    assert!(!snapshot.to_string().contains("secret-sentinel"));
    child.kill().await.unwrap();
}
