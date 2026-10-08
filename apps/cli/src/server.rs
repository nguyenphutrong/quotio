//! HTTP management and snapshot transport; provider work uses the shared usage cache.
mod bootstrap;
mod clients;
#[cfg(test)]
mod discovery_tests;
mod history;
#[cfg(test)]
mod history_tests;
mod management;
mod native;
mod openapi;
mod operations;
mod security;
mod sharing;
#[cfg(test)]
mod tests;
use crate::{
    cli::{Provider, ServeArgs},
    config::Config,
    domain::{ProviderFailure, ProviderId, UsageReport},
    error::ProviderError,
    fetch::{Cancellation, CollectRequest, Collector},
    providers::{EnvironmentCredentials, ProviderContext, SystemClock},
    settings::{Overrides, SettingsError, SettingsPatch, SettingsStore, SettingsView},
};
use axum::{
    Extension, Json, Router,
    extract::{FromRequest, Path, Request, State},
    http::StatusCode,
    middleware,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use clap::ValueEnum;
use operations::{Operation, Operations};
use security::error;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    future::IntoFuture,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    net::TcpListener,
    sync::{Mutex, Notify, RwLock, watch},
};

#[derive(Debug, thiserror::Error)]
pub enum ServerError {
    #[error("server requires a loopback listen address")]
    Listen,
    #[error("could not load server configuration")]
    Config,
    #[error("invalid server security configuration; check token, public URL and allowed origins")]
    Security,
    #[error("could not bind server; check the listen address and port")]
    Bind,
    #[error("could not initialize the server")]
    Initialize,
}
impl ServerError {
    pub fn exit_code(&self) -> u8 {
        match self {
            Self::Listen | Self::Config | Self::Security => 2,
            _ => 3,
        }
    }
}
#[derive(Debug)]
struct ApiError(StatusCode, &'static str);
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        error(self.0, self.1)
    }
}
struct ApiJson<T>(T);
impl<S: Send + Sync, T: DeserializeOwned> FromRequest<S> for ApiJson<T> {
    type Rejection = ApiError;
    async fn from_request(request: Request, state: &S) -> Result<Self, Self::Rejection> {
        match tokio::time::timeout(
            Duration::from_secs(5),
            Json::<T>::from_request(request, state),
        )
        .await
        {
            Ok(Ok(Json(value))) => Ok(Self(value)),
            Ok(Err(e)) => Err(ApiError(
                e.status(),
                if e.status() == StatusCode::PAYLOAD_TOO_LARGE {
                    "body_too_large"
                } else {
                    "invalid_request"
                },
            )),
            Err(_) => Err(ApiError(StatusCode::REQUEST_TIMEOUT, "request_timeout")),
        }
    }
}
#[derive(Default, Serialize)]
struct RefreshStatus {
    refreshing: bool,
    last_completed_at: Option<String>,
    next_refresh_at: Option<String>,
}
struct ApiState {
    history: Option<crate::history::History>,
    history_epochs: Mutex<HashMap<String, (Option<String>, String)>>,
    sharing: Mutex<sharing::Sharing>,
    settings: RwLock<SettingsView>,
    store: SettingsStore,
    snapshot: RwLock<Option<(u64, UsageReport)>>,
    transient_snapshot: Mutex<Option<crate::contract::Snapshot>>,
    generation: Arc<AtomicU64>,
    restore_pending: AtomicBool,
    commit_guard: Arc<Mutex<()>>,
    refresh_lock: Mutex<()>,
    pending: Mutex<HashMap<String, String>>,
    wake: Notify,
    operations: Mutex<Operations>,
    jobs: std::sync::Mutex<Vec<tokio::task::AbortHandle>>,
    discovery: Arc<std::sync::Mutex<crate::accounts::discovery::Registry>>,
    native_scan_lock: Mutex<()>,
    status: Mutex<RefreshStatus>,
    context: ProviderContext,
    no_saved_accounts: bool,
    proxy_auth_directory: Option<std::path::PathBuf>,
    proxy_configuration: Option<std::path::PathBuf>,
    manage: bool,
    vault: Option<crate::accounts::vault::Vault>,
    oauth: Option<crate::accounts::oauth::OAuthSessionManager>,
}
impl ApiState {
    fn spawn(
        &self,
        work: impl std::future::Future<Output = ()> + Send + 'static,
    ) -> Result<(), ApiError> {
        let mut jobs = self.jobs.lock().expect("job tracker");
        jobs.retain(|h| !h.is_finished());
        if jobs.len() >= 128 {
            return Err(ApiError(StatusCode::SERVICE_UNAVAILABLE, "server_busy"));
        }
        jobs.push(tokio::spawn(work).abort_handle());
        Ok(())
    }
    async fn client_mutation_guard(
        &self,
        principal: &security::Principal,
    ) -> Result<tokio::sync::MutexGuard<'_, ()>, &'static str> {
        if let Some(reason) = self.management_restriction(principal) {
            return Err(reason);
        }
        let guard = crate::accounts::service::mutation_guard(&self.commit_guard)
            .await
            .map_err(|e| management::account_code(&e))?;
        if !principal.owner {
            let vault = self.vault.clone().ok_or("account_storage_disabled")?;
            if !crate::accounts::clients::can_manage(vault, &principal.id, self.context.clock.now())
                .await
                .map_err(|e| management::account_code(&e))?
            {
                return Err("client_revoked");
            }
        }
        Ok(guard)
    }

