//! Cookie-free subscription quota routes backed by existing native OAuth state.
//!
//! These adapters deliberately reuse an already-issued access token. Refreshing
//! another application's token can rotate its credential and leave that application
//! signed out, so an expired native token remains an authentication failure until its
//! owning client signs in again.

use super::{AuthKind, Definition, Setting, common};
use crate::{
    domain::{ProviderUsage, QuotaWindow},
    error::ProviderError,
    providers::{FetchFuture, ProviderContext, Secret, http},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    io::Read,
    path::{Path, PathBuf},
    time::Duration,
};
use time::OffsetDateTime;

const CLAUDE_TOKEN_ENV: &str = "CLAUDE_OAUTH_ACCESS_TOKEN";
const GEMINI_TOKEN_ENV: &str = "GEMINI_OAUTH_ACCESS_TOKEN";
const COPILOT_TOKEN_ENV: &str = "COPILOT_API_TOKEN";

const CLAUDE_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const GEMINI_LOAD_CODE_ASSIST_URL: &str =
    "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist";
const GEMINI_QUOTA_URL: &str = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota";
const COPILOT_USAGE_URL: &str = "https://api.github.com/copilot_internal/user";

const MAX_NATIVE_FILE_BYTES: usize = 1024 * 1024;
const MAX_TOKEN_BYTES: usize = 16 * 1024;
const MAX_LABEL_BYTES: usize = 128;
const NATIVE_READ_TIMEOUT: Duration = Duration::from_secs(2);

const GEMINI_SETTINGS: &[Setting] = &[Setting {
    name: "project",
    env: "GEMINI_PROJECT",
    required: false,
}];

pub const DEFINITIONS: &[Definition] = &[
    Definition {
        id: "claude",
        name: "Claude",
        key_env: CLAUDE_TOKEN_ENV,
        auth: AuthKind::OAuth,
        settings: &[],
        fetch: fetch_claude,
    },
    Definition {
        id: "gemini",
        name: "Gemini",
        key_env: GEMINI_TOKEN_ENV,
        auth: AuthKind::OAuth,
        settings: GEMINI_SETTINGS,
        fetch: fetch_gemini,
    },
    Definition {
        id: "copilot",
        name: "GitHub Copilot",
        key_env: COPILOT_TOKEN_ENV,
        auth: AuthKind::OAuth,
        settings: &[],
        fetch: fetch_copilot,
    },
];

fn fetch_claude(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(fetch_claude_at(context, CLAUDE_USAGE_URL))
}

fn fetch_gemini(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(fetch_gemini_at(
        context,
        GEMINI_LOAD_CODE_ASSIST_URL,
        GEMINI_QUOTA_URL,
    ))
}

/// Set only from a saved Quotio Copilot OAuth credential; see `accounts::service`.
pub(crate) const COPILOT_HOST_ENV: &str = "QUOTIO_COPILOT_HOST";

fn fetch_copilot(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(async move {
        match copilot_usage_url(context)? {
            Some(endpoint) => fetch_copilot_at(context, &endpoint).await,
            None => fetch_copilot_at(context, COPILOT_USAGE_URL).await,
        }
    })
}

/// Enterprise quota uses the API host of the instance that issued the token. The
/// host is revalidated so a malformed stored value can never redirect the token.
fn copilot_usage_url(context: &ProviderContext) -> Result<Option<String>, ProviderError> {
    let Some(raw) = context.credentials.get(COPILOT_HOST_ENV) else {
        return Ok(None);
    };
    // Never send a native GitHub.com token discovered on disk to another host.
    if context.credentials.get(COPILOT_TOKEN_ENV).is_none() {
        return Err(ProviderError::Authentication);
    }
    let host = crate::accounts::github_host::GitHubHost::parse(&raw.0)
        .map_err(|_| ProviderError::Authentication)?;
    Ok((!host.is_github_com()).then(|| host.api_url("/copilot_internal/user")))
}

/// An explicit Quotio token always wins over native application state. This avoids
/// silently changing which GitHub or Claude account is queried.
fn explicit_key(context: &ProviderContext, env: &str) -> Result<Option<Secret>, ProviderError> {
    if context.credentials.get(env).is_some() {
        common::key(context, env).map(Some)
    } else {
        Ok(None)
    }
}

fn token(raw: &str) -> Result<Option<Secret>, ProviderError> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Ok(None);
    }
    if raw.len() > MAX_TOKEN_BYTES || raw.chars().any(char::is_control) {
        return Err(ProviderError::Authentication);
    }
    Ok(Some(Secret(raw.into())))
}

