//! Connection to the Quotio host. The UI depends only on `HostClient`; today the
//! implementation speaks the `/v2` contract over loopback, the same one the macOS
//! menu bar and the iPhone app use.
use std::{net::SocketAddr, path::PathBuf, sync::Arc, time::Duration};

use anyhow::{Context as _, Result, anyhow, bail};
use futures::{FutureExt as _, future::BoxFuture};
use quotio::{
    cli::{Provider, ServeArgs},
    contract::Snapshot,
    server::{self, Embedded},
    settings::NativePreferences,
};
pub use reqwest::Method;
use serde_json::Value;
use tokio::{runtime::Runtime, sync::oneshot};

pub trait HostClient: Send + Sync + 'static {
    fn snapshot(&self) -> BoxFuture<'static, Result<Snapshot>>;
    fn refresh(&self, provider: Option<String>) -> BoxFuture<'static, Result<()>>;
    /// One request; the response body, or `Null` for an empty one. Writes carry an
    /// `Idempotency-Key`, which the host requires for account changes.
    fn call(
        &self,
        method: Method,
        path: String,
        body: Option<Value>,
    ) -> BoxFuture<'static, Result<Value>>;
    /// A write that the host runs as a background operation: send it, wait for the
    /// operation to finish, and return its `result`.
    fn mutate(
        &self,
        method: Method,
        path: String,
        body: Option<Value>,
    ) -> BoxFuture<'static, Result<Value>>;
}

/// A host error code such as `duplicate_account`, with a sentence for people.
#[derive(Debug)]
pub struct HostError {
    pub code: String,
}

impl HostError {
    pub fn code(error: &anyhow::Error) -> Option<&str> {
        error.downcast_ref::<HostError>().map(|e| e.code.as_str())
    }
}

impl std::fmt::Display for HostError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let message = match self.code.as_str() {
            "credential_storage_unavailable" | "account_storage_disabled" => {
                "the account vault is locked"
            }
            "duplicate_account" => "this account is already in Quotio",
            "account_not_found" => "the account no longer exists",
            "account_busy" => "the account is busy; try again in a moment",
            "invalid_label" => "names must be 1–80 characters",
            "invalid_credential" | "credential_validation_failed" => {
                "the provider did not accept this credential"
            }
            "native_login_required" => "sign in with the provider’s own app first",
            "unsupported_operation" => "this provider does not support that",
            "oauth_failed" => "sign-in failed",
            "oauth_expired_or_cancelled" | "expired" => "sign-in expired; start again",
            "callback_port_unavailable" => {
                "another app is using the sign-in port (1455); close it and retry"
            }
            "permission_required" => "Quotio needs permission to read this login",
            "entry_required" => "choose which login to add",
            "no_saved_accounts" => "demo mode does not save accounts",
            "revision_conflict" | "settings_busy" => "settings changed elsewhere; try again",
            "setting_overridden" => "this setting is fixed by a command-line option",
            "share_port_unavailable" => "that port is already in use",
            "network_address_unavailable" => "that network address is not available",
            "invalid_share_address" => "enter an address like 192.168.1.24:6768",
            "invalid_public_url" => "enter an https:// address",
            "disable_sharing_before_changing_origin" => "turn sharing off before changing it",
            "history_storage_unavailable" => "quota history is unavailable",
            "operation_timeout" => "the host did not finish in time",
            code => return write!(f, "the host returned {code}"),
        };
        f.write_str(message)
    }
}

impl std::error::Error for HostError {}

pub struct HostOptions {
    /// Run only the deterministic `mock` provider and skip saved accounts.
    pub demo: bool,
}

/// Host running on a private Tokio runtime inside this process.
pub struct EmbeddedHost {
    runtime: Runtime,
    base: String,
    token: Arc<str>,
    http: reqwest::Client,
    stop: Option<oneshot::Sender<()>>,
}

