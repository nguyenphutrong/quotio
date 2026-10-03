//! Explicit native and proxy references. No discovery or writes.
use super::{AccountError, Credential};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AntigravityLocation {
    GeminiKeychain,
    StateDb,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct AntigravityNativeReference {
    pub location: AntigravityLocation,
    pub path: Option<std::path::PathBuf>,
}
impl AntigravityNativeReference {
    pub fn system(location: AntigravityLocation) -> Result<Self, AccountError> {
        let path = match location {
            AntigravityLocation::StateDb => Some(
                std::env::var_os("HOME")
                    .map(std::path::PathBuf::from)
                    .ok_or(AccountError::NotFound)?
                    .join("Library/Application Support/Antigravity/User/globalStorage/state.vscdb"),
            ),
            _ if !cfg!(target_os = "macos") => return Err(AccountError::Unsupported),
            _ => None,
        };
        let source = Self { location, path };
        source.identity()?;
        Ok(source)
    }
    pub fn identity(&self) -> Result<String, AccountError> {
        let location = match (self.location, &self.path) {
            (AntigravityLocation::GeminiKeychain, None) => "gemini/antigravity",
            (AntigravityLocation::StateDb, Some(path))
                if path.is_absolute()
                    && path.ends_with(
                        "Library/Application Support/Antigravity/User/globalStorage/state.vscdb",
                    )
                    && !path
                        .components()
                        .any(|c| matches!(c, std::path::Component::ParentDir)) =>
            {
                path.to_str().ok_or(AccountError::Input)?
            }
            _ => return Err(AccountError::Input),
        };
        Ok(crate::cache::fingerprint(&["antigravity_native", location]))
    }
    pub async fn resolve(&self) -> Result<Resolved, AccountError> {
        self.identity()?;
        let credential = crate::providers::antigravity_auth::reference_token(self).await?;
        Ok(Resolved {
            label: "Antigravity native account".into(),
            provider: crate::cli::Provider::Antigravity,
            plan: None,
            subscription_status: None,
            credentials: vec![credential],
        })
    }
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CopilotLocation {
    Apps,
    Hosts,
    GhHosts,
    GhKeychain,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CopilotNativeReference {
    pub location: CopilotLocation,
    pub path: Option<std::path::PathBuf>,
    pub entry_key: String,
}
impl CopilotNativeReference {
    pub fn system(location: CopilotLocation, entry_key: String) -> Result<Self, AccountError> {
        let path = match location {
            CopilotLocation::Apps | CopilotLocation::Hosts => Some(
                std::env::var_os("HOME")
                    .map(std::path::PathBuf::from)
                    .ok_or(AccountError::NotFound)?
                    .join(match location {
                        CopilotLocation::Apps => ".config/github-copilot/apps.json",
                        _ => ".config/github-copilot/hosts.json",
                    }),
            ),
            CopilotLocation::GhHosts => Some(
                std::env::var_os("HOME")
                    .map(std::path::PathBuf::from)
                    .ok_or(AccountError::NotFound)?
                    .join(".config/gh/hosts.yml"),
            ),
            CopilotLocation::GhKeychain => {
                if !cfg!(target_os = "macos") {
                    return Err(AccountError::Unsupported);
                }
                None
            }
        };
        let source = Self {
            location,
            path,
            entry_key,
        };
        source.identity()?;
        Ok(source)
    }
    pub fn identity(&self) -> Result<String, AccountError> {
        let key = &self.entry_key;
        if key.len() > 256 || key.is_empty() || key.chars().any(char::is_control) {
            return Err(AccountError::Input);
        }
        let location = match (self.location, &self.path) {
            (CopilotLocation::Apps | CopilotLocation::Hosts, Some(path))
                if path.is_absolute()
                    && !path
                        .components()
                        .any(|c| matches!(c, std::path::Component::ParentDir)) =>
            {
                if !(key == "github.com"
                    || key.strip_prefix("github.com:").is_some_and(|suffix| {
                        !suffix.is_empty()
                            && suffix
                                .bytes()
                                .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
                    }))
                {
                    return Err(AccountError::Input);
                }
                path.to_str().ok_or(AccountError::Input)?
            }
            (CopilotLocation::GhHosts, Some(path))
                if key == "github.com"
                    && path.is_absolute()
                    && !path
                        .components()
                        .any(|c| matches!(c, std::path::Component::ParentDir)) =>
            {
                path.to_str().ok_or(AccountError::Input)?
            }
            (CopilotLocation::GhKeychain, None) => "gh:github.com",
            _ => return Err(AccountError::Input),
        };
        Ok(crate::cache::fingerprint(&[
            "copilot_native",
            location,
            key,
        ]))
    }
    pub async fn resolve(&self) -> Result<Resolved, AccountError> {
        self.identity()?;
        let token = match self.location {
            CopilotLocation::GhHosts => {
                crate::providers::catalog::oauth_primary::copilot_gh_hosts_reference_token(
                    self.path.clone().ok_or(AccountError::Input)?,
                    &self.entry_key,
                )
                .await?
            }
            _ => {
                crate::providers::catalog::oauth_primary::copilot_reference_token(
                    self.path.clone(),
                    &self.entry_key,
                )
                .await?
            }
        };
        Ok(Resolved {
            label: format!("Copilot {}", &self.identity()?[..8]),
            provider: crate::cli::Provider::Catalog("copilot"),
            plan: None,
            subscription_status: None,
            credentials: vec![Credential::CatalogKey {
                token: token.0,
                settings: Default::default(),
            }],
        })
    }
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ClaudeLocation {
    CodeFile,
    CodeKeychain,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ClaudeNativeReference {
    pub location: ClaudeLocation,
    pub path: Option<std::path::PathBuf>,
}
impl ClaudeNativeReference {
    pub fn system(location: ClaudeLocation) -> Result<Self, AccountError> {
        let path = match location {
            ClaudeLocation::CodeFile => Some(
                std::env::var_os("HOME")
                    .map(std::path::PathBuf::from)
                    .ok_or(AccountError::NotFound)?
                    .join(".claude/.credentials.json"),
            ),
            ClaudeLocation::CodeKeychain => {
                if !cfg!(target_os = "macos") {
                    return Err(AccountError::Unsupported);
                }
                None
            }
        };
        let source = Self { location, path };
        source.identity()?;
        Ok(source)
    }
    pub fn identity(&self) -> Result<String, AccountError> {
        let location = match (self.location, &self.path) {
            (ClaudeLocation::CodeFile, Some(path))
                if path.is_absolute()
                    && !path
                        .components()
                        .any(|c| matches!(c, std::path::Component::ParentDir)) =>
            {
                path.to_str().ok_or(AccountError::Input)?
            }
            (ClaudeLocation::CodeKeychain, None) => "Claude Code-credentials",
            _ => return Err(AccountError::Input),
        };
        Ok(crate::cache::fingerprint(&["claude_native", location]))
    }
    pub async fn resolve(&self) -> Result<Resolved, AccountError> {
        self.identity()?;
        let token =
            crate::providers::catalog::oauth_primary::claude_reference_token(self.path.clone())
                .await?;
        Ok(Resolved {
            label: match self.location {
                ClaudeLocation::CodeFile => "Claude Code file",
                ClaudeLocation::CodeKeychain => "Claude Code Keychain",
            }
            .into(),
            provider: crate::cli::Provider::Catalog("claude"),
            plan: None,
            subscription_status: None,
            credentials: vec![Credential::CatalogKey {
                token: token.0,
                settings: Default::default(),
            }],
        })
    }
}

#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct KiroNativeReference {
    pub path: std::path::PathBuf,
}
impl KiroNativeReference {
    pub fn system() -> Result<Self, AccountError> {
        Ok(Self {
            path: std::env::var_os("HOME")
                .map(std::path::PathBuf::from)
                .ok_or(AccountError::NotFound)?
                .join(".aws/sso/cache/kiro-auth-token.json"),
        })
    }
    pub fn identity(&self) -> Result<String, AccountError> {
        if !self.path.is_absolute()
            || !self.path.ends_with(".aws/sso/cache/kiro-auth-token.json")
            || self
                .path
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir))
        {
            return Err(AccountError::Input);
        }
        Ok(crate::cache::fingerprint(&[
            "kiro_native",
            self.path.to_str().ok_or(AccountError::Input)?,
        ]))
    }
    pub async fn resolve(&self) -> Result<Resolved, AccountError> {
        self.identity()?;
        let credential =
            crate::providers::catalog::oauth_cloud::kiro_reference_token(&self.path).await?;
        Ok(Resolved {
            label: "Kiro native account".into(),
            provider: crate::cli::Provider::Catalog("kiro"),
            plan: None,
            subscription_status: None,
            credentials: vec![credential],
        })
    }
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum FactoryLocation {
    V2File,
    V2LoginKeychain,
    V2Keyring,
    Legacy,
}
impl FactoryLocation {
    pub(crate) fn filename(self) -> &'static str {
        match self {
            Self::V2File => "auth.v2.file",
            Self::V2LoginKeychain => "auth.v2.loginkeychain",
            Self::V2Keyring => "auth.v2.keyring",
            Self::Legacy => "auth.encrypted",
        }
    }
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct FactoryNativeReference {
    pub directory: std::path::PathBuf,
    pub location: FactoryLocation,
}
impl FactoryNativeReference {
    pub fn system(location: FactoryLocation) -> Result<Self, AccountError> {
        if !cfg!(target_os = "macos")
            && matches!(
                location,
                FactoryLocation::V2LoginKeychain | FactoryLocation::V2Keyring
            )
        {
            return Err(AccountError::Unsupported);
        }
        let source = Self {
            directory: std::env::var_os("HOME")
                .map(std::path::PathBuf::from)
                .ok_or(AccountError::NotFound)?
                .join(".factory"),
            location,
        };
        source.identity()?;
        Ok(source)
    }
    pub fn identity(&self) -> Result<String, AccountError> {
        if !self.directory.is_absolute()
            || self
                .directory
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir))
        {
            return Err(AccountError::Input);
        }
        Ok(crate::cache::fingerprint(&[
            "factory_native",
            self.directory.to_str().ok_or(AccountError::Input)?,
            self.location.filename(),
        ]))
    }
    pub async fn resolve(&self) -> Result<Resolved, AccountError> {
        self.identity()?;
        let credential = crate::providers::factory::load_native(self).await?;
        Ok(Resolved {
            label: format!("Factory {}", self.location.filename()),
            provider: crate::cli::Provider::Factory,
            plan: None,
            subscription_status: None,
            credentials: vec![credential],
        })
    }
}

#[derive(Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DevinDesktopLocation {
    CredentialsToml,
    StateDatabase,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DevinDesktopNativeReference {
    pub path: std::path::PathBuf,
    pub location: DevinDesktopLocation,
}
impl DevinDesktopNativeReference {
    pub fn system(location: DevinDesktopLocation) -> Result<Self, AccountError> {
        let home = std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .ok_or(AccountError::NotFound)?;
        let relative = match location {
            DevinDesktopLocation::CredentialsToml => ".local/share/devin/credentials.toml",
            DevinDesktopLocation::StateDatabase if cfg!(target_os = "macos") => {
                "Library/Application Support/Devin/User/globalStorage/state.vscdb"
            }
            DevinDesktopLocation::StateDatabase if cfg!(target_os = "linux") => {
                ".config/Devin/User/globalStorage/state.vscdb"
            }
            _ => return Err(AccountError::Unsupported),
        };
        let source = Self {
            path: home.join(relative),
            location,
        };
        source.identity()?;
        Ok(source)
    }
    pub fn identity(&self) -> Result<String, AccountError> {
        if !self.path.is_absolute()
            || self
                .path
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir))
        {
            return Err(AccountError::Input);
        }
        Ok(crate::cache::fingerprint(&[
            "devin_desktop_native",
            self.path.to_str().ok_or(AccountError::Input)?,
            match self.location {
                DevinDesktopLocation::CredentialsToml => "credentials_toml",
                DevinDesktopLocation::StateDatabase => "state_database",
            },
        ]))
    }
    pub async fn resolve(&self) -> Result<Resolved, AccountError> {
        self.identity()?;
        let token = crate::providers::catalog::devin_desktop::load_native(self).await?;
        Ok(Resolved {
            label: match self.location {
                DevinDesktopLocation::CredentialsToml => "Devin Desktop credentials.toml",
                DevinDesktopLocation::StateDatabase => "Devin Desktop state.vscdb",
            }
            .into(),
            provider: crate::cli::Provider::Catalog("devin-desktop"),
            plan: None,
            subscription_status: None,
            credentials: vec![Credential::CatalogKey {
                token: token.0,
                settings: Default::default(),
            }],
        })
    }
}

