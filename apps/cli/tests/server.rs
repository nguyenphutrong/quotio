use clap::Parser;
use quotio::cli::{Cli, Command, ServeArgs};
use std::{path::PathBuf, process::Stdio, time::Duration};
use tokio::io::{AsyncBufReadExt, BufReader};

struct Config(PathBuf);
impl Config {
    fn new(name: &str) -> Self {
        let path =
            std::env::temp_dir().join(format!("quotio-server-{}-{name}.toml", std::process::id()));
        std::fs::write(&path, "enabled_providers = []\n").unwrap();
        Self(path)
    }
}
impl Drop for Config {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
        let _ = std::fs::remove_dir_all(self.0.with_extension("cache"));
    }
}

#[test]
fn server_argument_contract() {
    let Command::Serve(args) = Cli::try_parse_from(["quotio", "serve"]).unwrap().command else {
        panic!()
    };
    assert_eq!(args.listen.to_string(), "127.0.0.1:6767");
    assert_eq!(args.refresh_interval, None);
    assert!(args.account_vault_namespace.is_none());
    let Command::Serve(isolated) = Cli::try_parse_from([
        "quotio",
        "serve",
        "--manage",
        "--parent-pipe",
        "--account-vault-namespace",
        "manual-test",
        "--account-data-dir",
        "/tmp/quotio-manual-test",
        "--cli-proxy-auth-dir",
        "/tmp/quotio-proxy-auth",
    ])
    .unwrap()
    .command
    else {
        panic!()
    };
    assert_eq!(
        isolated.account_vault_namespace,
        Some("manual-test".parse().unwrap())
    );
    assert_eq!(
        isolated.cli_proxy_auth_dir,
        Some(PathBuf::from("/tmp/quotio-proxy-auth"))
    );
    for args in [
        vec!["--refresh-interval", "86401"],
        vec!["--timeout", "0"],
        vec!["--listen", "example.com:6767"],
        vec!["--token", "must-not-be-in-argv"],
        vec!["--account-vault-namespace", "manual-test"],
        vec!["--account-data-dir", "/tmp/quotio-manual-test"],
        vec!["--cli-proxy-auth-dir", "/tmp/quotio-proxy-auth"],
        vec!["--manage", "--cli-proxy-auth-dir", "/tmp/quotio-proxy-auth"],
        vec!["--manage", "--account-vault-namespace", "../production"],
        vec![
            "--manage",
            "--no-saved-accounts",
            "--account-vault-namespace",
            "manual-test",
        ],
    ] {
        assert!(Cli::try_parse_from(["quotio", "serve"].into_iter().chain(args)).is_err());
    }
    let Command::Serve(disabled) =
        Cli::try_parse_from(["quotio", "serve", "--refresh-interval", "0"])
            .unwrap()
            .command
    else {
        panic!()
    };
    assert_eq!(disabled.refresh_interval, Some(0));
}

#[tokio::test]
async fn startup_rejects_remote_bind_empty_selection_and_occupied_port() {
    let config = Config::new("startup");
    let args = || ServeArgs {
        parent_pipe: false,
        listen: "127.0.0.1:0".parse().unwrap(),
        provider: vec![],
        config: Some(config.0.clone()),
        refresh_interval: None,
        timeout: Some(1),
        no_saved_accounts: true,
        account_vault_namespace: None,
        account_data_dir: None,
        cli_proxy_auth_dir: None,
        manage: false,
        public_url: None,
        allow_origin: vec![],
    };

    let mut remote = args();
    remote.listen = "0.0.0.0:6767".parse().unwrap();
    assert!(matches!(
        quotio::server::run(remote).await,
        Err(quotio::server::ServerError::Listen)
    ));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut occupied = args();
    occupied.listen = listener.local_addr().unwrap();
    occupied.provider = vec![quotio::cli::Provider::Mock];
    assert!(matches!(
        quotio::server::run(occupied).await,
        Err(quotio::server::ServerError::Bind)
    ));
}

