//! Providers the host can connect, from `GET /v2/providers`. The host's own
//! descriptor types only serialize, so this keeps the fields the app reads.
use quotio::contract::Action;
use serde::Deserialize;

#[derive(Clone, Debug, Deserialize)]
pub struct ProviderList {
    pub providers: Vec<Provider>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Provider {
    pub id: String,
    pub display_name: String,
    #[serde(default)]
    pub actions: Vec<Action>,
    pub capabilities: Capabilities,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Capabilities {
    #[serde(default)]
    pub settings: Vec<SettingField>,
    #[serde(default)]
    pub source_references: Vec<SourceReference>,
}

/// An extra field an API key needs, such as a region or a base URL.
#[derive(Clone, Debug, Deserialize)]
pub struct SettingField {
    pub name: String,
    /// `region` and `organization` go at the top level; `settings.x` into `settings`.
    pub field_path: String,
    #[serde(default)]
    pub required: bool,
    pub values: Option<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct SourceReference {
    pub kind: String,
    #[serde(default)]
    pub platforms: Vec<String>,
    /// Environment variable that selects a CLI's config folder, e.g. `CODEX_HOME`.
    pub config_dir_env: Option<String>,
}

impl Provider {
    fn allows(&self, kind: &str) -> bool {
        self.actions.iter().any(|a| a.kind == kind && a.available)
    }

    pub fn browser_sign_in(&self) -> bool {
        self.allows("start_oauth")
    }

    pub fn api_key(&self) -> bool {
        self.allows("add_api_key")
    }

    pub fn scan(&self) -> bool {
        self.allows("discover_native")
    }

    /// A CLI login in a folder of the user's choice, when this platform has one.
    pub fn local_login(&self) -> Option<&SourceReference> {
        let platform = std::env::consts::OS;
        self.capabilities
            .source_references
            .iter()
            .find(|r| r.config_dir_env.is_some() && r.platforms.iter().any(|p| p == platform))
    }

    pub fn connectable(&self) -> bool {
        self.browser_sign_in() || self.api_key() || self.scan() || self.local_login().is_some()
    }
}