fn enabled_default() -> bool {
    true
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct AmpNativeReference {
    pub path: std::path::PathBuf,
    #[serde(default = "enabled_default")]
    pub enabled: bool,
}
impl AmpNativeReference {
    pub fn system() -> Result<Self, AccountError> {
        let path = crate::providers::amp::AmpProvider::default()
            .credential_path
            .ok_or(AccountError::Unsupported)?;
        Ok(Self {
            path,
            enabled: true,
        })
    }
    pub fn identity(&self) -> Result<String, AccountError> {
        if !self.path.is_absolute() {
            return Err(AccountError::Input);
        }
        Ok(crate::cache::fingerprint(&[
            "amp_native",
            self.path.to_str().ok_or(AccountError::Input)?,
        ]))
    }
    pub async fn resolve(&self) -> Result<Resolved, AccountError> {
        self.identity()?;
        if !self.enabled {
            return Err(AccountError::SourceDisabled);
        }
        let path = self.path.clone();
        let token = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            tokio::task::spawn_blocking(move || crate::providers::amp::local_key(&path)),
        )
        .await
        .map_err(|_| AccountError::Busy)?
        .map_err(|_| AccountError::Storage)??
        .ok_or(AccountError::NotFound)?;
        Ok(Resolved {
            plan: None,
            subscription_status: None,
            label: "Local Amp account".into(),
            provider: crate::cli::Provider::Amp,
            credentials: vec![Credential::ApiKey {
                token,
                region: None,
                organization: None,
            }],
        })
    }
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CursorNativeReference {
    pub path: std::path::PathBuf,
}
impl CursorNativeReference {
    pub fn system() -> Result<Self, AccountError> {
        #[cfg(target_os = "macos")]
        {
            crate::providers::catalog::oauth_editors::cursor_state_database_path()
                .map(|path| Self { path })
                .ok_or(AccountError::Unsupported)
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err(AccountError::Unsupported)
        }
    }
    pub fn identity(&self) -> Result<String, AccountError> {
        if !self.path.is_absolute() {
            return Err(AccountError::Input);
        }
        Ok(crate::cache::fingerprint(&[
            "cursor_native",
            self.path.to_str().ok_or(AccountError::Input)?,
        ]))
    }
    pub async fn resolve(&self) -> Result<Resolved, AccountError> {
        self.identity()?;
        let login =
            crate::providers::catalog::oauth_editors::cursor_login(self.path.clone()).await?;
        Ok(Resolved {
            label: login.email.unwrap_or_else(|| "Local Cursor account".into()),
            plan: login
                .membership
                .as_deref()
                .map(crate::providers::catalog::oauth_editors::cursor_plan_name),
            subscription_status: login.subscription_status,
            provider: crate::cli::Provider::Catalog("cursor"),
            credentials: vec![Credential::CatalogKey {
                token: login.token,
                settings: Default::default(),
            }],
        })
    }
}

#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct GrokNativeReference {
    pub path: std::path::PathBuf,
    pub entry_key: String,
}
impl GrokNativeReference {
    pub fn system(entry_key: String) -> Result<Self, AccountError> {
        let source = Self {
            path: crate::providers::catalog::oauth_editors::grok_auth_path()
                .ok_or(AccountError::Unsupported)?,
            entry_key,
        };
        source.identity()?;
        Ok(source)
    }
    pub fn identity(&self) -> Result<String, AccountError> {
        let key = &self.entry_key;
        if !self.path.is_absolute()
            || key.len() > 256
            || !(key == "https://accounts.x.ai/sign-in"
                || key.strip_prefix("https://auth.x.ai::").is_some_and(|id| {
                    !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                }))
        {
            return Err(AccountError::Input);
        }
        Ok(crate::cache::fingerprint(&[
            "grok_native",
            self.path.to_str().ok_or(AccountError::Input)?,
            key,
        ]))
    }
    pub async fn resolve(&self) -> Result<Resolved, AccountError> {
        self.identity()?;
        let source = self.clone();
        let token = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            tokio::task::spawn_blocking(move || {
                crate::providers::catalog::oauth_editors::grok_entry_token(
                    &source.path,
                    &source.entry_key,
                    time::OffsetDateTime::now_utc(),
                )
            }),
        )
        .await
        .map_err(|_| AccountError::Busy)?
        .map_err(|_| AccountError::Storage)??;
        Ok(Resolved {
            label: format!("Grok {}", &self.identity()?[..8]),
            provider: crate::cli::Provider::Catalog("grok"),
            plan: None,
            subscription_status: None,
            credentials: vec![Credential::CatalogKey {
                token: token.0,
                settings: Default::default(),
            }],
        })
    }
}

