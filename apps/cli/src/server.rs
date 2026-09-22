//! HTTP management and snapshot transport; provider work uses the shared usage cache.
mod bootstrap;
#[cfg(test)]
mod discovery_tests;
mod management;
mod openapi;
mod operations;
mod security;
#[cfg(test)]
mod tests;
mod usage_queries;
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
    Json, Router,
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
        atomic::{AtomicU64, Ordering},
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
    settings: RwLock<SettingsView>,
    store: SettingsStore,
    snapshot: RwLock<Option<(u64, UsageReport)>>,
    generation: Arc<AtomicU64>,
    commit_guard: Arc<Mutex<()>>,
    refresh_lock: Mutex<()>,
    pending: Mutex<HashMap<String, String>>,
    wake: Notify,
    operations: Mutex<Operations>,
    jobs: std::sync::Mutex<Vec<tokio::task::AbortHandle>>,
    discovery: std::sync::Mutex<crate::accounts::discovery::Registry>,
    status: Mutex<RefreshStatus>,
    context: ProviderContext,
    no_saved_accounts: bool,
    proxy_auth_directory: Option<std::path::PathBuf>,
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
    async fn invalidate(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        self.snapshot.write().await.take();
        self.wake.notify_one();
    }
}
fn timestamp(now: time::OffsetDateTime) -> String {
    now.format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default()
}
fn router(state: Arc<ApiState>, policy: Arc<security::Policy>) -> Router {
    Router::new()
        .route("/openapi.json", get(openapi::document))
        .route("/health", get(health))
        .route("/v1/status", get(status))
        .route(
            "/v1/accounts",
            get(management::list).post(management::create),
        )
        .route(
            "/v1/accounts/{id}",
            get(management::get_account)
                .patch(management::patch)
                .delete(management::remove),
        )
        .route("/v1/accounts/migrate", post(management::migrate))
        .route("/v1/account-sources", post(management::reference))
        .route("/v1/account-sources/discover", post(management::discover))
        .route("/v1/accounts/{id}/usage", get(management::usage))
        .route("/v1/auth/sessions", post(management::begin))
        .route(
            "/v1/auth/sessions/{id}",
            get(management::session).delete(management::cancel),
        )
        .route(
            "/v1/auth/sessions/{id}/callback",
            post(management::callback),
        )
        .route("/v1/providers", get(providers))
        .route("/v1/providers/{id}", get(provider))
        .route("/v1/usage", get(usage))
        .route("/v1/usage/queries", post(usage_queries::start))
        .route("/v1/usage/{id}", get(provider_usage))
        .route("/v1/settings", get(settings).patch(patch_settings))
        .route("/v1/refresh", post(manual_refresh))
        .route("/v1/operations/{id}", get(operation))
        .fallback(|| async { error(StatusCode::NOT_FOUND, "not_found") })
        .layer(axum::extract::DefaultBodyLimit::max(65536))
        .layer(middleware::from_fn_with_state(policy, security::guard))
        .with_state(state)
}
async fn health(State(state): State<Arc<ApiState>>) -> Json<Value> {
    Json(
        json!({"status":"ok","ready":state.snapshot.read().await.as_ref().is_some_and(|(generation,_)|*generation==state.generation.load(Ordering::SeqCst))}),
    )
}
async fn status(State(state): State<Arc<ApiState>>) -> Json<Value> {
    let settings = state.settings.read().await;
    let status = state.status.lock().await;
    Json(
        json!({"schema_version":1,"ready":state.snapshot.read().await.as_ref().is_some_and(|(g,_)|*g==state.generation.load(Ordering::SeqCst)),"refreshing":status.refreshing,"last_completed_at":status.last_completed_at,"next_refresh_at":status.next_refresh_at,"settings_revision":settings.revision,"access_mode":if state.manage {"manage"} else {"read_only"},"account_storage_enabled":state.vault.is_some(),"api_version":1,"server_version":env!("CARGO_PKG_VERSION")}),
    )
}
fn provider_value(p: Provider, enabled: &[Provider]) -> Value {
    json!({"id":p.id(),"description":p.description(),"enabled":enabled.contains(&p),"capabilities":crate::providers::capabilities::capability(p)})
}
async fn providers(State(state): State<Arc<ApiState>>) -> Json<Value> {
    let enabled = state
        .settings
        .read()
        .await
        .values
        .providers()
        .unwrap_or_default();
    Json(
        json!({"schema_version":1,"providers":Provider::value_variants().iter().map(|p|provider_value(*p,&enabled)).collect::<Vec<_>>()}),
    )
}
async fn provider(State(state): State<Arc<ApiState>>, Path(id): Path<String>) -> Response {
    let Some(p) = Provider::value_variants().iter().find(|p| p.id() == id) else {
        return error(StatusCode::NOT_FOUND, "provider_not_found");
    };
    Json(provider_value(
        *p,
        &state
            .settings
            .read()
            .await
            .values
            .providers()
            .unwrap_or_default(),
    ))
    .into_response()
}
async fn usage(State(state): State<Arc<ApiState>>) -> Response {
    usage_response(&state, None, None).await
}
async fn provider_usage(State(state): State<Arc<ApiState>>, Path(id): Path<String>) -> Response {
    if !state
        .settings
        .read()
        .await
        .values
        .enabled_providers
        .contains(&id)
    {
        return error(StatusCode::NOT_FOUND, "provider_not_enabled");
    }
    usage_response(&state, Some(&id), None).await
}
async fn usage_response(
    state: &ApiState,
    provider: Option<&str>,
    account: Option<&str>,
) -> Response {
    let _guard = match crate::accounts::service::mutation_guard(&state.commit_guard).await {
        Ok(guard) => guard,
        Err(_) => return error(StatusCode::SERVICE_UNAVAILABLE, "account_busy"),
    };
    let snapshot = state.snapshot.read().await;
    let Some((generation, report)) = &*snapshot else {
        return error(StatusCode::SERVICE_UNAVAILABLE, "not_ready");
    };
    if *generation != state.generation.load(Ordering::SeqCst) {
        state.wake.notify_one();
        return error(StatusCode::SERVICE_UNAVAILABLE, "not_ready");
    }
    let mut value = match serde_json::to_value(report) {
        Ok(value) => value,
        Err(_) => return error(StatusCode::INTERNAL_SERVER_ERROR, "encoding_failed"),
    };
    // A server snapshot can outlive its earliest reset credit between refreshes.
    for (entry, usage) in value["providers"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .zip(&report.providers)
    {
        if usage
            .reset_credits
            .as_ref()
            .is_some_and(|c| !c.valid_at(state.context.clock.now()))
        {
            entry.as_object_mut().unwrap().remove("reset_credits");
        }
    }
    for field in ["providers", "failures"] {
        value[field].as_array_mut().unwrap().retain(|entry| {
            provider.is_none_or(|p| entry["provider"] == p)
                && account.is_none_or(|a| entry["account_ref"]["id"] == a)
        });
    }
    Json(value).into_response()
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
    ApiJson(patch): ApiJson<SettingsPatch>,
) -> Result<Json<SettingsView>, ApiError> {
    // Once started, a config transaction completes even if the HTTP client leaves.
    let (send, receive) = tokio::sync::oneshot::channel();
    let work = state.clone();
    state.spawn(async move {
        let _guard = match crate::accounts::service::mutation_guard(&work.commit_guard).await {
            Ok(guard) => guard,
            Err(_) => {
                let _ = send.send(Err(SettingsError::Busy));
                return;
            }
        };
        let store = work.store.clone();
        let result = tokio::task::spawn_blocking(move || store.patch(patch))
            .await
            .unwrap_or(Err(SettingsError::Storage));
        if let Ok(view) = &result {
            *work.settings.write().await = view.clone();
            work.invalidate().await;
        }
        let _ = send.send(result);
    })?;
    receive
        .await
        .map_err(|_| ApiError(StatusCode::INTERNAL_SERVER_ERROR, "internal_error"))?
        .map(Json)
        .map_err(settings_error)
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
    ApiJson(mut request): ApiJson<RefreshRequest>,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    let enabled = state
        .settings
        .read()
        .await
        .values
        .providers()
        .unwrap_or_default();
    if request.account_id.is_some() && request.providers.len() != 1 {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_refresh_scope"));
    }
    if request.providers.is_empty() && request.account_id.is_none() {
        request.providers = enabled.clone();
    }
    request.providers.sort_by_key(|p| p.id());
    request.providers.dedup();
    if let Some(id) = &request.account_id {
        management::validate_refresh_account(&state, request.providers[0], id).await?;
    } else if request.providers.iter().any(|p| !enabled.contains(p)) {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_refresh_scope"));
    }
    let key = serde_json::to_string(&request)
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_request"))?;
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
        .start("refresh", None, key.clone())
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
async fn operation(State(state): State<Arc<ApiState>>, Path(id): Path<String>) -> Response {
    match state.operations.lock().await.get(&id) {
        Some(op) => Json(op).into_response(),
        None => error(StatusCode::NOT_FOUND, "operation_not_found"),
    }
}
async fn refresh(state: &ApiState, request: Option<RefreshRequest>) -> Result<Value, &'static str> {
    let _refresh = state.refresh_lock.lock().await;
    let generation = state.generation.load(Ordering::SeqCst);
    let config = state.settings.read().await.values.clone();
    let enabled = config.providers().map_err(|_| "invalid_settings")?;
    let (selected, account, force, include_owned, disabled_proxy_auth_files) = match request {
        Some(r) => (
            r.providers,
            r.account_id,
            r.force,
            r.include_owned,
            r.disabled_proxy_auth_files,
        ),
        None => (enabled.clone(), None, false, true, Vec::new()),
    };
    if account.is_none() && selected.iter().any(|p| !enabled.contains(p)) {
        return Err("refresh_scope_changed");
    }
    state.status.lock().await.refreshing = true;
    let timeout = Duration::from_secs(config.provider_timeout);
    let borrowed = state
        .proxy_auth_directory
        .as_deref()
        .map(|directory| {
            crate::accounts::proxy::adapters(
                directory,
                &selected,
                account.as_deref(),
                &disabled_proxy_auth_files,
            )
        })
        .transpose()
        .unwrap_or_else(|_| {
            tracing::warn!("CLIProxyAPI auth directory is unavailable or unsafe");
            None
        })
        .unwrap_or_default();
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
            crate::accounts::service::adapters_in_vault(
                selected.clone(),
                include_owned,
                timeout,
                account.as_deref(),
                vault,
            )
            .await
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
    let report = match adapters {
        Ok(providers) => {
            cache
                .collect(
                    &collector,
                    CollectRequest {
                        providers,
                        timeout,
                        cancellation: Cancellation::default(),
                    },
                    force,
                )
                .await
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
    status.last_completed_at = Some(timestamp(report.generated_at));
    drop(status);
    if generation != state.generation.load(Ordering::SeqCst) {
        state.wake.notify_one();
        return Err("state_changed");
    }
    let result = json!({"providers":successes,"failures":failures,"report":&report});
    let mut snapshot = state.snapshot.write().await;
    if !merge_refresh_report(
        &mut snapshot,
        generation,
        &selected,
        &enabled,
        account.as_deref(),
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
    account: Option<&str>,
    report: UsageReport,
) -> bool {
    if selected.iter().any(|provider| !enabled.contains(provider)) {
        return false;
    }
    // Replace the requested scope, never restore failed data here; UsageCache owns retention.
    let full_refresh = account.is_none()
        && selected.len() == enabled.len()
        && selected.iter().all(|provider| enabled.contains(provider));
    if full_refresh {
        *snapshot = Some((generation, report));
        return true;
    }

    let (old_generation, previous) = snapshot.get_or_insert_with(|| {
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
    if *old_generation != generation {
        return false;
    }
    let matches = |provider: &ProviderId, reference: Option<&crate::domain::AccountRef>| {
        selected.iter().any(|p| p.id() == provider.0)
            && account.is_none_or(|a| reference.is_some_and(|r| r.id == a))
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
    if let Some(directory) = args.cli_proxy_auth_dir.as_deref() {
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
    let view = store.load().map_err(|_| ServerError::Config)?;
    let mut parent = if args.parent_pipe {
        Some(bootstrap::Parent::open().await?)
    } else {
        None
    };
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
            crate::accounts::vault::Vault::isolated_for_management(namespace, directory)
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
    let state = Arc::new(ApiState {
        discovery: Default::default(),
        settings: RwLock::new(view),
        store,
        snapshot: RwLock::new(None),
        generation,
        commit_guard,
        refresh_lock: Mutex::new(()),
        pending: Mutex::new(HashMap::new()),
        wake: Notify::new(),
        operations: Mutex::new(Operations::default()),
        jobs: std::sync::Mutex::new(Vec::new()),
        status: Mutex::new(RefreshStatus::default()),
        context,
        no_saved_accounts: args.no_saved_accounts,
        proxy_auth_directory: args.cli_proxy_auth_dir,
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