fn json_payload(bytes: &[u8]) -> Result<Value, ProviderError> {
    if bytes.len() > MAX_NATIVE_FILE_BYTES {
        return Err(ProviderError::Authentication);
    }
    let raw = std::str::from_utf8(bytes)
        .map_err(|_| ProviderError::Authentication)?
        .trim();
    let decoded;
    let input = if let Some(encoded) = raw.strip_prefix("go-keyring-base64:") {
        decoded = STANDARD
            .decode(encoded.trim())
            .map_err(|_| ProviderError::Authentication)?;
        if decoded.len() > MAX_NATIVE_FILE_BYTES {
            return Err(ProviderError::Authentication);
        }
        decoded.as_slice()
    } else {
        raw.as_bytes()
    };
    serde_json::from_slice(input).map_err(|_| ProviderError::Authentication)
}

/// Read fixed native-client files only. Both metadata checks and the capped read
/// make a symlink/replacement race fail closed without following it.
fn read_regular_file(path: &Path) -> Result<Option<Vec<u8>>, ProviderError> {
    let before = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(ProviderError::Authentication),
    };
    if !before.is_file()
        || before.file_type().is_symlink()
        || before.len() > MAX_NATIVE_FILE_BYTES as u64
    {
        return Err(ProviderError::Authentication);
    }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC);
    }
    let file = options
        .open(path)
        .map_err(|_| ProviderError::Authentication)?;
    let opened = file.metadata().map_err(|_| ProviderError::Authentication)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if before.dev() != opened.dev() || before.ino() != opened.ino() {
            return Err(ProviderError::Authentication);
        }
    }
    if !opened.is_file() || opened.len() > MAX_NATIVE_FILE_BYTES as u64 {
        return Err(ProviderError::Authentication);
    }
    let mut bytes = Vec::new();
    file.take((MAX_NATIVE_FILE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| ProviderError::Authentication)?;
    if bytes.len() > MAX_NATIVE_FILE_BYTES {
        return Err(ProviderError::Authentication);
    }
    Ok(Some(bytes))
}

pub(crate) async fn native_file(path: PathBuf) -> Result<Option<Vec<u8>>, ProviderError> {
    match tokio::time::timeout(
        NATIVE_READ_TIMEOUT,
        tokio::task::spawn_blocking(move || read_regular_file(&path)),
    )
    .await
    {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err(ProviderError::Internal),
        Err(_) => Err(ProviderError::CredentialStorage),
    }
}

pub(crate) async fn native_keychain(
    service: &'static str,
    account: Option<&str>,
) -> Result<Option<Vec<u8>>, ProviderError> {
    let account = account.map(str::to_owned);
    match tokio::time::timeout(
        NATIVE_READ_TIMEOUT,
        tokio::task::spawn_blocking(move || common::read_keychain(service, account.as_deref())),
    )
    .await
    {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err(ProviderError::Internal),
        Err(_) => Err(ProviderError::CredentialStorage),
    }
}

fn home_dir() -> Option<PathBuf> {
    directories::BaseDirs::new().map(|dirs| dirs.home_dir().to_path_buf())
}

fn retain_native_error(last: &mut ProviderError, error: ProviderError) {
    if !matches!(
        error,
        ProviderError::Authentication | ProviderError::Unavailable
    ) {
        *last = error;
    }
}

// Claude ---------------------------------------------------------------------

fn claude_token_from_bytes(bytes: &[u8]) -> Result<Option<Secret>, ProviderError> {
    let value = json_payload(bytes)?;
    let Some(oauth) = value.get("claudeAiOauth") else {
        return Ok(None);
    };
    let oauth = oauth.as_object().ok_or(ProviderError::Authentication)?;
    if let Some(scopes) = oauth.get("scopes") {
        let scopes = scopes.as_array().ok_or(ProviderError::Authentication)?;
        if !scopes.is_empty()
            && !scopes
                .iter()
                .any(|scope| scope.as_str() == Some("user:profile"))
        {
            // Claude setup tokens are intentionally inference-only.
            return Ok(None);
        }
    }
    match oauth.get("accessToken") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => token(value),
        Some(_) => Err(ProviderError::Authentication),
    }
}

pub(crate) async fn claude_reference_token(path: Option<PathBuf>) -> Result<Secret, ProviderError> {
    let bytes = match path {
        Some(path) => native_file(path).await?,
        None => native_keychain("Claude Code-credentials", None).await?,
    }
    .ok_or(ProviderError::Authentication)?;
    claude_token_from_bytes(&bytes)?.ok_or(ProviderError::Authentication)
}

async fn native_claude_token() -> Result<Secret, ProviderError> {
    let mut last = ProviderError::Authentication;
    match native_keychain("Claude Code-credentials", None).await {
        Ok(Some(bytes)) => match claude_token_from_bytes(&bytes) {
            Ok(Some(value)) => return Ok(value),
            Ok(None) => (),
            Err(error) => retain_native_error(&mut last, error),
        },
        Ok(None) => (),
        Err(error) => retain_native_error(&mut last, error),
    }
    if let Some(path) = home_dir().map(|home| home.join(".claude/.credentials.json")) {
        match native_file(path).await {
            Ok(Some(bytes)) => match claude_token_from_bytes(&bytes) {
                Ok(Some(value)) => return Ok(value),
                Ok(None) => (),
                Err(error) => retain_native_error(&mut last, error),
            },
            Ok(None) => (),
            Err(error) => retain_native_error(&mut last, error),
        }
    }
    Err(last)
}