#[derive(Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CodexLocation {
    #[default]
    Default,
    Config,
    CodexHome,
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CodexNativeReference {
    pub path: std::path::PathBuf,
}
impl CodexNativeReference {
    pub fn system(location: CodexLocation) -> Result<Self, AccountError> {
        let path = match location {
            CodexLocation::CodexHome => std::env::var_os("CODEX_HOME")
                .map(std::path::PathBuf::from)
                .ok_or(AccountError::NotFound)?
                .join("auth.json"),
            location => std::env::var_os("HOME")
                .map(std::path::PathBuf::from)
                .ok_or(AccountError::NotFound)?
                .join(match location {
                    CodexLocation::Config => ".config/codex/auth.json",
                    _ => ".codex/auth.json",
                }),
        };
        let source = Self { path };
        source.identity()?;
        Ok(source)
    }
    pub fn identity(&self) -> Result<String, AccountError> {
        if !self.path.is_absolute()
            || self
                .path
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir))
        {
            return Err(AccountError::Input);
        }
        Ok(crate::cache::fingerprint(&[
            "codex_native",
            self.path.to_str().ok_or(AccountError::Input)?,
        ]))
    }
    pub async fn resolve(&self) -> Result<Resolved, AccountError> {
        self.identity()?;
        let path = self.path.clone();
        let credential = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            tokio::task::spawn_blocking(move || crate::providers::codex_native::load(&path)),
        )
        .await
        .map_err(|_| AccountError::Busy)?
        .map_err(|_| AccountError::Storage)??;
        let Credential::CodexOAuth { ref email, .. } = credential else {
            return Err(AccountError::Corrupt);
        };
        Ok(Resolved {
            label: email.clone(),
            provider: crate::cli::Provider::Codex,
            plan: None,
            subscription_status: None,
            credentials: vec![credential],
        })
    }
}

