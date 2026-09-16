use clap::{Args, Parser, Subcommand, ValueEnum};
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(name = "quotio", version, about = "Check provider quota and usage", color = clap::ColorChoice::Never)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}
#[derive(Debug, Subcommand)]
pub enum Command {
    /// List supported providers
    Providers,
    /// Assess one explicit Swift PIV envelope; never import or unlock credentials
    MigrationInspect {
        /// Absolute envelope path; symlink components are refused
        #[arg(long)]
        piv_envelope: PathBuf,
        /// Selected key fingerprint from Swift settings; not verified against hardware
        #[arg(long)]
        piv_fingerprint: String,
        /// Save assessment artifacts without replacement in an existing private directory
        #[arg(long)]
        stage_dir: Option<PathBuf>,
        /// Explicit Swift metadata file; all mapping declarations are required together
        #[arg(long, requires_all = ["account_id", "provider", "source", "credential_reference", "service"])]
        metadata: Option<PathBuf>,
        /// Exact Swift account ID (not a CLI account ID)
        #[arg(long, requires = "metadata")]
        account_id: Option<String>,
        /// Exact Swift provider identifier
        #[arg(long, requires = "metadata")]
        provider: Option<String>,
        /// Owned Swift source: quotioKeychain or apiKey
        #[arg(long, requires = "metadata")]
        source: Option<String>,
        /// Exact credential reference; currently only keychain is supported
        #[arg(long, requires = "metadata")]
        credential_reference: Option<String>,
        /// Explicit production or legacy Swift monitor-auth service
        #[arg(long, requires = "metadata")]
        service: Option<String>,
    },
    /// Add, select, list or remove accounts managed by Quotio
    Accounts(AccountsArgs),
    /// Collect quota for detected or explicitly selected providers
    Usage(UsageArgs),
    /// Serve cached usage through a local read-only HTTP API
    Serve(ServeArgs),
}
#[derive(Clone, Copy, Debug, Default, ValueEnum)]
pub enum Format {
    #[default]
    Text,
    Json,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    Mock,
    Codex,
    Amp,
    Antigravity,
    Synthetic,
    OpenRouter,
    Zai,
    MiniMax,
    Factory,
    Catalog(&'static str),
}
impl Provider {
    pub fn id(self) -> &'static str {
        match self {
            Self::Mock => "mock",
            Self::Codex => "codex",
            Self::Amp => "amp",
            Self::Antigravity => "antigravity",
            Self::Synthetic => "synthetic",
            Self::OpenRouter => "openrouter",
            Self::Zai => "zai",
            Self::MiniMax => "minimax",
            Self::Factory => "factory",
            Self::Catalog(id) => id,
        }
    }
    pub fn catalog(self) -> Option<&'static crate::providers::catalog::Definition> {
        match self {
            Self::Catalog(id) => crate::providers::catalog::find(id),
            _ => None,
        }
    }
}
impl ValueEnum for Provider {
    fn value_variants<'a>() -> &'a [Self] {
        static VALUES: std::sync::OnceLock<Vec<Provider>> = std::sync::OnceLock::new();
        VALUES.get_or_init(|| {
            let mut values = vec![
                Self::Mock,
                Self::Codex,
                Self::Amp,
                Self::Antigravity,
                Self::Synthetic,
                Self::OpenRouter,
                Self::Zai,
                Self::MiniMax,
                Self::Factory,
            ];
            let mut catalog: Vec<_> = crate::providers::catalog::definitions()
                .map(|d| Self::Catalog(d.id))
                .collect();
            catalog.sort_by_key(|p| p.id());
            values.extend(catalog);
            values
        })
    }
    fn to_possible_value(&self) -> Option<clap::builder::PossibleValue> {
        let value = clap::builder::PossibleValue::new(self.id());
        Some(match self {
            Self::Zai => value.alias("glm"),
            Self::Factory => value.alias("droid").alias("factory-droid"),
            _ => value,
        })
    }
}
impl serde::Serialize for Provider {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.id())
    }
}
impl<'de> serde::Deserialize<'de> for Provider {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let id = String::deserialize(deserializer)?;
        Self::from_str(&id, false).map_err(|_| serde::de::Error::custom("unsupported provider"))
    }
}
#[derive(Debug, Args)]
pub struct UsageArgs {
    /// Fetch selected accounts even when their cached usage is fresh
    #[arg(long)]
    pub force: bool,
    /// Select a provider instead of auto-detection; repeat to select more than one
    #[arg(long, value_enum)]
    pub provider: Vec<Provider>,
    #[arg(long, value_enum, default_value = "text")]
    pub format: Format,
    /// Total seconds allowed for each provider, including retries
    #[arg(long, default_value_t = 10, value_parser = clap::value_parser!(u64).range(1..=3600))]
    pub timeout: u64,
    /// Read this TOML config instead of the platform default
    #[arg(long)]
    pub config: Option<PathBuf>,
    /// Disable terminal color (output is currently always plain)
    #[arg(long)]
    pub no_color: bool,
    /// Write diagnostic logs to stderr
    #[arg(long)]
    pub verbose: bool,
    /// Use environment/local CLI sources without reading saved accounts
    #[arg(long)]
    pub no_saved_accounts: bool,
    /// Select one saved account ID, or local; requires exactly one provider
    #[arg(long, requires = "provider", conflicts_with = "no_saved_accounts")]
    pub account: Option<String>,
}