async fn claude_token(context: &ProviderContext) -> Result<Secret, ProviderError> {
    match explicit_key(context, CLAUDE_TOKEN_ENV)? {
        Some(value) => Ok(value),
        None => native_claude_token().await,
    }
}

fn clean_label(value: &str) -> Result<String, ProviderError> {
    let value = value.trim();
    if value.is_empty() || value.len() > MAX_LABEL_BYTES || value.chars().any(char::is_control) {
        return Err(ProviderError::InvalidData);
    }
    Ok(value.into())
}

fn claude_window(
    value: &Value,
    label: &str,
    now: OffsetDateTime,
) -> Result<Option<QuotaWindow>, ProviderError> {
    if value.is_null() {
        return Ok(None);
    }
    let object = value.as_object().ok_or(ProviderError::InvalidData)?;
    let Some(used) = common::number(object.get("utilization"))? else {
        return Ok(None);
    };
    if used > 100.0 {
        return Err(ProviderError::InvalidData);
    }
    Ok(Some(common::window(
        label,
        Some(used),
        Some(100.0),
        None,
        "percent",
        common::date(object.get("resets_at"))?,
        "claude_oauth_usage",
        now,
    )?))
}

fn claude_windows(value: &Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    let object = value.as_object().ok_or(ProviderError::InvalidData)?;
    let mut windows = Vec::new();
    for (key, label) in [
        ("five_hour", "Session"),
        ("seven_day", "Weekly"),
        ("seven_day_oauth_apps", "OAuth apps weekly"),
        ("seven_day_opus", "Opus weekly"),
        ("seven_day_sonnet", "Sonnet weekly"),
    ] {
        if let Some(value) = object.get(key)
            && let Some(window) = claude_window(value, label, now)?
        {
            windows.push(window);
        }
    }
    for key in [
        "seven_day_routines",
        "seven_day_claude_routines",
        "claude_routines",
        "routines",
        "routine",
        "seven_day_cowork",
        "cowork",
    ] {
        if let Some(value) = object.get(key) {
            if let Some(window) = claude_window(value, "Routines weekly", now)? {
                windows.push(window);
            }
            break;
        }
    }
    if let Some(limits) = object.get("limits") {
        let limits = limits.as_array().ok_or(ProviderError::InvalidData)?;
        for limit in limits {
            let limit = limit.as_object().ok_or(ProviderError::InvalidData)?;
            if limit.get("kind").and_then(Value::as_str) != Some("weekly_scoped")
                || limit.get("is_active").and_then(Value::as_bool) == Some(false)
            {
                continue;
            }
            let Some(model) = limit
                .get("scope")
                .and_then(Value::as_object)
                .and_then(|scope| scope.get("model"))
                .and_then(Value::as_object)
                .and_then(|model| model.get("display_name"))
                .and_then(Value::as_str)
            else {
                continue;
            };
            let Some(used) = common::number(limit.get("percent"))? else {
                continue;
            };
            if used > 100.0 {
                return Err(ProviderError::InvalidData);
            }
            windows.push(common::window(
                &format!("{} weekly", clean_label(model)?),
                Some(used),
                Some(100.0),
                None,
                "percent",
                common::date(limit.get("resets_at"))?,
                "claude_oauth_usage",
                now,
            )?);
        }
    }
    if windows.is_empty() {
        return Err(ProviderError::QuotaUnavailable);
    }
    Ok(windows)
}

pub(crate) async fn fetch_claude_at(
    context: &ProviderContext,
    endpoint: &str,
) -> Result<ProviderUsage, ProviderError> {
    let token = claude_token(context).await?;
    let now = context.clock.now();
    let response: Value = common::json(
        context
            .http
            .get(endpoint)
            .header(
                "Authorization",
                http::sensitive(&format!("Bearer {}", token.0))?,
            )
            .header("Accept", "application/json")
            .header("anthropic-beta", "oauth-2025-04-20")
            .header("User-Agent", "claude-code/2.1.0"),
        now,
    )
    .await?;
    let mut usage = common::usage(
        "claude",
        &token,
        "subscription-oauth",
        claude_windows(&response, now)?,
    )?;
    usage.account.label = "Claude OAuth token".into();
    Ok(usage)
}

// Gemini ---------------------------------------------------------------------