impl EmbeddedHost {
    pub fn start(options: HostOptions) -> Result<Self> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("quotio-host")
            .enable_all()
            .build()?;
        let token = random_token()?;
        let (ready_tx, ready_rx) = oneshot::channel();
        let (stop_tx, stop_rx) = oneshot::channel();
        let args = serve_args(&options)?;
        let embedded = Embedded {
            token: token.clone(),
            preferences: (!options.demo).then(first_run_preferences),
            ready: ready_tx,
            stop: stop_rx,
        };
        runtime.spawn(async move {
            if let Err(error) = server::run_embedded(args, embedded).await {
                eprintln!("Quotio host stopped: {error}");
            }
        });
        let address: SocketAddr = runtime
            .block_on(async { tokio::time::timeout(Duration::from_secs(15), ready_rx).await })
            .context("host did not start in time")?
            .map_err(|_| anyhow!("host failed to start"))?;
        let http = reqwest::Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(30))
            .build()?;
        Ok(Self {
            runtime,
            base: format!("http://{address}"),
            token: token.into(),
            http,
            stop: Some(stop_tx),
        })
    }

    pub fn client(&self) -> Arc<dyn HostClient> {
        Arc::new(LoopbackClient {
            handle: self.runtime.handle().clone(),
            base: self.base.clone().into(),
            token: self.token.clone(),
            http: self.http.clone(),
        })
    }
}

impl Drop for EmbeddedHost {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}

fn serve_args(options: &HostOptions) -> Result<ServeArgs> {
    let (provider, vault_namespace, account_data_dir) = if options.demo {
        (vec![Provider::Mock], None, None)
    } else {
        // The desktop app keeps its own vault, like the macOS app's `quotio-macos`.
        let namespace = "quotio-desktop"
            .parse()
            .map_err(|error: &str| anyhow!(error))?;
        (Vec::new(), Some(namespace), Some(account_data_dir()?))
    };
    Ok(ServeArgs {
        parent_pipe: false,
        listen: SocketAddr::from(([127, 0, 0, 1], 0)),
        provider,
        // Its own settings too, apart from the command-line tool's `config.toml`.
        config: Some(project_dirs()?.config_dir().join("host.toml")),
        refresh_interval: None,
        timeout: None,
        no_saved_accounts: options.demo,
        account_vault_namespace: vault_namespace,
        account_data_dir,
        cli_proxy_auth_dir: None,
        cli_proxy_config: None,
        manage: true,
        public_url: None,
        allow_origin: Vec::new(),
    })
}

/// Settings the host saves the first time it starts with an empty config. It then
/// tracks every provider, as the macOS app does on first launch.
fn first_run_preferences() -> NativePreferences {
    NativePreferences {
        disabled_providers: Vec::new(),
        disabled_proxy_auth_files: Vec::new(),
        automatically_discover_logins: true,
        quota_history_enabled: true,
        refresh_interval: 600,
    }
}

fn project_dirs() -> Result<directories::ProjectDirs> {
    directories::ProjectDirs::from("app", "Quotio", "Quotio").context("no home directory")
}

fn account_data_dir() -> Result<PathBuf> {
    let dir = project_dirs()?.data_local_dir().join("accounts");
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(&dir)?;
    Ok(dir)
}

fn random_token() -> Result<String> {
    random_hex::<32>()
}

fn random_hex<const N: usize>() -> Result<String> {
    use ring::rand::{SecureRandom, SystemRandom};
    let mut bytes = [0u8; N];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| anyhow!("no secure random source"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

struct LoopbackClient {
    handle: tokio::runtime::Handle,
    base: Arc<str>,
    token: Arc<str>,
    http: reqwest::Client,
}

impl LoopbackClient {
    /// reqwest needs Tokio; run on the host runtime and await the join handle from GPUI.
    fn run<T: Send + 'static>(
        &self,
        work: impl Future<Output = Result<T>> + Send + 'static,
    ) -> BoxFuture<'static, Result<T>> {
        let task = self.handle.spawn(work);
        async move { task.await? }.boxed()
    }
}

impl LoopbackClient {
    fn request(&self, method: Method, path: &str, body: Option<Value>) -> reqwest::RequestBuilder {
        let writes = method != Method::GET;
        let mut request = self
            .http
            .request(method, format!("{}{path}", self.base))
            .bearer_auth(&*self.token);
        if writes && let Ok(key) = random_hex::<16>() {
            request = request.header("Idempotency-Key", key);
        }
        match body {
            Some(body) => request.json(&body),
            None => request,
        }
    }
}