    fn management_restriction(&self, principal: &security::Principal) -> Option<&'static str> {
        if !self.manage {
            Some("management_disabled")
        } else if !principal.manage {
            Some("insufficient_scope")
        } else {
            None
        }
    }

    fn account_write_restriction(&self, principal: &security::Principal) -> Option<&'static str> {
        if let Some(reason) = self.management_restriction(principal) {
            Some(reason)
        } else if self.no_saved_accounts {
            Some("no_saved_accounts")
        } else if self.vault.is_none() {
            Some("account_storage_disabled")
        } else {
            None
        }
    }

    fn restrict_provider(
        &self,
        provider: &mut crate::providers::capabilities::ProviderDescriptor,
        principal: &security::Principal,
    ) {
        restrict_actions(
            &mut provider.actions,
            self.account_write_restriction(principal),
        );
        for action in &mut provider.actions {
            if action.available
                && !principal.host_user
                && (action.kind == "authorize_native"
                    || (action.kind == "start_oauth" && provider.id == Provider::Codex))
            {
                action.available = false;
                action.reason = Some("host_interaction_required".into());
            }
        }
    }

    fn restrict_host(&self, host: &mut crate::contract::Host, principal: &security::Principal) {
        let reason = self.account_write_restriction(principal);
        for (name, write) in [("quota_history", false), ("quota_history_write", true)] {
            let reason = history::restriction(self, principal, write);
            host.capabilities.insert(
                name.into(),
                crate::contract::Availability {
                    available: reason.is_none(),
                    reason: reason.map(str::to_owned),
                },
            );
        }
        host.capabilities.insert(
            "account_write_v2".into(),
            crate::contract::Availability {
                available: reason.is_none(),
                reason: reason.map(str::to_owned),
            },
        );
        host.capabilities.insert(
            "refresh".into(),
            crate::contract::Availability {
                available: self.management_restriction(principal).is_none(),
                reason: self.management_restriction(principal).map(str::to_owned),
            },
        );
        host.capabilities.insert(
            "settings_write".into(),
            crate::contract::Availability {
                available: self.management_restriction(principal).is_none(),
                reason: self.management_restriction(principal).map(str::to_owned),
            },
        );
        let native = reason.is_none() && principal.host_user && cfg!(target_os = "macos");
        host.capabilities.insert(
            "native_authorization".into(),
            crate::contract::Availability {
                available: native,
                reason: (!native).then(|| reason.unwrap_or("host_interaction_required").into()),
            },
        );
    }

    fn restrict_issue(&self, issue: &mut crate::contract::Issue, principal: &security::Principal) {
        if let Some(action) = &mut issue.action {
            let reason = if action.kind == "authorize" && !principal.host_user {
                Some("host_interaction_required")
            } else if action.kind == "retry" {
                self.management_restriction(principal)
            } else {
                self.account_write_restriction(principal)
            };
            restrict_actions(std::slice::from_mut(action), reason);
        }
    }

    fn restrict_account(
        &self,
        account: &mut crate::contract::Account,
        principal: &security::Principal,
    ) {
        restrict_actions(
            &mut account.actions,
            self.account_write_restriction(principal),
        );
        for source in &mut account.sources {
            restrict_actions(
                &mut source.actions,
                self.account_write_restriction(principal),
            );
            if let Some(issue) = &mut source.issue {
                self.restrict_issue(issue, principal);
            }
        }
    }

    fn restrict_snapshot(
        &self,
        snapshot: &mut crate::contract::Snapshot,
        principal: &security::Principal,
    ) {
        self.restrict_host(&mut snapshot.host, principal);
        for account in &mut snapshot.accounts {
            self.restrict_account(account, principal);
        }
        for usage in &mut snapshot.usage {
            if let Some(issue) = &mut usage.issue {
                self.restrict_issue(issue, principal);
            }
        }
        for issue in snapshot.provider_issues.values_mut() {
            self.restrict_issue(issue, principal);
        }
    }

    async fn invalidate(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        self.snapshot.write().await.take();
        self.restore_pending.store(true, Ordering::SeqCst);
        self.wake.notify_one();
    }

    async fn invalidate_sources(&self, source_ids: &[String]) {
        let previous = self.generation.fetch_add(1, Ordering::SeqCst);
        let mut snapshot = self.snapshot.write().await;
        if let Some((generation, report)) = snapshot.as_mut() {
            if *generation == previous {
                report.providers.retain(|usage| {
                    usage
                        .account_ref
                        .as_ref()
                        .is_none_or(|source| !source_ids.contains(&source.id))
                });
                report.failures.retain(|failure| {
                    failure
                        .account_ref
                        .as_ref()
                        .is_none_or(|source| !source_ids.contains(&source.id))
                });
                *generation = previous + 1;
            } else {
                // An earlier credential mutation already invalidated this report.
                *snapshot = None;
            }
        }
        self.restore_pending.store(true, Ordering::SeqCst);
        self.wake.notify_one();
    }
}
fn restrict_actions(actions: &mut [crate::contract::Action], reason: Option<&str>) {
    if let Some(reason) = reason {
        for action in actions.iter_mut().filter(|action| action.available) {
            action.available = false;
            action.reason = Some(reason.into());
        }
    }
}

