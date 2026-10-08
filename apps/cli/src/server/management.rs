use super::*;
use crate::accounts::{
    AccountError, api,
    oauth::{OAuthMode, SessionDto},
    vault::Vault,
};
use axum::http::HeaderMap;

fn vault(state: &ApiState) -> Result<Vault, ApiError> {
    state.vault.clone().ok_or(ApiError(
        StatusCode::SERVICE_UNAVAILABLE,
        "account_storage_disabled",
    ))
}
pub(super) fn account_code(error: &AccountError) -> &'static str {
    match error {
        AccountError::Storage => "credential_storage_unavailable",
        AccountError::Corrupt => "credential_storage_corrupt",
        AccountError::NewerFormat => "credential_storage_newer_version",
        AccountError::Busy => "account_busy",
        AccountError::SourceDisabled => "source_disabled",
        AccountError::Snapshot => "invalid_snapshot",
        AccountError::CommitUncertain => "credential_commit_uncertain",
        AccountError::IdempotencyConflict => "idempotency_conflict",
        AccountError::IdempotencyFull => "idempotency_full",
        AccountError::NotFound => "account_not_found",
        AccountError::Duplicate => "duplicate_account",
        AccountError::Label => "invalid_label",
        AccountError::Settings => "invalid_provider_settings",
        AccountError::NativeOAuth(_) => "native_login_required",
        AccountError::Unsupported => "unsupported_operation",
        AccountError::CallbackPort => "callback_port_unavailable",
        AccountError::OAuth => "oauth_failed",
        AccountError::Cancelled => "oauth_expired_or_cancelled",
        AccountError::Provider(_) => "credential_validation_failed",
        _ => "invalid_credential",
    }
}
fn native_source_error(error: &AccountError) -> &'static str {
    match error {
        AccountError::Provider(
            crate::error::ProviderError::Authentication
            | crate::error::ProviderError::OwnerRefreshRequired,
        ) => "native_login_required",
        AccountError::Provider(crate::error::ProviderError::InvalidData)
        | AccountError::Corrupt => "native_credential_invalid",
        AccountError::Provider(
            crate::error::ProviderError::CredentialStorage
            | crate::error::ProviderError::LocalCredentialStorage,
        ) => "native_keychain_access_failed",
        _ => account_code(error),
    }
}

fn account_error(error: AccountError) -> ApiError {
    let status = match error {
        AccountError::NotFound => StatusCode::NOT_FOUND,
        AccountError::Busy
        | AccountError::Duplicate
        | AccountError::CallbackPort
        | AccountError::IdempotencyConflict => StatusCode::CONFLICT,
        AccountError::Storage
        | AccountError::Corrupt
        | AccountError::NewerFormat
        | AccountError::CommitUncertain => StatusCode::SERVICE_UNAVAILABLE,
        _ => StatusCode::BAD_REQUEST,
    };
    ApiError(status, account_code(&error))
}
pub(super) async fn resolved_accounts(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
) -> Result<Json<crate::contract::AccountList>, ApiError> {
    let mut accounts =
        tokio::time::timeout(Duration::from_secs(10), api::resolved_list(vault(&state)?))
            .await
            .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "account_busy"))?
            .map_err(account_error)?;
    state.restrict_host(&mut accounts.host, &principal);
    for account in &mut accounts.accounts {
        state.restrict_account(account, &principal);
    }
    Ok(Json(accounts))
}

pub(super) async fn resolved_create(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    headers: HeaderMap,
    ApiJson(body): ApiJson<Value>,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    let input = serde_json::from_value(body.clone())
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_request"))?;
    mutate(
        state,
        principal,
        headers,
        "resolved_account_create",
        "",
        body,
        Mutation::ResolvedCreate(input),
    )
    .await
}