fn gemini_token_from_bytes(
    bytes: &[u8],
    now: OffsetDateTime,
) -> Result<Option<Secret>, ProviderError> {
    let value = json_payload(bytes)?;
    let object = value.as_object().ok_or(ProviderError::Authentication)?;
    let Some(Value::String(value)) = object.get("access_token") else {
        return Ok(None);
    };
    if let Some(expiry) = common::number(object.get("expiry_date"))? {
        if expiry.fract() != 0.0 || expiry > i64::MAX as f64 {
            return Err(ProviderError::Authentication);
        }
        let seconds = if expiry >= 100_000_000_000.0 {
            expiry / 1000.0
        } else {
            expiry
        };
        let expiry = OffsetDateTime::from_unix_timestamp(seconds as i64)
            .map_err(|_| ProviderError::Authentication)?;
        if expiry <= now + time::Duration::seconds(60) {
            // Never use the native refresh_token; Gemini CLI owns rotation.
            return Ok(None);
        }
    }
    token(value)
}

async fn native_gemini_token(now: OffsetDateTime) -> Result<Secret, ProviderError> {
    let Some(path) = home_dir().map(|home| home.join(".gemini/oauth_creds.json")) else {
        return Err(ProviderError::Authentication);
    };
    native_file(path)
        .await?
        .map(|bytes| gemini_token_from_bytes(&bytes, now))
        .transpose()?
        .flatten()
        .ok_or(ProviderError::Authentication)
}

async fn gemini_token(context: &ProviderContext) -> Result<Secret, ProviderError> {
    match explicit_key(context, GEMINI_TOKEN_ENV)? {
        Some(value) => Ok(value),
        None => native_gemini_token(context.clock.now()).await,
    }
}

fn gemini_project(context: &ProviderContext) -> Result<Option<String>, ProviderError> {
    let Some(value) = context.credentials.get("GEMINI_PROJECT") else {
        return Ok(None);
    };
    let value = value.0.trim();
    if value.is_empty() {
        return Ok(None);
    }
    if value.len() > 64
        || value.chars().any(char::is_control)
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(ProviderError::InvalidData);
    }
    Ok(Some(value.into()))
}

fn project_from_code_assist(value: &Value) -> Option<String> {
    let value = value
        .get("cloudaicompanionProject")
        .or_else(|| value.get("cloudAiCompanionProject"))?;
    let project = match value {
        Value::String(value) => value.as_str(),
        Value::Object(value) => value.get("id")?.as_str()?,
        _ => return None,
    };
    if project.is_empty()
        || project.len() > 64
        || !project
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return None;
    }
    Some(project.into())
}

async fn resolve_gemini_project(
    context: &ProviderContext,
    token: &Secret,
    endpoint: &str,
    now: OffsetDateTime,
) -> Result<Option<String>, ProviderError> {
    if let Some(project) = gemini_project(context)? {
        return Ok(Some(project));
    }
    let response: Result<Value, ProviderError> = common::json(
        context
            .http
            .post(endpoint)
            .header(
                "Authorization",
                http::sensitive(&format!("Bearer {}", token.0))?,
            )
            .json(&json!({"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}})),
        now,
    )
    .await;
    match response {
        Ok(value) => Ok(project_from_code_assist(&value)),
        // This selector is not quota evidence. The fixed quota endpoint below
        // determines whether the token actually has access to a quota lane.
        Err(
            ProviderError::Transient
            | ProviderError::Timeout
            | ProviderError::Unavailable
            | ProviderError::InvalidData,
        ) => Ok(None),
        Err(error) => Err(error),
    }
}

fn gemini_windows(value: &Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    let buckets = value
        .get("buckets")
        .and_then(Value::as_array)
        .ok_or(ProviderError::QuotaUnavailable)?;
    let mut models: BTreeMap<String, (f64, Option<OffsetDateTime>)> = BTreeMap::new();
    for bucket in buckets {
        let bucket = bucket.as_object().ok_or(ProviderError::InvalidData)?;
        let Some(model) = bucket.get("modelId").and_then(Value::as_str) else {
            continue;
        };
        let Some(remaining) = common::number(bucket.get("remainingFraction"))? else {
            continue;
        };
        if remaining > 1.0 {
            return Err(ProviderError::InvalidData);
        }
        let reset = common::date(bucket.get("resetTime"))?;
        let model = clean_label(model)?;
        match models.get(&model) {
            Some((current, _)) if *current <= remaining => (),
            _ => {
                models.insert(model, (remaining, reset));
            }
        }
    }
    if models.is_empty() {
        return Err(ProviderError::QuotaUnavailable);
    }
    models
        .into_iter()
        .map(|(model, (remaining, resets_at))| {
            common::window(
                &model,
                Some((1.0 - remaining) * 100.0),
                Some(100.0),
                Some(remaining * 100.0),
                "percent",
                resets_at,
                "gemini_cli_oauth_quota",
                now,
            )
        })
        .collect()
}

async fn fetch_gemini_at(
    context: &ProviderContext,
    load_code_assist_url: &str,
    quota_url: &str,
) -> Result<ProviderUsage, ProviderError> {
    let token = gemini_token(context).await?;
    let now = context.clock.now();
    let body = resolve_gemini_project(context, &token, load_code_assist_url, now)
        .await?
        .map(|project| json!({"project": project}))
        .unwrap_or_else(|| json!({}));
    let response: Value = common::json(
        context
            .http
            .post(quota_url)
            .header(
                "Authorization",
                http::sensitive(&format!("Bearer {}", token.0))?,
            )
            .json(&body),
        now,
    )
    .await?;
    let mut usage = common::usage(
        "gemini",
        &token,
        "google-oauth",
        gemini_windows(&response, now)?,
    )?;
    usage.account.label = "Gemini OAuth token".into();
    Ok(usage)
}

// GitHub Copilot -------------------------------------------------------------

fn copilot_editor_token(bytes: &[u8]) -> Result<Option<Secret>, ProviderError> {
    let value = json_payload(bytes)?;
    let object = value.as_object().ok_or(ProviderError::Authentication)?;
    let mut keys: Vec<_> = object
        .keys()
        .filter(|key| *key == "github.com" || key.starts_with("github.com:"))
        .collect();
    keys.sort_unstable();
    for key in keys {
        let Some(value) = object
            .get(key)
            .and_then(Value::as_object)
            .and_then(|entry| entry.get("oauth_token"))
            .and_then(Value::as_str)
        else {
            continue;
        };
        if let Some(value) = token(value)? {
            return Ok(Some(value));
        }
    }
    Ok(None)
}

struct CopilotGhHost<'a> {
    oauth_token: Option<&'a str>,
}

fn copilot_gh_host(bytes: &[u8]) -> Result<Option<CopilotGhHost<'_>>, ProviderError> {
    let text = std::str::from_utf8(bytes).map_err(|_| ProviderError::Authentication)?;
    let mut in_github = false;
    let mut found = false;
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if !line.as_bytes().first().is_some_and(u8::is_ascii_whitespace) {
            in_github = trimmed == "github.com:";
            found |= in_github;
            continue;
        }
        if !in_github {
            continue;
        }
        let Some(value) = trimmed.strip_prefix("oauth_token:") else {
            continue;
        };
        return Ok(Some(CopilotGhHost {
            oauth_token: Some(value.trim().trim_matches(['\'', '"'])),
        }));
    }
    Ok(found.then_some(CopilotGhHost { oauth_token: None }))
}