fn client_access_error(code: &'static str) -> ApiError {
    ApiError(
        if matches!(
            code,
            "client_revoked" | "insufficient_scope" | "management_disabled"
        ) {
            StatusCode::FORBIDDEN
        } else {
            StatusCode::SERVICE_UNAVAILABLE
        },
        code,
    )
}

fn timestamp(now: time::OffsetDateTime) -> String {
    now.format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default()
}
fn router(state: Arc<ApiState>, policy: Arc<security::Policy>) -> Router {
    let access = (
        policy,
        state.vault.clone().filter(|_| !state.no_saved_accounts),
        state.context.clock.clone(),
    );
    Router::new()
        .route("/v2/sharing", get(sharing::get).put(sharing::update))
        .route("/v2/clients", get(clients::list).post(clients::create))
        .route("/v2/clients/{id}", axum::routing::delete(clients::revoke))
        .route("/openapi.json", get(openapi::document))
        .route("/health", get(health))
        .route("/v2/snapshot", get(resolved_snapshot))
        .route(
            "/v2/accounts/{id}/quota-history",
            get(history::catalog).delete(history::clear_account),
        )
        .route(
            "/v2/accounts/{id}/quota-history/{metric}/{range}",
            get(history::chart),
        )
        .route(
            "/v2/accounts/{id}/quota-history/{metric}/{range}/events/{cursor}",
            get(history::events),
        )
        .route(
            "/v2/quota-history",
            axum::routing::delete(history::clear_all),
        )
        .route("/v2/discovery", get(native::status).post(native::start))
        .route("/v2/status", get(status))
        .route("/v2/migrations/accounts", post(management::migrate))
        .route("/v2/sources", post(management::reference))
        .route("/v2/sources/discover", post(management::discover))
        .route("/v2/sources/authorize", post(management::authorize))
        .route(
            "/v2/account-vault/authorize",
            post(management::authorize_vault),
        )
        .route("/v2/auth/sessions", post(management::begin))
        .route(
            "/v2/auth/sessions/{id}",
            get(management::session).delete(management::cancel),
        )
        .route(
            "/v2/auth/sessions/{id}/callback",
            post(management::callback),
        )
        .route(
            "/v2/accounts",
            get(management::resolved_accounts).post(management::resolved_create),
        )
        .route(
            "/v2/accounts/{id}",
            get(management::resolved_account)
                .patch(management::resolved_patch)
                .delete(management::resolved_remove),
        )
        .route(
            "/v2/sources/{id}",
            axum::routing::patch(management::source_patch).delete(management::source_remove),
        )
        .route("/v2/providers", get(providers))
        .route("/v2/providers/{id}", get(provider))
        .route("/v2/settings", get(settings).patch(patch_settings))
        .route("/v2/refresh", post(manual_refresh))
        .route("/v2/operations/{id}", get(operation))
        .fallback(|| async { error(StatusCode::NOT_FOUND, "not_found") })
        .layer(axum::extract::DefaultBodyLimit::max(65536))
        .layer(middleware::from_fn_with_state(access, security::guard))
        .with_state(state)
}
async fn health(State(state): State<Arc<ApiState>>) -> Json<Value> {
    Json(
        json!({"status":"ok","ready":state.snapshot.read().await.as_ref().is_some_and(|(generation,_)|*generation==state.generation.load(Ordering::SeqCst))}),
    )
}
async fn status(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
) -> Json<Value> {
    let settings = state.settings.read().await;
    let status = state.status.lock().await;
    Json(
        json!({"schema_version":2,"ready":state.snapshot.read().await.as_ref().is_some_and(|(g,_)|*g==state.generation.load(Ordering::SeqCst)),"refreshing":status.refreshing,"last_completed_at":status.last_completed_at,"next_refresh_at":status.next_refresh_at,"settings_revision":settings.revision,"client_id":principal.id,"access_mode":if state.manage && principal.manage {"manage"} else {"read_only"},"account_storage_enabled":state.vault.is_some(),"api_version":2,"server_version":env!("CARGO_PKG_VERSION")}),
    )
}
fn provider_value(
    p: Provider,
    enabled: &[Provider],
) -> crate::providers::capabilities::ProviderDescriptor {
    crate::providers::capabilities::ProviderDescriptor::new(p, enabled)
}
async fn providers(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
) -> Json<crate::providers::capabilities::ProviderList> {
    let enabled = state
        .settings
        .read()
        .await
        .values
        .tracked_providers()
        .unwrap_or_default();
    let mut list = crate::providers::capabilities::ProviderList::new(&enabled);
    for provider in &mut list.providers {
        state.restrict_provider(provider, &principal);
    }
    Json(list)
}
async fn provider(
    State(state): State<Arc<ApiState>>,
    Path(id): Path<String>,
    Extension(principal): Extension<security::Principal>,
) -> Response {
    let Some(p) = Provider::value_variants().iter().find(|p| p.id() == id) else {
        return error(StatusCode::NOT_FOUND, "provider_not_found");
    };
    let mut descriptor = provider_value(
        *p,
        &state
            .settings
            .read()
            .await
            .values
            .tracked_providers()
            .unwrap_or_default(),
    );
    state.restrict_provider(&mut descriptor, &principal);
    Json(descriptor).into_response()
}
async fn resolved_snapshot(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
) -> Result<Json<crate::contract::Snapshot>, ApiError> {
    let _guard = crate::accounts::service::mutation_guard(&state.commit_guard)
        .await
        .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "account_busy"))?;
    let now = state.context.clock.now();
    let ttl = time::Duration::seconds(
        state
            .settings
            .read()
            .await
            .values
            .cache_ttl_seconds
            .min(i64::MAX as u64) as i64,
    );
    let report = state
        .snapshot
        .read()
        .await
        .as_ref()
        .filter(|(generation, _)| *generation == state.generation.load(Ordering::SeqCst))
        .map(|(_, report)| report.clone())
        .unwrap_or(UsageReport {
            schema_version: 1,
            generated_at: now,
            providers: Vec::new(),
            failures: Vec::new(),
        });
    if !state.no_saved_accounts {
        let vault = state.vault.clone().ok_or(ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "account_storage_disabled",
        ))?;
        return crate::accounts::api::resolved_snapshot(vault, report, now, ttl)
            .await
            .map(|mut snapshot| {
                state.restrict_snapshot(&mut snapshot, &principal);
                Json(snapshot)
            })
            .map_err(|error| {
                ApiError(
                    StatusCode::SERVICE_UNAVAILABLE,
                    management::account_code(&error),
                )
            });
    }
    // This mode deliberately never opens the protected account vault. Its host ID is session-scoped.
    let mut previous = state.transient_snapshot.lock().await;
    let mut accounts = match previous.as_ref() {
        Some(snapshot) => crate::contract::AccountList {
            schema_version: 2,
            account_redirects: std::collections::BTreeMap::new(),
            host: snapshot.host.clone(),
            revision: snapshot.revision,
            accounts: Vec::new(),
        },
        None => crate::accounts::resolved::Registry::new(&[])
            .and_then(|registry| registry.account_list(&[]))
            .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "host_state_unavailable"))?,
    };
    accounts.host.capabilities.insert(
        "account_write_v2".into(),
        crate::contract::Availability {
            available: false,
            reason: Some("no_saved_accounts".into()),
        },
    );
    let mut snapshot = crate::contract::snapshot::project(accounts, &report, now, ttl)
        .map_err(|_| ApiError(StatusCode::INTERNAL_SERVER_ERROR, "invalid_snapshot"))?;
    state.restrict_snapshot(&mut snapshot, &principal);
    let digest = crate::contract::snapshot::digest(&snapshot)
        .map_err(|_| ApiError(StatusCode::INTERNAL_SERVER_ERROR, "invalid_snapshot"))?;
    if previous
        .as_ref()
        .and_then(|old| crate::contract::snapshot::digest(old).ok())
        .as_ref()
        != Some(&digest)
    {
        snapshot.revision = snapshot.revision.checked_add(1).ok_or(ApiError(
            StatusCode::INTERNAL_SERVER_ERROR,
            "revision_exhausted",
        ))?;
    }
    *previous = Some(snapshot.clone());
    Ok(Json(snapshot))
}