impl Provider {
    pub fn key_api(self) -> Option<crate::providers::key_api::Kind> {
        use crate::providers::key_api::Kind;
        match self {
            Self::Synthetic => Some(Kind::Synthetic),
            Self::OpenRouter => Some(Kind::OpenRouter),
            Self::Zai => Some(Kind::Zai),
            Self::MiniMax => Some(Kind::MiniMax),
            _ => None,
        }
    }
    pub fn api_key_name(self) -> Option<&'static str> {
        match self {
            Self::Amp => Some("AMP_API_KEY"),
            Self::Factory => Some("FACTORY_API_KEY"),
            Self::Catalog(id) => crate::providers::catalog::find(id)
                .filter(|d| d.auth == crate::providers::catalog::AuthKind::ApiKey)
                .map(|d| d.key_env),
            other => other.key_api().map(|k| k.key()),
        }
    }
    pub fn supports_accounts(self) -> bool {
        matches!(
            self,
            Self::Codex
                | Self::Antigravity
                | Self::Catalog("cursor" | "grok" | "claude" | "copilot" | "kiro")
        ) || self.api_key_name().is_some()
    }

    pub fn description(self) -> &'static str {
        match self {
            Self::Catalog(id) => match crate::providers::catalog::find(id).map(|d| d.auth) {
                Some(crate::providers::catalog::AuthKind::ApiKey) => {
                    "Usage via API key and provider-specific settings"
                }
                _ => "Usage via native OAuth login or explicit access token",
            },
            Self::Synthetic => "Subscription, rolling and search quota via Synthetic API key",
            Self::OpenRouter => "Key spending limits and USD usage via OpenRouter API key",
            Self::Zai => "Coding Plan quota via Z.ai or BigModel API key",
            Self::MiniMax => "Token Plan quota via MiniMax subscription key",
            Self::Mock => "Deterministic demo data; no live requests",
            Self::Codex => "ChatGPT quota via saved OAuth or installed Codex CLI",
            Self::Amp => "Quota and balances via saved API key or installed Amp CLI",
            Self::Antigravity => "Google quota API; existing Antigravity OAuth token",
            Self::Factory => {
                "Factory Droid quota via saved owned/native accounts or FACTORY_API_KEY"
            }
        }
    }
    pub fn adapter(self) -> std::sync::Arc<dyn crate::providers::ProviderAdapter> {
        if let Self::Catalog(id) = self {
            return std::sync::Arc::new(crate::providers::catalog::CatalogProvider(id));
        }
        if let Some(kind) = self.key_api() {
            return std::sync::Arc::new(crate::providers::key_api::KeyApiProvider(kind));
        }
        use crate::providers::{
            amp::AmpProvider, antigravity::AntigravityProvider, codex::CodexProvider,
            factory::FactoryProvider, mock::MockProvider,
        };
        match self {
            Self::Mock => std::sync::Arc::new(MockProvider),
            Self::Codex => std::sync::Arc::new(CodexProvider::default()),
            Self::Amp => std::sync::Arc::new(AmpProvider::default()),
            Self::Antigravity => std::sync::Arc::new(AntigravityProvider),
            Self::Factory => std::sync::Arc::new(FactoryProvider),
            Self::Synthetic | Self::OpenRouter | Self::Zai | Self::MiniMax | Self::Catalog(_) => {
                unreachable!("key API provider handled above")
            }
        }
    }
}

