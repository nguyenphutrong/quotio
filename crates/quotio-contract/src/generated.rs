// Generated from schema/contract.json. Do not edit manually.

pub const CONTRACT_VERSION: u16 = 1;
pub const REQUEST_KINDS: &[&str] = &["runtime.status", "runtime.start", "runtime.stop", "management.request"];
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