pub(crate) fn copilot_gh_host_present(bytes: &[u8]) -> Result<bool, ProviderError> {
    Ok(copilot_gh_host(bytes)?.is_some())
}

fn copilot_gh_token(bytes: &[u8]) -> Result<Option<Secret>, ProviderError> {
    copilot_gh_host(bytes)?
        .and_then(|host| host.oauth_token)
        .map_or(Ok(None), token)
}

fn copilot_keychain_token(bytes: &[u8]) -> Result<Option<Secret>, ProviderError> {
    let raw = std::str::from_utf8(bytes)
        .map_err(|_| ProviderError::Authentication)?
        .trim();
    let decoded;
    let value = if let Some(encoded) = raw.strip_prefix("go-keyring-base64:") {
        decoded = STANDARD
            .decode(encoded.trim())
            .map_err(|_| ProviderError::Authentication)?;
        std::str::from_utf8(&decoded).map_err(|_| ProviderError::Authentication)?
    } else {
        raw
    };
    token(value)
}

pub(crate) async fn copilot_reference_token(
    path: Option<PathBuf>,
    entry: &str,
) -> Result<Secret, ProviderError> {
    match path {
        Some(path) => {
            let bytes = native_file(path)
                .await?
                .ok_or(ProviderError::Authentication)?;
            let value = json_payload(&bytes)?;
            let raw = value
                .as_object()
                .and_then(|object| object.get(entry))
                .and_then(|entry| entry.get("oauth_token"))
                .and_then(Value::as_str)
                .ok_or(ProviderError::Authentication)?;
            token(raw)?.ok_or(ProviderError::Authentication)
        }
        None => {
            let bytes = native_keychain("gh:github.com", Some(entry))
                .await?
                .ok_or(ProviderError::Authentication)?;
            copilot_keychain_token(&bytes)?.ok_or(ProviderError::Authentication)
        }
    }
}

pub(crate) async fn copilot_gh_hosts_reference_token(
    path: PathBuf,
    entry: &str,
) -> Result<Secret, ProviderError> {
    if entry != "github.com" {
        return Err(ProviderError::Authentication);
    }
    let bytes = native_file(path)
        .await?
        .ok_or(ProviderError::Authentication)?;
    copilot_gh_token(&bytes)?.ok_or(ProviderError::Authentication)
}

