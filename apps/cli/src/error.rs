use serde::{Deserialize, Serialize};
use thiserror::Error;

// Fixed messages deliberately exclude transport errors, URLs and response bodies.
#[derive(Clone, Copy, Debug, Error, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderError {
    #[error("provider request timed out")]
    Timeout,
    #[error("request cancelled")]
    Cancelled,
    #[error("temporary provider failure")]
    Transient,
    #[error("credentials unavailable or rejected")]
    Authentication,
    #[error("the native credential owner must refresh or sign in again")]
    OwnerRefreshRequired,
    #[error("the credential source is disabled by its owner")]
    SourceDisabled,
    #[error("provider returned invalid usage")]
    InvalidData,
    #[error("signed in, but direct Google API quota could not be verified")]
    QuotaUnavailable,
    #[error("provider rate limited the request; retry later")]
    RateLimited,
    #[error("required local tool or service is unavailable")]
    Unavailable,
    #[error("the provider's command-line tool was not found on PATH or in its install locations")]
    CliNotFound,
    #[error("saved account storage is unavailable or invalid; check Keychain access")]
    CredentialStorage,
    #[error(
        "Antigravity Keychain access is unavailable; run quotio accounts authorize --provider antigravity"
    )]
    LocalCredentialStorage,
    #[error("provider task failed")]
    Internal,
}
