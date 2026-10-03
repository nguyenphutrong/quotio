use super::{
    AccountError, Credential, github_host::GitHubHost, random_string, service, vault::Vault,
};
use crate::providers::{ProviderContext, http};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::digest::{SHA256, digest};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
    time::Instant,
};

pub(crate) mod claude;
mod copilot;

pub const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
const TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
const REDIRECT: &str = "http://localhost:1455/auth/callback";
#[derive(Deserialize)]
struct Tokens {
    access_token: String,
    refresh_token: Option<String>,
    id_token: Option<String>,
    expires_in: i64,
}
fn challenge(verifier: &str) -> String {
    URL_SAFE_NO_PAD.encode(digest(&SHA256, verifier.as_bytes()).as_ref())
}
fn claims(token: &str) -> Result<Value, AccountError> {
    let parts: Vec<_> = token.split('.').collect();
    if parts.len() != 3 {
        return Err(AccountError::OAuth);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(parts[1])
        .map_err(|_| AccountError::OAuth)?;
    serde_json::from_slice(&bytes).map_err(|_| AccountError::OAuth)
}
fn credential(
    tokens: Tokens,
    nonce: Option<&str>,
    previous: Option<&Credential>,
    now: i64,
) -> Result<Credential, AccountError> {
    if tokens.access_token.is_empty() || tokens.expires_in <= 0 {
        return Err(AccountError::OAuth);
    }
    let old = match previous {
        Some(Credential::CodexOAuth {
            refresh_token,
            id_token,
            account_id,
            email,
            ..
        }) => Some((refresh_token, id_token, account_id, email)),
        _ => None,
    };
    let id_token = tokens
        .id_token
        .or_else(|| old.map(|v| v.1.clone()))
        .ok_or(AccountError::OAuth)?;
    // Identity is read only from the response of the fixed TLS token endpoint.
    let claims = claims(&id_token)?;
    let audience = claims.get("aud").is_some_and(|v| {
        v.as_str() == Some(CLIENT_ID)
            || v.as_array()
                .is_some_and(|a| a.iter().any(|v| v.as_str() == Some(CLIENT_ID)))
    });
    if claims.get("iss").and_then(Value::as_str) != Some("https://auth.openai.com") || !audience {
        return Err(AccountError::OAuth);
    }
    if let Some(nonce) = nonce
        && (claims.get("nonce").and_then(Value::as_str) != Some(nonce)
            || claims
                .get("exp")
                .and_then(Value::as_i64)
                .is_none_or(|e| e <= now))
    {
        return Err(AccountError::OAuth);
    }
    let email = claims
        .get("email")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or(AccountError::OAuth)?
        .to_owned();
    let account_id = claims
        .pointer("/https:~1~1api.openai.com~1auth/chatgpt_account_id")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or(AccountError::OAuth)?
        .to_owned();
    if old.is_some_and(|v| *v.2 != account_id || *v.3 != email) {
        return Err(AccountError::OAuth);
    }
    let refresh_token = tokens
        .refresh_token
        .or_else(|| old.map(|v| v.0.clone()))
        .filter(|s| !s.is_empty())
        .ok_or(AccountError::OAuth)?;
    Ok(Credential::CodexOAuth {
        access_token: tokens.access_token,
        refresh_token,
        id_token,
        account_id,
        email,
        expires_at: now
            .checked_add(tokens.expires_in)
            .ok_or(AccountError::OAuth)?,
    })
}
fn callback_code(target: &str, state: &str) -> Result<String, AccountError> {
    let url = reqwest::Url::parse(&format!("http://localhost{target}"))
        .map_err(|_| AccountError::OAuth)?;
    if url.path() != "/auth/callback" {
        return Err(AccountError::OAuth);
    }
    let pairs: Vec<_> = url.query_pairs().collect();
    let states: Vec<_> = pairs.iter().filter(|(k, _)| k == "state").collect();
    let codes: Vec<_> = pairs.iter().filter(|(k, _)| k == "code").collect();
    if states.len() != 1
        || states[0].1 != state
        || codes.len() != 1
        || codes[0].1.is_empty()
        || pairs.iter().any(|(k, _)| k == "error")
    {
        return Err(AccountError::OAuth);
    }
    Ok(codes[0].1.to_string())
}
pub struct Authorization {
    state: String,
    verifier: String,
    nonce: String,
    pub url: String,
}
pub fn begin_authorization() -> Result<Authorization, AccountError> {
    let state = random_string()?;
    let verifier = random_string()?;
    let nonce = random_string()?;
    let mut url = reqwest::Url::parse("https://auth.openai.com/oauth/authorize")
        .map_err(|_| AccountError::OAuth)?;
    url.query_pairs_mut().extend_pairs([
        ("client_id", CLIENT_ID),
        ("redirect_uri", REDIRECT),
        ("response_type", "code"),
        ("scope", "openid profile email offline_access"),
        ("state", &state),
        ("nonce", &nonce),
        ("code_challenge", &challenge(&verifier)),
        ("code_challenge_method", "S256"),
        ("codex_cli_simplified_flow", "true"),
        ("id_token_add_organizations", "true"),
        ("originator", "codex_cli_rs"),
    ]);
    Ok(Authorization {
        state,
        verifier,
        nonce,
        url: url.into(),
    })
}
async fn exchange_code_at(
    context: &ProviderContext,
    authorization: Authorization,
    code: &str,
    endpoint: &str,
) -> Result<Credential, AccountError> {
    let tokens: Tokens = tokio::time::timeout(
        Duration::from_secs(30),
        http::json(
            context.http.post(endpoint).form(&[
                ("grant_type", "authorization_code"),
                ("client_id", CLIENT_ID),
                ("code", code),
                ("redirect_uri", REDIRECT),
                ("code_verifier", &authorization.verifier),
            ]),
            context.clock.now(),
        ),
    )
    .await
    .map_err(|_| AccountError::Cancelled)??;
    credential(
        tokens,
        Some(&authorization.nonce),
        None,
        context.clock.now().unix_timestamp(),
    )
}
async fn exchange_code(
    context: &ProviderContext,
    authorization: Authorization,
    code: &str,
) -> Result<Credential, AccountError> {
    exchange_code_at(context, authorization, code, TOKEN_URL).await
}
pub async fn exchange(
    context: &ProviderContext,
    authorization: Authorization,
    full_url: &str,
) -> Result<Credential, AccountError> {
    if full_url.is_empty() || full_url.len() > 8192 || full_url.chars().any(char::is_control) {
        return Err(AccountError::OAuth);
    }
    let callback = reqwest::Url::parse(full_url).map_err(|_| AccountError::OAuth)?;
    if callback.scheme() != "http"
        || callback.host_str() != Some("localhost")
        || callback.port() != Some(1455)
        || callback.path() != "/auth/callback"
        || !callback.username().is_empty()
        || callback.password().is_some()
        || callback.fragment().is_some()
    {
        return Err(AccountError::OAuth);
    }
    let target = match callback.query() {
        Some(query) => format!("/auth/callback?{query}"),
        None => return Err(AccountError::OAuth),
    };
    let code = callback_code(&target, &authorization.state)?;
    exchange_code(context, authorization, &code).await
}
#[derive(Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OAuthMode {
    Relay,
    Loopback,
}
#[derive(Clone, Copy, Serialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Waiting,
    Processing,
    Completed,
    Failed,
    Cancelled,
    Expired,
}
#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Workflow {
    BrowserCallback,
    ManualCode,
    DeviceCode,
}
#[derive(Clone, Serialize)]
pub struct SessionDto {
    pub provider: crate::cli::Provider,
    pub workflow: Workflow,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_code: Option<String>,
    pub id: String,
    pub url: String,
    pub expires_at: i64,
    pub status: SessionStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<&'static str>,
}
struct PendingSession {
    provider: crate::cli::Provider,
    workflow: Workflow,
    user_code: Option<String>,
    lifetime: Duration,
    authorization: Option<Authorization>,
    url: String,
    label: Option<String>,
    expires_at: i64,
    created: Instant,
    status: SessionStatus,
    account_id: Option<String>,
    error_code: Option<&'static str>,
    cancel: Arc<tokio::sync::Notify>,
}
struct BeginClaim {
    provider: crate::cli::Provider,
    label: Option<String>,
    mode: OAuthMode,
    host: Option<GitHubHost>,
    session_id: Option<String>,
}
struct Sessions {
    sessions: HashMap<String, PendingSession>,
    begins: HashMap<String, BeginClaim>,
}
#[derive(Clone)]
pub struct OAuthSessionManager {
    context: ProviderContext,
    vault: Vault,
    sessions: Arc<tokio::sync::Mutex<Sessions>>,
    commit_guard: Arc<tokio::sync::Mutex<()>>,
    generation: Arc<AtomicU64>,
}
impl OAuthSessionManager {
    pub fn new(
        context: ProviderContext,
        vault: Vault,
        commit_guard: Arc<tokio::sync::Mutex<()>>,
        generation: Arc<AtomicU64>,
    ) -> Self {
        Self {
            context,
            vault,
            sessions: Arc::new(tokio::sync::Mutex::new(Sessions {
                sessions: HashMap::new(),
                begins: HashMap::new(),
            })),
            commit_guard,
            generation,
        }
    }
    fn dto(id: String, session: &PendingSession) -> SessionDto {
        SessionDto {
            provider: session.provider,
            workflow: session.workflow,
            user_code: session.user_code.clone(),
            id,
            url: session.url.clone(),
            expires_at: session.expires_at,
            status: session.status,
            account_id: session.account_id.clone(),
            error_code: session.error_code,
        }
    }
    fn prune(sessions: &mut Sessions) {
        let now = Instant::now();
        for session in sessions.sessions.values_mut() {
            if session.status == SessionStatus::Waiting
                && now.duration_since(session.created) >= session.lifetime
            {
                session.status = SessionStatus::Expired;
                session.authorization = None;
                session.cancel.notify_one();
            }
        }
        sessions.sessions.retain(|_, session| {
            session.status == SessionStatus::Processing
                || now.duration_since(session.created)
                    <= session.lifetime + Duration::from_secs(720)
        });
        if sessions.sessions.len() > 128 {
            let mut ids: Vec<_> = sessions
                .sessions
                .iter()
                .filter(|(_, s)| {
                    s.status != SessionStatus::Waiting && s.status != SessionStatus::Processing
                })
                .map(|(id, s)| (id.clone(), s.created))
                .collect();
            ids.sort_by_key(|(_, created)| *created);
            for (id, _) in ids
                .into_iter()
                .take(sessions.sessions.len().saturating_sub(128))
            {
                sessions.sessions.remove(&id);
            }
        }
        sessions.begins.retain(|_, claim| {
            claim
                .session_id
                .as_ref()
                .is_none_or(|id| sessions.sessions.contains_key(id))
        });
    }
    /// A detached claim survives loss of the HTTP request, so a retry can recover
    /// the session instead of issuing a second provider device-code request.
    pub async fn begin_idempotent(
        &self,
        provider: crate::cli::Provider,
        label: Option<String>,
        mode: OAuthMode,
        key: String,
    ) -> Result<SessionDto, AccountError> {
        self.begin_idempotent_at(provider, label, mode, None, key)
            .await
    }
    /// `host` selects a GitHub Enterprise Cloud data-residency instance and is
    /// accepted only for Copilot. It is part of the retry intent.
    pub async fn begin_idempotent_at(
        &self,
        provider: crate::cli::Provider,
        label: Option<String>,
        mode: OAuthMode,
        host: Option<GitHubHost>,
        key: String,
    ) -> Result<SessionDto, AccountError> {
        Self::check_host(provider, &host)?;
        let endpoints =
            copilot::Endpoints::for_host(host.clone().unwrap_or_else(GitHubHost::github_com));
        self.begin_keyed(provider, label, mode, host, key, endpoints)
            .await
    }
    fn check_host(
        provider: crate::cli::Provider,
        host: &Option<GitHubHost>,
    ) -> Result<(), AccountError> {
        if host.is_some() && provider != crate::cli::Provider::Catalog("copilot") {
            return Err(AccountError::Unsupported);
        }
        Ok(())
    }
    async fn begin_keyed(
        &self,
        provider: crate::cli::Provider,
        label: Option<String>,
        mode: OAuthMode,
        host: Option<GitHubHost>,
        key: String,
        endpoints: copilot::Endpoints,
    ) -> Result<SessionDto, AccountError> {
        if let Some(label) = &label {
            super::validate_label(label)?;
        }
        let mut sessions = self.sessions.lock().await;
        Self::prune(&mut sessions);
        let Sessions {
            sessions: entries,
            begins,
        } = &mut *sessions;
        if let Some(claim) = begins.get(&key) {
            if claim.provider != provider
                || claim.label != label
                || claim.mode != mode
                || claim.host != host
            {
                return Err(AccountError::IdempotencyConflict);
            }
            return match &claim.session_id {
                Some(id) => Ok(Self::dto(
                    id.clone(),
                    entries.get(id).expect("retained session"),
                )),
                None => Err(AccountError::Busy),
            };
        }
        if begins.len() >= 128 || entries.len() >= 128 {
            return Err(AccountError::Busy);
        }
        begins.insert(
            key.clone(),
            BeginClaim {
                provider,
                label: label.clone(),
                mode,
                host,
                session_id: None,
            },
        );
        let manager = self.clone();
        let (send, receive) = tokio::sync::oneshot::channel();
        // Spawn while holding the claim lock: cancellation cannot strand a claim
        // between insertion and task creation. No lock is held over provider I/O.
        tokio::spawn(async move {
            let result = if provider == crate::cli::Provider::Catalog("copilot")
                && mode == OAuthMode::Relay
            {
                manager.begin_device(label, endpoints).await
            } else {
                manager.begin_at(provider, label, mode, None).await
            };
            let mut sessions = manager.sessions.lock().await;
            match &result {
                Ok(session) => {
                    sessions
                        .begins
                        .get_mut(&key)
                        .expect("begin claim")
                        .session_id = Some(session.id.clone())
                }
                Err(_) => {
                    sessions.begins.remove(&key);
                }
            }
            let _ = send.send(result);
        });
        drop(sessions);
        receive.await.map_err(|_| AccountError::Cancelled)?
    }
    pub async fn begin(
        &self,
        label: Option<String>,
        mode: OAuthMode,
    ) -> Result<SessionDto, AccountError> {
        self.begin_for(crate::cli::Provider::Codex, label, mode)
            .await
    }
    pub async fn begin_for(
        &self,
        provider: crate::cli::Provider,
        label: Option<String>,
        mode: OAuthMode,
    ) -> Result<SessionDto, AccountError> {
        self.begin_at(provider, label, mode, None).await
    }
    pub async fn begin_at(
        &self,
        provider: crate::cli::Provider,
        label: Option<String>,
        mode: OAuthMode,
        host: Option<GitHubHost>,
    ) -> Result<SessionDto, AccountError> {
        Self::check_host(provider, &host)?;
        if provider == crate::cli::Provider::Catalog("copilot") {
            if !matches!(mode, OAuthMode::Relay) {
                return Err(AccountError::Unsupported);
            }
            return self
                .begin_device(
                    label,
                    copilot::Endpoints::for_host(host.unwrap_or_else(GitHubHost::github_com)),
                )
                .await;
        }
        let workflow = match provider {
            crate::cli::Provider::Codex => Workflow::BrowserCallback,
            crate::cli::Provider::Catalog("claude") if matches!(mode, OAuthMode::Relay) => {
                Workflow::ManualCode
            }
            _ => return Err(AccountError::Unsupported),
        };
        if let Some(label) = &label {
            super::validate_label(label)?;
        }
        let listener = if matches!(mode, OAuthMode::Loopback) {
            Some(
                TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 1455))
                    .await
                    .map_err(|_| AccountError::CallbackPort)?,
            )
        } else {
            None
        };
        let authorization = if workflow == Workflow::ManualCode {
            claude::begin()?
        } else {
            begin_authorization()?
        };
        let id = random_string()?;
        let expires_at = self
            .context
            .clock
            .now()
            .unix_timestamp()
            .checked_add(180)
            .ok_or(AccountError::OAuth)?;
        let mut sessions = self.sessions.lock().await;
        Self::prune(&mut sessions);
        if sessions.sessions.len() >= 128 {
            return Err(AccountError::Busy);
        }
        let url = authorization.url.clone();
        sessions.sessions.insert(
            id.clone(),
            PendingSession {
                provider,
                workflow,
                user_code: None,
                lifetime: Duration::from_secs(180),
                authorization: Some(authorization),
                url,
                label,
                expires_at,
                created: Instant::now(),
                status: SessionStatus::Waiting,
                account_id: None,
                error_code: None,
                cancel: Arc::new(tokio::sync::Notify::new()),
            },
        );
        if let Some(listener) = listener {
            let state = sessions
                .sessions
                .get(&id)
                .expect("inserted")
                .authorization
                .as_ref()
                .expect("inserted")
                .state
                .clone();
            let manager = self.clone();
            let session_id = id.clone();
            tokio::spawn(async move {
                manager.wait_loopback(session_id, listener, state).await;
            });
        }
        Ok(Self::dto(
            id.clone(),
            sessions.sessions.get(&id).expect("inserted"),
        ))
    }
    async fn begin_device(
        &self,
        label: Option<String>,
        endpoints: copilot::Endpoints,
    ) -> Result<SessionDto, AccountError> {
        if let Some(label) = &label {
            super::validate_label(label)?;
        }
        {
            let mut sessions = self.sessions.lock().await;
            Self::prune(&mut sessions);
            if sessions.sessions.len() >= 128 {
                return Err(AccountError::Busy);
            }
        }
        let started = Instant::now();
        let device = tokio::time::timeout(
            Duration::from_secs(30),
            copilot::begin(&self.context, &endpoints),
        )
        .await
        .map_err(|_| AccountError::Cancelled)??;
        let lifetime = Duration::from_secs(device.expires_in);
        let remaining = lifetime
            .checked_sub(started.elapsed())
            .filter(|d| !d.is_zero())
            .ok_or(AccountError::Cancelled)?;
        let id = random_string()?;
        let expires_at = self
            .context
            .clock
            .now()
            .unix_timestamp()
            .checked_add(remaining.as_secs() as i64 + i64::from(remaining.subsec_nanos() != 0))
            .ok_or(AccountError::OAuth)?;
        let mut sessions = self.sessions.lock().await;
        Self::prune(&mut sessions);
        if sessions.sessions.len() >= 128 {
            return Err(AccountError::Busy);
        }
        let cancel = Arc::new(tokio::sync::Notify::new());
        let session = PendingSession {
            provider: crate::cli::Provider::Catalog("copilot"),
            workflow: Workflow::DeviceCode,
            user_code: Some(device.user_code),
            lifetime,
            authorization: None,
            url: device.verification_uri,
            label,
            expires_at,
            created: started,
            status: SessionStatus::Waiting,
            account_id: None,
            error_code: None,
            cancel: cancel.clone(),
        };
        let dto = Self::dto(id.clone(), &session);
        sessions.sessions.insert(id.clone(), session);
        let manager = self.clone();
        tokio::spawn(async move {
            manager
                .poll_device(
                    id,
                    device.device_code,
                    device.interval.max(5),
                    started + lifetime,
                    cancel,
                    endpoints,
                )
                .await;
        });
        Ok(dto)
    }
    async fn end_device(&self, id: &str, status: SessionStatus, error_code: Option<&'static str>) {
        let mut sessions = self.sessions.lock().await;
        if let Some(session) = sessions.sessions.get_mut(id)
            && session.status == SessionStatus::Waiting
        {
            session.status = status;
            session.error_code = error_code;
        }
    }
    async fn poll_device(
        &self,
        id: String,
        device_code: String,
        mut interval: u64,
        deadline: Instant,
        cancel: Arc<tokio::sync::Notify>,
        endpoints: copilot::Endpoints,
    ) {
        let result = tokio::select! {
            _ = cancel.notified() => return,
            _ = tokio::time::sleep_until(deadline) => { self.end_device(&id, SessionStatus::Expired, None).await; return; },
            result = async {
                loop {
                    tokio::time::sleep(Duration::from_secs(interval)).await;
                    if Instant::now() >= deadline { self.end_device(&id, SessionStatus::Expired, None).await; return Ok(None); }
                    let response = match tokio::time::timeout(Duration::from_secs(30), copilot::poll(&self.context, &endpoints.token, &device_code)).await {
                        Ok(Ok(response)) => response,
                        // RFC 8628 §3.5: reduce frequency after connection timeouts.
                        // Keep the original session deadline, including backoff waits.
                        Err(_) | Ok(Err(AccountError::Provider(crate::error::ProviderError::Timeout | crate::error::ProviderError::Transient))) => {
                            interval = interval.saturating_mul(2).min(3600);
                            continue;
                        }
                        Ok(Err(error)) => return Err(error),
                    };
                    match response {
                        copilot::Poll::Pending => (),
                        copilot::Poll::SlowDown => interval = interval.saturating_add(5),
                        copilot::Poll::Expired => { self.end_device(&id, SessionStatus::Expired, None).await; return Ok(None); },
                        copilot::Poll::Denied => { self.end_device(&id, SessionStatus::Cancelled, None).await; return Ok(None); },
                        copilot::Poll::Token(token) => return tokio::time::timeout(Duration::from_secs(30), copilot::credential(&self.context, &endpoints, token)).await.map_err(|_| AccountError::Cancelled)?.map(Some),
                    }
                }
            } => result,
        };
        let credential = match result {
            Ok(Some(credential)) => credential,
            Ok(None) => return,
            Err(error) => {
                self.end_device(&id, SessionStatus::Failed, Some(Self::failure_code(&error)))
                    .await;
                return;
            }
        };
        let label = {
            let mut sessions = self.sessions.lock().await;
            Self::prune(&mut sessions);
            let Some(session) = sessions.sessions.get_mut(&id) else {
                return;
            };
            if session.status != SessionStatus::Waiting {
                return;
            }
            session.status = SessionStatus::Processing;
            session.label.clone()
        };
        // Once claimed, persistence completes even if the polling client disconnects.
        let _ = self.finish(&id, Ok(credential), label).await;
    }
    pub async fn get(&self, id: &str) -> Result<SessionDto, AccountError> {
        let mut sessions = self.sessions.lock().await;
        Self::prune(&mut sessions);
        let session = sessions
            .sessions
            .get_mut(id)
            .ok_or(AccountError::NotFound)?;
        if session.status == SessionStatus::Waiting
            && Instant::now().duration_since(session.created) >= session.lifetime
        {
            session.status = SessionStatus::Expired;
        }
        Ok(Self::dto(id.into(), session))
    }
    pub async fn cancel(&self, id: &str) -> Result<SessionDto, AccountError> {
        let mut sessions = self.sessions.lock().await;
        Self::prune(&mut sessions);
        let session = sessions
            .sessions
            .get_mut(id)
            .ok_or(AccountError::NotFound)?;
        if session.status != SessionStatus::Waiting {
            return Err(AccountError::Busy);
        }
        session.status = SessionStatus::Cancelled;
        session.authorization = None;
        session.cancel.notify_one();
        Ok(Self::dto(id.into(), session))
    }
    async fn wait_loopback(&self, id: String, listener: TcpListener, state: String) {
        let cancel = {
            let sessions = self.sessions.lock().await;
            match sessions.sessions.get(&id) {
                Some(session) if session.status == SessionStatus::Waiting => session.cancel.clone(),
                _ => return,
            }
        };
        let result = tokio::select! { _ = cancel.notified() => Err(AccountError::Cancelled), result = tokio::time::timeout(Duration::from_secs(180), callback(listener, &state)) => result.map_err(|_| AccountError::Cancelled).and_then(|result| result) };
        match result {
            Ok(code) => {
                let _ = self.complete_code(&id, code).await;
            }
            Err(_) => {
                let mut sessions = self.sessions.lock().await;
                if let Some(session) = sessions.sessions.get_mut(&id)
                    && session.status == SessionStatus::Waiting
                {
                    session.status = SessionStatus::Expired;
                    session.authorization = None;
                }
            }
        }
    }
    async fn complete_code(&self, id: &str, code: String) -> Result<SessionDto, AccountError> {
        let (authorization, label) = self.claim(id).await?;
        self.finish(
            id,
            exchange_code(&self.context, authorization, &code).await,
            label,
        )
        .await
    }
    async fn claim(&self, id: &str) -> Result<(Authorization, Option<String>), AccountError> {
        let mut sessions = self.sessions.lock().await;
        Self::prune(&mut sessions);
        let session = sessions
            .sessions
            .get_mut(id)
            .ok_or(AccountError::NotFound)?;
        if session.status != SessionStatus::Waiting {
            return Err(AccountError::Busy);
        }
        session.status = SessionStatus::Processing;
        session.cancel.notify_one();
        Ok((
            session.authorization.take().ok_or(AccountError::Busy)?,
            session.label.clone(),
        ))
    }
    fn failure_code(error: &AccountError) -> &'static str {
        match error {
            AccountError::Storage => "credential_storage_unavailable",
            AccountError::CommitUncertain => "credential_commit_uncertain",
            AccountError::Busy => "account_busy",
            AccountError::Cancelled => "cancelled",
            AccountError::Provider(_) => "validation_failed",
            _ => "oauth_failed",
        }
    }
    async fn finish(
        &self,
        id: &str,
        credential: Result<Credential, AccountError>,
        label: Option<String>,
    ) -> Result<SessionDto, AccountError> {
        let provider = self.get(id).await?.provider;
        let result = async {
            let credential = credential?;
            let identity = if let Credential::CopilotOAuth { .. } = &credential {
                service::copilot_identity(&credential).expect("copilot credential")
            } else if let Credential::ClaudeOAuth { account_id, .. } = &credential {
                account_id.clone()
            } else {
                tokio::time::timeout(
                    Duration::from_secs(30),
                    service::validate(&self.context, provider, &credential),
                )
                .await
                .map_err(|_| AccountError::Cancelled)??
                .account
                .id
            };
            let label = service::default_label(label.as_deref(), &credential)?;
            let _guard = service::mutation_guard(&self.commit_guard).await?;
            let account_id =
                service::add(self.vault.clone(), provider, label, credential, identity).await?;
            self.generation.fetch_add(1, Ordering::SeqCst);
            Ok::<_, AccountError>(account_id)
        }
        .await;
        let mut sessions = self.sessions.lock().await;
        let session = sessions
            .sessions
            .get_mut(id)
            .ok_or(AccountError::NotFound)?;
        match result {
            Ok(account_id) => {
                session.status = SessionStatus::Completed;
                session.account_id = Some(account_id);
                Ok(Self::dto(id.into(), session))
            }
            Err(error) => {
                if matches!(error, AccountError::CommitUncertain) {
                    self.generation.fetch_add(1, Ordering::SeqCst);
                }
                session.status = SessionStatus::Failed;
                session.error_code = Some(Self::failure_code(&error));
                Err(error)
            }
        }
    }
    pub async fn manual_code(&self, id: &str, code: &str) -> Result<SessionDto, AccountError> {
        if self.get(id).await?.workflow != Workflow::ManualCode {
            return Err(AccountError::Unsupported);
        }
        let (authorization, label) = self.claim(id).await?;
        let result = tokio::time::timeout(
            Duration::from_secs(30),
            claude::exchange(&self.context, authorization, code),
        )
        .await
        .map_err(|_| AccountError::Cancelled)
        .and_then(|r| r);
        self.finish(id, result, label).await
    }
    pub async fn callback(&self, id: &str, full_url: &str) -> Result<SessionDto, AccountError> {
        if self.get(id).await?.workflow != Workflow::BrowserCallback {
            return Err(AccountError::Unsupported);
        }
        let (authorization, label) = self.claim(id).await?;
        self.finish(
            id,
            exchange(&self.context, authorization, full_url).await,
            label,
        )
        .await
    }
}
async fn callback(listener: TcpListener, state: &str) -> Result<String, AccountError> {
    loop {
        let (socket, peer) = listener.accept().await.map_err(|_| AccountError::OAuth)?;
        if !peer.ip().is_loopback() {
            continue;
        }
        let mut reader = BufReader::new(socket);
        let mut bytes = Vec::new();
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            (&mut reader).take(8193).read_until(b'\n', &mut bytes),
        )
        .await
        .map_err(|_| AccountError::OAuth)?
        .map_err(|_| AccountError::OAuth)?;
        if bytes.len() > 8192 {
            return Err(AccountError::OAuth);
        }
        let text = std::str::from_utf8(&bytes).map_err(|_| AccountError::OAuth)?;
        let fields: Vec<_> = text.split_whitespace().collect();
        if fields.len() != 3 || fields[0] != "GET" || !fields[1].starts_with("/auth/callback?") {
            let _ = reader
                .get_mut()
                .write_all(
                    b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await;
            continue;
        }
        let result = callback_code(fields[1], state);
        let body = if result.is_ok() {
            "Callback received. Return to Quotio."
        } else {
            "Login callback rejected. Return to Quotio."
        };
        let status = if result.is_ok() {
            "200 OK"
        } else {
            "400 Bad Request"
        };
        let _=reader.get_mut().write_all(format!("HTTP/1.1 {status}\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).as_bytes()).await;
        return result;
    }
}
pub async fn login(
    context: &ProviderContext,
    open_browser: bool,
) -> Result<Credential, AccountError> {
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 1455))
        .await
        .map_err(|_| AccountError::CallbackPort)?;
    let authorization = begin_authorization()?;
    eprintln!("Open this URL to sign in to Codex:\n{}", authorization.url);
    if open_browser {
        #[cfg(target_os = "macos")]
        {
            let _ = tokio::process::Command::new("/usr/bin/open")
                .arg(&authorization.url)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true)
                .status()
                .await;
        }
    }
    let code = callback(listener, &authorization.state).await?;
    exchange_code(context, authorization, &code).await
}
pub async fn refresh(
    context: &ProviderContext,
    previous: &Credential,
) -> Result<Credential, AccountError> {
    refresh_at(context, previous, TOKEN_URL).await
}
async fn refresh_at(
    context: &ProviderContext,
    previous: &Credential,
    endpoint: &str,
) -> Result<Credential, AccountError> {
    let Credential::CodexOAuth { refresh_token, .. } = previous else {
        return Err(AccountError::Unsupported);
    };
    let tokens: Tokens = http::json(
        context.http.post(endpoint).form(&[
            ("grant_type", "refresh_token"),
            ("client_id", CLIENT_ID),
            ("refresh_token", refresh_token),
        ]),
        context.clock.now(),
    )
    .await?;
    credential(
        tokens,
        None,
        Some(previous),
        context.clock.now().unix_timestamp(),
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn id_token(account: &str) -> String {
        format!("e30.{}.signature",URL_SAFE_NO_PAD.encode(json!({"iss":"https://auth.openai.com","aud":CLIENT_ID,"nonce":"nonce","exp":10000,"email":"demo@example.com","https://api.openai.com/auth":{"chatgpt_account_id":account}}).to_string()))
    }
    #[test]
    fn pkce_and_callback_security() {
        assert_eq!(
            challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
        assert_eq!(
            callback_code("/auth/callback?state=s&code=c", "s").unwrap(),
            "c"
        );
        for target in [
            "/auth/callback?state=bad&code=c",
            "/auth/callback?state=s&state=s&code=c",
            "/auth/callback?state=s&error=denied",
            "/other?state=s&code=c",
        ] {
            assert!(callback_code(target, "s").is_err());
        }
    }
    #[tokio::test]
    async fn refresh_rotates_tokens_and_rejects_account_changes() {
        let old = Credential::CodexOAuth {
            access_token: "old".into(),
            refresh_token: "old-refresh".into(),
            id_token: id_token("a"),
            account_id: "a".into(),
            email: "demo@example.com".into(),
            expires_at: 0,
        };
        for account in ["a", "different"] {
            let (url,task)=http::fixture::server(vec![json!({"access_token":"new","refresh_token":"rotated","id_token":id_token(account),"expires_in":3600})]).await;
            let result = refresh_at(&http::fixture::context(), &old, &url).await;
            assert_eq!(result.is_ok(), account == "a");
            if let Ok(Credential::CodexOAuth { refresh_token, .. }) = result {
                assert_eq!(refresh_token, "rotated");
            }
            let requests = task.await.unwrap();
            assert!(requests[0].contains("grant_type=refresh_token"));
            assert!(requests[0].contains("old-refresh"));
        }
    }
    #[tokio::test]
    async fn token_exchange_failure_is_offline_and_keeps_production_endpoint_fixed() {
        let context = http::fixture::context();
        let authorization = begin_authorization().unwrap();
        let nonce = authorization.nonce.clone();
        let token = format!("e30.{}.signature", URL_SAFE_NO_PAD.encode(json!({"iss":"https://auth.openai.com","aud":CLIENT_ID,"nonce":nonce,"exp":10000,"email":"demo@example.com","https://api.openai.com/auth":{"chatgpt_account_id":"account"}}).to_string()));
        let (url, task) = http::fixture::server(vec![json!({"access_token":"access","refresh_token":"refresh","id_token":token,"expires_in":3600})]).await;
        assert!(
            exchange_code_at(&context, authorization, "opaque-code", &url)
                .await
                .is_ok()
        );
        let requests = task.await.unwrap();
        assert!(requests[0].contains("grant_type=authorization_code"));
        assert!(requests[0].contains("code_verifier="));
        let (url, task) =
            http::fixture::server_status(vec![(500, json!({"error":"unavailable"}))]).await;
        assert!(
            exchange_code_at(
                &context,
                begin_authorization().unwrap(),
                "opaque-code",
                &url
            )
            .await
            .is_err()
        );
        let _ = task.await.unwrap();
        let (url, task) = http::fixture::server(vec![json!({"access_token":"access"})]).await;
        assert!(
            exchange_code_at(
                &context,
                begin_authorization().unwrap(),
                "opaque-code",
                &url
            )
            .await
            .is_err()
        );
        let _ = task.await.unwrap();
    }

    #[tokio::test]
    async fn callback_uses_loopback_and_rejects_wrong_state() {
        for state in ["expected", "wrong"] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let task = tokio::spawn(async move { callback(listener, "expected").await });
            let mut stream = tokio::net::TcpStream::connect(address).await.unwrap();
            stream.write_all(format!("GET /auth/callback?state={state}&code=synthetic-code HTTP/1.1\r\nHost: localhost\r\n\r\n").as_bytes()).await.unwrap();
            let mut response = String::new();
            stream.read_to_string(&mut response).await.unwrap();
            let result = task.await.unwrap();
            assert_eq!(result.is_ok(), state == "expected");
            assert!(!response.contains("synthetic-code"));
        }
    }
    #[test]
    fn login_requires_matching_nonce_and_identity() {
        let tokens = || Tokens {
            access_token: "access".into(),
            refresh_token: Some("refresh".into()),
            id_token: Some(id_token("account")),
            expires_in: 3600,
        };
        assert!(credential(tokens(), Some("nonce"), None, 0).is_ok());
        assert!(credential(tokens(), Some("different"), None, 0).is_err());
        assert!(credential(tokens(), Some("nonce"), None, 20000).is_err());
    }
}

#[cfg(test)]
mod session_tests {
    use super::*;
    use crate::accounts::vault::tests::Memory;

    fn manager() -> OAuthSessionManager {
        let path = std::env::temp_dir().join(format!(
            "quotio-oauth-session-{}.lock",
            random_string().unwrap()
        ));
        OAuthSessionManager::new(
            http::fixture::context(),
            Vault::new(Arc::new(Memory::default()), path),
            Arc::new(tokio::sync::Mutex::new(())),
            Arc::new(AtomicU64::new(0)),
        )
    }

    #[tokio::test]
    async fn loopback_binds_before_return_and_cancel_is_terminal() {
        let manager = manager();
        let first = manager.begin(None, OAuthMode::Loopback).await.unwrap();
        assert_eq!(first.status, SessionStatus::Waiting);
        assert!(matches!(
            manager.begin(None, OAuthMode::Loopback).await,
            Err(AccountError::CallbackPort)
        ));
        let cancelled = manager.cancel(&first.id).await.unwrap();
        assert_eq!(cancelled.status, SessionStatus::Cancelled);
        assert!(matches!(
            manager
                .callback(
                    &first.id,
                    "http://localhost:1455/auth/callback?state=x&code=y"
                )
                .await,
            Err(AccountError::Busy)
        ));
    }

    #[tokio::test]
    async fn expiry_is_inclusive_and_failed_sessions_expose_safe_code() {
        let manager = manager();
        let session = manager.begin(None, OAuthMode::Relay).await.unwrap();
        {
            let mut sessions = manager.sessions.lock().await;
            sessions.sessions.get_mut(&session.id).unwrap().created = Instant::now()
                .checked_sub(Duration::from_secs(180))
                .unwrap();
        }
        assert_eq!(
            manager.get(&session.id).await.unwrap().status,
            SessionStatus::Expired
        );
        let failed = manager.begin(None, OAuthMode::Relay).await.unwrap();
        assert!(
            manager
                .callback(
                    &failed.id,
                    "https://localhost:1455/auth/callback?state=x&code=y"
                )
                .await
                .is_err()
        );
        assert_eq!(
            manager.get(&failed.id).await.unwrap().error_code,
            Some("oauth_failed")
        );
    }

    #[tokio::test]
    async fn aged_processing_session_survives_pruning() {
        let manager = manager();
        let session = manager.begin(None, OAuthMode::Relay).await.unwrap();
        {
            let mut sessions = manager.sessions.lock().await;
            let pending = sessions.sessions.get_mut(&session.id).unwrap();
            pending.status = SessionStatus::Processing;
            pending.created = Instant::now()
                .checked_sub(Duration::from_secs(901))
                .unwrap();
            pending.authorization = None;
        }
        assert_eq!(
            manager.get(&session.id).await.unwrap().status,
            SessionStatus::Processing
        );
    }

    fn device_response(expires_in: u64) -> Value {
        serde_json::json!({"device_code":"private-device", "user_code":"PUBLIC-CODE", "verification_uri":"https://github.com/login/device", "expires_in":expires_in, "interval":5})
    }
    fn device_endpoints(url: &str) -> copilot::Endpoints {
        copilot::Endpoints {
            device: url.into(),
            token: url.into(),
            profile: url.into(),
            ..copilot::Endpoints::default()
        }
    }
    #[tokio::test]
    async fn enterprise_host_is_copilot_only_and_part_of_retry_intent() {
        let manager = manager();
        let host = GitHubHost::parse("octocorp.ghe.com").unwrap();
        assert!(matches!(
            manager
                .begin_at(
                    crate::cli::Provider::Codex,
                    None,
                    OAuthMode::Relay,
                    Some(host.clone())
                )
                .await,
            Err(AccountError::Unsupported)
        ));
        assert!(matches!(
            manager
                .begin_idempotent_at(
                    crate::cli::Provider::Catalog("claude"),
                    None,
                    OAuthMode::Relay,
                    Some(host.clone()),
                    "host".into()
                )
                .await,
            Err(AccountError::Unsupported)
        ));
        let (url, mut requests, server) = controlled_http().await;
        let worker = manager.clone();
        let endpoint = url.clone();
        let enterprise = host.clone();
        let request = tokio::spawn(async move {
            worker
                .begin_keyed(
                    crate::cli::Provider::Catalog("copilot"),
                    None,
                    OAuthMode::Relay,
                    Some(enterprise),
                    "host".into(),
                    device_endpoints(&endpoint),
                )
                .await
        });
        let (_, respond) = requests.recv().await.unwrap();
        for other in [None, Some(GitHubHost::parse("other.ghe.com").unwrap())] {
            assert!(matches!(
                manager
                    .begin_keyed(
                        crate::cli::Provider::Catalog("copilot"),
                        None,
                        OAuthMode::Relay,
                        other,
                        "host".into(),
                        device_endpoints(&url),
                    )
                    .await,
                Err(AccountError::IdempotencyConflict)
            ));
        }
        respond.send(device_response(900).to_string()).unwrap();
        let session = request.await.unwrap().unwrap();
        manager.cancel(&session.id).await.unwrap();
        server.abort();
    }
    #[tokio::test]
    async fn keyed_begin_recovers_lost_response_without_duplicate_device_request() {
        let manager = manager();
        let (url, mut requests, server) = controlled_http().await;
        let worker = manager.clone();
        let endpoint = url.clone();
        let request = tokio::spawn(async move {
            worker
                .begin_keyed(
                    crate::cli::Provider::Catalog("copilot"),
                    None,
                    OAuthMode::Relay,
                    None,
                    "recover".into(),
                    device_endpoints(&endpoint),
                )
                .await
        });
        let (_, respond) = requests.recv().await.unwrap();
        // Drop the HTTP caller while the provider request is still outstanding.
        request.abort();
        assert!(matches!(
            manager
                .begin_keyed(
                    crate::cli::Provider::Catalog("copilot"),
                    None,
                    OAuthMode::Relay,
                    None,
                    "recover".into(),
                    device_endpoints(&url)
                )
                .await,
            Err(AccountError::Busy)
        ));
        assert!(matches!(
            manager
                .begin_idempotent(
                    crate::cli::Provider::Codex,
                    None,
                    OAuthMode::Relay,
                    "recover".into()
                )
                .await,
            Err(AccountError::IdempotencyConflict)
        ));
        respond.send(device_response(900).to_string()).unwrap();
        let session = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                match manager
                    .begin_keyed(
                        crate::cli::Provider::Catalog("copilot"),
                        None,
                        OAuthMode::Relay,
                        None,
                        "recover".into(),
                        device_endpoints(&url),
                    )
                    .await
                {
                    Ok(session) => break session,
                    Err(AccountError::Busy) => tokio::task::yield_now().await,
                    _ => panic!("unexpected begin result"),
                }
            }
        })
        .await
        .unwrap();
        manager.cancel(&session.id).await.unwrap();
        let replay = manager
            .begin_keyed(
                crate::cli::Provider::Catalog("copilot"),
                None,
                OAuthMode::Relay,
                None,
                "recover".into(),
                device_endpoints(&url),
            )
            .await
            .unwrap();
        assert_eq!(replay.id, session.id);
        assert_eq!(replay.status, SessionStatus::Cancelled);
        assert_eq!(manager.sessions.lock().await.sessions.len(), 1);
        assert!(requests.try_recv().is_err());
        assert!(manager.vault.begin().unwrap().document.accounts.is_empty());
        server.abort();
    }

    #[tokio::test]
    async fn keyed_begin_checks_intent_and_expires_with_session() {
        let manager = manager();
        let provider = crate::cli::Provider::Codex;
        let first = manager
            .begin_idempotent(provider, None, OAuthMode::Relay, "key".into())
            .await
            .unwrap();
        assert!(matches!(
            manager
                .begin_idempotent(
                    provider,
                    Some("other".into()),
                    OAuthMode::Relay,
                    "key".into()
                )
                .await,
            Err(AccountError::IdempotencyConflict)
        ));
        assert!(matches!(
            manager
                .begin_idempotent(provider, None, OAuthMode::Loopback, "key".into())
                .await,
            Err(AccountError::IdempotencyConflict)
        ));
        manager.cancel(&first.id).await.unwrap();
        manager
            .sessions
            .lock()
            .await
            .sessions
            .get_mut(&first.id)
            .unwrap()
            .created = Instant::now() - Duration::from_secs(901);
        let next = manager
            .begin_idempotent(provider, None, OAuthMode::Relay, "key".into())
            .await
            .unwrap();
        assert_ne!(next.id, first.id);
        assert_eq!(manager.sessions.lock().await.begins.len(), 1);
    }

    #[tokio::test]
    async fn copilot_pending_slow_down_persists_only_after_identity() {
        let manager = manager();
        let (url, task) = http::fixture::server(vec![
            device_response(900),
            serde_json::json!({"error":"authorization_pending"}),
            serde_json::json!({"error":"slow_down"}),
            serde_json::json!({"access_token":"private-token"}),
            serde_json::json!({"login":"fixture-login", "id":42}),
        ])
        .await;
        let started = Instant::now();
        let session = manager
            .begin_device(None, device_endpoints(&url))
            .await
            .unwrap();
        assert_eq!(session.workflow, Workflow::DeviceCode);
        assert_eq!(session.user_code.as_deref(), Some("PUBLIC-CODE"));
        assert!(
            manager
                .manual_code(&session.id, "wrong-workflow")
                .await
                .is_err()
        );
        assert!(manager.vault.begin().unwrap().document.accounts.is_empty());
        let completed = tokio::time::timeout(Duration::from_secs(25), async {
            loop {
                let current = manager.get(&session.id).await.unwrap();
                if current.status != SessionStatus::Waiting
                    && current.status != SessionStatus::Processing
                {
                    break current;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(completed.status, SessionStatus::Completed);
        assert!(started.elapsed() >= Duration::from_secs(20));
        assert!(
            !serde_json::to_string(&completed)
                .unwrap()
                .contains("private-")
        );
        let tx = manager.vault.begin().unwrap();
        assert_eq!(tx.document.accounts.len(), 1);
        assert!(
            matches!(&tx.document.accounts[0].credential, Credential::CopilotOAuth { access_token, account_id, .. } if access_token == "private-token" && account_id == "42")
        );
        assert_eq!(
            tx.document.accounts[0].origin(),
            super::super::AccountOrigin::Owned
        );
        drop(tx);
        assert_eq!(task.await.unwrap().len(), 5);
    }
    #[tokio::test(start_paused = true)]
    async fn copilot_retries_timeout_and_transport_with_backoff_before_expiry() {
        let awake = tokio::spawn(async {
            loop {
                tokio::task::yield_now().await;
            }
        });
        for request_timeout in [None, Some(10)] {
            let mut manager = manager();
            if let Some(seconds) = request_timeout {
                manager.context.http = reqwest::Client::builder()
                    .no_proxy()
                    .redirect(reqwest::redirect::Policy::none())
                    .timeout(Duration::from_secs(seconds))
                    .build()
                    .unwrap();
            }
            let (url, mut requests, server) = controlled_http().await;
            let worker = manager.clone();
            let begin =
                tokio::spawn(
                    async move { worker.begin_device(None, device_endpoints(&url)).await },
                );
            let (_, response) = requests.recv().await.unwrap();
            response.send(device_response(900).to_string()).unwrap();
            let session = begin.await.unwrap().unwrap();
            let (pending_at, response) = next_http_request(&mut requests).await;
            response
                .send(serde_json::json!({"error":"authorization_pending"}).to_string())
                .unwrap();
            let (slow_at, response) = next_http_request(&mut requests).await;
            assert!(slow_at - pending_at >= Duration::from_secs(5));
            response
                .send(serde_json::json!({"error":"slow_down"}).to_string())
                .unwrap();
            let (timeout_at, held_response) = next_http_request(&mut requests).await;
            assert!(timeout_at - slow_at >= Duration::from_secs(10));
            // A real connection remains open but sends no headers or body.
            let (transport_at, response) = next_http_request(&mut requests).await;
            assert!(
                transport_at - timeout_at
                    >= Duration::from_secs(request_timeout.unwrap_or(30) + 20)
            );
            drop(held_response);
            assert_eq!(
                manager.get(&session.id).await.unwrap().status,
                SessionStatus::Waiting
            );
            // Closing the next socket without a response exercises reqwest transport errors.
            drop(response);
            let (token_at, response) = next_http_request(&mut requests).await;
            assert!(token_at - transport_at >= Duration::from_secs(40));
            response
                .send(serde_json::json!({"access_token":"private-token"}).to_string())
                .unwrap();
            let (_, response) = next_http_request(&mut requests).await;
            response
                .send(serde_json::json!({"login":"fixture-login", "id":42}).to_string())
                .unwrap();
            let completed = loop {
                let current = manager.get(&session.id).await.unwrap();
                if current.status == SessionStatus::Completed {
                    break current;
                }
                assert!(matches!(
                    current.status,
                    SessionStatus::Waiting | SessionStatus::Processing
                ));
                tokio::task::yield_now().await;
            };
            assert!(
                !serde_json::to_string(&completed)
                    .unwrap()
                    .contains("private-")
            );
            assert_eq!(manager.vault.begin().unwrap().document.accounts.len(), 1);
            server.abort();
        }
        awake.abort();
    }

    #[tokio::test(start_paused = true)]
    async fn copilot_retry_backoff_obeys_original_expiry_and_cancel() {
        let awake = tokio::spawn(async {
            loop {
                tokio::task::yield_now().await;
            }
        });
        for cancel in [false, true] {
            let manager = manager();
            let (url, mut requests, server) = controlled_http().await;
            let worker = manager.clone();
            let started = Instant::now();
            let begin =
                tokio::spawn(
                    async move { worker.begin_device(None, device_endpoints(&url)).await },
                );
            let (_, response) = requests.recv().await.unwrap();
            response.send(device_response(42).to_string()).unwrap();
            let session = begin.await.unwrap().unwrap();
            let (_, held_response) = next_http_request(&mut requests).await;
            tokio::time::advance(Duration::from_secs(30)).await;
            for _ in 0..100 {
                tokio::task::yield_now().await;
            }
            assert_eq!(
                manager.get(&session.id).await.unwrap().status,
                SessionStatus::Waiting
            );
            if cancel {
                manager.cancel(&session.id).await.unwrap();
            }
            tokio::time::advance(
                (started + Duration::from_secs(42)).saturating_duration_since(Instant::now()),
            )
            .await;
            for _ in 0..100 {
                tokio::task::yield_now().await;
            }
            let terminal = manager.get(&session.id).await.unwrap();
            assert_eq!(
                terminal.status,
                if cancel {
                    SessionStatus::Cancelled
                } else {
                    SessionStatus::Expired
                }
            );
            assert!(requests.try_recv().is_err());
            assert!(manager.vault.begin().unwrap().document.accounts.is_empty());
            assert!(
                !serde_json::to_string(&terminal)
                    .unwrap()
                    .contains("private-")
            );
            drop(held_response);
            server.abort();
        }
        awake.abort();
    }

    async fn next_http_request(
        requests: &mut tokio::sync::mpsc::UnboundedReceiver<(
            Instant,
            tokio::sync::oneshot::Sender<String>,
        )>,
    ) -> (Instant, tokio::sync::oneshot::Sender<String>) {
        for _ in 0..480 {
            // Give real socket I/O a turn without advancing the injected clock.
            for _ in 0..100 {
                tokio::task::yield_now().await;
            }
            if let Ok(request) = requests.try_recv() {
                return request;
            }
            tokio::time::advance(Duration::from_millis(250)).await;
        }
        panic!("expected loopback request within virtual polling budget");
    }
    #[tokio::test]
    async fn copilot_cancel_expiry_and_denial_never_persist() {
        for outcome in [
            "cancel",
            "expiry",
            "access_denied",
            "expired_token",
            "unknown-private-error",
        ] {
            let manager = manager();
            let mut responses = vec![device_response(if outcome == "expiry" { 1 } else { 900 })];
            if !matches!(outcome, "cancel" | "expiry") {
                responses.push(serde_json::json!({"error":outcome}));
            }
            let (url, task) = http::fixture::server(responses).await;
            let session = manager
                .begin_device(None, device_endpoints(&url))
                .await
                .unwrap();
            if outcome == "cancel" {
                manager.cancel(&session.id).await.unwrap();
            }
            let terminal = tokio::time::timeout(Duration::from_secs(8), async {
                loop {
                    let current = manager.get(&session.id).await.unwrap();
                    if current.status != SessionStatus::Waiting {
                        break current;
                    }
                    tokio::time::sleep(Duration::from_millis(20)).await;
                }
            })
            .await
            .unwrap();
            assert_eq!(
                terminal.status,
                match outcome {
                    "cancel" | "access_denied" => SessionStatus::Cancelled,
                    "expiry" | "expired_token" => SessionStatus::Expired,
                    _ => SessionStatus::Failed,
                }
            );
            assert!(
                !serde_json::to_string(&terminal)
                    .unwrap()
                    .contains("private-")
            );
            assert!(manager.vault.begin().unwrap().document.accounts.is_empty());
            task.await.unwrap();
        }
    }
    #[tokio::test]
    async fn claude_exchange_persists_identity_without_quota_or_token_responses() {
        let manager = manager();
        let session = manager
            .begin_for(
                crate::cli::Provider::Catalog("claude"),
                None,
                OAuthMode::Relay,
            )
            .await
            .unwrap();
        let (authorization, label) = manager.claim(&session.id).await.unwrap();
        let code = format!("private-code#{}", authorization.state);
        let (url, task) = http::fixture::server(vec![serde_json::json!({"access_token":"private-access", "refresh_token":"private-refresh", "expires_in":3600, "account":{"uuid":"fixture-id", "email_address":"demo@example.com"}})]).await;
        let credential = claude::exchange_at(&manager.context, authorization, &code, &url).await;
        let completed = manager
            .finish(&session.id, credential, label)
            .await
            .unwrap();
        assert_eq!(completed.status, SessionStatus::Completed);
        assert!(
            !serde_json::to_string(&completed)
                .unwrap()
                .contains("private-")
        );
        let tx = manager.vault.begin().unwrap();
        assert_eq!(tx.document.accounts[0].identity, "fixture-id");
        assert_eq!(tx.document.claude_refresh_owners.len(), 1);
        assert_eq!(tx.document.version, 6);
        drop(tx);
        assert_eq!(task.await.unwrap().len(), 1);
    }
    #[tokio::test(start_paused = true)]
    async fn claude_late_claim_survives_delayed_http_and_persistence() {
        // Keep virtual time under test control while real loopback I/O runs.
        let awake = tokio::spawn(async {
            loop {
                tokio::task::yield_now().await;
            }
        });
        let manager = manager();
        let session = manager
            .begin_for(
                crate::cli::Provider::Catalog("claude"),
                None,
                OAuthMode::Relay,
            )
            .await
            .unwrap();
        tokio::time::advance(Duration::from_secs(179)).await;
        let (authorization, label) = manager.claim(&session.id).await.unwrap();
        let code = format!("private-code#{}", authorization.state);
        let (url, mut requests, server) = controlled_http().await;
        let worker = manager.clone();
        let id = session.id.clone();
        let guard = manager.commit_guard.clone().lock_owned().await;
        let completion = tokio::spawn(async move {
            let credential = tokio::time::timeout(
                Duration::from_secs(30),
                claude::exchange_at(&worker.context, authorization, &code, &url),
            )
            .await
            .unwrap();
            worker.finish(&id, credential, label).await
        });
        let (_, response) = requests.recv().await.unwrap();
        tokio::time::advance(Duration::from_secs(20)).await;
        response.send(serde_json::json!({"access_token":"private-access", "refresh_token":"private-refresh", "expires_in":3600, "account":{"uuid":"fixture-id", "email_address":"demo@example.com"}}).to_string()).unwrap();
        assert_eq!(
            manager.get(&session.id).await.unwrap().status,
            SessionStatus::Processing
        );
        tokio::time::advance(Duration::from_secs(5)).await;
        assert!(!completion.is_finished());
        drop(guard);
        let completed = completion.await.unwrap().unwrap();
        assert_eq!(completed.status, SessionStatus::Completed);
        assert!(
            !serde_json::to_string(&completed)
                .unwrap()
                .contains("private-")
        );
        assert_eq!(manager.vault.begin().unwrap().document.accounts.len(), 1);
        server.abort();
        awake.abort();
    }

    // Each real HTTP request is acknowledged before the test advances virtual time.
    async fn controlled_http() -> (
        String,
        tokio::sync::mpsc::UnboundedReceiver<(Instant, tokio::sync::oneshot::Sender<String>)>,
        tokio::task::JoinHandle<()>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let task = tokio::spawn(async move {
            loop {
                let (socket, _) = listener.accept().await.unwrap();
                let tx = tx.clone();
                tokio::spawn(async move {
                    let mut reader = BufReader::new(socket);
                    let mut length = 0;
                    loop {
                        let mut line = String::new();
                        reader.read_line(&mut line).await.unwrap();
                        if line == "\r\n" {
                            break;
                        }
                        if let Some(value) =
                            line.to_ascii_lowercase().strip_prefix("content-length:")
                        {
                            length = value.trim().parse::<usize>().unwrap();
                        }
                    }
                    let mut body = vec![0; length];
                    reader.read_exact(&mut body).await.unwrap();
                    let (respond, response) = tokio::sync::oneshot::channel::<String>();
                    if tx.send((Instant::now(), respond)).is_err() {
                        return;
                    }
                    if let Ok(body) = response.await {
                        let response = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        );
                        let _ = reader.get_mut().write_all(response.as_bytes()).await;
                    }
                });
            }
        });
        (url, rx, task)
    }

    #[tokio::test]
    async fn claude_manual_workflow_is_typed_and_single_use() {
        let manager = manager();
        assert!(
            manager
                .begin_for(
                    crate::cli::Provider::Catalog("claude"),
                    None,
                    OAuthMode::Loopback
                )
                .await
                .is_err()
        );
        let session = manager
            .begin_for(
                crate::cli::Provider::Catalog("claude"),
                None,
                OAuthMode::Relay,
            )
            .await
            .unwrap();
        assert_eq!(session.workflow, Workflow::ManualCode);
        let json = serde_json::to_string(&session).unwrap();
        assert!(!json.contains("verifier"));
        assert!(
            manager
                .callback(&session.id, "http://localhost:1455/auth/callback?code=x")
                .await
                .is_err()
        );
        assert_eq!(
            manager.get(&session.id).await.unwrap().status,
            SessionStatus::Waiting
        );
        assert!(
            manager
                .manual_code(&session.id, "code#wrong-state")
                .await
                .is_err()
        );
        assert_eq!(
            manager.get(&session.id).await.unwrap().status,
            SessionStatus::Failed
        );
        assert!(matches!(
            manager.manual_code(&session.id, "code").await,
            Err(AccountError::Busy)
        ));
        let session = manager
            .begin_for(
                crate::cli::Provider::Catalog("claude"),
                None,
                OAuthMode::Relay,
            )
            .await
            .unwrap();
        manager.cancel(&session.id).await.unwrap();
        assert!(matches!(
            manager.manual_code(&session.id, "code").await,
            Err(AccountError::Busy)
        ));
    }
    #[tokio::test]
    async fn relay_sessions_are_bounded() {
        let manager = manager();
        for _ in 0..128 {
            manager.begin(None, OAuthMode::Relay).await.unwrap();
        }
        assert!(matches!(
            manager.begin(None, OAuthMode::Relay).await,
            Err(AccountError::Busy)
        ));
    }
}

#[cfg(test)]
mod callback_url_tests {
    use super::*;

    #[tokio::test]
    async fn exchange_rejects_noncanonical_callback_urls_before_network() {
        let context = http::fixture::context();
        for url in [
            "http://user@localhost:1455/auth/callback?state=s&code=c",
            "http://localhost:1455/auth/callback?state=s&code=c#fragment",
            "http://localhost:1455/auth/callback?state=s&code=c\n",
            &format!("http://localhost:1455/auth/callback?{}", "x".repeat(8192)),
        ] {
            assert!(
                exchange(&context, begin_authorization().unwrap(), url)
                    .await
                    .is_err()
            );
        }
    }
}