async fn settings(State(state): State<Arc<ApiState>>) -> Result<Json<SettingsView>, ApiError> {
    let _guard = crate::accounts::service::mutation_guard(&state.commit_guard)
        .await
        .map_err(|_| settings_error(SettingsError::Busy))?;
    let store = state.store.clone();
    let view = tokio::task::spawn_blocking(move || store.load())
        .await
        .map_err(|_| settings_error(SettingsError::Storage))?
        .map_err(settings_error)?;
    if state.settings.read().await.revision != view.revision {
        *state.settings.write().await = view.clone();
        state.invalidate().await;
    }
    Ok(Json(view))
}
fn settings_error(e: SettingsError) -> ApiError {
    match e {
        SettingsError::Conflict => ApiError(StatusCode::CONFLICT, "revision_conflict"),
        SettingsError::Overridden => ApiError(StatusCode::CONFLICT, "setting_overridden"),
        SettingsError::Busy => ApiError(StatusCode::CONFLICT, "settings_busy"),
        SettingsError::Invalid => ApiError(StatusCode::BAD_REQUEST, "invalid_settings"),
        SettingsError::Storage => ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "settings_storage_unavailable",
        ),
    }
}
async fn patch_settings(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    ApiJson(patch): ApiJson<SettingsPatch>,
) -> Result<Json<SettingsView>, ApiError> {
    if patch.quota_history_enabled.is_some() && !principal.owner {
        return Err(ApiError(StatusCode::FORBIDDEN, "insufficient_scope"));
    }
    // Once started, a config transaction completes even if the HTTP client leaves.
    let (send, receive) = tokio::sync::oneshot::channel();
    let work = state.clone();
    state.spawn(async move {
        let _guard = match work.client_mutation_guard(&principal).await {
            Ok(guard) => guard,
            Err(code) => {
                let _ = send.send(Err(client_access_error(code)));
                return;
            }
        };
        let previous_history_enabled = work.settings.read().await.values.quota_history_enabled;
        let changing_history = patch
            .quota_history_enabled
            .is_some_and(|enabled| enabled != previous_history_enabled);
        let history_only = patch.quota_history_enabled.is_some()
            && patch.enabled_providers.is_none()
            && patch.disabled_providers.is_none()
            && patch.disabled_proxy_auth_files.is_none()
            && patch.automatically_discover_logins.is_none()
            && patch.cache_ttl_seconds.is_none()
            && patch.refresh_interval.is_none()
            && patch.provider_timeout.is_none();
        // Fence in-flight refreshes before the setting changes, so a failed fence leaves the
        // setting as it was and a retry fences again.
        if changing_history
            && let Some(history) = &work.history
            && history.pause(work.context.clock.now()).await.is_err()
        {
            let _ = send.send(Err(ApiError(
                StatusCode::SERVICE_UNAVAILABLE,
                "history_storage_unavailable",
            )));
            return;
        }
        let store = work.store.clone();
        let result = tokio::task::spawn_blocking(move || store.patch(patch))
            .await
            .unwrap_or(Err(SettingsError::Storage));
        if let Ok(view) = &result {
            *work.settings.write().await = view.clone();
            if !history_only {
                work.invalidate().await;
            }
        }
        let _ = send.send(result.map_err(settings_error));
    })?;
    receive
        .await
        .map_err(|_| ApiError(StatusCode::INTERNAL_SERVER_ERROR, "internal_error"))?
        .map(Json)
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct RefreshRequest {
    #[serde(default)]
    providers: Vec<Provider>,
    account_id: Option<String>,
    #[serde(default = "force_default")]
    force: bool,
    #[serde(default = "include_owned_default")]
    include_owned: bool,
    #[serde(default)]
    disabled_proxy_auth_files: Vec<String>,
}
fn force_default() -> bool {
    true
}
fn include_owned_default() -> bool {
    true
}
async fn manual_refresh(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    ApiJson(mut request): ApiJson<RefreshRequest>,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    let enabled = state
        .settings
        .read()
        .await
        .values
        .tracked_providers()
        .unwrap_or_default();
    if request.account_id.is_some() && request.providers.len() != 1 {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_refresh_scope"));
    }
    if request.providers.is_empty() && request.account_id.is_none() {
        request.providers = enabled.clone();
    }
    request.providers.sort_by_key(|p| p.id());
    request.providers.dedup();
    if let Some(id) = &mut request.account_id {
        let snapshot = state.snapshot.read().await;
        if let Some((generation, report)) = snapshot.as_ref()
            && *generation == state.generation.load(Ordering::SeqCst)
            && let Some(source) = crate::contract::snapshot::external_refresh_source(
                report,
                request.providers[0].id(),
                id,
            )
        {
            *id = source.into();
        }
        drop(snapshot);
        management::validate_refresh_account(&state, request.providers[0], id).await?;
    } else if request.providers.iter().any(|p| !enabled.contains(p)) {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_refresh_scope"));
    }
    let key = principal.scoped_key(
        &serde_json::to_string(&request)
            .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_request"))?,
    );
    let mut pending = state.pending.lock().await;
    if let Some(id) = pending.get(&key)
        && let Some(op) = state.operations.lock().await.get(id)
    {
        return Ok((StatusCode::ACCEPTED, Json(op)));
    }
    let (op, _) = state
        .operations
        .lock()
        .await
        .start(&principal.id, "refresh", None, key.clone())
        .map_err(operation_error)?;
    pending.insert(key.clone(), op.id.clone());
    drop(pending);
    let work = state.clone();
    let id = op.id.clone();
    let pending_key = key.clone();
    let spawn_result = state.spawn(async move {
        let result = refresh(&work, Some(request)).await;
        work.operations.lock().await.finish(&id, result);
        work.pending.lock().await.remove(&key);
    });
    if let Err(e) = spawn_result {
        state.pending.lock().await.remove(&pending_key);
        state
            .operations
            .lock()
            .await
            .finish(&op.id, Err("server_busy"));
        return Err(e);
    }
    Ok((StatusCode::ACCEPTED, Json(op)))
}
fn operation_error(code: &'static str) -> ApiError {
    ApiError(
        match code {
            "idempotency_conflict" => StatusCode::CONFLICT,
            "invalid_idempotency_key" => StatusCode::BAD_REQUEST,
            _ => StatusCode::SERVICE_UNAVAILABLE,
        },
        code,
    )
}
async fn operation(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path(id): Path<String>,
) -> Response {
    match state
        .operations
        .lock()
        .await
        .get_for(&id, &principal.id, principal.owner)
    {
        Some(op) => Json(op).into_response(),
        None => error(StatusCode::NOT_FOUND, "operation_not_found"),
    }
}
async fn refresh(state: &ApiState, request: Option<RefreshRequest>) -> Result<Value, &'static str> {
    collect_usage(state, request, false).await
}