async fn body(response: reqwest::Response) -> Result<Value> {
    let bytes = check(response).await?.bytes().await?;
    Ok(if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes)?
    })
}

impl HostClient for LoopbackClient {
    fn call(
        &self,
        method: Method,
        path: String,
        body: Option<Value>,
    ) -> BoxFuture<'static, Result<Value>> {
        let request = self.request(method, &path, body);
        self.run(async move { self::body(request.send().await?).await })
    }

    fn mutate(
        &self,
        method: Method,
        path: String,
        body: Option<Value>,
    ) -> BoxFuture<'static, Result<Value>> {
        let request = self.request(method, &path, body);
        let poll = {
            let http = self.http.clone();
            let base = self.base.clone();
            let token = self.token.clone();
            move |id: &str| {
                http.get(format!("{base}/v2/operations/{id}"))
                    .bearer_auth(&*token)
            }
        };
        self.run(async move {
            let mut operation = self::body(request.send().await?).await?;
            // Discovery and keychain prompts can take minutes; most writes finish in
            // well under a second.
            let deadline = tokio::time::Instant::now() + Duration::from_secs(300);
            while operation["status"] == "running" {
                if tokio::time::Instant::now() > deadline {
                    bail!(HostError {
                        code: "operation_timeout".into()
                    });
                }
                tokio::time::sleep(Duration::from_millis(250)).await;
                let id = operation["id"].as_str().context("operation without id")?;
                operation = self::body(poll(id).send().await?).await?;
            }
            match operation["status"].as_str() {
                Some("completed") => Ok(operation["result"].take()),
                _ => Err(HostError {
                    code: operation["error"]
                        .as_str()
                        .unwrap_or("operation_failed")
                        .to_owned(),
                }
                .into()),
            }
        })
    }

    fn snapshot(&self) -> BoxFuture<'static, Result<Snapshot>> {
        let request = self
            .http
            .get(format!("{}/v2/snapshot", self.base))
            .bearer_auth(&*self.token);
        self.run(async move {
            let response = check(request.send().await?).await?;
            let snapshot: Snapshot = response.json().await?;
            snapshot.validate().map_err(|code| anyhow!(code))?;
            Ok(snapshot)
        })
    }

    fn refresh(&self, provider: Option<String>) -> BoxFuture<'static, Result<()>> {
        let body = match provider {
            Some(provider) => serde_json::json!({ "providers": [provider] }),
            None => serde_json::json!({}),
        };
        let request = self
            .http
            .post(format!("{}/v2/refresh", self.base))
            .bearer_auth(&*self.token)
            .json(&body);
        self.run(async move {
            check(request.send().await?).await?;
            Ok(())
        })
    }
}

/// Turn a failed response into the host's error code, e.g. `credential_storage_unavailable`.
async fn check(response: reqwest::Response) -> Result<reqwest::Response> {
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    let body: Value = response.json().await.unwrap_or_default();
    match body["error"].as_str() {
        Some(code) => Err(HostError { code: code.into() }.into()),
        None => bail!("host returned {status}"),
    }
}

/// Serves a saved snapshot, for design review and screenshots without accounts.
pub struct FixtureClient(pub Snapshot);

impl HostClient for FixtureClient {
    fn snapshot(&self) -> BoxFuture<'static, Result<Snapshot>> {
        let snapshot = self.0.clone();
        async move { Ok(snapshot) }.boxed()
    }

    fn refresh(&self, _provider: Option<String>) -> BoxFuture<'static, Result<()>> {
        async { Ok(()) }.boxed()
    }

    fn call(&self, _: Method, _: String, _: Option<Value>) -> BoxFuture<'static, Result<Value>> {
        async { bail!("changes are not available while showing a fixture") }.boxed()
    }

    fn mutate(&self, _: Method, _: String, _: Option<Value>) -> BoxFuture<'static, Result<Value>> {
        async { bail!("changes are not available while showing a fixture") }.boxed()
    }
}

pub fn load_fixture(path: &std::path::Path) -> Result<Snapshot> {
    let snapshot: Snapshot = serde_json::from_slice(&std::fs::read(path)?)?;
    snapshot.validate().map_err(|code| anyhow!(code))?;
    Ok(snapshot)
}
