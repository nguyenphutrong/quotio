use crate::cli::Provider;
use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("could not read config file")]
    Read,
    #[error(
        "invalid TOML config at line {line}, column {column}; expected provider lists such as disabled_providers = [\"provider-id\"]"
    )]
    Parse { line: usize, column: usize },
    #[error("config contains an unsupported provider; run quotio providers")]
    Unsupported,
}
// Read-only compatibility for preferences written by the unreleased 0.2.1 native
// integration. Preserve them on settings writes without using them for behavior.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct LegacyNotificationPreferences {
    pub enabled: bool,
    pub quota_threshold: f64,
    pub quota_low: bool,
    pub cooling: bool,
    pub proxy_crash: bool,
    pub proxy_update: bool,
    pub suppressed_update_version: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notifications: Option<LegacyNotificationPreferences>,
    #[serde(default)]
    pub enabled_providers: Vec<String>,
    #[serde(default)]
    pub disabled_providers: Vec<String>,
    /// Maximum cache age in seconds; zero refreshes every time.
    #[serde(default = "default_cache_ttl")]
    pub cache_ttl_seconds: u64,
    #[serde(default = "default_refresh_interval")]
    /// Seconds between completed refresh cycles; zero disables scheduled refreshes.
    pub refresh_interval: u64,
    #[serde(default = "default_provider_timeout")]
    pub provider_timeout: u64,
}
fn default_refresh_interval() -> u64 {
    60
}
fn default_provider_timeout() -> u64 {
    10
}
fn default_cache_ttl() -> u64 {
    300
}
impl Default for Config {
    fn default() -> Self {
        Self {
            notifications: None,
            enabled_providers: vec![],
            disabled_providers: vec![],
            cache_ttl_seconds: default_cache_ttl(),
            refresh_interval: default_refresh_interval(),
            provider_timeout: default_provider_timeout(),
        }
    }
}
impl Config {
    pub fn default_path() -> Option<PathBuf> {
        directories::ProjectDirs::from("", "", "quotio")
            .map(|dirs| dirs.config_dir().join("config.toml"))
    }
    pub fn load(explicit: Option<&Path>) -> Result<Self, ConfigError> {
        let path = explicit.map(Path::to_path_buf).or_else(Self::default_path);
        let Some(path) = path else {
            return Ok(Self::default());
        };
        let input = match std::fs::read_to_string(path) {
            Ok(input) => input,
            Err(error) if explicit.is_none() && error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Self::default());
            }
            Err(_) => return Err(ConfigError::Read),
        };
        Self::parse(&input)
    }
    pub fn parse(input: &str) -> Result<Self, ConfigError> {
        toml::from_str(input).map_err(|error: toml::de::Error| {
            let prefix = &input[..error.span().map(|span| span.start).unwrap_or(0)];
            ConfigError::Parse {
                line: prefix.bytes().filter(|byte| *byte == b'\n').count() + 1,
                column: prefix.rsplit('\n').next().unwrap_or("").chars().count() + 1,
            }
        })
    }
    pub fn providers(&self) -> Result<Vec<Provider>, ConfigError> {
        parse_providers(&self.enabled_providers)
    }
    pub fn disabled_providers(&self) -> Result<Vec<Provider>, ConfigError> {
        parse_providers(&self.disabled_providers)
    }
}

fn parse_providers(ids: &[String]) -> Result<Vec<Provider>, ConfigError> {
    let mut providers = Vec::new();
    for id in ids {
        let provider = Provider::from_str(id, false).map_err(|_| ConfigError::Unsupported)?;
        if !providers.contains(&provider) {
            providers.push(provider);
        }
    }
    Ok(providers)
}