async fn collect_usage(
    state: &ApiState,
    request: Option<RefreshRequest>,
    cache_only: bool,
) -> Result<Value, &'static str> {
    let _refresh = state.refresh_lock.lock().await;
    if !state.no_saved_accounts
        && let Some(vault) = state.vault.clone()
    {
        match crate::accounts::service::freeze_native_selectors(vault).await {
            Ok(true) => state.invalidate().await,
            Ok(false) => (),
            Err(error) => {
                if matches!(error, crate::accounts::AccountError::CommitUncertain) {
                    state.invalidate().await;
                }
                return Err(management::account_code(&error));
            }
        }
    }
    let generation = state.generation.load(Ordering::SeqCst);
    let history_revision = state
        .history
        .as_ref()
        .map_or(0, crate::history::History::revision);
    let config = state.settings.read().await.values.clone();
    let enabled = config.tracked_providers().map_err(|_| "invalid_settings")?;
    let (selected, account, force, include_owned, mut disabled_proxy_auth_files) = match request {
        Some(r) => (
            r.providers,
            r.account_id,
            r.force,
            r.include_owned,
            r.disabled_proxy_auth_files,
        ),
        None => (enabled.clone(), None, false, true, Vec::new()),
    };
    disabled_proxy_auth_files.extend(config.disabled_proxy_auth_files);
    if account.is_none() && selected.iter().any(|p| !enabled.contains(p)) {
        return Err("refresh_scope_changed");
    }
    if !cache_only {
        state.status.lock().await.refreshing = true;
    }
    let timeout = Duration::from_secs(config.provider_timeout);
    let borrowed: Vec<_> = [
        crate::accounts::proxy::sources(
            state.proxy_auth_directory.as_deref(),
            None,
            &selected,
            account.as_deref(),
            &disabled_proxy_auth_files,
        ),
        crate::accounts::proxy::sources(
            None,
            state.proxy_configuration.as_deref(),
            &selected,
            account.as_deref(),
            &[],
        ),
    ]
    .into_iter()
    .flat_map(|sources| {
        sources.unwrap_or_else(|_| {
            tracing::warn!("A CLIProxyAPI credential source is unavailable, invalid, or unsafe");
            Vec::new()
        })
    })
    .collect();
    let disabled_proxy_account = account.as_deref().is_some_and(|id| {
        state.proxy_auth_directory.is_some()
            && selected.iter().any(|provider| {
                disabled_proxy_auth_files.iter().any(|name| {
                    crate::cache::fingerprint(&["cli_proxy_auth_file", provider.id(), name]) == id
                })
            })
    });
    let adapters = if disabled_proxy_account || (account.is_some() && !borrowed.is_empty()) {
        Ok(borrowed)
    } else {
        let managed = if state.no_saved_accounts {
            crate::accounts::service::adapters(selected.clone(), false, timeout, account.as_deref())
                .await
        } else if let Some(vault) = state.vault.clone() {
            if let Some(id) = account.as_deref().filter(|id| *id != "local") {
                crate::accounts::service::resolved_adapters(vault, selected[0], id)
                    .await
                    .map(|adapters| {
                        adapters
                            .into_iter()
                            .filter(|adapter| {
                                include_owned
                                    || adapter.account_ref().is_none_or(|reference| {
                                        reference.origin
                                            != Some(crate::domain::AccountOrigin::Owned)
                                    })
                            })
                            .collect()
                    })
            } else {
                crate::accounts::service::adapters_in_vault(
                    selected.clone(),
                    include_owned,
                    timeout,
                    account.as_deref(),
                    vault,
                )
                .await
            }
        } else {
            Err(crate::accounts::AccountError::Storage)
        };
        managed.map(|mut adapters| {
            if account.is_none() {
                adapters.extend(borrowed);
            }
            adapters
        })
    };
    let collector = Collector {
        context: state.context.clone(),
    };
    let cache = crate::cache::UsageCache::platform(Duration::from_secs(config.cache_ttl_seconds));
    let source_scope = account.as_ref().map(|id| {
        let mut sources = adapters
            .as_ref()
            .map(|adapters| {
                adapters
                    .iter()
                    .filter_map(|adapter| adapter.account_ref().map(|reference| reference.id))
                    .collect::<std::collections::HashSet<_>>()
            })
            .unwrap_or_default();
        sources.insert(id.clone());
        sources
    });
    let report = match adapters {
        Ok(providers) => {
            let request = CollectRequest {
                providers,
                timeout,
                cancellation: Cancellation::default(),
            };
            if cache_only {
                cache.restore(&collector, request).await
            } else {
                cache.collect(&collector, request, force).await
            }
        }
        Err(error) if account.is_some() => {
            state.status.lock().await.refreshing = false;
            return Err(management::account_code(&error));
        }
        Err(_) => UsageReport {
            schema_version: 1,
            generated_at: state.context.clock.now(),
            providers: vec![],
            failures: selected
                .iter()
                .map(|p| ProviderFailure {
                    provider: ProviderId(p.id().into()),
                    account_ref: None,
                    code: ProviderError::CredentialStorage,
                    message: ProviderError::CredentialStorage.to_string(),
                })
                .collect(),
        },
    };
    accept_report(
        state,
        report,
        AcceptedRefresh {
            generation,
            history_revision,
            cache_only,
            selected: &selected,
            enabled: &enabled,
            source_scope: source_scope.as_ref(),
            cache_ttl_seconds: config.cache_ttl_seconds,
        },
    )
    .await
}