#[tokio::test]
async fn http_snapshots_security_and_process_shutdown() {
    let config = Config::new("http");
    let token = "synthetic-server-test-bearer-1234567890";
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_quotio"))
        .args([
            "serve",
            "--listen",
            "127.0.0.1:0",
            "--provider",
            "mock",
            "--no-saved-accounts",
            "--config",
        ])
        .arg(&config.0)
        .env("QUOTIO_SERVER_TOKEN", token)
        .env("QUOTIO_CACHE_DIR", config.0.with_extension("cache"))
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
    assert!(!line.contains(token));
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(3))
        .build()
        .unwrap();
    let get = |path: &str| client.get(format!("{base}{path}")).bearer_auth(token);
    let mut ready = false;
    for _ in 0..100 {
        let value: serde_json::Value = get("/health").send().await.unwrap().json().await.unwrap();
        if value["ready"] == true {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(ready);
    let response = get("/v1/usage").send().await.unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()["cache-control"], "no-store");
    assert!(
        !response
            .headers()
            .contains_key("access-control-allow-origin")
    );
    let snapshot: serde_json::Value = response.json().await.unwrap();
    assert_eq!(snapshot["schema_version"], 1);
    assert_eq!(snapshot["providers"][0]["provider"], "mock");
    assert_eq!(snapshot["failures"].as_array().unwrap().len(), 0);
    let filtered: serde_json::Value = get("/v1/usage/mock")
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(snapshot, filtered);
    let catalog: serde_json::Value = get("/v1/providers")
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        catalog["providers"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|p| p["enabled"] == true)
            .count(),
        1
    );
    for (path, status) in [
        ("/v1/usage/codex", 404),
        ("/v1/usage/not-a-provider", 404),
        ("/missing", 404),
        ("/v1/usage?token=private", 400),
    ] {
        let response = get(path).send().await.unwrap();
        assert_eq!(response.status(), status);
        assert!(!response.text().await.unwrap().contains("private"));
    }
    assert_eq!(
        client
            .get(format!("{base}/health"))
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        get("/health")
            .header("origin", "https://untrusted.example")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert_eq!(
        get("/health")
            .header("host", "untrusted.example")
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    assert_eq!(
        get("/health")
            .header("authorization", "Bearer wrong")
            .send()
            .await
            .unwrap()
            .status(),
        401
    );
    assert_eq!(
        client
            .post(format!("{base}/v1/usage"))
            .bearer_auth(token)
            .send()
            .await
            .unwrap()
            .status(),
        405
    );
    // Keep an idle TCP client open while shutting down, to exercise the drain bound.
    let _idle = tokio::net::TcpStream::connect(base.trim_start_matches("http://"))
        .await
        .unwrap();
    #[cfg(unix)]
    {
        assert_eq!(
            unsafe { libc::kill(child.id().unwrap() as i32, libc::SIGTERM) },
            0
        );
        assert!(
            tokio::time::timeout(Duration::from_secs(5), child.wait())
                .await
                .unwrap()
                .unwrap()
                .success()
        );
    }
    #[cfg(not(unix))]
    child.kill().await.unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn parent_pipe_bootstrap_authentication_and_eof_shutdown() {
    use tokio::io::AsyncWriteExt;
    let config = Config::new("parent-pipe");
    let token = "synthetic-parent-pipe-bearer-1234567890";
    let mut child = tokio::process::Command::new(env!("CARGO_BIN_EXE_quotio"))
        .args([
            "serve",
            "--manage",
            "--parent-pipe",
            "--listen",
            "127.0.0.1:0",
            "--no-saved-accounts",
            "--config",
        ])
        .arg(&config.0)
        .env_remove("QUOTIO_SERVER_TOKEN")
        .env("QUOTIO_CACHE_DIR", config.0.with_extension("cache"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let pid = child.id().unwrap();
    let mut input = child.stdin.take().unwrap();
    input
        .write_all(format!("{token}\n").as_bytes())
        .await
        .unwrap();
    let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
    let record = tokio::time::timeout(Duration::from_secs(10), lines.next_line())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(!record.contains(token));
    let record: serde_json::Value = serde_json::from_str(&record).unwrap();
    assert_eq!(record["bootstrap_version"], 1);
    assert_eq!(record["api_version"], 1);
    assert_eq!(record["server_version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(record["pid"], pid);
    assert_eq!(record["host"], "127.0.0.1");
    let port = record["port"].as_u64().unwrap();
    assert!(port > 0 && port <= 65535);
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();
    let url = format!("http://127.0.0.1:{port}/v1/status");
    assert_eq!(client.get(&url).send().await.unwrap().status(), 401);
    let status: serde_json::Value = client
        .get(&url)
        .bearer_auth(token)
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(status["access_mode"], "manage");
    assert_eq!(status["server_version"], record["server_version"]);
    drop(input);
    let output = tokio::time::timeout(Duration::from_secs(5), child.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    assert!(output.status.success());
    assert!(!String::from_utf8_lossy(&output.stderr).contains(token));
}

#[cfg(unix)]
#[tokio::test]
async fn parent_pipe_rejects_ambiguous_token_without_bootstrap() {
    let config = Config::new("parent-conflict");
    let output = tokio::process::Command::new(env!("CARGO_BIN_EXE_quotio"))
        .args([
            "serve",
            "--manage",
            "--parent-pipe",
            "--listen",
            "127.0.0.1:0",
            "--no-saved-accounts",
            "--config",
        ])
        .arg(&config.0)
        .env(
            "QUOTIO_SERVER_TOKEN",
            "synthetic-conflicting-token-1234567890",
        )
        .stdin(Stdio::null())
        .output()
        .await
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
    assert!(!String::from_utf8_lossy(&output.stderr).contains("synthetic-conflicting"));
    assert!(Cli::try_parse_from(["quotio", "serve", "--parent-pipe"]).is_err());
}
