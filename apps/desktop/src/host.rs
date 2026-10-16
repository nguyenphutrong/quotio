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
};
use tokio::{runtime::Runtime, sync::oneshot};

pub trait HostClient: Send + Sync + 'static {
    fn snapshot(&self) -> BoxFuture<'static, Result<Snapshot>>;
    fn refresh(&self, provider: Option<String>) -> BoxFuture<'static, Result<()>>;
}

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
        config: None,
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

fn account_data_dir() -> Result<PathBuf> {
    let dirs =
        directories::ProjectDirs::from("app", "Quotio", "Quotio").context("no home directory")?;
    let dir = dirs.data_local_dir().join("accounts");
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, 0o700);
    builder.create(&dir)?;
    Ok(dir)
}

fn random_token() -> Result<String> {
    use ring::rand::{SecureRandom, SystemRandom};
    let mut bytes = [0u8; 32];
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

impl HostClient for LoopbackClient {
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
    let body: serde_json::Value = response.json().await.unwrap_or_default();
    match body["error"].as_str() {
        Some("credential_storage_unavailable") => bail!("the account vault is locked"),
        Some(code) => bail!("host returned {status} ({code})"),
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
}

pub fn load_fixture(path: &std::path::Path) -> Result<Snapshot> {
    let snapshot: Snapshot = serde_json::from_slice(&std::fs::read(path)?)?;
    snapshot.validate().map_err(|code| anyhow!(code))?;
    Ok(snapshot)
}