struct AcceptedRefresh<'a> {
    generation: u64,
    history_revision: u64,
    cache_only: bool,
    selected: &'a [Provider],
    enabled: &'a [Provider],
    source_scope: Option<&'a std::collections::HashSet<String>>,
    cache_ttl_seconds: u64,
}
async fn accept_report(
    state: &ApiState,
    report: UsageReport,
    scope: AcceptedRefresh<'_>,
) -> Result<Value, &'static str> {
    let AcceptedRefresh {
        generation,
        history_revision,
        cache_only,
        selected,
        enabled,
        source_scope,
        cache_ttl_seconds,
    } = scope;
    let failures = report.failures.len();
    let successes = report.providers.len();
    let _guard = match crate::accounts::service::mutation_guard(&state.commit_guard).await {
        Ok(guard) => guard,
        Err(_) => {
            state.status.lock().await.refreshing = false;
            return Err("account_busy");
        }
    };
    let mut status = state.status.lock().await;
    status.refreshing = false;
    if !cache_only {
        status.last_completed_at = Some(timestamp(report.generated_at));
    }
    drop(status);
    if generation != state.generation.load(Ordering::SeqCst) {
        state.wake.notify_one();
        return Err("state_changed");
    }
    let result = json!({"providers":successes,"failures":failures});
    if cache_only && successes == 0 && failures == 0 {
        return Ok(result);
    }
    // merge_refresh_report rejects reports that touch a disabled provider; keep them out of history too.
    if !cache_only
        && selected.iter().all(|provider| enabled.contains(provider))
        && let Err(error) =
            history::record(state, &report, history_revision, cache_ttl_seconds).await
    {
        tracing::warn!(code = error.1, "quota history recording failed");
        if let Some(history) = &state.history {
            let _ = history.note_error("history_recording_failed").await;
        }
    }
    let mut snapshot = state.snapshot.write().await;
    if !merge_refresh_report(
        &mut snapshot,
        generation,
        selected,
        enabled,
        source_scope,
        report,
    ) {
        tracing::info!(
            successes,
            failures,
            "scoped refresh completed outside scheduled snapshot"
        );
        return Ok(result);
    }
    tracing::info!(successes, failures, "refresh completed");
    Ok(result)
}

