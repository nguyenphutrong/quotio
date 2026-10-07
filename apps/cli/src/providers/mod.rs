pub mod amp;
pub mod antigravity;
pub(crate) mod antigravity_auth;
mod antigravity_local;
pub mod capabilities;
pub mod catalog;
pub mod codex;
pub mod codex_api;
pub(crate) mod codex_native;
mod codex_profile;
mod codex_reset_credits;
pub mod factory;
pub(crate) mod http;
pub mod key_api;
pub mod mock;
pub mod openrouter;
pub(crate) mod process;
use crate::{
    domain::{ProviderId, ProviderUsage},
    error::ProviderError,
};
use std::{future::Future, pin::Pin, sync::Arc};
use time::OffsetDateTime;

tokio::task_local! {
    pub(crate) static FETCH_DEADLINE: tokio::time::Instant;
}
pub(crate) fn remaining_fetch_time() -> Option<std::time::Duration> {
    FETCH_DEADLINE
        .try_with(|deadline| deadline.saturating_duration_since(tokio::time::Instant::now()))
        .ok()
}

pub trait Clock: Send + Sync {
    fn now(&self) -> OffsetDateTime;
}
pub struct SystemClock;
impl Clock for SystemClock {
    fn now(&self) -> OffsetDateTime {
        OffsetDateTime::now_utc()
    }
}
// Credentials are intentionally not Debug or Serialize.
pub struct Secret(pub String);
pub trait CredentialStore: Send + Sync {
    fn get(&self, name: &str) -> Option<Secret>;
}
pub struct EnvironmentCredentials;
impl CredentialStore for EnvironmentCredentials {
    fn get(&self, name: &str) -> Option<Secret> {
        // Routing values that decide where a token is sent come only from saved
        // accounts, never from the ambient process environment.
        if name == catalog::oauth_primary::COPILOT_HOST_ENV {
            return None;
        }
        std::env::var(name).ok().map(Secret)
    }
}
#[derive(Clone)]
pub struct ProviderContext {
    pub http: reqwest::Client,
    pub clock: Arc<dyn Clock>,
    pub credentials: Arc<dyn CredentialStore>,
}
pub type FetchFuture<'a> =
    Pin<Box<dyn Future<Output = Result<ProviderUsage, ProviderError>> + Send + 'a>>;
/// Dropping fetch must cancel network requests and child processes. Native OS reads
/// may finish after cancellation; keep those closures read-only and bound their
/// response size and caller wait. Never detach writes or return raw diagnostics.
/// Only public account and
/// quota metadata belongs in ProviderUsage.
pub trait ProviderAdapter: Send + Sync {
    fn id(&self) -> ProviderId;
    fn account_ref(&self) -> Option<crate::domain::AccountRef> {
        None
    }
    /// Opaque login/scope identity. None disables caching when identity cannot be verified.
    fn cache_identity<'a>(
        &'a self,
        context: &'a ProviderContext,
    ) -> Pin<Box<dyn Future<Output = Option<String>> + Send + 'a>> {
        Box::pin(async move { crate::cache::environment_identity(&self.id().0, context) })
    }
    /// Whether this result belongs to the login verified by cache_identity.
    fn cacheable(&self, _: &ProviderUsage) -> bool {
        true
    }
    fn idempotent(&self) -> bool {
        false
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a>;
}