impl Credential {
    pub async fn resolve_reference(
        &self,
        provider: crate::cli::Provider,
    ) -> Result<Option<Resolved>, AccountError> {
        match self {
            Self::DevinDesktopNative { source }
                if provider == crate::cli::Provider::Catalog("devin-desktop") =>
            {
                source.resolve().await.map(Some)
            }
            Self::AntigravityNative { source } if provider == crate::cli::Provider::Antigravity => {
                source.resolve().await.map(Some)
            }
            Self::KiroNative { source } if provider == crate::cli::Provider::Catalog("kiro") => {
                source.resolve().await.map(Some)
            }
            Self::FactoryNative { source } if provider == crate::cli::Provider::Factory => {
                source.resolve().await.map(Some)
            }
            Self::CopilotNative { source }
                if provider == crate::cli::Provider::Catalog("copilot") =>
            {
                source.resolve().await.map(Some)
            }
            Self::ClaudeNative { source }
                if provider == crate::cli::Provider::Catalog("claude") =>
            {
                source.resolve().await.map(Some)
            }
            Self::CodexNative { source } if provider == crate::cli::Provider::Codex => {
                source.resolve().await.map(Some)
            }
            Self::QuotioCustomProvider { source }
                if matches!(
                    provider,
                    crate::cli::Provider::Catalog("clinepass") | crate::cli::Provider::Zai
                ) =>
            {
                let resolved = source.resolve().await?;
                if resolved.provider != provider {
                    return Err(AccountError::Unsupported);
                }
                Ok(Some(resolved))
            }
            Self::AmpNative { source } if provider == crate::cli::Provider::Amp => {
                source.resolve().await.map(Some)
            }
            Self::GrokNative { source } if provider == crate::cli::Provider::Catalog("grok") => {
                source.resolve().await.map(Some)
            }
            Self::CursorNative { source }
                if provider == crate::cli::Provider::Catalog("cursor") =>
            {
                source.resolve().await.map(Some)
            }
            Self::QuotioCustomProvider { .. }
            | Self::DevinDesktopNative { .. }
            | Self::FactoryNative { .. }
            | Self::KiroNative { .. }
            | Self::AntigravityNative { .. }
            | Self::CodexNative { .. }
            | Self::ClaudeNative { .. }
            | Self::CopilotNative { .. }
            | Self::AmpNative { .. }
            | Self::GrokNative { .. }
            | Self::CursorNative { .. } => Err(AccountError::Unsupported),
            _ => Ok(None),
        }
    }
}

#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum QuotioDomain {
    Production,
    Development,
    #[serde(untagged)]
    BundleIdentifier(#[serde(deserialize_with = "deserialize_bundle_identifier")] String),
}
fn deserialize_bundle_identifier<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<String, D::Error> {
    let value = String::deserialize(deserializer)?;
    let domain = QuotioDomain::BundleIdentifier(value.clone());
    domain
        .identifier()
        .map_err(|_| serde::de::Error::custom("invalid bundle identifier"))?;
    Ok(value)
}
impl QuotioDomain {
    fn identifier(&self) -> Result<&str, AccountError> {
        match self {
            Self::Production => Ok("app.bytrong.quotio"),
            Self::Development => Ok("app.bytrong.quotio.dev"),
            Self::BundleIdentifier(value)
                if value.len() <= 255
                    && value.contains('.')
                    && value.split('.').all(|part| {
                        !part.is_empty()
                            && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                    }) =>
            {
                Ok(value)
            }
            Self::BundleIdentifier(_) => Err(AccountError::Input),
        }
    }
}
#[derive(Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CustomProviderReference {
    pub domain: QuotioDomain,
    pub record_id: String,
}
#[derive(Clone, Serialize, PartialEq, Eq)]
pub struct Resolved {
    pub plan: Option<String>,
    pub subscription_status: Option<String>,
    pub label: String,
    pub provider: crate::cli::Provider,
    pub credentials: Vec<Credential>,
}
#[derive(Deserialize)]
struct Record {
    id: String,
    name: String,
    #[serde(rename = "type")]
    kind: String,
    #[serde(rename = "base-url")]
    base_url: Option<String>,
    #[serde(rename = "is-enabled")]
    enabled: Option<bool>,
    #[serde(rename = "api-keys")]
    keys: Option<Vec<Key>>,
}
#[derive(Deserialize)]
struct Key {
    #[serde(rename = "api-key")]
    token: String,
}
impl CustomProviderReference {
    pub fn identity(&self) -> Result<String, AccountError> {
        let id = &self.record_id;
        if id.len() != 36
            || !id.bytes().enumerate().all(|(i, b)| {
                if [8, 13, 18, 23].contains(&i) {
                    b == b'-'
                } else {
                    b.is_ascii_hexdigit()
                }
            })
        {
            return Err(AccountError::Input);
        }
        Ok(crate::cache::fingerprint(&[
            "quotio_custom_provider",
            self.domain.identifier()?,
            &id.to_ascii_lowercase(),
        ]))
    }
    pub(super) fn parse(&self, bytes: &[u8]) -> Result<Resolved, AccountError> {
        self.identity()?;
        if bytes.len() > 1024 * 1024 {
            return Err(AccountError::Corrupt);
        }
        let records: Vec<Record> =
            serde_json::from_slice(bytes).map_err(|_| AccountError::Corrupt)?;
        let mut matching = records
            .iter()
            .filter(|r| r.id.eq_ignore_ascii_case(&self.record_id));
        let record = matching.next().ok_or(AccountError::NotFound)?;
        if matching.next().is_some() {
            return Err(AccountError::Corrupt);
        }
        if record.enabled == Some(false) {
            return Err(AccountError::SourceDisabled);
        }
        let keys = record.keys.as_deref().unwrap_or_default();
        let valid = |token: &str| {
            !token.trim().is_empty()
                && token.len() <= 16_384
                && !token.chars().any(char::is_control)
        };
        let (provider, credentials) = match record.kind.as_str() {
            "clinepass" => {
                let token = keys.first().ok_or(AccountError::Input)?.token.trim();
                if !valid(token) {
                    return Err(AccountError::Input);
                }
                (
                    crate::cli::Provider::Catalog("clinepass"),
                    vec![Credential::CatalogKey {
                        token: token.into(),
                        settings: Default::default(),
                    }],
                )
            }
            "glm-api-key" => {
                let url = record
                    .base_url
                    .as_deref()
                    .and_then(|v| reqwest::Url::parse(v).ok())
                    .ok_or(AccountError::Settings)?;
                if url.scheme() != "https"
                    || url.host_str() != Some("api.z.ai")
                    || url.port_or_known_default() != Some(443)
                    || !url.username().is_empty()
                    || url.password().is_some()
                {
                    return Err(AccountError::Unsupported);
                }
                if !keys.iter().any(|key| valid(&key.token)) {
                    return Err(AccountError::Input);
                }
                (
                    crate::cli::Provider::Zai,
                    keys.iter()
                        .map(|key| Credential::ApiKey {
                            token: key.token.trim().into(),
                            region: Some("global".into()),
                            organization: None,
                        })
                        .collect(),
                )
            }
            _ => return Err(AccountError::Unsupported),
        };
        Ok(Resolved {
            plan: None,
            subscription_status: None,
            label: super::validate_label(&record.name)?,
            provider,
            credentials,
        })
    }