fn merge_refresh_report(
    snapshot: &mut Option<(u64, UsageReport)>,
    generation: u64,
    selected: &[Provider],
    enabled: &[Provider],
    account: Option<&std::collections::HashSet<String>>,
    report: UsageReport,
) -> bool {
    if selected.iter().any(|provider| !enabled.contains(provider)) {
        return false;
    }
    // Replace the requested scope, never restore failed data here; UsageCache owns retention.
    let full_refresh = account.is_none()
        && selected.len() == enabled.len()
        && selected.iter().all(|provider| enabled.contains(provider));
    // OAuth can advance the generation without clearing the previous snapshot.
    // Seed the current scope instead of retaining data from that invalidated state.
    if full_refresh || snapshot.as_ref().is_some_and(|(old, _)| *old != generation) {
        *snapshot = Some((generation, report));
        return true;
    }

    let (_, previous) = snapshot.get_or_insert_with(|| {
        (
            generation,
            UsageReport {
                schema_version: 1,
                generated_at: report.generated_at,
                providers: vec![],
                failures: vec![],
            },
        )
    });
    let matches = |provider: &ProviderId, reference: Option<&crate::domain::AccountRef>| {
        selected.iter().any(|p| p.id() == provider.0)
            && account.is_none_or(|ids| ids.contains(reference.map_or("local", |r| r.id.as_str())))
    };
    previous
        .providers
        .retain(|p| !matches(&p.provider, p.account_ref.as_ref()));
    previous
        .failures
        .retain(|p| !matches(&p.provider, p.account_ref.as_ref()));
    previous.providers.extend(report.providers);
    previous.failures.extend(report.failures);
    previous.generated_at = report.generated_at;
    true
}
async fn wait_for_next_refresh(state: &ApiState) {
    let interval = state.settings.read().await.values.refresh_interval;
    if interval == 0 {
        state.status.lock().await.next_refresh_at = None;
        state.wake.notified().await;
        return;
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(interval);
    state.status.lock().await.next_refresh_at = Some(timestamp(
        state.context.clock.now() + time::Duration::seconds(interval as i64),
    ));
    tokio::select! {
        _ = tokio::time::sleep_until(deadline) => (),
        _ = state.wake.notified() => (),
    }
    state.status.lock().await.next_refresh_at = None;
}
pub async fn run(args: ServeArgs) -> Result<(), ServerError> {
    if !args.listen.ip().is_loopback() {
        return Err(ServerError::Listen);
    }
    let proxy_auth_directory = args
        .cli_proxy_auth_dir
        .or_else(crate::accounts::proxy::default_auth_directory);
    if let Some(directory) = proxy_auth_directory.as_deref() {
        crate::accounts::proxy::validate_directory(directory).map_err(|_| ServerError::Config)?;
    }
    let path = args
        .config
        .clone()
        .or_else(Config::default_path)
        .ok_or(ServerError::Config)?;
    let store = SettingsStore::new(
        path,
        Overrides {
            providers: (!args.provider.is_empty()).then_some(args.provider.clone()),
            refresh_interval: args.refresh_interval,
            provider_timeout: args.timeout,
        },
    );
    let mut parent = if args.parent_pipe {
        Some(bootstrap::Parent::open().await?)
    } else {
        None
    };
    let view = match parent
        .as_mut()
        .and_then(bootstrap::Parent::take_preferences)
    {
        Some(preferences) => store.import_native_preferences(preferences),
        None => store.load(),
    }
    .map_err(|_| ServerError::Config)?;
    let token = if let Some(parent) = &mut parent {
        Some(parent.take_token())
    } else {
        match std::env::var("QUOTIO_SERVER_TOKEN") {
            Ok(t) => Some(t),
            Err(std::env::VarError::NotPresent) => None,
            Err(_) => return Err(ServerError::Security),
        }
    };
    // Validate before binding or inspecting any provider credential.
    security::Policy::new(
        args.listen,
        args.manage,
        args.public_url.as_deref(),
        &args.allow_origin,
        token.clone(),
    )
    .map_err(|_| ServerError::Security)?;
    let listener = TcpListener::bind(args.listen)
        .await
        .map_err(|_| ServerError::Bind)?;
    let address = listener.local_addr().map_err(|_| ServerError::Bind)?;
    let policy = Arc::new(
        security::Policy::new(
            address,
            args.manage,
            args.public_url.as_deref(),
            &args.allow_origin,
            token,
        )
        .map_err(|_| ServerError::Security)?,
    );
    let context = ProviderContext {
        http: reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|_| ServerError::Initialize)?,
        clock: Arc::new(SystemClock),
        credentials: Arc::new(EnvironmentCredentials),
    };
    let generation = Arc::new(AtomicU64::new(0));
    let commit_guard = Arc::new(Mutex::new(()));
    let vault = if args.no_saved_accounts {
        None
    } else if let (Some(namespace), Some(directory)) =
        (&args.account_vault_namespace, &args.account_data_dir)
    {
        Some(
            crate::accounts::vault::Vault::isolated_for_usage(namespace, directory)
                .map_err(|_| ServerError::Config)?,
        )
    } else {
        crate::accounts::vault::Vault::for_usage().ok()
    };
    let oauth = vault.clone().map(|v| {
        crate::accounts::oauth::OAuthSessionManager::new(
            context.clone(),
            v,
            commit_guard.clone(),
            generation.clone(),
        )
    });
    let history = if let Some(vault) = &vault {
        crate::history::History::open(vault.history_path(), context.clock.now())
            .await
            .ok()
    } else {
        None
    };
    let state = Arc::new(ApiState {
        history,
        history_epochs: Mutex::new(HashMap::new()),
        sharing: Mutex::new(sharing::Sharing::default()),
        discovery: Default::default(),
        native_scan_lock: Mutex::new(()),
        settings: RwLock::new(view),
        store,
        snapshot: RwLock::new(None),
        transient_snapshot: Mutex::new(None),
        generation,
        restore_pending: AtomicBool::new(true),
        commit_guard,
        refresh_lock: Mutex::new(()),
        pending: Mutex::new(HashMap::new()),
        wake: Notify::new(),
        operations: Mutex::new(Operations::default()),
        jobs: std::sync::Mutex::new(Vec::new()),
        status: Mutex::new(RefreshStatus::default()),
        context,
        no_saved_accounts: args.no_saved_accounts,
        proxy_auth_directory,
        proxy_configuration: args.cli_proxy_config,
        manage: args.manage,
        vault,
        oauth,
    });
    if args.parent_pipe {
        bootstrap::announce(address)?;
    } else {
        eprintln!("Quotio API listening on http://{address}");
    }
    tracing::info!(
        manage = state.manage,
        version = env!("CARGO_PKG_VERSION"),
        "server started"
    );
    let worker_state = state.clone();
    let mut worker = tokio::spawn(async move {
        loop {
            if let Err(code) = native::scheduled(&worker_state).await {
                tracing::warn!(code, "scheduled discovery failed");
            }
            let generation = worker_state.generation.load(Ordering::SeqCst);
            let current = worker_state
                .snapshot
                .read()
                .await
                .as_ref()
                .is_some_and(|(observed, _)| *observed == generation);
            let needs_restore =
                worker_state.restore_pending.swap(false, Ordering::SeqCst) || !current;
            if needs_restore && let Err(code) = collect_usage(&worker_state, None, true).await {
                worker_state.restore_pending.store(true, Ordering::SeqCst);
                tracing::warn!(code, "cached quota restoration failed");
            }
            if worker_state.settings.read().await.values.refresh_interval == 0 {
                wait_for_next_refresh(&worker_state).await;
                continue;
            }
            if let Err(code) = refresh(&worker_state, None).await {
                tracing::warn!(code, "scheduled refresh failed");
            }
            wait_for_next_refresh(&worker_state).await;
        }
    });
    let (stop, mut stopped) = watch::channel(false);
    let server = axum::serve(listener, router(state.clone(), policy))
        .with_graceful_shutdown(async move {
            let _ = stopped.wait_for(|v| *v).await;
        })
        .into_future();
    tokio::pin!(server);
    let result = tokio::select! {
        r=&mut server=>r.map_err(|_|ServerError::Initialize),
        _=&mut worker=>Err(ServerError::Initialize),
        _=async {
            if let Some(parent) = &mut parent {
                tokio::select! { _=shutdown_signal()=>(), _=parent.closed()=>() }
            } else {
                shutdown_signal().await;
            }
        }=>{stop.send_replace(true);let _=tokio::time::timeout(Duration::from_secs(2),&mut server).await;Ok(())}
    };
    stop.send_replace(true);
    state.sharing.lock().await.stop();
    worker.abort();
    for job in state.jobs.lock().expect("job tracker").iter() {
        job.abort();
    }
    tracing::info!(success = result.is_ok(), "server stopped");
    result
}
async fn shutdown_signal() {
    #[cfg(unix)]
    {
        if let Ok(mut terminate) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            tokio::select! {_=tokio::signal::ctrl_c()=>(),_=terminate.recv()=>()}
            return;
        }
    }
    let _ = tokio::signal::ctrl_c().await;
}