pub(super) async fn resolved_account(
    State(state): State<Arc<ApiState>>,
    Path(id): Path<String>,
    Extension(principal): Extension<security::Principal>,
) -> Result<Json<crate::contract::Account>, ApiError> {
    let mut account = tokio::time::timeout(
        Duration::from_secs(10),
        api::resolved_get(vault(&state)?, id),
    )
    .await
    .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "account_busy"))?
    .map_err(account_error)?;
    state.restrict_account(&mut account, &principal);
    Ok(Json(account))
}

pub(super) async fn resolved_patch(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path(id): Path<String>,
    headers: HeaderMap,
    ApiJson(body): ApiJson<Value>,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    let patch = serde_json::from_value(body.clone())
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_request"))?;
    mutate(
        state,
        principal,
        headers,
        "resolved_account_update",
        &id.clone(),
        body,
        Mutation::ResolvedUpdate(id, patch),
    )
    .await
}
pub(super) async fn resolved_remove(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    mutate(
        state,
        principal,
        headers,
        "resolved_account_remove",
        &id.clone(),
        json!({}),
        Mutation::ResolvedRemove(id),
    )
    .await
}
pub(super) async fn source_patch(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path(id): Path<String>,
    headers: HeaderMap,
    ApiJson(body): ApiJson<Value>,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    let patch: api::SourcePatch = serde_json::from_value(body.clone())
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_request"))?;
    let patch = patch.into_account_patch().map_err(account_error)?;
    mutate(
        state,
        principal,
        headers,
        "source_update",
        &id.clone(),
        body,
        Mutation::SourceUpdate(id, Some(patch)),
    )
    .await
}
pub(super) async fn source_remove(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    mutate(
        state,
        principal,
        headers,
        "source_remove",
        &id.clone(),
        json!({}),
        Mutation::SourceUpdate(id, None),
    )
    .await
}

enum Mutation {
    ResolvedCreate(api::AccountCreateInput),
    ResolvedUpdate(String, api::ResolvedAccountPatch),
    ResolvedRemove(String),
    SourceUpdate(String, Option<api::AccountPatch>),
    Migrate(api::migration::Input),
    Reference(api::SourceInput),
    Authorize(api::SourceInput),
    AuthorizeVault,
}
pub(super) async fn migrate(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    headers: HeaderMap,
    ApiJson(body): ApiJson<Value>,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    if !principal.owner {
        return Err(ApiError(StatusCode::FORBIDDEN, "owner_required"));
    }
    let input = serde_json::from_value(body.clone())
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_request"))?;
    mutate(
        state,
        principal,
        headers,
        "account_migrate",
        "",
        body,
        Mutation::Migrate(input),
    )
    .await
}
pub(super) async fn discover(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    ApiJson(body): ApiJson<Value>,
) -> Result<Json<Value>, ApiError> {
    let input = serde_json::from_value(body)
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_request"))?;
    if !state.manage {
        return Err(ApiError(StatusCode::FORBIDDEN, "management_required"));
    }
    let result = tokio::time::timeout(
        Duration::from_secs(10),
        tokio::task::spawn_blocking(move || {
            state
                .discovery
                .try_lock()
                .map_err(|_| AccountError::Busy)?
                .inspect_for(&principal.id, input)
        }),
    )
    .await
    .map_err(|_| {
        ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "source_inspection_unavailable",
        )
    })?
    .map_err(|_| {
        ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "source_inspection_unavailable",
        )
    })?
    .map_err(account_error)?;
    Ok(Json(result))
}
pub(super) async fn authorize(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    headers: HeaderMap,
    ApiJson(body): ApiJson<Value>,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    if !principal.host_user {
        return Err(ApiError(StatusCode::FORBIDDEN, "host_interaction_required"));
    }
    let input = serde_json::from_value(body.clone())
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_request"))?;
    crate::accounts::authorization::validate(&input).map_err(account_error)?;
    mutate(
        state,
        principal,
        headers,
        "native_source_authorize",
        "",
        body,
        Mutation::Authorize(input),
    )
    .await
}