async fn native_copilot_token() -> Result<Secret, ProviderError> {
    let mut last = ProviderError::Authentication;
    if let Some(home) = home_dir() {
        for path in [
            home.join(".config/github-copilot/apps.json"),
            home.join(".config/github-copilot/hosts.json"),
        ] {
            match native_file(path).await {
                Ok(Some(bytes)) => match copilot_editor_token(&bytes) {
                    Ok(Some(value)) => return Ok(value),
                    Ok(None) => (),
                    Err(error) => retain_native_error(&mut last, error),
                },
                Ok(None) => (),
                Err(error) => retain_native_error(&mut last, error),
            }
        }
        match native_file(home.join(".config/gh/hosts.yml")).await {
            Ok(Some(bytes)) => match copilot_gh_token(&bytes) {
                Ok(Some(value)) => return Ok(value),
                Ok(None) => (),
                Err(error) => retain_native_error(&mut last, error),
            },
            Ok(None) => (),
            Err(error) => retain_native_error(&mut last, error),
        }
    }
    match native_keychain("gh:github.com", None).await {
        Ok(Some(bytes)) => match copilot_keychain_token(&bytes) {
            Ok(Some(value)) => return Ok(value),
            Ok(None) => (),
            Err(error) => retain_native_error(&mut last, error),
        },
        Ok(None) => (),
        Err(error) => retain_native_error(&mut last, error),
    }
    Err(last)
}

async fn copilot_token(context: &ProviderContext) -> Result<Secret, ProviderError> {
    match explicit_key(context, COPILOT_TOKEN_ENV)? {
        Some(value) => Ok(value),
        None => native_copilot_token().await,
    }
}

#[derive(Clone)]
struct Reset {
    at: Option<OffsetDateTime>,
    description: Option<String>,
}

fn date_only(value: &str) -> bool {
    if value.len() != 10 {
        return false;
    }
    let bytes = value.as_bytes();
    bytes[4] == b'-'
        && bytes[7] == b'-'
        && bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| matches!(index, 4 | 7) || byte.is_ascii_digit())
        && OffsetDateTime::parse(
            &format!("{value}T00:00:00Z"),
            &time::format_description::well_known::Rfc3339,
        )
        .is_ok()
}

fn copilot_reset(value: Option<&Value>) -> Result<Reset, ProviderError> {
    match value {
        None | Some(Value::Null) => Ok(Reset {
            at: None,
            description: None,
        }),
        Some(Value::String(value)) if value.trim().is_empty() => Ok(Reset {
            at: None,
            description: None,
        }),
        Some(Value::String(value)) if date_only(value.trim()) => Ok(Reset {
            at: None,
            description: Some(value.trim().into()),
        }),
        value => Ok(Reset {
            at: common::date(value)?,
            description: None,
        }),
    }
}

fn with_reset(mut window: QuotaWindow, reset: &Reset) -> QuotaWindow {
    if window.resets_at.is_none() {
        window.reset_description = reset.description.clone();
    }
    window
}

fn unlimited(value: Option<&Value>) -> bool {
    value.and_then(Value::as_bool) == Some(true)
        || matches!(value, Some(Value::Number(value)) if value.as_i64() == Some(-1))
        || matches!(value, Some(Value::String(value)) if value.trim() == "-1")
}

fn copilot_snapshot_window(
    label: &str,
    value: Option<&Value>,
    reset: &Reset,
    now: OffsetDateTime,
) -> Result<Option<QuotaWindow>, ProviderError> {
    let Some(value) = value else {
        return Ok(None);
    };
    let snapshot = value.as_object().ok_or(ProviderError::InvalidData)?;
    if unlimited(snapshot.get("unlimited"))
        || unlimited(snapshot.get("entitlement"))
        || unlimited(snapshot.get("remaining"))
    {
        return Ok(None);
    }
    let entitlement = common::number(snapshot.get("entitlement"))?;
    let remaining = common::number(snapshot.get("remaining"))?;
    if entitlement == Some(0.0) {
        // A Business token-billing placeholder is not a personal 0% quota.
        return Ok(None);
    }
    let window = if let Some(remaining) = common::number(snapshot.get("percent_remaining"))? {
        if remaining > 100.0 {
            return Err(ProviderError::InvalidData);
        }
        common::window(
            label,
            Some(100.0 - remaining),
            Some(100.0),
            Some(remaining),
            "percent",
            reset.at,
            "github_copilot_usage",
            now,
        )?
    } else if let (Some(limit), Some(remaining)) = (entitlement, remaining) {
        if limit == 0.0 {
            return Ok(None);
        }
        common::window(
            label,
            Some((limit - remaining).max(0.0)),
            Some(limit),
            Some(remaining),
            "requests",
            reset.at,
            "github_copilot_usage",
            now,
        )?
    } else {
        return Ok(None);
    };
    Ok(Some(with_reset(window, reset)))
}

fn copilot_legacy_window(
    label: &str,
    remaining: Option<&Value>,
    limit: Option<&Value>,
    reset: &Reset,
    now: OffsetDateTime,
) -> Result<Option<QuotaWindow>, ProviderError> {
    let Some(limit) = common::number(limit)? else {
        return Ok(None);
    };
    let Some(remaining) = common::number(remaining)? else {
        return Ok(None);
    };
    if limit == 0.0 {
        return Ok(None);
    }
    Ok(Some(with_reset(
        common::window(
            label,
            Some((limit - remaining).max(0.0)),
            Some(limit),
            Some(remaining),
            "requests",
            reset.at,
            "github_copilot_usage",
            now,
        )?,
        reset,
    )))
}