#[derive(Debug, Args)]
pub struct AccountsArgs {
    #[command(subcommand)]
    pub command: AccountCommand,
}
#[derive(Debug, Subcommand)]
pub enum AccountCommand {
    /// Allow Keychain to ask for access to the local Antigravity login
    Authorize {
        #[arg(long, value_enum)]
        provider: Provider,
    },
    /// Validate and save a new account in the OS credential store
    Add {
        #[arg(long, value_enum)]
        provider: Provider,
        /// Override the default email or masked API-key label
        #[arg(long)]
        label: Option<String>,
        /// Read an API key from a pipe instead of the hidden terminal prompt
        #[arg(long)]
        token_stdin: bool,
        /// Print the Codex sign-in URL without opening a browser
        #[arg(long)]
        no_browser: bool,
        /// Factory: global/eu; Z.ai and MiniMax: global/cn
        #[arg(long,value_parser=["global","eu","cn"])]
        region: Option<String>,
        #[arg(long)]
        organization: Option<String>,
        /// Provider metadata such as project or region; repeat NAME=VALUE, never secrets
        #[arg(long = "setting", value_name = "NAME=VALUE")]
        settings: Vec<String>,
    },
    /// List saved account metadata without credentials
    List {
        #[arg(long, value_enum, default_value = "text")]
        format: Format,
    },
    /// Select the active account for its provider
    Use { id: String },
    /// Remove a Quotio-managed account; other apps remain signed in
    Remove { id: String },
}

#[derive(Debug, Args)]
pub struct ServeArgs {
    /// Native parent protocol: token on stdin, bootstrap JSON on stdout, stop on stdin EOF
    #[arg(long, requires = "manage")]
    pub parent_pipe: bool,
    /// Listen on a loopback address; port 0 selects an available port
    #[arg(long, default_value = "127.0.0.1:6767")]
    pub listen: std::net::SocketAddr,
    /// Enable a provider; repeat to enable more than one
    #[arg(long, value_enum)]
    pub provider: Vec<Provider>,
    /// Read this TOML config instead of the platform default
    #[arg(long)]
    pub config: Option<PathBuf>,
    /// Seconds between completed refresh cycles
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..=86400))]
    pub refresh_interval: Option<u64>,
    /// Total seconds allowed for each provider, including retries
    #[arg(long, value_parser = clap::value_parser!(u64).range(1..=3600))]
    pub timeout: Option<u64>,
    /// Use environment/local sources without reading saved accounts
    #[arg(long)]
    pub no_saved_accounts: bool,
    /// Store managed accounts in a separate application-owned vault namespace
    #[arg(long, requires_all = ["manage", "parent_pipe", "account_data_dir"], conflicts_with = "no_saved_accounts")]
    pub account_vault_namespace: Option<crate::accounts::vault::VaultNamespace>,
    /// Store isolated account locks and platform vault data in this absolute directory
    #[arg(long, requires = "account_vault_namespace")]
    pub account_data_dir: Option<PathBuf>,
    /// Read supported CLIProxyAPI auth files without importing or modifying them
    #[arg(long, requires_all = ["manage", "parent_pipe"])]
    pub cli_proxy_auth_dir: Option<PathBuf>,
    /// Enable account/auth/settings/refresh writes; requires QUOTIO_SERVER_TOKEN
    #[arg(long)]
    pub manage: bool,
    /// External HTTPS origin supplied by your reverse proxy or tunnel
    #[arg(long)]
    pub public_url: Option<String>,
    /// Allow this exact browser origin; repeat for multiple origins
    #[arg(long)]
    pub allow_origin: Vec<String>,
}