    pub async fn resolve(&self) -> Result<Resolved, AccountError> {
        self.identity()?;
        let source = self.clone();
        tokio::time::timeout(
            std::time::Duration::from_secs(10),
            tokio::task::spawn_blocking(move || {
                source.parse(&read_preferences(source.domain.clone())?)
            }),
        )
        .await
        .map_err(|_| AccountError::Busy)?
        .map_err(|_| AccountError::Storage)?
    }
}
#[cfg(target_os = "macos")]
pub(super) fn read_preferences(domain: QuotioDomain) -> Result<Vec<u8>, AccountError> {
    read_preferences_domain(domain.identifier()?)
}
#[cfg(target_os = "macos")]
fn read_preferences_domain(identifier: &str) -> Result<Vec<u8>, AccountError> {
    use core_foundation::{
        base::{CFType, CFTypeRef, TCFType},
        data::CFData,
        string::{CFString, CFStringRef},
    };
    unsafe extern "C" {
        fn CFPreferencesCopyAppValue(key: CFStringRef, application_id: CFStringRef) -> CFTypeRef;
    }
    let key = CFString::new("customProviders");
    let domain = CFString::new(identifier);
    let value = unsafe {
        CFPreferencesCopyAppValue(key.as_concrete_TypeRef(), domain.as_concrete_TypeRef())
    };
    if value.is_null() {
        return Err(AccountError::NotFound);
    }
    let value = unsafe { CFType::wrap_under_create_rule(value) };
    let data = value.downcast::<CFData>().ok_or(AccountError::Corrupt)?;
    if data.len() > 1024 * 1024 {
        return Err(AccountError::Corrupt);
    }
    Ok(data.bytes().to_vec())
}
#[cfg(not(target_os = "macos"))]
pub(super) fn read_preferences(_: QuotioDomain) -> Result<Vec<u8>, AccountError> {
    Err(AccountError::Unsupported)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn factory_native_reads_one_fixed_file_without_copying_refresh_secrets() {
        use base64::{Engine, engine::general_purpose::STANDARD};
        use ring::aead;
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let source = FactoryNativeReference {
            directory: dir.clone(),
            location: FactoryLocation::V2File,
        };
        let clear = br#"{"access_token":"fixture-access","refresh_token":"owner-only-refresh","active_organization_id":"org"}"#;
        let key = [42u8; 32];
        let nonce = [7u8; 12];
        let cipher =
            aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, &key).unwrap());
        let mut encrypted = clear.to_vec();
        let tag = cipher
            .seal_in_place_separate_tag(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::empty(),
                &mut encrypted,
            )
            .unwrap();
        let envelope = format!(
            "{}:{}:{}",
            STANDARD.encode(nonce),
            STANDARD.encode(tag),
            STANDARD.encode(&encrypted)
        );
        let path = dir.join("auth.v2.file");
        std::fs::write(&path, &envelope).unwrap();
        for key_bytes in [key.to_vec(), STANDARD.encode(key).into_bytes()] {
            std::fs::write(dir.join("auth.v2.key"), key_bytes).unwrap();
            let resolved = source.resolve().await.unwrap();
            assert!(
                matches!(&resolved.credentials[0], Credential::FactoryOAuth { access_token, refresh_token, organization_id, .. } if access_token == "fixture-access" && refresh_token.is_empty() && organization_id.as_deref() == Some("org"))
            );
            assert!(
                !serde_json::to_string(&resolved)
                    .unwrap()
                    .contains("owner-only-refresh")
            );
            assert!(
                !serde_json::to_string(&source)
                    .unwrap()
                    .contains("fixture-access")
            );
            assert_eq!(std::fs::read(&path).unwrap(), envelope.as_bytes());
        }
        std::fs::write(dir.join("auth.v2.key"), [41u8; 32]).unwrap();
        assert!(source.resolve().await.is_err());
        // A valid legacy sibling must not rescue a broken explicit v2 selection.
        std::fs::write(dir.join("auth.encrypted"), clear).unwrap();
        assert!(source.resolve().await.is_err());
        let legacy = FactoryNativeReference {
            directory: dir.clone(),
            location: FactoryLocation::Legacy,
        };
        assert!(legacy.resolve().await.is_ok());
        assert_ne!(legacy.identity().unwrap(), source.identity().unwrap());
        for bytes in [b"{}".to_vec(), vec![b' '; 1024 * 1024 + 1]] {
            std::fs::write(&path, bytes).unwrap();
            assert!(source.resolve().await.is_err());
        }
        std::fs::remove_file(&path).unwrap();
        assert!(source.resolve().await.is_err());
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(dir.join("auth.encrypted"), &path).unwrap();
            assert!(source.resolve().await.is_err());
            std::fs::remove_file(&path).unwrap();
            use std::os::unix::ffi::OsStrExt;
            let name = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
            assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
            assert!(source.resolve().await.is_err());
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn factory_registration_rejects_custom_paths_and_credentials() {
        let base = serde_json::json!({"kind":"factory_native", "location":"v2_file"});
        assert!(serde_json::from_value::<crate::accounts::api::SourceInput>(base.clone()).is_ok());
        for field in [
            "path",
            "directory",
            "token",
            "refresh_token",
            "owned",
            "source",
            "enabled",
        ] {
            let mut input = base.clone();
            input[field] = "fixture".into();
            assert!(serde_json::from_value::<crate::accounts::api::SourceInput>(input).is_err());
        }
        for location in ["default", "../../secret", "newest"] {
            let mut input = base.clone();
            input["location"] = location.into();
            assert!(serde_json::from_value::<crate::accounts::api::SourceInput>(input).is_err());
        }
    }
    #[tokio::test]
    async fn copilot_native_pins_one_entry_and_rejects_hostile_files() {
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("apps.json");
        let source = CopilotNativeReference {
            location: CopilotLocation::Apps,
            path: Some(path.clone()),
            entry_key: "github.com:chosen".into(),
        };
        std::fs::write(&path, br#"{"github.com:other":{"oauth_token":"wrong"}}"#).unwrap();
        assert!(source.resolve().await.is_err());
        std::fs::write(&path, br#"{"github.com:other":{"oauth_token":"wrong"},"github.com:chosen":{"oauth_token":"right"}}"#).unwrap();
        let resolved = source.resolve().await.unwrap();
        assert!(
            matches!(&resolved.credentials[0], Credential::CatalogKey { token, .. } if token == "right")
        );
        let mut other = source.clone();
        other.entry_key = "github.com:other".into();
        assert_ne!(source.identity().unwrap(), other.identity().unwrap());
        for key in [
            "",
            "github.enterprise",
            "github.com:",
            "github.com:../../secret",
        ] {
            other.entry_key = key.into();
            assert!(other.identity().is_err());
        }
        std::fs::write(&path, vec![b' '; 1024 * 1024 + 1]).unwrap();
        assert!(source.resolve().await.is_err());
        std::fs::remove_file(&path).unwrap();
        #[cfg(unix)]
        {
            let other = dir.join("other.json");
            std::fs::write(&other, br#"{"github.com:chosen":{"oauth_token":"right"}}"#).unwrap();
            std::os::unix::fs::symlink(&other, &path).unwrap();
            assert!(source.resolve().await.is_err());
        }
        assert!(matches!(
            Credential::CopilotNative { source }
                .resolve_reference(crate::cli::Provider::Amp)
                .await,
            Err(AccountError::Unsupported)
        ));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[tokio::test]
    async fn copilot_gh_hosts_pins_github_and_observes_rotation() {
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("hosts.yml");
        let mut source = CopilotNativeReference {
            location: CopilotLocation::GhHosts,
            path: Some(path.clone()),
            entry_key: "enterprise.example".into(),
        };
        assert!(source.identity().is_err());
        source.entry_key = "github.com".into();
        std::fs::write(
            &path,
            b"enterprise.example:\n  oauth_token: wrong\ngithub.com:\n  oauth_token: first\n",
        )
        .unwrap();
        let first = source.resolve().await.unwrap();
        assert!(
            matches!(&first.credentials[0], Credential::CatalogKey { token, .. } if token == "first")
        );
        let identity = source.identity().unwrap();
        std::fs::write(&path, b"github.com:\n  oauth_token: second\n").unwrap();
        let second = source.resolve().await.unwrap();
        assert!(
            matches!(&second.credentials[0], Credential::CatalogKey { token, .. } if token == "second")
        );
        assert_eq!(source.identity().unwrap(), identity);
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink("/dev/zero", &path).unwrap();
        assert!(source.resolve().await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn copilot_native_registration_rejects_paths_and_credentials() {
        use crate::accounts::api::SourceInput;
        let base = serde_json::json!({"kind":"copilot_native","location":"apps","entry_key":"github.com:fixture"});
        assert!(serde_json::from_value::<SourceInput>(base.clone()).is_ok());
        for field in [
            "path",
            "token",
            "refresh_token",
            "owned",
            "source",
            "enabled",
        ] {
            let mut value = base.clone();
            value[field] = "fixture".into();
            assert!(serde_json::from_value::<SourceInput>(value).is_err());
        }
        let mut gh_hosts = base.clone();
        gh_hosts["location"] = "gh_hosts".into();
        gh_hosts["entry_key"] = "github.com".into();
        assert!(serde_json::from_value::<SourceInput>(gh_hosts).is_ok());
        for location in ["proxy", "gh_file", "default"] {
            let mut value = base.clone();
            value["location"] = location.into();
            assert!(serde_json::from_value::<SourceInput>(value).is_err());
        }
    }
    #[test]
    fn claude_native_registration_rejects_paths_credentials_and_desktop() {
        use crate::accounts::api::SourceInput;
        let base = serde_json::json!({"kind":"claude_native","location":"code_file"});
        assert!(serde_json::from_value::<SourceInput>(base.clone()).is_ok());
        for field in [
            "path",
            "token",
            "refresh_token",
            "owned",
            "source",
            "enabled",
        ] {
            let mut value = base.clone();
            value[field] = "fixture".into();
            assert!(serde_json::from_value::<SourceInput>(value).is_err());
        }
        for location in ["desktop", "../../secret", "default"] {
            let mut value = base.clone();
            value["location"] = location.into();
            assert!(serde_json::from_value::<SourceInput>(value).is_err());
        }
    }
    #[tokio::test]
    async fn claude_native_rejects_hostile_files_without_fallback() {
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("credentials.json");
        let source = ClaudeNativeReference {
            location: ClaudeLocation::CodeFile,
            path: Some(path.clone()),
        };
        assert!(source.resolve().await.is_err());
        for bytes in [b"{}".to_vec(), vec![b' '; 1024 * 1024 + 1]] {
            std::fs::write(&path, &bytes).unwrap();
            assert!(source.resolve().await.is_err());
            assert_eq!(std::fs::read(&path).unwrap(), bytes);
        }
        std::fs::remove_file(&path).unwrap();
        #[cfg(unix)]
        {
            let other = dir.join("other.json");
            std::fs::write(&other, br#"{"claudeAiOauth":{"accessToken":"fixture"}}"#).unwrap();
            std::os::unix::fs::symlink(&other, &path).unwrap();
            assert!(source.resolve().await.is_err());
        }
        assert!(matches!(
            Credential::ClaudeNative { source }
                .resolve_reference(crate::cli::Provider::Amp)
                .await,
            Err(AccountError::Unsupported)
        ));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn codex_registration_only_accepts_standard_location_selectors() {
        use crate::accounts::api::SourceInput;
        for location in ["default", "config", "codex_home"] {
            assert!(
                serde_json::from_value::<SourceInput>(
                    serde_json::json!({"kind":"codex_native","location":location})
                )
                .is_ok()
            );
        }
        let base = serde_json::json!({"kind":"codex_native"});
        assert!(serde_json::from_value::<SourceInput>(base.clone()).is_ok());
        for field in [
            "path",
            "token",
            "owned",
            "source",
            "refresh_token",
            "enabled",
        ] {
            let mut value = base.clone();
            value[field] = "fixture".into();
            assert!(serde_json::from_value::<SourceInput>(value).is_err());
        }
        assert!(
            serde_json::from_value::<SourceInput>(
                serde_json::json!({"kind":"codex_native","location":"../../secret"})
            )
            .is_err()
        );
    }
    #[tokio::test]
    async fn codex_source_rejects_hostile_files_and_observes_owner_removal() {
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("auth.json");
        let source = CodexNativeReference { path: path.clone() };
        std::fs::write(
            &path,
            br#"{"tokens":{"access_token":"fixture","account_id":"id"}}"#,
        )
        .unwrap();
        assert!(source.resolve().await.is_ok());
        assert!(matches!(
            Credential::CodexNative {
                source: source.clone()
            }
            .resolve_reference(crate::cli::Provider::Amp)
            .await,
            Err(AccountError::Unsupported)
        ));
        std::fs::remove_file(&path).unwrap();
        assert!(matches!(
            source.resolve().await,
            Err(AccountError::NotFound)
        ));
        #[cfg(unix)]
        {
            let other = dir.join("other.json");
            std::fs::write(&other, b"{}").unwrap();
            std::os::unix::fs::symlink(&other, &path).unwrap();
            assert!(source.resolve().await.is_err());
            assert_eq!(std::fs::read(&other).unwrap(), b"{}");
            std::fs::remove_file(&path).unwrap();
        }
        std::fs::write(&path, vec![b' '; 1024 * 1024 + 1]).unwrap();
        assert!(matches!(source.resolve().await, Err(AccountError::Corrupt)));
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert!(source.resolve().await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn grok_registration_only_accepts_an_explicit_safe_entry() {
        let base =
            serde_json::json!({"kind":"grok_native", "entry_key":"https://auth.x.ai::fixture"});
        assert!(serde_json::from_value::<crate::accounts::api::SourceInput>(base.clone()).is_ok());
        for field in ["path", "token", "owned", "source", "refresh_token"] {
            let mut value = base.clone();
            value[field] = "fixture".into();
            assert!(serde_json::from_value::<crate::accounts::api::SourceInput>(value).is_err());
        }
        for key in [
            "",
            "../../secret",
            "https://other.example::id",
            "https://auth.x.ai::",
        ] {
            assert!(GrokNativeReference::system(key.into()).is_err());
        }
    }
    #[test]
    fn cursor_source_input_cannot_supply_paths_tokens_or_ownership() {
        assert!(
            serde_json::from_str::<crate::accounts::api::SourceInput>(
                r#"{"kind":"cursor_native"}"#
            )
            .is_ok()
        );
        for field in ["path", "token", "owned", "source"] {
            let value = serde_json::json!({"kind":"cursor_native",field:"fixture"});
            assert!(serde_json::from_value::<crate::accounts::api::SourceInput>(value).is_err());
        }
    }
    fn source() -> CustomProviderReference {
        CustomProviderReference {
            domain: QuotioDomain::Production,
            record_id: "01234567-89ab-cdef-0123-456789abcdef".into(),
        }
    }
    fn records() -> serde_json::Value {
        serde_json::from_str(include_str!(
            "../../tests/fixtures/quotio-clinepass-custom-providers.json"
        ))
        .unwrap()
    }

    #[tokio::test]
    async fn amp_reference_observes_rotation_disable_and_removal_without_copying_credentials() {
        use crate::accounts::{
            service::{MutationIntent, commit_once, mutation_receipt},
            vault::{Vault, tests::Memory},
        };
        use std::sync::Arc;
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("secrets.json");
        let mut source = AmpNativeReference {
            path: path.clone(),
            enabled: true,
        };
        std::fs::write(&path, br#"{"apiKey@https://ampcode.com/":"fixture-first"}"#).unwrap();
        let first = source.resolve().await.unwrap().credentials;
        let identity = source.identity().unwrap();
        let vault = Vault::new(Arc::new(Memory::default()), dir.join("lock"));
        let intent = MutationIntent::new("native-fixture", identity.clone()).unwrap();
        let copy = source.clone();
        let id = commit_once(vault.clone(), intent.clone(), move |doc| {
            doc.add(
                crate::cli::Provider::Amp,
                "Local Amp",
                identity,
                Credential::AmpNative { source: copy },
            )
        })
        .await
        .unwrap();
        assert_eq!(
            mutation_receipt(vault.clone(), &intent).await.unwrap(),
            Some(id.clone())
        );
        let tx = vault.begin().unwrap();
        assert_eq!(
            tx.document.accounts[0].origin(),
            crate::domain::AccountOrigin::BorrowedNative
        );
        assert!(
            !serde_json::to_string(&tx.document)
                .unwrap()
                .contains("fixture-first")
        );
        drop(tx);
        std::fs::write(
            &path,
            br#"{"apiKey@https://ampcode.com/":"fixture-second"}"#,
        )
        .unwrap();
        assert!(source.resolve().await.unwrap().credentials != first);
        let bytes = std::fs::read(&path).unwrap();
        let mut tx = vault.begin().unwrap();
        tx.document.patch(&id, None, None, Some(false)).unwrap();
        tx.commit().unwrap();
        assert!(!vault.begin().unwrap().document.accounts[0].enabled());
        source.enabled = false;
        assert!(matches!(
            source.resolve().await,
            Err(AccountError::SourceDisabled)
        ));
        source.enabled = true;
        assert!(source.resolve().await.is_ok());
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        std::fs::remove_file(&path).unwrap();
        assert!(source.resolve().await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn amp_registration_cannot_supply_a_path_or_credential() {
        assert!(
            serde_json::from_str::<crate::accounts::api::SourceInput>(r#"{"kind":"amp_native"}"#)
                .is_ok()
        );
        for field in ["path", "token", "owned", "source"] {
            let value = serde_json::json!({"kind":"amp_native",field:"fixture"});
            assert!(serde_json::from_value::<crate::accounts::api::SourceInput>(value).is_err());
        }
    }
    #[test]
    fn glm_group_preserves_key_order_and_rejects_non_zai_origins() {
        let source = source();
        let mut value = records();
        value[0]["type"] = "glm-api-key".into();
        value[0]["base-url"] = "https://api.z.ai/api/paas/v4".into();
        let result = source.parse(&serde_json::to_vec(&value).unwrap()).unwrap();
        assert_eq!(result.provider, crate::cli::Provider::Zai);
        assert_eq!(result.credentials.len(), 2);
        assert!(
            matches!(&result.credentials[1], Credential::ApiKey { token, region, .. } if token == "fixture-second" && region.as_deref() == Some("global"))
        );
        for url in [
            "https://open.bigmodel.cn",
            "https://custom.example",
            "http://api.z.ai",
            "https://secret@api.z.ai",
        ] {
            value[0]["base-url"] = url.into();
            assert!(matches!(
                source.parse(&serde_json::to_vec(&value).unwrap()),
                Err(AccountError::Unsupported)
            ));
        }
    }
    #[test]
    fn custom_bundle_domains_round_trip_and_preserve_alias_identity() {
        let mut source = source();
        let production = source.identity().unwrap();
        source.domain = serde_json::from_str(r#""app.bytrong.quotio""#).unwrap();
        assert_eq!(source.identity().unwrap(), production);
        source.domain = serde_json::from_str(r#""com.example.quotio""#).unwrap();
        assert_eq!(source.domain.identifier().unwrap(), "com.example.quotio");
        assert_eq!(
            serde_json::to_string(&source.domain).unwrap(),
            r#""com.example.quotio""#
        );
        assert_ne!(source.identity().unwrap(), production);
        for invalid in ["", "../quotio", "a..b", "a/b.c", "a. b"] {
            source.domain = QuotioDomain::BundleIdentifier(invalid.into());
            assert!(matches!(source.identity(), Err(AccountError::Input)));
        }
    }

    #[test]
    fn reference_preserves_group_identity_and_selects_first_key() {
        let source = source();
        let bytes = serde_json::to_vec(&records()).unwrap();
        let resolved = source.parse(&bytes).unwrap();
        assert_eq!(resolved.label, "Cline group");
        assert!(
            matches!(&resolved.credentials[0], Credential::CatalogKey{token,..} if token == "fixture-first")
        );
        assert!(
            !serde_json::to_string(&source)
                .unwrap()
                .contains("fixture-first")
        );
        let mut alias = source.clone();
        alias.record_id = alias.record_id.to_uppercase();
        assert_eq!(source.identity().unwrap(), alias.identity().unwrap());
        alias.domain = QuotioDomain::Development;
        assert_ne!(source.identity().unwrap(), alias.identity().unwrap());
    }
    #[test]
    fn disabled_duplicate_missing_and_wrong_provider_are_rejected() {
        let source = source();
        let mut value = records();
        value[0]["is-enabled"] = false.into();
        assert!(matches!(
            source.parse(&serde_json::to_vec(&value).unwrap()),
            Err(AccountError::SourceDisabled)
        ));
        let row = records()[0].clone();
        assert!(matches!(
            source.parse(&serde_json::to_vec(&vec![&row, &row]).unwrap()),
            Err(AccountError::Corrupt)
        ));
        assert!(matches!(source.parse(b"[]"), Err(AccountError::NotFound)));
        let mut value = records();
        value[0]["type"] = "openai-compatibility".into();
        assert!(matches!(
            source.parse(&serde_json::to_vec(&value).unwrap()),
            Err(AccountError::Unsupported)
        ));
    }
    #[tokio::test]
    async fn reference_receipt_survives_restart_without_downgrading_document() {
        use crate::accounts::{
            service::{MutationIntent, commit_once, mutation_receipt},
            vault::{Backend, Vault, tests::Memory},
        };
        use std::sync::Arc;
        let backend = Arc::new(Memory::default());
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        let vault = Vault::new(backend.clone(), dir.join("lock"));
        let source = source();
        let identity = source.identity().unwrap();
        let intent = MutationIntent::new("source-registration-fixture", identity.clone()).unwrap();
        let id = commit_once(vault.clone(), intent.clone(), move |doc| {
            doc.add(
                crate::cli::Provider::Catalog("clinepass"),
                "Cline group",
                identity,
                Credential::QuotioCustomProvider { source },
            )
        })
        .await
        .unwrap();
        let reopened = Vault::new(backend.clone(), dir.join("lock"));
        assert_eq!(
            mutation_receipt(reopened.clone(), &intent).await.unwrap(),
            Some(id)
        );
        let tx = reopened.begin().unwrap();
        assert_eq!(tx.document.version, 3);
        assert!(matches!(
            tx.document.accounts[0].origin(),
            super::super::AccountOrigin::BorrowedProxy
        ));
        let public = serde_json::to_string(&crate::accounts::api::AccountDto::from(
            &tx.document.accounts[0],
        ))
        .unwrap();
        assert!(!public.contains("credential"));
        drop(tx);
        let bytes = backend.read().unwrap().unwrap();
        let mut old: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        old["version"] = 2.into();
        backend.write(&serde_json::to_vec(&old).unwrap()).unwrap();
        assert!(matches!(reopened.begin(), Err(AccountError::Corrupt)));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn registration_cannot_supply_credentials_paths_or_ownership() {
        let base = serde_json::json!({"kind":"quotio_custom_provider", "source":{"domain":"production","record_id":source().record_id}});
        assert!(serde_json::from_value::<crate::accounts::api::SourceInput>(base.clone()).is_ok());
        for name in ["credential", "api_key", "path", "owned", "origin"] {
            let mut value = base.clone();
            value[name] = "fixture".into();
            assert!(serde_json::from_value::<crate::accounts::api::SourceInput>(value).is_err());
        }
        let mut value = base;
        value["source"]["domain"] = "../other.application".into();
        assert!(serde_json::from_value::<crate::accounts::api::SourceInput>(value).is_err());
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn preference_fixture_writer() {
        use core_foundation::{
            base::TCFType,
            data::CFData,
            string::{CFString, CFStringRef},
        };
        unsafe extern "C" {
            fn CFPreferencesSetAppValue(
                key: CFStringRef,
                value: core_foundation::base::CFTypeRef,
                application: CFStringRef,
            );
            fn CFPreferencesAppSynchronize(application: CFStringRef) -> u8;
        }
        let Ok(domain) = std::env::var("QUOTIO_TEST_PREFERENCE_DOMAIN") else {
            return;
        };
        assert!(domain.starts_with("app.quotio.cli.fixture."));
        assert!(
            domain
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b".-_".contains(&b))
        );
        let mode = std::env::var("QUOTIO_TEST_PREFERENCE_VALUE").unwrap();
        let value = CFData::from_buffer(mode.as_bytes());
        let domain = CFString::new(&domain);
        let key = CFString::new("customProviders");
        unsafe {
            CFPreferencesSetAppValue(
                key.as_concrete_TypeRef(),
                if mode == "clear" {
                    std::ptr::null()
                } else {
                    value.as_CFTypeRef()
                },
                domain.as_concrete_TypeRef(),
            );
            assert_ne!(CFPreferencesAppSynchronize(domain.as_concrete_TypeRef()), 0);
        }
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn native_preferences_observe_changes_from_another_process() {
        let domain = format!(
            "app.quotio.cli.fixture.{}",
            super::super::random_string().unwrap().replace('_', "-")
        );
        let write = |mode| {
            let result = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "accounts::sources::tests::preference_fixture_writer",
                ])
                .env("QUOTIO_TEST_PREFERENCE_DOMAIN", &domain)
                .env("QUOTIO_TEST_PREFERENCE_VALUE", mode)
                .output()
                .unwrap();
            assert!(result.status.success());
        };
        write("first-fixture");
        let first = read_preferences(QuotioDomain::BundleIdentifier(domain.clone()));
        write("second-fixture");
        let second = read_preferences(QuotioDomain::BundleIdentifier(domain.clone()));
        write("clear");
        assert_eq!(first.unwrap(), b"first-fixture");
        assert_eq!(second.unwrap(), b"second-fixture");
    }
}