#[derive(Debug)]
struct CopilotUsage {
    plan: Option<String>,
    windows: Vec<QuotaWindow>,
}

fn copilot_usage(value: &Value, now: OffsetDateTime) -> Result<CopilotUsage, ProviderError> {
    let object = value.as_object().ok_or(ProviderError::InvalidData)?;
    let reset = copilot_reset(
        object
            .get("quota_reset_date")
            .or_else(|| object.get("limited_user_reset_date")),
    )?;
    let plan = match object.get("copilot_plan") {
        None | Some(Value::Null) => None,
        Some(Value::String(value)) => Some(clean_label(value)?),
        Some(_) => return Err(ProviderError::InvalidData),
    };
    let mut windows = Vec::new();
    if let Some(snapshots) = object.get("quota_snapshots") {
        let snapshots = snapshots.as_object().ok_or(ProviderError::InvalidData)?;
        for (key, label) in [
            ("premium_interactions", "Premium interactions"),
            ("chat", "Chat"),
            ("completions", "Completions"),
        ] {
            if let Some(window) = copilot_snapshot_window(label, snapshots.get(key), &reset, now)? {
                windows.push(window);
            }
        }
    }
    if windows.is_empty() {
        let limited = object.get("limited_user_quotas").and_then(Value::as_object);
        let monthly = object.get("monthly_quotas").and_then(Value::as_object);
        for (key, label) in [("chat", "Chat"), ("completions", "Completions")] {
            if let Some(window) = copilot_legacy_window(
                label,
                limited.and_then(|value| value.get(key)),
                monthly.and_then(|value| value.get(key)),
                &reset,
                now,
            )? {
                windows.push(window);
            }
        }
    }
    if windows.is_empty() {
        // Organization token billing and unlimited lanes expose no personal
        // allowance here. Never report them as 0% subscription quota.
        return Err(ProviderError::QuotaUnavailable);
    }
    Ok(CopilotUsage { plan, windows })
}

pub(crate) async fn fetch_copilot_at(
    context: &ProviderContext,
    endpoint: &str,
) -> Result<ProviderUsage, ProviderError> {
    let token = copilot_token(context).await?;
    let now = context.clock.now();
    let response: Value = common::json(
        context
            .http
            .get(endpoint)
            .header(
                "Authorization",
                http::sensitive(&format!("token {}", token.0))?,
            )
            .header("Accept", "application/json")
            .header("Editor-Version", "vscode/1.96.2")
            .header("Editor-Plugin-Version", "copilot-chat/0.26.7")
            .header("User-Agent", "GitHubCopilotChat/0.26.7")
            .header("X-Github-Api-Version", "2025-04-01"),
        now,
    )
    .await?;
    let parsed = copilot_usage(&response, now)?;
    let mut usage = common::usage("copilot", &token, "github-oauth", parsed.windows)?;
    usage.account.label = "GitHub Copilot OAuth token".into();
    usage.account.plan = parsed.plan;
    Ok(usage)
}

