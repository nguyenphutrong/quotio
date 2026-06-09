// Generated from schema/contract.json. Do not edit manually.

pub const CONTRACT_VERSION: u16 = 1;
pub const REQUEST_KINDS: &[&str] = &["runtime.status", "runtime.start", "runtime.stop", "runtime.restart", "management.request"];
pub const EVENT_KINDS: &[&str] = &["runtime.statusChanged"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuntimeStatus {
    pub state: String,
    pub endpoint: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ManagementResponse {
    pub status: u16,
    pub body: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentDescriptor {
    pub id: String,
    pub display_name: String,
    pub config_type: String,
    pub binary_names: Vec<String>,
    pub macos_config_paths: Vec<String>,
    pub windows_config_paths: Vec<String>,
    pub macos_support: String,
    pub windows_support: String,
    pub backup_policy: String,
    pub docs_url: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentDetectionStatus {
    pub agent_id: String,
    pub platform_support: String,
    pub installed: bool,
    pub configured: bool,
    pub rollback_available: bool,
    pub binary_path: Option<String>,
    pub version: Option<String>,
    pub message: Option<String>,
}