pub(super) async fn authorize_vault(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    headers: HeaderMap,
    ApiJson(body): ApiJson<Value>,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    if !principal.host_user {
        return Err(ApiError(StatusCode::FORBIDDEN, "host_interaction_required"));
    }
    if body != json!({}) {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_request"));
    }
    mutate(
        state,
        principal,
        headers,
        "account_vault_authorize",
        "",
        body,
        Mutation::AuthorizeVault,
    )
    .await
}

pub(super) async fn reference(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    headers: HeaderMap,
    ApiJson(body): ApiJson<Value>,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    let input = serde_json::from_value(body.clone())
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_request"))?;
    mutate(
        state,
        principal,
        headers,
        "account_source_register",
        "",
        body,
        Mutation::Reference(input),
    )
    .await
}
async fn mutate(
    state: Arc<ApiState>,
    principal: security::Principal,
    headers: HeaderMap,
    kind: &str,
    target: &str,
    body: Value,
    mutation: Mutation,
) -> Result<(StatusCode, Json<Operation>), ApiError> {
    let vault = vault(&state)?;
    let mut keys = headers.get_all("idempotency-key").iter();
    let key = keys.next().and_then(|v| v.to_str().ok()).ok_or(ApiError(
        StatusCode::BAD_REQUEST,
        "idempotency_key_required",
    ))?;
    if keys.next().is_some() {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_idempotency_key"));
    }
    let fingerprint = crate::cache::fingerprint(&[
        kind,
        target,
        &serde_json::to_string(&body)
            .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_request"))?,
    ]);
    drop(body);
    crate::accounts::service::MutationIntent::new(key, String::new())
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_idempotency_key"))?;
    let key = principal.scoped_key(key);
    let intent = crate::accounts::service::MutationIntent::new(&key, fingerprint.clone())
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_idempotency_key"))?;
    // Durable receipts survive both discovery expiry and server restart. Validate
    // the body fingerprint before attempting to read a live native source.
    let authorize = matches!(&mutation, Mutation::Authorize(_) | Mutation::AuthorizeVault);
    let receipt = if authorize {
        None
    } else {
        crate::accounts::service::mutation_receipt(vault.clone(), &intent)
            .await
            .map_err(account_error)?
    };
    let (operation, new) = state
        .operations
        .lock()
        .await
        .start(&principal.id, kind, Some(key), fingerprint)
        .map_err(operation_error)?;
    if new {
        let work = state.clone();
        let id = operation.id.clone();
        let spawn_result = state.spawn(async move {
            let result = async {
                if authorize {
                    vault
                        .authorize_interactively()
                        .await
                        .map_err(|_| "quotio_vault_access_failed")?;
                    if matches!(&mutation, Mutation::Authorize(_))
                        && let Some(id) =
                            crate::accounts::service::mutation_receipt(vault.clone(), &intent)
                                .await
                                .map_err(|error| account_code(&error))?
                    {
                        return Ok(json!({"account_id": id}));
                    }
                }
                if let Some(id) = receipt {
                    return Ok(json!({"account_id":id}));
                }
                match mutation {
                    Mutation::ResolvedUpdate(id, patch) => {
                        let _guard = work.client_mutation_guard(&principal).await?;
                        let id = api::resolved_update_once(vault, id, patch, intent)
                            .await
                            .map_err(|e| account_code(&e))?;
                        work.invalidate_sources(&[]).await;
                        Ok(json!({"account_id":id}))
                    }
                    Mutation::ResolvedRemove(id) => {
                        let _guard = work.client_mutation_guard(&principal).await?;
                        let sources = api::resolved_get(vault.clone(), id.clone())
                            .await
                            .map_err(|e| account_code(&e))?
                            .sources
                            .into_iter()
                            .map(|source| source.id)
                            .collect::<Vec<_>>();
                        let id = api::resolved_remove_once(vault, id, intent)
                            .await
                            .map_err(|e| account_code(&e))?;
                        work.invalidate_sources(&sources).await;
                        Ok(json!({"account_id":id}))
                    }
                    Mutation::SourceUpdate(id, patch) => {
                        let source_id = id.clone();
                        let patch = match patch {
                            Some(patch) => Some(
                                api::prepare_update(vault.clone(), &work.context, &id, patch)
                                    .await
                                    .map_err(|e| account_code(&e))?,
                            ),
                            None => None,
                        };
                        let _guard = work.client_mutation_guard(&principal).await?;
                        let id = api::source_update_once(vault, id, patch, intent)
                            .await
                            .map_err(|e| account_code(&e))?;
                        work.invalidate_sources(&[source_id]).await;
                        Ok(json!({"account_id":id}))
                    }
                    Mutation::AuthorizeVault => Ok(json!({})),
                    Mutation::Migrate(input) => {
                        let (prepared, enabled) = api::migration::prepare(input, &work.context)
                            .map_err(|e| account_code(&e))?;
                        let _guard = work.client_mutation_guard(&principal).await?;
                        let id = api::migration::save_once(vault, prepared, enabled, intent)
                            .await
                            .map_err(|e| account_code(&e))?;
                        work.invalidate().await;
                        Ok(json!({"account_id":id}))
                    }
                    Mutation::ResolvedCreate(input) => {
                        let prepared = match input {
                            api::AccountCreateInput::ApiKey(input) => {
                                api::prepare(&work.context, input).await
                            }
                            api::AccountCreateInput::AntigravityOwned(input) => {
                                api::prepare_antigravity_owned(input)
                            }
                            api::AccountCreateInput::KiroOwned(input) => {
                                api::prepare_kiro_owned(input)
                            }
                            api::AccountCreateInput::FactoryOwned(input) => {
                                api::prepare_factory_owned(input)
                            }
                            api::AccountCreateInput::GrokOwned(input) => {
                                api::prepare_grok_owned(input)
                            }
                        }
                        .map_err(|e| account_code(&e))?;
                        let _guard = work.client_mutation_guard(&principal).await?;
                        let account_id = api::resolved_save_once(vault, prepared, intent)
                            .await
                            .map_err(|e| account_code(&e))?;
                        work.invalidate().await;
                        Ok(json!({"account_id":account_id}))
                    }
                    Mutation::Reference(input) | Mutation::Authorize(input) => {
                        let input = if authorize {
                            crate::accounts::authorization::authorize(input)
                                .await
                                .map_err(|error| match error {
                                    AccountError::Provider(
                                        crate::error::ProviderError::Authentication,
                                    ) => "native_login_required",
                                    _ => "native_keychain_access_failed",
                                })?
                        } else {
                            input
                        };
                        let prepared = match input {
                            api::SourceInput::Discovered { discovery_ref } => {
                                let reference = work
                                    .discovery
                                    .try_lock()
                                    .map_err(|_| account_code(&AccountError::Busy))?
                                    .get_for(&discovery_ref, &principal.id, principal.owner)
                                    .map_err(|e| account_code(&e))?;
                                reference.resolve().await
                            }
                            input => api::prepare_source(input).await,
                        }
                        .map_err(|e| {
                            if authorize {
                                native_source_error(&e)
                            } else {
                                account_code(&e)
                            }
                        })?;
                        let _guard = work.client_mutation_guard(&principal).await?;
                        let account_id = api::register_source_once(vault, prepared, intent)
                            .await
                            .map_err(|e| account_code(&e))?;
                        work.invalidate().await;
                        Ok(json!({"account_id":account_id}))
                    }
                }
            }
            .await;
            if matches!(result, Err("credential_commit_uncertain")) {
                work.invalidate().await;
            }
            work.operations.lock().await.finish(&id, result);
        });
        if let Err(error) = spawn_result {
            state
                .operations
                .lock()
                .await
                .finish(&operation.id, Err("server_busy"));
            return Err(error);
        }
    }
    Ok((StatusCode::ACCEPTED, Json(operation)))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct SessionInput {
    provider: Provider,
    label: Option<String>,
    #[serde(default)]
    callback_mode: Option<OAuthMode>,
    /// Copilot only: `github.com` (default) or a `<subdomain>.ghe.com` host.
    #[serde(default)]
    host: Option<String>,
}
impl SessionInput {
    fn effective_mode(&self) -> OAuthMode {
        self.callback_mode.unwrap_or_else(|| {
            match crate::providers::capabilities::capability(self.provider).oauth_workflow {
                Some(crate::accounts::oauth::Workflow::BrowserCallback) => OAuthMode::Loopback,
                _ => OAuthMode::Relay,
            }
        })
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct CallbackInput {
    callback_url: Option<String>,
    code: Option<String>,
}
fn oauth_manager(
    state: &ApiState,
    principal: &security::Principal,
) -> Result<crate::accounts::oauth::OAuthSessionManager, ApiError> {
    if !principal.owner && !principal.manage {
        return Err(ApiError(StatusCode::FORBIDDEN, "insufficient_scope"));
    }
    let manager = state.oauth.as_ref().ok_or(ApiError(
        StatusCode::SERVICE_UNAVAILABLE,
        "account_storage_disabled",
    ))?;
    Ok(manager.for_owner((!principal.owner).then(|| principal.id.clone())))
}

pub(super) async fn begin(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    headers: HeaderMap,
    ApiJson(input): ApiJson<SessionInput>,
) -> Result<(StatusCode, Json<SessionDto>), ApiError> {
    if input.provider == Provider::Codex && !principal.host_user {
        return Err(ApiError(StatusCode::FORBIDDEN, "host_interaction_required"));
    }
    let manager = oauth_manager(&state, &principal)?;
    let mut keys = headers.get_all("idempotency-key").iter();
    let key = keys
        .next()
        .map(|value| {
            let key = value
                .to_str()
                .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_idempotency_key"))?;
            crate::accounts::service::MutationIntent::new(key, String::new())
                .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_idempotency_key"))?;
            Ok::<_, ApiError>(key.to_owned())
        })
        .transpose()?;
    if keys.next().is_some() {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_idempotency_key"));
    }
    let mode = input.effective_mode();
    let host = input
        .host
        .as_deref()
        .map(crate::accounts::github_host::GitHubHost::parse)
        .transpose()
        .map_err(|_| ApiError(StatusCode::BAD_REQUEST, "invalid_github_host"))?;
    if host.is_some() && input.provider != Provider::Catalog("copilot") {
        return Err(account_error(AccountError::Unsupported));
    }
    let host = host.filter(|host| !host.is_github_com());
    let session = match key {
        Some(key) => {
            manager
                .begin_idempotent_at(input.provider, input.label, mode, host, key)
                .await
        }
        None => {
            manager
                .begin_at(input.provider, input.label, mode, host)
                .await
        }
    }
    .map_err(account_error)?;
    Ok((StatusCode::CREATED, Json(session)))
}
pub(super) async fn session(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path(id): Path<String>,
) -> Result<Json<SessionDto>, ApiError> {
    let manager = oauth_manager(&state, &principal)?;
    let session = manager.get(&id).await.map_err(account_error)?;
    if session.status == crate::accounts::oauth::SessionStatus::Completed
        && state
            .snapshot
            .read()
            .await
            .as_ref()
            .is_none_or(|(g, _)| *g != state.generation.load(Ordering::SeqCst))
    {
        state.wake.notify_one();
    }
    Ok(Json(session))
}
pub(super) async fn cancel(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path(id): Path<String>,
) -> Result<Json<SessionDto>, ApiError> {
    let manager = oauth_manager(&state, &principal)?;
    Ok(Json(manager.cancel(&id).await.map_err(account_error)?))
}
pub(super) async fn callback(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path(id): Path<String>,
    ApiJson(input): ApiJson<CallbackInput>,
) -> Result<Json<SessionDto>, ApiError> {
    if input.callback_url.is_some() == input.code.is_some() {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_request"));
    }
    let manager = oauth_manager(&state, &principal)?;
    // Continue token exchange/commit if the caller disconnects; polling reflects the actual result.
    let (send, receive) = tokio::sync::oneshot::channel();
    let work = state.clone();
    state.spawn(async move {
        let result = match (input.callback_url, input.code) {
            (Some(url), None) => manager.callback(&id, &url).await,
            (None, Some(code)) => manager.manual_code(&id, &code).await,
            _ => unreachable!("validated callback input"),
        };
        work.wake.notify_one();
        let _ = send.send(result);
    })?;
    Ok(Json(
        receive
            .await
            .map_err(|_| ApiError(StatusCode::INTERNAL_SERVER_ERROR, "internal_error"))?
            .map_err(account_error)?,
    ))
}

pub(super) async fn validate_refresh_account(
    state: &ApiState,
    provider: Provider,
    id: &str,
) -> Result<(), ApiError> {
    if [
        crate::accounts::proxy::sources(
            state.proxy_auth_directory.as_deref(),
            None,
            &[provider],
            Some(id),
            &[],
        ),
        crate::accounts::proxy::sources(
            None,
            state.proxy_configuration.as_deref(),
            &[provider],
            Some(id),
            &[],
        ),
    ]
    .into_iter()
    .any(|sources| sources.is_ok_and(|accounts| !accounts.is_empty()))
    {
        return Ok(());
    }
    if id == "local" {
        if !state.no_saved_accounts && provider.supports_accounts() {
            let accounts = crate::accounts::service::list(vault(state)?)
                .await
                .map_err(account_error)?;
            if accounts.iter().any(|a| {
                a.provider == provider
                    && crate::accounts::service::native_reference_replaces_local(
                        provider,
                        &a.credential,
                    )
            }) {
                return Err(ApiError(
                    StatusCode::CONFLICT,
                    "registered_source_requires_account_id",
                ));
            }
        }
        return Ok(());
    }
    let account = tokio::time::timeout(
        Duration::from_secs(10),
        api::resolved_get(vault(state)?, id.into()),
    )
    .await
    .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "account_busy"))?
    .map_err(account_error)?;
    if account.provider_id != provider.id() {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_refresh_scope"));
    }
    Ok(())
}

#[cfg(test)]
mod authorization_error_tests {
    use super::*;
    use crate::error::ProviderError;

    #[test]
    fn host_selects_callback_mode_from_the_declared_workflow() {
        for (provider, expected) in [
            ("codex", OAuthMode::Loopback),
            ("claude", OAuthMode::Relay),
            ("copilot", OAuthMode::Relay),
        ] {
            let input: SessionInput = serde_json::from_value(json!({"provider":provider})).unwrap();
            assert!(input.effective_mode() == expected);
        }
        let explicit: SessionInput =
            serde_json::from_value(json!({"provider":"codex", "callback_mode":"relay"})).unwrap();
        assert!(explicit.effective_mode() == OAuthMode::Relay);
    }

    #[test]
    fn successful_keychain_read_does_not_turn_invalid_login_into_permission_failure() {
        assert_eq!(
            native_source_error(&AccountError::Provider(ProviderError::Authentication)),
            "native_login_required"
        );
        assert_eq!(
            native_source_error(&AccountError::Provider(ProviderError::InvalidData)),
            "native_credential_invalid"
        );
        assert_eq!(
            native_source_error(&AccountError::Provider(ProviderError::CredentialStorage)),
            "native_keychain_access_failed"
        );
        assert_eq!(
            native_source_error(&AccountError::Storage),
            "credential_storage_unavailable"
        );
        assert_eq!(
            account_code(&AccountError::Corrupt),
            "credential_storage_corrupt"
        );
        assert_eq!(
            account_code(&AccountError::NewerFormat),
            "credential_storage_newer_version"
        );
    }
}