// Resolve the existing login without sending a quota request or refreshing tokens.
pub(super) async fn cache_token(id: &str, context: &ProviderContext) -> Option<Secret> {
    match id {
        "claude" => claude_token(context).await.ok(),
        "gemini" => gemini_token(context).await.ok(),
        "copilot" => copilot_token(context).await.ok(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::Quota;

    struct CopilotKeys(&'static [(&'static str, &'static str)]);
    impl crate::providers::CredentialStore for CopilotKeys {
        fn get(&self, name: &str) -> Option<Secret> {
            self.0
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| Secret((*value).into()))
        }
    }
    fn copilot_context(keys: &'static [(&'static str, &'static str)]) -> ProviderContext {
        ProviderContext {
            credentials: std::sync::Arc::new(CopilotKeys(keys)),
            ..http::fixture::context()
        }
    }

    #[test]
    fn copilot_quota_route_follows_the_saved_host_only() {
        assert_eq!(
            copilot_usage_url(&copilot_context(&[(COPILOT_TOKEN_ENV, "token")])).unwrap(),
            None
        );
        assert_eq!(
            copilot_usage_url(&copilot_context(&[
                (COPILOT_TOKEN_ENV, "token"),
                (COPILOT_HOST_ENV, "github.com"),
            ]))
            .unwrap(),
            None
        );
        assert_eq!(
            copilot_usage_url(&copilot_context(&[
                (COPILOT_TOKEN_ENV, "token"),
                (COPILOT_HOST_ENV, "octocorp.ghe.com"),
            ]))
            .unwrap()
            .as_deref(),
            Some("https://api.octocorp.ghe.com/copilot_internal/user")
        );
        assert!(matches!(
            copilot_usage_url(&copilot_context(&[
                (COPILOT_TOKEN_ENV, "token"),
                (COPILOT_HOST_ENV, "evil.example"),
            ])),
            Err(ProviderError::Authentication)
        ));
        // A native GitHub.com login must never be sent to an enterprise host.
        assert!(matches!(
            copilot_usage_url(&copilot_context(&[(COPILOT_HOST_ENV, "octocorp.ghe.com")])),
            Err(ProviderError::Authentication)
        ));
    }

    #[test]
    fn claude_source_response_maps_real_windows_without_extra_spend() {
        let now = OffsetDateTime::UNIX_EPOCH;
        let windows = claude_windows(
            &json!({
                "five_hour":{"utilization":25,"resets_at":"2026-09-06T00:00:00Z"},
                "seven_day":{"utilization":75},
                "extra_usage":{"used_credits":900,"monthly_limit":1000},
                "limits":[{"kind":"weekly_scoped","percent":40,"scope":{"model":{"display_name":"Fable"}}}]
            }),
            now,
        )
        .unwrap();
        assert_eq!(
            windows
                .iter()
                .map(|window| window.label.as_str())
                .collect::<Vec<_>>(),
            ["Session", "Weekly", "Fable weekly"]
        );
        assert_eq!(windows[0].quota, Quota::from_used(Some(25.0)));
        assert_eq!(windows[2].quota, Quota::from_used(Some(40.0)));
        assert!(claude_windows(&json!({"five_hour":{"utilization":101}}), now).is_err());
        assert_eq!(
            claude_windows(&json!({"five_hour":null}), now).unwrap_err(),
            ProviderError::QuotaUnavailable
        );
    }

    #[test]
    fn gemini_source_response_keeps_the_lowest_model_lane() {
        let now = OffsetDateTime::UNIX_EPOCH;
        let windows = gemini_windows(
            &json!({"buckets":[
                {"modelId":"gemini-2.5-pro","remainingFraction":0.75},
                {"modelId":"gemini-2.5-pro","remainingFraction":0.25,"resetTime":"2026-09-06T00:00:00Z"},
                {"modelId":"gemini-2.5-flash","remainingFraction":"0.5"}
            ]}),
            now,
        )
        .unwrap();
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].label, "gemini-2.5-flash");
        assert_eq!(windows[0].quota, Quota::from_remaining(Some(50.0)));
        assert_eq!(windows[1].quota, Quota::from_remaining(Some(25.0)));
        assert!(
            gemini_windows(
                &json!({"buckets":[{"modelId":"m","remainingFraction":1.1}]}),
                now
            )
            .is_err()
        );
        assert_eq!(
            gemini_windows(&json!({"buckets":[{"modelId":"m"}]}), now).unwrap_err(),
            ProviderError::QuotaUnavailable
        );
    }

    #[test]
    fn copilot_source_response_omits_unlimited_and_org_placeholders() {
        let now = OffsetDateTime::UNIX_EPOCH;
        let usage = copilot_usage(
            &json!({
                "copilot_plan":"individual",
                "quota_reset_date":"2026-10-01T00:00:00Z",
                "quota_snapshots": {
                    "premium_interactions":{"percent_remaining":80},
                    "chat":{"entitlement":20,"remaining":5},
                    "completions":{"unlimited":true,"entitlement":-1,"remaining":-1}
                }
            }),
            now,
        )
        .unwrap();
        assert_eq!(usage.plan.as_deref(), Some("individual"));
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].quota, Quota::from_remaining(Some(80.0)));
        assert_eq!(usage.windows[1].quota, Quota::from_remaining(Some(25.0)));
        assert_eq!(
            copilot_usage(
                &json!({"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":0,"remaining":0}}}),
                now,
            )
            .unwrap_err(),
            ProviderError::QuotaUnavailable
        );
    }

    #[test]
    fn copilot_native_parsers_reject_non_github_dot_com_hosts() {
        assert_eq!(
            copilot_editor_token(
                br#"{"github.example":{"oauth_token":"wrong"},"github.com:chat":{"oauth_token":"right"}}"#
            )
            .unwrap()
            .unwrap()
            .0,
            "right"
        );
        assert_eq!(
            copilot_gh_token(
                b"enterprise.example:\n  oauth_token: wrong\ngithub.com:\n  oauth_token: right\n"
            )
            .unwrap()
            .unwrap()
            .0,
            "right"
        );
        assert!(copilot_gh_host_present(b"github.com:\n  user: fixture\n").unwrap());
        assert!(
            copilot_gh_token(b"github.com:\n  user: fixture\n")
                .unwrap()
                .is_none()
        );
        assert!(!copilot_gh_host_present(b"enterprise.example:\n  oauth_token: wrong\n").unwrap());
        assert_eq!(
            copilot_keychain_token(b"go-keyring-base64:cmlnaHQ=")
                .unwrap()
                .unwrap()
                .0,
            "right"
        );
    }
}
