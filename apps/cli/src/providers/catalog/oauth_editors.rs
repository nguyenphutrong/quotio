use super::{AuthKind, Definition, common};
#[cfg(unix)]
use crate::providers::process;
use crate::{
    domain::{ProviderUsage, Quota, QuotaWindow, UsageDiagnostic},
    error::ProviderError,
    providers::{FetchFuture, ProviderContext, Secret, http},
};
use serde_json::Value;
use std::{
    io::Read,
    path::{Path, PathBuf},
    time::Duration,
};

#[cfg(unix)]
use std::process::Stdio;
use time::OffsetDateTime;
#[cfg(unix)]
use tokio::{
    io::{AsyncReadExt, BufReader},
    process::Command,
};

const CURSOR_USAGE_URL: &str =
    "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage";
const CURSOR_SUMMARY_URL: &str = "https://api2.cursor.sh/auth/usage-summary";
const GROK_SETTINGS_URL: &str = "https://cli-chat-proxy.grok.com/v1/settings";
const GROK_CREDITS_URL: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
const KIMI_CODE_USAGE_URL: &str = "https://api.kimi.com/coding/v1/usages";
const CURSOR_KEYCHAIN_SERVICE: &str = "cursor-access-token";
#[cfg(any(target_os = "macos", all(test, unix)))]
const CURSOR_STATE_QUERY: &str =
    "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;";
const MAX_NATIVE_FILE_BYTES: u64 = 1024 * 1024;
#[cfg(unix)]
const MAX_CURSOR_DATABASE_BYTES: u64 = 64 * 1024 * 1024;
const NATIVE_READ_TIMEOUT: Duration = Duration::from_secs(1);
#[cfg(unix)]
const CURSOR_SQLITE_TIMEOUT: Duration = Duration::from_secs(2);
#[cfg(unix)]
const CURSOR_SNAPSHOT_PREFIX: &str = "quotio-cursor-";
#[cfg(unix)]
const CURSOR_SNAPSHOT_LOCK: &str = ".lock";

pub const DEFINITIONS: &[Definition] = &[
    Definition {
        id: "cursor",
        name: "Cursor",
        key_env: "CURSOR_ACCESS_TOKEN",
        auth: AuthKind::OAuth,
        settings: &[],
        fetch: cursor,
    },
    Definition {
        id: "grok",
        name: "Grok",
        key_env: "GROK_OAUTH_TOKEN",
        auth: AuthKind::OAuth,
        settings: &[],
        fetch: grok,
    },
    Definition {
        id: "kimi",
        name: "Kimi Code",
        key_env: "KIMI_CODE_API_KEY",
        auth: AuthKind::ApiKey,
        settings: &[],
        fetch: kimi,
    },
];

fn cursor(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(async move {
        fetch_cursor_complete_at(context, CURSOR_USAGE_URL, CURSOR_SUMMARY_URL).await
    })
}

fn grok(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(async move {
        fetch_grok_complete_at(context, GROK_CREDITS_URL, Some(GROK_SETTINGS_URL)).await
    })
}

fn kimi(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(async move { fetch_kimi_at(context, KIMI_CODE_USAGE_URL).await })
}

#[cfg(test)]
async fn fetch_cursor_at(
    context: &ProviderContext,
    endpoint: &str,
) -> Result<ProviderUsage, ProviderError> {
    let key = cursor_token(context).await?;
    fetch_cursor_with_key(context, endpoint, &key).await
}

async fn fetch_cursor_with_key(
    context: &ProviderContext,
    endpoint: &str,
    key: &Secret,
) -> Result<ProviderUsage, ProviderError> {
    let now = context.clock.now();
    let root: Value = common::json(
        context
            .http
            .post(endpoint)
            .header(
                "Authorization",
                http::sensitive(&format!("Bearer {}", key.0))?,
            )
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .header("Connect-Protocol-Version", "1")
            .body("{}"),
        now,
    )
    .await?;
    token_usage(
        "cursor",
        key,
        "native-oauth",
        "Cursor OAuth token",
        cursor_windows(&root, now)?,
    )
}

pub(crate) async fn fetch_cursor_complete_at(
    context: &ProviderContext,
    endpoint: &str,
    summary_endpoint: &str,
) -> Result<ProviderUsage, ProviderError> {
    // Both endpoints use the same credential snapshot, even if the native login changes.
    let key = cursor_token(context).await?;
    let now = context.clock.now();
    let budget = crate::providers::remaining_fetch_time()
        .unwrap_or(Duration::from_secs(15))
        .mul_f64(0.9);
    let summary = async {
        let root = common::json(
            context
                .http
                .get(summary_endpoint)
                .header(
                    "Authorization",
                    http::sensitive(&format!("Bearer {}", key.0))?,
                )
                .header("Accept", "application/json"),
            now,
        )
        .await?;
        cursor_summary(&root, &key, now)
    };
    let (summary, period) = tokio::join!(
        tokio::time::timeout(budget, summary),
        tokio::time::timeout(budget, fetch_cursor_with_key(context, endpoint, &key)),
    );
    let summary = summary.unwrap_or(Err(ProviderError::Timeout));
    let period = period.unwrap_or(Err(ProviderError::Timeout));
    match (summary, period) {
        (Ok(mut summary), Ok(period)) => {
            summary.windows.extend(period.windows);
            Ok(summary)
        }
        (Ok(mut usage), Err(code)) => {
            usage.diagnostics.push(UsageDiagnostic {
                source: "cursor_current_period".into(),
                code,
            });
            Ok(usage)
        }
        (Err(code), Ok(mut usage)) => {
            usage.diagnostics.push(UsageDiagnostic {
                source: "cursor_usage_summary".into(),
                code,
            });
            Ok(usage)
        }
        (Err(error), Err(_)) => Err(error),
    }
}

pub(crate) fn cursor_plan_name(value: &str) -> String {
    value
        .split('_')
        .filter(|word| !word.is_empty())
        .map(|word| {
            let mut chars = word.chars();
            chars
                .next()
                .map(|first| first.to_uppercase().to_string() + &chars.as_str().to_lowercase())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn cursor_summary(
    root: &Value,
    key: &Secret,
    now: OffsetDateTime,
) -> Result<ProviderUsage, ProviderError> {
    if !root.is_object()
        || !["membershipType", "individualUsage", "isUnlimited"]
            .iter()
            .any(|field| root.get(field).is_some())
    {
        return Err(ProviderError::InvalidData);
    }
    let mut account = common::account_identity("cursor", key, "native-oauth");
    account.label = "Cursor OAuth token".into();
    account.plan = root
        .get("membershipType")
        .and_then(Value::as_str)
        .filter(|value| value.len() <= 128 && !value.chars().any(char::is_control))
        .map(cursor_plan_name);
    let mut windows = Vec::new();
    let mut diagnostics = Vec::new();
    let reset = match common::date(root.get("billingCycleEnd")) {
        Ok(reset) => reset,
        Err(code) => {
            diagnostics.push(UsageDiagnostic {
                source: "cursor_billing_cycle".into(),
                code,
            });
            None
        }
    };
    for (field, id, label) in [
        ("plan", "plan-usage", "Plan usage"),
        ("onDemand", "on-demand", "On demand"),
    ] {
        let Some(value) = root
            .get("individualUsage")
            .and_then(|usage| usage.get(field))
        else {
            continue;
        };
        if value.get("enabled").and_then(Value::as_bool) == Some(false) {
            continue;
        }
        let parsed = (|| {
            if value.get("enabled").and_then(Value::as_bool) != Some(true) {
                return Err(ProviderError::InvalidData);
            }
            let mut window = common::window(
                label,
                common::number(value.get("used"))?,
                common::number(value.get("limit"))?,
                common::number(value.get("remaining"))?,
                "units",
                if field == "plan" { reset } else { None },
                "cursor_usage_summary",
                now,
            )?;
            window.metric_id = Some(id.into());
            Ok(window)
        })();
        match parsed {
            Ok(window) => windows.push(window),
            Err(code) => diagnostics.push(UsageDiagnostic {
                source: format!("cursor_{field}"),
                code,
            }),
        }
    }
    if windows.is_empty() {
        let mut window = common::window(
            "Usage",
            None,
            None,
            None,
            "units",
            None,
            "cursor_usage_summary",
            now,
        )?;
        window.metric_id = Some("cursor-usage".into());
        if root.get("isUnlimited").and_then(Value::as_bool) == Some(true) {
            window.quota = Quota::Unlimited;
            window.provenance.confidence = crate::domain::Confidence::Exact;
        }
        windows.push(window);
    }
    Ok(ProviderUsage {
        fresh_observation: false,
        history_identity: None,
        reset_credits: None,
        antigravity_subscription: None,
        codex_profile: None,
        codex_reset_credits: None,
        provider: crate::domain::ProviderId("cursor".into()),
        account,
        account_ref: None,
        windows,
        diagnostics,
    })
}

#[cfg(test)]
async fn fetch_grok_at(
    context: &ProviderContext,
    endpoint: &str,
) -> Result<ProviderUsage, ProviderError> {
    fetch_grok_complete_at(context, endpoint, None).await
}

pub(crate) async fn fetch_grok_complete_at(
    context: &ProviderContext,
    endpoint: &str,
    settings_endpoint: Option<&str>,
) -> Result<ProviderUsage, ProviderError> {
    let key = grok_token(context).await?;
    let now = context.clock.now();
    let authorization = http::sensitive(&format!("Bearer {}", key.0))?;
    let get = |url: &str| {
        common::json::<Value>(
            context
                .http
                .get(url)
                .header("Authorization", authorization.clone())
                .header("x-xai-token-auth", "xai-grok-cli")
                .header("Accept", "application/json"),
            now,
        )
    };
    let settings = async {
        let Some(endpoint) = settings_endpoint else {
            return Ok(None);
        };
        let root = get(endpoint).await?;
        let plan = root
            .get("subscription_tier_display")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty() && s.len() <= 128 && !s.chars().any(char::is_control))
            .ok_or(ProviderError::InvalidData)?;
        Ok::<_, ProviderError>(Some(plan.to_owned()))
    };
    let budget = crate::providers::remaining_fetch_time()
        .unwrap_or(Duration::from_secs(15))
        .mul_f64(0.9);
    let (billing, settings) = tokio::join!(
        tokio::time::timeout(budget, get(endpoint)),
        tokio::time::timeout(budget.min(Duration::from_secs(5)), settings),
    );
    let root = billing.map_err(|_| ProviderError::Timeout)??;
    let (windows, mut diagnostics) = grok_windows(&root, now)?;
    let mut account = common::account_identity("grok", &key, "cli-oauth");
    account.label = "Grok OAuth token".into();
    match settings.unwrap_or(Err(ProviderError::Timeout)) {
        Ok(plan) => account.plan = plan,
        Err(code) => diagnostics.push(UsageDiagnostic {
            source: "grok_settings".into(),
            code,
        }),
    }
    Ok(ProviderUsage {
        fresh_observation: false,
        history_identity: None,
        reset_credits: None,
        antigravity_subscription: None,
        codex_profile: None,
        codex_reset_credits: None,
        provider: crate::domain::ProviderId("grok".into()),
        account,
        account_ref: None,
        windows,
        diagnostics,
    })
}

async fn fetch_kimi_at(
    context: &ProviderContext,
    endpoint: &str,
) -> Result<ProviderUsage, ProviderError> {
    let key = kimi_code_key(context)?;
    let now = context.clock.now();
    let root: Value = common::json(
        context
            .http
            .get(endpoint)
            .header(
                "Authorization",
                http::sensitive(&format!("Bearer {}", key.0))?,
            )
            .header("Accept", "application/json"),
        now,
    )
    .await?;
    token_usage(
        "kimi",
        &key,
        "code-api-key",
        "Kimi Code API key",
        kimi_windows(&root, now)?,
    )
}

fn token_usage(
    id: &str,
    key: &Secret,
    scope: &str,
    label: &str,
    windows: Vec<QuotaWindow>,
) -> Result<ProviderUsage, ProviderError> {
    let mut usage = common::usage(id, key, scope, windows)?;
    usage.account.label = label.into();
    Ok(usage)
}

fn percentage(value: Option<&Value>) -> Result<Option<f64>, ProviderError> {
    let value = common::number(value)?;
    if value.is_some_and(|value| value > 100.0) {
        return Err(ProviderError::InvalidData);
    }
    Ok(value)
}

fn cursor_windows(root: &Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    if root.get("enabled").and_then(Value::as_bool) == Some(false) {
        return Err(ProviderError::InvalidData);
    }
    let plan = root
        .get("planUsage")
        .filter(|value| value.is_object())
        .ok_or(ProviderError::InvalidData)?;
    let reset = common::date(root.get("billingCycleEnd"))?;
    if reset.is_some_and(|reset| reset <= now) {
        return Err(ProviderError::InvalidData);
    }
    let mut windows = Vec::new();
    for (field, label) in [
        ("totalPercentUsed", "Current period"),
        ("autoPercentUsed", "Cursor Models"),
        ("apiPercentUsed", "Other Models"),
    ] {
        if let Some(used) = percentage(plan.get(field))? {
            let mut window = common::window(
                label,
                Some(used),
                Some(100.0),
                None,
                "percent",
                reset,
                "cursor_native_oauth",
                now,
            )?;
            window.metric_id = Some(format!("cursor-{field}"));
            windows.push(window);
        }
    }
    if windows.is_empty() {
        return Err(ProviderError::InvalidData);
    }
    Ok(windows)
}

fn grok_windows(
    root: &Value,
    now: OffsetDateTime,
) -> Result<(Vec<QuotaWindow>, Vec<UsageDiagnostic>), ProviderError> {
    let config = root
        .get("config")
        .filter(|v| v.is_object())
        .ok_or(ProviderError::InvalidData)?;
    let period = config.get("currentPeriod").filter(|v| v.is_object());
    let (id, label) = match period.and_then(|p| p.get("type")).and_then(Value::as_str) {
        Some("USAGE_PERIOD_TYPE_WEEKLY") => ("grok-weekly", "Weekly"),
        Some("USAGE_PERIOD_TYPE_MONTHLY") => ("grok-monthly", "Monthly"),
        _ => ("grok-credits", "Credits"),
    };
    let mut diagnostics = Vec::new();
    let mut windows = Vec::new();
    let mut parse = |result: Result<Option<f64>, ProviderError>, source: &str| match result {
        Ok(value) => value,
        Err(code) => {
            diagnostics.push(UsageDiagnostic {
                source: source.into(),
                code,
            });
            None
        }
    };
    let used = parse(percentage(config.get("creditUsagePercent")), "grok_credits");
    let cap = parse(
        common::number(config.get("onDemandCap").and_then(|v| v.get("val"))),
        "grok_extra_usage",
    );
    let reset = match common::date(
        period
            .and_then(|p| p.get("end"))
            .or_else(|| config.get("billingPeriodEnd")),
    ) {
        Ok(reset) => reset,
        Err(code) => {
            diagnostics.push(UsageDiagnostic {
                source: "grok_billing_period".into(),
                code,
            });
            None
        }
    };
    let mut window = common::window(
        label,
        used,
        Some(100.0),
        None,
        "percent",
        reset,
        "grok_cli_oauth",
        now,
    )?;
    window.metric_id = Some(id.into());
    if used.is_none() {
        window.note = Some("Grok did not report usage for this period.".into());
    }
    windows.push(window);
    let mut extra = common::window(
        "Extra usage",
        None,
        None,
        None,
        "units",
        None,
        "grok_cli_oauth",
        now,
    )?;
    extra.metric_id = Some("grok-extra-usage".into());
    extra.quota = match cap {
        Some(0.0) => Quota::Disabled,
        Some(amount) => Quota::Limit {
            amount,
            unit: "units".into(),
        },
        None => Quota::Unknown,
    };
    if cap.is_some() {
        extra.provenance.confidence = crate::domain::Confidence::Exact;
    }
    windows.push(extra);
    Ok((windows, diagnostics))
}

fn kimi_windows(root: &Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    let usage = root.get("usage").ok_or(ProviderError::InvalidData)?;
    let mut windows = vec![kimi_detail_window(
        usage,
        "Code 7-day",
        "kimi_code_api",
        now,
    )?];
    match root.get("limits") {
        None | Some(Value::Null) => (),
        Some(Value::Array(limits)) => {
            if limits.len() > 8 {
                return Err(ProviderError::InvalidData);
            }
            for limit in limits {
                let window = limit.get("window").ok_or(ProviderError::InvalidData)?;
                let detail = limit.get("detail").ok_or(ProviderError::InvalidData)?;
                windows.push(kimi_detail_window(
                    detail,
                    &kimi_rate_label(window)?,
                    "kimi_code_api",
                    now,
                )?);
            }
        }
        Some(_) => return Err(ProviderError::InvalidData),
    }
    Ok(windows)
}

fn kimi_detail_window(
    detail: &Value,
    label: &str,
    source: &str,
    now: OffsetDateTime,
) -> Result<QuotaWindow, ProviderError> {
    let detail = detail.as_object().ok_or(ProviderError::InvalidData)?;
    let limit = common::number(detail.get("limit"))?
        .filter(|limit| *limit > 0.0)
        .ok_or(ProviderError::InvalidData)?;
    let used = common::number(detail.get("used"))?;
    let remaining = common::number(detail.get("remaining"))?;
    // A supplied used count is authoritative. Some plans report an overage,
    // where an independently reported remaining value would be stale or wrong.
    let (used, remaining) = if used.is_some() {
        (used, None)
    } else {
        (None, remaining)
    };
    if used.is_none() && remaining.is_none() {
        return Err(ProviderError::InvalidData);
    }
    let reset = first(detail, &["resetTime", "resetAt", "reset_time", "reset_at"]);
    common::window(
        label,
        used,
        Some(limit),
        remaining,
        "requests",
        common::date(reset)?,
        source,
        now,
    )
}

fn kimi_rate_label(window: &Value) -> Result<String, ProviderError> {
    let window = window.as_object().ok_or(ProviderError::InvalidData)?;
    let duration = common::number(window.get("duration"))?.ok_or(ProviderError::InvalidData)?;
    if duration.fract() != 0.0 || !(1.0..=10_080.0).contains(&duration) {
        return Err(ProviderError::InvalidData);
    }
    let unit = match window.get("timeUnit").and_then(Value::as_str) {
        Some("TIME_UNIT_MINUTE") => "minute",
        Some("TIME_UNIT_HOUR") => "hour",
        Some("TIME_UNIT_DAY") => "day",
        _ => return Err(ProviderError::InvalidData),
    };
    let duration = duration as u64;
    let suffix = if duration == 1 { "" } else { "s" };
    Ok(format!("Rate limit ({duration} {unit}{suffix})"))
}

fn first<'a>(object: &'a serde_json::Map<String, Value>, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| object.get(*key))
}

fn kimi_code_key(context: &ProviderContext) -> Result<Secret, ProviderError> {
    validate_kimi_code_key(common::key(context, "KIMI_CODE_API_KEY")?)
}

fn validate_kimi_code_key(key: Secret) -> Result<Secret, ProviderError> {
    let value = key.0.trim();
    let lower = value.to_ascii_lowercase();
    if lower.starts_with("bearer ")
        || lower.starts_with("cookie:")
        || lower.starts_with("kimi-auth=")
        || looks_like_jwt(value)
    {
        return Err(ProviderError::Authentication);
    }
    Ok(key)
}

fn looks_like_jwt(value: &str) -> bool {
    let mut parts = value.split('.');
    matches!(
        (parts.next(), parts.next(), parts.next(), parts.next()),
        (Some(first), Some(second), Some(third), None)
            if !first.is_empty() && !second.is_empty() && !third.is_empty()
    )
}

async fn cursor_token(context: &ProviderContext) -> Result<Secret, ProviderError> {
    if context.credentials.get("CURSOR_ACCESS_TOKEN").is_some() {
        return common::key(context, "CURSOR_ACCESS_TOKEN");
    }
    match cursor_state_token().await {
        Ok(Some(token)) => return Ok(token),
        Ok(None)
        | Err(
            ProviderError::Authentication
            | ProviderError::CredentialStorage
            | ProviderError::InvalidData
            | ProviderError::Unavailable,
        ) => (),
        Err(error) => return Err(error),
    }
    let bytes = blocking(|| common::read_keychain(CURSOR_KEYCHAIN_SERVICE, None)).await?;
    let bytes = bytes.ok_or(ProviderError::Authentication)?;
    secret_from_bytes(&bytes)
}

#[cfg(unix)]
struct CursorDatabase {
    directory: PathBuf,
    _lock: std::fs::File,
    sources: Vec<(PathBuf, Option<std::fs::Metadata>)>,
}

#[cfg(unix)]
impl Drop for CursorDatabase {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[cfg(target_os = "macos")]
async fn cursor_state_token() -> Result<Option<Secret>, ProviderError> {
    let path = cursor_state_database_path().ok_or(ProviderError::Authentication)?;
    let Some(database) = blocking(move || open_cursor_database(&path)).await? else {
        return Ok(None);
    };
    let bytes =
        match tokio::time::timeout(CURSOR_SQLITE_TIMEOUT, cursor_sqlite_output(&database)).await {
            Ok(Ok(bytes)) => bytes,
            Ok(Err(_)) | Err(_) => return Ok(None),
        };
    if !blocking(move || cursor_database_remains_safe(&database)).await? {
        return Ok(None);
    }
    cursor_token_from_sqlite_output(&bytes)
}

#[cfg(any(target_os = "macos", all(test, unix)))]
async fn cursor_sqlite_output(database: &CursorDatabase) -> Result<Vec<u8>, ProviderError> {
    cursor_sqlite_query(database, CURSOR_STATE_QUERY).await
}

#[cfg(unix)]
async fn cursor_sqlite_query(
    database: &CursorDatabase,
    query: &'static str,
) -> Result<Vec<u8>, ProviderError> {
    let mut child = Command::new("/usr/bin/sqlite3")
        .args([
            "-init",
            "/dev/null",
            "-safe",
            "-batch",
            "-noheader",
            "-readonly",
        ])
        .args(["-cmd", ".limit length 1048576"])
        .args(["-cmd", ".limit length"])
        .arg(database.directory.join("state.vscdb"))
        // Do not evaluate a hostile view or virtual table in place of ItemTable.
        .arg(format!(
            "PRAGMA trusted_schema=OFF; SELECT CASE WHEN EXISTS(SELECT 1 FROM pragma_table_list('ItemTable') WHERE schema='main' AND type='table') THEN 1 ELSE json('invalid') END; {query}"
        ))
        .env("SQLITE_TMPDIR", &database.directory)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| ProviderError::Unavailable)?;
    let stdout = child.stdout.take().ok_or(ProviderError::Internal)?;
    let mut bytes = Vec::new();
    BufReader::new(stdout)
        .take((process::MAX_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .await
        .map_err(|_| ProviderError::InvalidData)?;
    if bytes.len() > process::MAX_BYTES {
        return Err(ProviderError::InvalidData);
    }
    if !child
        .wait()
        .await
        .map_err(|_| ProviderError::Unavailable)?
        .success()
    {
        return Err(ProviderError::Unavailable);
    }
    sqlite_query_payload(&bytes).map(<[u8]>::to_vec)
}

#[cfg(unix)]
fn sqlite_query_payload(mut bytes: &[u8]) -> Result<&[u8], ProviderError> {
    // Query the effective limit explicitly. Older SQLite also echoes the setter.
    let mut limit_records = 0;
    for _ in 0..2 {
        let end = bytes
            .iter()
            .position(|byte| *byte == b'\n')
            .ok_or(ProviderError::Unavailable)?;
        if std::str::from_utf8(&bytes[..end]).ok().map(str::trim) != Some("length 1048576") {
            break;
        }
        limit_records += 1;
        bytes = &bytes[end + 1..];
    }
    if limit_records == 0 {
        return Err(ProviderError::Unavailable);
    }
    bytes.strip_prefix(b"1\n").ok_or(ProviderError::Unavailable)
}

#[cfg(not(target_os = "macos"))]
async fn cursor_state_token() -> Result<Option<Secret>, ProviderError> {
    Ok(None)
}

#[cfg(target_os = "macos")]
pub(crate) fn cursor_state_database_path() -> Option<PathBuf> {
    directories::BaseDirs::new().map(|dirs| {
        dirs.home_dir()
            .join("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    })
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct CursorLogin {
    pub token: String,
    pub email: Option<String>,
    pub membership: Option<String>,
    pub subscription_status: Option<String>,
}

#[cfg(any(target_os = "macos", all(test, unix)))]
pub(crate) async fn cursor_login(path: PathBuf) -> Result<CursorLogin, ProviderError> {
    let query = "SELECT json_group_array(json_object('key',key,'value',value)) FROM ItemTable WHERE key IN ('cursorAuth/accessToken','cursorAuth/cachedEmail','cursorAuth/stripeMembershipType','cursorAuth/stripeSubscriptionStatus');";
    let bytes = native_sqlite_rows(path, query).await?;
    cursor_login_from_output(&bytes)
}

// Only fixed provider queries may call this reader. SQLite sees private copies only.
#[cfg(unix)]
pub(crate) async fn native_sqlite_rows(
    path: PathBuf,
    query: &'static str,
) -> Result<Vec<u8>, ProviderError> {
    let Some(database) = blocking(move || open_cursor_database(&path)).await? else {
        return Err(ProviderError::CredentialStorage);
    };
    let bytes = tokio::time::timeout(CURSOR_SQLITE_TIMEOUT, cursor_sqlite_query(&database, query))
        .await
        .map_err(|_| ProviderError::Timeout)??;
    if !blocking(move || cursor_database_remains_safe(&database)).await? {
        return Err(ProviderError::CredentialStorage);
    }
    Ok(bytes)
}

#[cfg(not(unix))]
pub(crate) async fn native_sqlite_rows(
    _: PathBuf,
    _: &'static str,
) -> Result<Vec<u8>, ProviderError> {
    Err(ProviderError::Unavailable)
}

#[cfg(not(any(target_os = "macos", all(test, unix))))]
pub(crate) async fn cursor_login(_: PathBuf) -> Result<CursorLogin, ProviderError> {
    Err(ProviderError::Unavailable)
}

#[cfg(any(target_os = "macos", test))]
fn cursor_login_from_output(bytes: &[u8]) -> Result<CursorLogin, ProviderError> {
    let rows: Vec<Value> = serde_json::from_slice(bytes).map_err(|_| ProviderError::InvalidData)?;
    let mut values = std::collections::HashMap::new();
    for row in rows {
        let key = row
            .get("key")
            .and_then(Value::as_str)
            .ok_or(ProviderError::InvalidData)?;
        let value = match row.get("value").and_then(Value::as_str) {
            Some(value) => value,
            None if key != "cursorAuth/accessToken" => continue,
            None => return Err(ProviderError::InvalidData),
        };
        if values.insert(key.to_owned(), value.to_owned()).is_some() {
            return Err(ProviderError::InvalidData);
        }
    }
    let token = values
        .remove("cursorAuth/accessToken")
        .ok_or(ProviderError::Authentication)?;
    if token.trim().is_empty() || token.len() > 16384 || token.chars().any(char::is_control) {
        return Err(ProviderError::Authentication);
    }
    let mut metadata = |key, max| {
        values
            .remove(key)
            .filter(|v| !v.trim().is_empty() && v.len() <= max && !v.chars().any(char::is_control))
    };
    Ok(CursorLogin {
        token,
        email: metadata("cursorAuth/cachedEmail", 254),
        membership: metadata("cursorAuth/stripeMembershipType", 128),
        subscription_status: metadata("cursorAuth/stripeSubscriptionStatus", 128),
    })
}

#[cfg(unix)]
fn open_cursor_database(path: &Path) -> Result<Option<CursorDatabase>, ProviderError> {
    open_cursor_database_in(path, &cursor_snapshot_root()?)
}

#[cfg(unix)]
fn open_cursor_database_in(
    path: &Path,
    root: &Path,
) -> Result<Option<CursorDatabase>, ProviderError> {
    open_cursor_database_at_with_hooks(path, root, || {}, || {}, || {})
}

#[cfg(all(test, unix))]
fn open_cursor_database_with_hooks(
    path: &Path,
    after_capture: impl FnOnce(),
    after_database_read: impl FnOnce(),
) -> Result<Option<CursorDatabase>, ProviderError> {
    open_cursor_database_at_with_hooks(
        path,
        &cursor_snapshot_root()?,
        after_capture,
        after_database_read,
        || {},
    )
}

#[cfg(unix)]
fn open_cursor_database_at_with_hooks(
    path: &Path,
    root: &Path,
    after_capture: impl FnOnce(),
    after_database_read: impl FnOnce(),
    before_lock_acquired: impl FnOnce(),
) -> Result<Option<CursorDatabase>, ProviderError> {
    use std::{
        io::Write,
        os::{
            fd::AsRawFd,
            unix::fs::{DirBuilderExt, OpenOptionsExt},
        },
    };

    // Capture all identities before reading any bytes. Never give SQLite a source path:
    // even a read-only WAL connection may create or update the owner's shared memory.
    let mut sources = Vec::new();
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut name = path.as_os_str().to_os_string();
        name.push(suffix);
        let path = PathBuf::from(name);
        let metadata = regular_file(&path, MAX_CURSOR_DATABASE_BYTES)?;
        if suffix.is_empty() && metadata.is_none() {
            return Ok(None);
        }
        if suffix == "-journal" && metadata.as_ref().is_some_and(|m| m.len() != 0) {
            return Err(ProviderError::CredentialStorage);
        }
        sources.push((path, metadata));
    }
    after_capture();
    let mut after_database_read = Some(after_database_read);
    prepare_cursor_snapshot_root(root)?;
    recover_cursor_snapshots(root)?;
    let name = format!(
        "{CURSOR_SNAPSHOT_PREFIX}{}-{}",
        std::process::id(),
        crate::accounts::random_string().map_err(|_| ProviderError::CredentialStorage)?
    );
    let directory = root.join(format!(".pending-{name}"));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&directory)
        .map_err(|_| ProviderError::CredentialStorage)?;
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(directory.join(CURSOR_SNAPSHOT_LOCK))
        .map_err(|_| ProviderError::CredentialStorage)?;
    before_lock_acquired();
    if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(ProviderError::CredentialStorage);
    }
    let mut snapshot = CursorDatabase {
        directory,
        _lock: lock,
        sources,
    };
    // Recovery must not see the snapshot until its lifetime lock is held.
    let published = root.join(name);
    std::fs::rename(&snapshot.directory, &published)
        .map_err(|_| ProviderError::CredentialStorage)?;
    snapshot.directory = published;
    let mut page_size = 0;
    let mut wal_mode = false;
    for (index, (source, metadata)) in snapshot.sources.iter().take(2).enumerate() {
        let Some(before) = metadata else { continue };
        let file = open_readonly_file(source)?;
        let opened = file
            .metadata()
            .map_err(|_| ProviderError::CredentialStorage)?;
        if !cursor_same_file(before, &opened) || !opened.is_file() {
            return Err(ProviderError::CredentialStorage);
        }
        let mut bytes = Vec::new();
        (&file)
            .take(MAX_CURSOR_DATABASE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| ProviderError::CredentialStorage)?;
        if let Some(hook) = after_database_read.take() {
            hook();
        }
        if bytes.len() > MAX_CURSOR_DATABASE_BYTES as usize
            || !cursor_same_file(
                before,
                &file
                    .metadata()
                    .map_err(|_| ProviderError::CredentialStorage)?,
            )
        {
            return Err(ProviderError::CredentialStorage);
        }
        if index == 0 {
            if bytes.len() < 100
                || &bytes[..16] != b"SQLite format 3\0"
                || !matches!((bytes[18], bytes[19]), (1, 1) | (2, 2))
            {
                return Err(ProviderError::InvalidData);
            }
            page_size = u16::from_be_bytes([bytes[16], bytes[17]]) as usize;
            if page_size == 1 {
                page_size = 65536;
            }
            if !(512..=65536).contains(&page_size) || !page_size.is_power_of_two() {
                return Err(ProviderError::InvalidData);
            }
            wal_mode = bytes[18] == 2;
        } else if !bytes.is_empty() {
            if !wal_mode {
                return Err(ProviderError::InvalidData);
            }
            let committed_end = cursor_validate_wal(&bytes, page_size)?;
            bytes.truncate(committed_end);
        }
        let name = if index == 0 {
            "state.vscdb"
        } else {
            "state.vscdb-wal"
        };
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(snapshot.directory.join(name))
            .and_then(|mut file| file.write_all(&bytes))
            .map_err(|_| ProviderError::CredentialStorage)?;
    }
    // A read-only WAL connection needs a WAL file even after a clean checkpoint.
    if wal_mode && snapshot.sources[1].1.is_none() {
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(snapshot.directory.join("state.vscdb-wal"))
            .map_err(|_| ProviderError::CredentialStorage)?;
    }
    // SHM is deliberately not copied. SQLite rebuilds it only in the private directory.
    if !cursor_database_remains_safe(&snapshot)? {
        return Err(ProviderError::CredentialStorage);
    }
    Ok(Some(snapshot))
}

#[cfg(unix)]
fn cursor_snapshot_root() -> Result<PathBuf, ProviderError> {
    #[cfg(test)]
    if std::env::var_os("QUOTIO_CACHE_DIR").is_none() {
        return Ok(std::env::temp_dir().join(format!(
            "quotio-cursor-tests-{}-{}",
            unsafe { libc::geteuid() },
            std::process::id()
        )));
    }
    let base = std::env::var_os("QUOTIO_CACHE_DIR")
        .map(PathBuf::from)
        .or_else(|| {
            directories::ProjectDirs::from("", "", "quotio")
                .map(|directories| directories.cache_dir().to_owned())
        })
        .ok_or(ProviderError::CredentialStorage)?;
    if !base.is_absolute() {
        return Err(ProviderError::CredentialStorage);
    }
    Ok(base.join("cursor-snapshots-v1"))
}

#[cfg(unix)]
fn prepare_cursor_snapshot_root(root: &Path) -> Result<(), ProviderError> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(root)
        .map_err(|_| ProviderError::CredentialStorage)?;
    let metadata = std::fs::symlink_metadata(root).map_err(|_| ProviderError::CredentialStorage)?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o777 != 0o700
    {
        return Err(ProviderError::CredentialStorage);
    }
    Ok(())
}

#[cfg(unix)]
fn recover_cursor_snapshots(root: &Path) -> Result<(), ProviderError> {
    use std::os::fd::AsRawFd;
    use std::os::unix::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
    };
    for entry in std::fs::read_dir(root).map_err(|_| ProviderError::CredentialStorage)? {
        let entry = entry.map_err(|_| ProviderError::CredentialStorage)?;
        let name = entry.file_name();
        let bytes = name.as_bytes();
        if cursor_snapshot_pid(bytes).is_none() {
            continue;
        }
        let directory = entry.path();
        let metadata = match std::fs::symlink_metadata(&directory) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return Err(ProviderError::CredentialStorage),
        };
        if !metadata.is_dir()
            || metadata.file_type().is_symlink()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o777 != 0o700
        {
            continue;
        }
        let lock = match std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(directory.join(CURSOR_SNAPSHOT_LOCK))
        {
            Ok(lock) => lock,
            Err(_) => continue,
        };
        let lock_metadata = lock
            .metadata()
            .map_err(|_| ProviderError::CredentialStorage)?;
        if !lock_metadata.is_file()
            || lock_metadata.uid() != unsafe { libc::geteuid() }
            || lock_metadata.nlink() != 1
            || lock_metadata.mode() & 0o777 != 0o600
            || unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0
            || !cursor_snapshot_contents_are_owned(&directory)?
        {
            continue;
        }
        std::fs::remove_dir_all(directory).map_err(|_| ProviderError::CredentialStorage)?;
    }
    Ok(())
}

#[cfg(unix)]
fn cursor_snapshot_pid(name: &[u8]) -> Option<libc::pid_t> {
    let value = name.strip_prefix(CURSOR_SNAPSHOT_PREFIX.as_bytes())?;
    let separator = value.iter().position(|byte| *byte == b'-')?;
    let (pid, random) = (&value[..separator], &value[separator + 1..]);
    if pid.is_empty()
        || random.len() != 43
        || !pid.iter().all(u8::is_ascii_digit)
        || !random
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return None;
    }
    std::str::from_utf8(pid)
        .ok()?
        .parse()
        .ok()
        .filter(|pid| *pid > 0)
}

#[cfg(unix)]
fn cursor_snapshot_contents_are_owned(directory: &Path) -> Result<bool, ProviderError> {
    use std::os::unix::fs::MetadataExt;
    for entry in std::fs::read_dir(directory).map_err(|_| ProviderError::CredentialStorage)? {
        let entry = entry.map_err(|_| ProviderError::CredentialStorage)?;
        let metadata = std::fs::symlink_metadata(entry.path())
            .map_err(|_| ProviderError::CredentialStorage)?;
        if !metadata.is_file()
            || metadata.file_type().is_symlink()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.nlink() != 1
        {
            return Ok(false);
        }
    }
    Ok(true)
}

#[cfg(unix)]
fn cursor_same_file(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    a.dev() == b.dev()
        && a.ino() == b.ino()
        && a.len() == b.len()
        && a.mtime() == b.mtime()
        && a.mtime_nsec() == b.mtime_nsec()
        && a.ctime() == b.ctime()
        && a.ctime_nsec() == b.ctime_nsec()
}

#[cfg(unix)]
fn cursor_database_remains_safe(database: &CursorDatabase) -> Result<bool, ProviderError> {
    for (path, before) in &database.sources {
        let after = regular_file(path, MAX_CURSOR_DATABASE_BYTES)?;
        match (before, after) {
            (None, None) => (),
            (Some(before), Some(after)) if cursor_same_file(before, &after) => (),
            _ => return Ok(false),
        }
    }
    Ok(true)
}

#[cfg(unix)]
fn cursor_validate_wal(bytes: &[u8], page_size: usize) -> Result<usize, ProviderError> {
    // SQLite silently ignores invalid WAL headers. Reject them rather than returning
    // stale credentials from the main database. Frame recovery still belongs to SQLite.
    let be = |bytes: &[u8]| u32::from_be_bytes(bytes[..4].try_into().unwrap());
    if bytes.len() < 32
        || !matches!(be(bytes), 0x377f0682 | 0x377f0683)
        || be(&bytes[4..]) != 3007000
        || be(&bytes[8..]) as usize != page_size
    {
        return Err(ProviderError::InvalidData);
    }
    let little = be(bytes) == 0x377f0682;
    let checksum = |bytes: &[u8], mut sum: [u32; 2]| {
        for pair in bytes.as_chunks::<8>().0 {
            let word = |v: &[u8]| {
                if little {
                    u32::from_le_bytes(v[..4].try_into().unwrap())
                } else {
                    be(v)
                }
            };
            sum[0] = sum[0].wrapping_add(word(pair)).wrapping_add(sum[1]);
            sum[1] = sum[1].wrapping_add(word(&pair[4..])).wrapping_add(sum[0]);
        }
        sum
    };
    let mut sum = checksum(&bytes[..24], [0, 0]);
    if sum != [be(&bytes[24..]), be(&bytes[28..])] {
        return Err(ProviderError::InvalidData);
    }
    let mut committed_end = None;
    for (index, frame) in bytes[32..].chunks_exact(24 + page_size).enumerate() {
        // Old frames can remain after a WAL reset. They are not part of this log.
        if frame[8..16] != bytes[16..24] {
            break;
        }
        sum = checksum(&frame[..8], sum);
        sum = checksum(&frame[24..], sum);
        if sum != [be(&frame[16..]), be(&frame[20..])]
            || be(frame) == 0
            || u64::from(be(frame)).max(u64::from(be(&frame[4..]))) * page_size as u64
                > MAX_CURSOR_DATABASE_BYTES
        {
            // Rollback followed by a shorter write can leave checksum-invalid
            // frames with the same salts. Like SQLite, retain the last valid commit.
            return committed_end.ok_or(ProviderError::InvalidData);
        }
        if be(&frame[4..]) != 0 {
            committed_end = Some(32 + (index + 1) * (24 + page_size));
        }
    }
    Ok(committed_end.unwrap_or(32))
}

#[cfg(any(target_os = "macos", test))]
fn cursor_token_from_sqlite_output(bytes: &[u8]) -> Result<Option<Secret>, ProviderError> {
    if bytes.is_empty() {
        return Ok(None);
    }
    let output = std::str::from_utf8(bytes).map_err(|_| ProviderError::InvalidData)?;
    let mut lines = output.lines();
    let token = lines.next().ok_or(ProviderError::InvalidData)?;
    if lines.next().is_some() {
        return Err(ProviderError::InvalidData);
    }
    secret_from_text(token).map(Some)
}

async fn grok_token(context: &ProviderContext) -> Result<Secret, ProviderError> {
    if context.credentials.get("GROK_OAUTH_TOKEN").is_some() {
        return grok_oauth_token(common::key(context, "GROK_OAUTH_TOKEN")?);
    }
    let path = grok_auth_path().ok_or(ProviderError::Authentication)?;
    let now = context.clock.now();
    blocking(move || grok_native_token(&path, now)).await
}

pub(crate) async fn refresh_grok(
    context: &ProviderContext,
    previous: &crate::accounts::Credential,
) -> Result<crate::accounts::Credential, crate::accounts::AccountError> {
    refresh_grok_at(context, previous, "https://auth.x.ai/oauth2/token").await
}
async fn refresh_grok_at(
    context: &ProviderContext,
    previous: &crate::accounts::Credential,
    endpoint: &str,
) -> Result<crate::accounts::Credential, crate::accounts::AccountError> {
    use crate::accounts::{AccountError, Credential};
    let Credential::GrokOAuth { refresh_token, .. } = previous else {
        return Err(AccountError::Unsupported);
    };
    #[derive(serde::Deserialize)]
    struct Tokens {
        access_token: String,
        refresh_token: Option<String>,
        expires_in: i64,
    }
    let tokens: Tokens = crate::providers::http::json(
        context.http.post(endpoint).form(&[
            ("grant_type", "refresh_token"),
            ("client_id", "b1a00492-073a-47ea-816f-4c329264a828"),
            ("refresh_token", refresh_token.as_str()),
        ]),
        context.clock.now(),
    )
    .await?;
    let rotated = tokens
        .refresh_token
        .unwrap_or_else(|| refresh_token.clone());
    if rotated.is_empty()
        || rotated.len() > 16_384
        || rotated.chars().any(|c| c.is_control() || c.is_whitespace())
        || tokens.expires_in <= 0
    {
        return Err(AccountError::OAuth);
    }
    let access = grok_oauth_token(Secret(tokens.access_token))?;
    let expires_at = context
        .clock
        .now()
        .unix_timestamp()
        .checked_add(tokens.expires_in)
        .ok_or(AccountError::OAuth)?;
    Ok(Credential::GrokOAuth {
        access_token: access.0,
        refresh_token: rotated,
        expires_at,
        refresh_pending: false,
    })
}

pub(crate) fn grok_auth_path() -> Option<PathBuf> {
    directories::BaseDirs::new().map(|dirs| dirs.home_dir().join(".grok/auth.json"))
}

pub(crate) fn grok_entry_login(
    path: &Path,
    entry_key: &str,
    now: OffsetDateTime,
) -> Result<(Secret, String), ProviderError> {
    let bytes = read_regular_file(path, MAX_NATIVE_FILE_BYTES)?;
    let root: Value = serde_json::from_slice(&bytes).map_err(|_| ProviderError::Authentication)?;
    let entry = root.get(entry_key).ok_or(ProviderError::Authentication)?;
    let selected = serde_json::json!({entry_key: entry});
    let token = grok_native_token_from_bytes(
        &serde_json::to_vec(&selected).map_err(|_| ProviderError::Authentication)?,
        now,
    )?;
    let label = ["email", "username"]
        .iter()
        .filter_map(|field| entry.get(*field).and_then(Value::as_str))
        .find_map(|value| crate::accounts::validate_label(value).ok())
        .unwrap_or_else(|| "Grok account".into());
    Ok((token, label))
}

fn grok_native_token(path: &Path, now: OffsetDateTime) -> Result<Secret, ProviderError> {
    let bytes = read_regular_file(path, MAX_NATIVE_FILE_BYTES)?;
    grok_native_token_from_bytes(&bytes, now)
}

fn grok_native_token_from_bytes(
    bytes: &[u8],
    now: OffsetDateTime,
) -> Result<Secret, ProviderError> {
    let root: Value = serde_json::from_slice(bytes).map_err(|_| ProviderError::Authentication)?;
    let entries = root.as_object().ok_or(ProviderError::Authentication)?;
    let modern: Vec<_> = entries
        .iter()
        .filter(|(scope, _)| scope.starts_with("https://auth.x.ai::"))
        .map(|(_, entry)| entry)
        .collect();
    let legacy: Vec<_> = entries
        .iter()
        .filter(|(scope, _)| scope.as_str() == "https://accounts.x.ai/sign-in")
        .map(|(_, entry)| entry)
        .collect();
    let candidates = if modern.is_empty() { legacy } else { modern };
    let [entry] = candidates.as_slice() else {
        return Err(ProviderError::Authentication);
    };
    let entry = entry.as_object().ok_or(ProviderError::Authentication)?;
    let expiration = first(entry, &["expires_at", "expires"]);
    let expires_at = common::date(expiration)?.ok_or(ProviderError::Authentication)?;
    if expires_at <= now {
        return Err(ProviderError::Authentication);
    }
    let token = entry
        .get("key")
        .and_then(Value::as_str)
        .ok_or(ProviderError::Authentication)?;
    grok_oauth_token(secret_from_text(token)?)
}

pub(crate) fn grok_oauth_token(key: Secret) -> Result<Secret, ProviderError> {
    let raw = key.0.trim();
    let token = raw
        .get(..7)
        .filter(|prefix| prefix.eq_ignore_ascii_case("bearer "))
        .map_or(raw, |prefix| &raw[prefix.len()..])
        .trim();
    let lower = token.to_ascii_lowercase();
    if lower.starts_with("cookie:") || lower.starts_with("xai-") || token.contains('=') {
        return Err(ProviderError::Authentication);
    }
    secret_from_text(token)
}

async fn blocking<T: Send + 'static>(
    operation: impl FnOnce() -> Result<T, ProviderError> + Send + 'static,
) -> Result<T, ProviderError> {
    match tokio::time::timeout(NATIVE_READ_TIMEOUT, tokio::task::spawn_blocking(operation)).await {
        Ok(Ok(result)) => result,
        Ok(Err(_)) | Err(_) => Err(ProviderError::CredentialStorage),
    }
}

fn open_readonly_file(path: &Path) -> Result<std::fs::File, ProviderError> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC);
    }
    options
        .open(path)
        .map_err(|_| ProviderError::CredentialStorage)
}
fn regular_file(
    path: &Path,
    maximum_bytes: u64,
) -> Result<Option<std::fs::Metadata>, ProviderError> {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(ProviderError::CredentialStorage),
    };
    if !metadata.file_type().is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() > maximum_bytes
    {
        return Err(ProviderError::CredentialStorage);
    }
    Ok(Some(metadata))
}

pub(super) fn read_regular_file(path: &Path, maximum_bytes: u64) -> Result<Vec<u8>, ProviderError> {
    read_regular_file_with_hook(path, maximum_bytes, || {})
}

fn read_regular_file_with_hook(
    path: &Path,
    maximum_bytes: u64,
    after_read: impl FnOnce(),
) -> Result<Vec<u8>, ProviderError> {
    let before = regular_file(path, maximum_bytes)?.ok_or(ProviderError::Authentication)?;
    let file = open_readonly_file(path)?;
    let opened = file
        .metadata()
        .map_err(|_| ProviderError::CredentialStorage)?;
    #[cfg(unix)]
    {
        if !cursor_same_file(&before, &opened) {
            return Err(ProviderError::CredentialStorage);
        }
    }
    if !opened.is_file() || opened.len() > maximum_bytes {
        return Err(ProviderError::CredentialStorage);
    }
    let mut bytes = Vec::new();
    (&file)
        .take(maximum_bytes + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ProviderError::CredentialStorage)?;
    after_read();
    let descriptor_after = file
        .metadata()
        .map_err(|_| ProviderError::CredentialStorage)?;
    let path_after = regular_file(path, maximum_bytes)?.ok_or(ProviderError::CredentialStorage)?;
    if bytes.len() > maximum_bytes as usize
        || bytes.len() as u64 != before.len()
        || !descriptor_after.is_file()
    {
        return Err(ProviderError::CredentialStorage);
    }
    #[cfg(unix)]
    if !cursor_same_file(&before, &descriptor_after) || !cursor_same_file(&before, &path_after) {
        return Err(ProviderError::CredentialStorage);
    }
    #[cfg(not(unix))]
    if before.len() != descriptor_after.len()
        || before.len() != path_after.len()
        || before
            .modified()
            .map_err(|_| ProviderError::CredentialStorage)?
            != descriptor_after
                .modified()
                .map_err(|_| ProviderError::CredentialStorage)?
        || before
            .modified()
            .map_err(|_| ProviderError::CredentialStorage)?
            != path_after
                .modified()
                .map_err(|_| ProviderError::CredentialStorage)?
    {
        return Err(ProviderError::CredentialStorage);
    }
    Ok(bytes)
}

fn secret_from_bytes(bytes: &[u8]) -> Result<Secret, ProviderError> {
    let value = std::str::from_utf8(bytes).map_err(|_| ProviderError::Authentication)?;
    secret_from_text(value)
}

fn secret_from_text(value: &str) -> Result<Secret, ProviderError> {
    let value = value.trim();
    if value.is_empty() || value.len() > 16_384 || value.chars().any(char::is_control) {
        return Err(ProviderError::Authentication);
    }
    Ok(Secret(value.into()))
}

pub(super) async fn cache_token(id: &str, context: &ProviderContext) -> Option<Secret> {
    match id {
        "cursor" => cursor_token(context).await.ok(),
        "grok" => grok_token(context).await.ok(),
        _ => None,
    }
}

#[cfg(all(test, unix))]
#[path = "cursor_wal_tests.rs"]
mod cursor_wal_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::{Clock, CredentialStore, http::fixture};
    use serde_json::json;
    use std::sync::Arc;

    #[cfg(target_os = "macos")]
    use std::{
        path::{Path, PathBuf},
        process::Command as StdCommand,
        sync::atomic::{AtomicU64, Ordering},
    };

    #[cfg(target_os = "macos")]
    static NEXT_TEMP_DIRECTORY: AtomicU64 = AtomicU64::new(0);

    #[cfg(target_os = "macos")]
    struct TemporaryDirectory(PathBuf);

    #[cfg(target_os = "macos")]
    impl TemporaryDirectory {
        fn new() -> Self {
            for attempt in 0..128 {
                let ordinal = NEXT_TEMP_DIRECTORY.fetch_add(1, Ordering::Relaxed);
                let path = std::env::temp_dir().join(format!(
                    "quotio-oauth-editors-{}-{ordinal}-{attempt}",
                    std::process::id()
                ));
                if std::fs::create_dir(&path).is_ok() {
                    return Self(path);
                }
            }
            panic!("could not create synthetic Cursor database directory");
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    #[cfg(target_os = "macos")]
    impl Drop for TemporaryDirectory {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[cfg(target_os = "macos")]
    fn create_cursor_database(path: &Path, token: &str) {
        let statement = format!(
            "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '{token}');"
        );
        let status = StdCommand::new("/usr/bin/sqlite3")
            .arg(path)
            .arg(statement)
            .status()
            .unwrap();
        assert!(status.success());
    }

    struct FixedClock;
    impl Clock for FixedClock {
        fn now(&self) -> OffsetDateTime {
            OffsetDateTime::UNIX_EPOCH
        }
    }

    struct Credentials;
    impl CredentialStore for Credentials {
        fn get(&self, name: &str) -> Option<Secret> {
            match name {
                "CURSOR_ACCESS_TOKEN" => Some(Secret("cursor-native-token".into())),
                "GROK_OAUTH_TOKEN" => Some(Secret("Bearer grok-native-token".into())),
                "KIMI_CODE_API_KEY" => Some(Secret("kimi-code-key".into())),
                _ => None,
            }
        }
    }

    fn context() -> ProviderContext {
        ProviderContext {
            http: reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .unwrap(),
            clock: Arc::new(FixedClock),
            credentials: Arc::new(Credentials),
        }
    }

    #[tokio::test]
    async fn cursor_uses_native_bearer_rpc_without_cookie() {
        let (base, server) = fixture::server(vec![json!({
            "enabled": true,
            "billingCycleEnd": "2026-09-12T00:00:00Z",
            "planUsage": {
                "totalPercentUsed": 25,
                "autoPercentUsed": 10,
                "apiPercentUsed": 15
            }
        })])
        .await;
        let usage = fetch_cursor_at(&context(), &format!("{base}/cursor"))
            .await
            .unwrap();
        assert_eq!(usage.windows.len(), 3);
        assert_eq!(usage.windows[0].label, "Current period");
        let request = server.await.unwrap().pop().unwrap();
        let lower = request.to_ascii_lowercase();
        assert!(request.starts_with("POST /cursor HTTP/1.1"));
        assert!(lower.contains("authorization: bearer cursor-native-token"));
        assert!(lower.contains("connect-protocol-version: 1"));
        assert!(!lower.contains("\r\ncookie:"));
        assert!(request.ends_with("{}"));
    }

    #[test]
    fn cursor_summary_preserves_swift_plan_amounts_and_unknown_values() {
        let key = Secret("fixture".into());
        let now = OffsetDateTime::UNIX_EPOCH;
        let usage = cursor_summary(
            &json!({
                "membershipType": "pro_student",
                "billingCycleEnd": "2030-01-02T03:04:05.000Z",
                "individualUsage": {
                    "plan": {"enabled": true, "used": 20, "limit": 100, "remaining": 80},
                    "onDemand": {"enabled": true, "used": 4, "limit": 10, "remaining": 6}
                }
            }),
            &key,
            now,
        )
        .unwrap();
        assert_eq!(usage.account.plan.as_deref(), Some("Pro Student"));
        assert_eq!(usage.windows[0].metric_id.as_deref(), Some("plan-usage"));
        assert_eq!(usage.windows[0].quota, Quota::from_remaining(Some(80.0)));
        assert_eq!(usage.windows[1].quota, Quota::from_remaining(Some(60.0)));
        assert!(usage.windows[0].resets_at.is_some());
        assert!(usage.windows[1].resets_at.is_none());
        for plan in [
            json!({"enabled":true}),
            json!({"enabled":true,"limit":0,"used":0}),
            json!({"enabled":true,"limit":100}),
        ] {
            let usage =
                cursor_summary(&json!({"individualUsage":{"plan":plan}}), &key, now).unwrap();
            assert_eq!(usage.windows[0].quota, Quota::Unknown);
        }
        let zero = cursor_summary(&json!({"individualUsage":{"plan":{"enabled":true,"used":100,"limit":100,"remaining":0}}}), &key, now).unwrap();
        assert!(matches!(zero.windows[0].quota, Quota::Exhausted { .. }));
        let unlimited = cursor_summary(&json!({"isUnlimited":true}), &key, now).unwrap();
        assert_eq!(unlimited.windows[0].quota, Quota::Unlimited);
        assert!(unlimited.windows[0].resets_at.is_none());
        assert!(cursor_summary(&json!({}), &key, now).is_err());
    }

    #[test]
    fn cursor_summary_keeps_valid_sibling_and_source_reset() {
        let key = Secret("fixture".into());
        let usage = cursor_summary(
            &json!({
                "billingCycleEnd":"1970-01-01T00:00:00Z",
                "individualUsage":{
                    "plan":{"enabled":true,"used":1,"limit":10},
                    "onDemand":{"enabled":true,"used":"invalid"}
                }
            }),
            &key,
            OffsetDateTime::UNIX_EPOCH + time::Duration::days(1),
        )
        .unwrap();
        assert_eq!(usage.windows.len(), 1);
        assert_eq!(usage.windows[0].resets_at, Some(OffsetDateTime::UNIX_EPOCH));
        assert_eq!(usage.diagnostics.len(), 1);
        assert_eq!(usage.diagnostics[0].source, "cursor_onDemand");
    }

    #[tokio::test]
    async fn cursor_combines_endpoints_and_preserves_partial_success() {
        for (summary_status, period_status) in [(200, 200), (500, 200), (200, 500)] {
            let (summary_url, summary_server) = fixture::server_status(vec![(summary_status, json!({
                "membershipType":"pro", "individualUsage":{"plan":{"enabled":true,"used":20,"limit":100}}
            }))]).await;
            let (period_url, period_server) = fixture::server_status(vec![(
                period_status,
                json!({
                    "planUsage":{"totalPercentUsed":20}
                }),
            )])
            .await;
            let usage = fetch_cursor_complete_at(&context(), &period_url, &summary_url)
                .await
                .unwrap();
            assert_eq!(
                usage.windows.len(),
                if summary_status == 200 && period_status == 200 {
                    2
                } else {
                    1
                }
            );
            assert_eq!(
                usage.diagnostics.len(),
                usize::from(summary_status != 200 || period_status != 200)
            );
            let request = summary_server.await.unwrap().pop().unwrap();
            assert!(request.starts_with("GET / HTTP/1.1"));
            assert!(
                !request
                    .lines()
                    .next()
                    .unwrap()
                    .contains("cursor-native-token")
            );
            assert!(!request.to_ascii_lowercase().contains("\r\ncookie:"));
            period_server.await.unwrap();
        }
    }

    #[tokio::test]
    async fn cursor_keeps_summary_when_period_exceeds_collection_deadline() {
        let (summary_url, summary_server) =
            fixture::server(vec![json!({"isUnlimited":true})]).await;
        let (period_url, period_server) = fixture::server_status_with_async_action(
            vec![(200, json!({"planUsage":{"totalPercentUsed":20}}))],
            |_| async {
                tokio::time::sleep(Duration::from_secs(1)).await;
            },
        )
        .await;
        let context = context();
        let deadline = tokio::time::Instant::now() + Duration::from_millis(200);
        let usage = crate::providers::FETCH_DEADLINE
            .scope(
                deadline,
                tokio::time::timeout_at(
                    deadline,
                    fetch_cursor_complete_at(&context, &period_url, &summary_url),
                ),
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(usage.windows[0].quota, Quota::Unlimited);
        assert_eq!(usage.diagnostics[0].code, ProviderError::Timeout);
        summary_server.await.unwrap();
        period_server.abort();
    }

    #[test]
    fn cursor_rejects_out_of_range_usage() {
        assert_eq!(
            cursor_windows(
                &json!({"planUsage": {"totalPercentUsed": 101}}),
                OffsetDateTime::UNIX_EPOCH
            )
            .err(),
            Some(ProviderError::InvalidData)
        );
    }

    #[test]
    fn cursor_login_metadata_rejects_duplicates_and_missing_tokens() {
        let login = cursor_login_from_output(br#"[{"key":"cursorAuth/accessToken","value":"fixture"},{"key":"cursorAuth/cachedEmail","value":"cursor@example.com"},{"key":"cursorAuth/stripeMembershipType","value":"pro_student"},{"key":"cursorAuth/stripeSubscriptionStatus","value":"active"}]"#).unwrap();
        assert_eq!(login.email.as_deref(), Some("cursor@example.com"));
        assert_eq!(login.membership.as_deref(), Some("pro_student"));
        assert_eq!(login.subscription_status.as_deref(), Some("active"));
        assert!(cursor_login_from_output(br#"[{"key":"cursorAuth/accessToken","value":"one"},{"key":"cursorAuth/accessToken","value":"two"}]"#).is_err());
        let optional = cursor_login_from_output(br#"[{"key":"cursorAuth/accessToken","value":"fixture"},{"key":"cursorAuth/cachedEmail","value":""},{"key":"cursorAuth/stripeMembershipType","value":null},{"key":"cursorAuth/stripeSubscriptionStatus","value":""}]"#).unwrap();
        assert!(optional.email.is_none());
        assert!(optional.membership.is_none());
        assert!(optional.subscription_status.is_none());
        assert!(matches!(
            cursor_login_from_output(b"[]"),
            Err(ProviderError::Authentication)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn sqlite_output_requires_verified_limit_and_schema_with_optional_setter_echo() {
        for output in [
            "              length 1048576\n1\n[]\n",
            "              length 1048576\n              length 1048576\n1\n[]\n",
        ] {
            assert_eq!(sqlite_query_payload(output.as_bytes()).unwrap(), b"[]\n");
        }
        for output in [
            "1\n[]\n",
            "length 2048\n1\n[]\n",
            "length 1048576\n0\n[]\n",
            "length 1048576\n",
        ] {
            assert_eq!(
                sqlite_query_payload(output.as_bytes()),
                Err(ProviderError::Unavailable)
            );
        }
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn cursor_login_reads_metadata_without_database_writes() {
        let dir = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("state with spaces.vscdb");
        create_cursor_database(&path, "fixture-native");
        let before = std::fs::read(&path).unwrap();
        let login = cursor_login(path.clone()).await.unwrap();
        assert_eq!(login.token, "fixture-native");
        assert_eq!(before, std::fs::read(&path).unwrap());
        let link = dir.join("linked.vscdb");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(cursor_login(link).await.is_err());
        std::fs::write(dir.join("state with spaces.vscdb-wal"), b"fixture").unwrap();
        assert!(cursor_login(path).await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn cursor_sqlite_output_accepts_exactly_one_token() {
        assert_eq!(
            cursor_token_from_sqlite_output(b"cursor-native-token\n")
                .unwrap()
                .unwrap()
                .0,
            "cursor-native-token"
        );
        assert_eq!(
            cursor_token_from_sqlite_output(b"first\nsecond\n").err(),
            Some(ProviderError::InvalidData)
        );
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn cursor_snapshot_rejects_path_replacement() {
        let directory = TemporaryDirectory::new();
        let database = directory.path().join("state.vscdb");
        create_cursor_database(&database, "opened-token");
        let snapshot = open_cursor_database(&database).unwrap().unwrap();

        let replacement = directory.path().join("replacement.vscdb");
        create_cursor_database(&replacement, "replacement-token");
        std::fs::rename(&replacement, &database).unwrap();

        let output = cursor_sqlite_output(&snapshot).await.unwrap();
        assert!(!cursor_database_remains_safe(&snapshot).unwrap());
        assert_eq!(
            cursor_token_from_sqlite_output(&output).unwrap().unwrap().0,
            "opened-token"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn native_reader_rejects_symlink_at_open() {
        let directory = TemporaryDirectory::new();
        let target = directory.path().join("target");
        std::fs::write(&target, b"fixture").unwrap();
        let link = directory.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert_eq!(
            open_readonly_file(&link).err(),
            Some(ProviderError::CredentialStorage)
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn cursor_rejects_malformed_wal() {
        let directory = TemporaryDirectory::new();
        let database = directory.path().join("state.vscdb");
        create_cursor_database(&database, "fixture-token");
        std::fs::write(format!("{}-wal", database.display()), b"synthetic-wal").unwrap();
        assert_eq!(
            open_cursor_database(&database).err(),
            Some(ProviderError::InvalidData)
        );
    }

    #[tokio::test]
    async fn grok_owned_refresh_uses_fixed_form_and_rejects_bad_responses() {
        use crate::accounts::Credential;
        let old = Credential::GrokOAuth {
            access_token: "old".into(),
            refresh_token: "fixture+refresh&".into(),
            expires_at: 0,
            refresh_pending: true,
        };
        for (status, body, success) in [
            (
                200,
                json!({"access_token":"new","refresh_token":"rotated","expires_in":3600}),
                true,
            ),
            (200, json!({"access_token":"new","expires_in":3600}), true),
            (200, json!({"access_token":"new","expires_in":0}), false),
            (
                200,
                json!({"access_token":"new","refresh_token":"","expires_in":3600}),
                false,
            ),
            (200, json!({"access_token":"new"}), false),
            (401, json!({"error":"fixture"}), false),
            (503, json!({"error":"fixture"}), false),
        ] {
            let (endpoint, server) =
                crate::providers::http::fixture::server_status(vec![(status, body)]).await;
            let result = refresh_grok_at(&context(), &old, &endpoint).await;
            assert_eq!(result.is_ok(), success);
            if let Ok(Credential::GrokOAuth {
                refresh_pending,
                expires_at,
                ..
            }) = result
            {
                assert!(!refresh_pending);
                assert!(expires_at > 0);
            }
            let requests = server.await.unwrap();
            assert_eq!(requests.len(), 1);
            assert!(requests[0].starts_with("POST "));
            assert!(requests[0].contains("grant_type=refresh_token"));
            assert!(requests[0].contains("refresh_token=fixture%2Brefresh%26"));
            assert!(!requests[0].to_ascii_lowercase().contains("authorization:"));
        }
    }

    #[tokio::test]
    async fn grok_uses_cli_oauth_proxy_without_cookie() {
        let (base, server) = fixture::server(vec![json!({
            "config": {
                "creditUsagePercent": 30,
                "currentPeriod": {
                    "type": "USAGE_PERIOD_TYPE_WEEKLY",
                    "end": "2026-09-12T00:00:00Z"
                }
            }
        })])
        .await;
        let usage = fetch_grok_at(&context(), &format!("{base}/billing?format=credits"))
            .await
            .unwrap();
        assert_eq!(usage.windows[0].label, "Weekly");
        let request = server.await.unwrap().pop().unwrap();
        let lower = request.to_ascii_lowercase();
        assert!(request.starts_with("GET /billing?format=credits HTTP/1.1"));
        assert!(lower.contains("authorization: bearer grok-native-token"));
        assert!(lower.contains("x-xai-token-auth: xai-grok-cli"));
        assert!(!lower.contains("\r\ncookie:"));
    }

    #[test]
    fn grok_unified_billing_without_usage_does_not_imply_zero_percent() {
        let (windows, diagnostics) = grok_windows(&json!({"config": {
            "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-10-03T00:00:00Z"},
            "isUnifiedBillingUser": true, "onDemandCap": {"val": 0},
            "onDemandUsed": {"val": 0}, "prepaidBalance": {"val": 0}
        }}), OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(windows[0].quota, Quota::Unknown);
        assert!(windows[0].amounts.is_none());
        assert!(windows[0].consumption.is_none());
        assert_eq!(
            windows[0].note.as_deref(),
            Some("Grok did not report usage for this period.")
        );
        assert_eq!(windows[1].quota, Quota::Disabled);
        assert!(diagnostics.is_empty());
    }

    #[test]
    fn grok_preserves_caps_unknown_and_partial_billing_fields() {
        let now = OffsetDateTime::UNIX_EPOCH;
        for cap in [None, Some(0.0), Some(2500.0)] {
            let mut config = json!({"creditUsagePercent":25,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"1970-01-01T00:00:00Z"}});
            if let Some(cap) = cap {
                config["onDemandCap"] = json!({"val":cap});
            }
            let (windows, diagnostics) = grok_windows(&json!({"config":config}), now).unwrap();
            assert_eq!(windows[0].metric_id.as_deref(), Some("grok-weekly"));
            assert_eq!(windows[0].quota, Quota::from_remaining(Some(75.0)));
            assert_eq!(windows[0].resets_at, Some(now));
            assert!(windows[1].resets_at.is_none());
            assert_eq!(
                windows[1].quota,
                match cap {
                    None => Quota::Unknown,
                    Some(0.0) => Quota::Disabled,
                    Some(amount) => Quota::Limit {
                        amount,
                        unit: "units".into()
                    },
                }
            );
            assert_eq!(
                serde_json::to_value(&windows[1].provenance.confidence).unwrap(),
                if cap.is_some() { "exact" } else { "unknown" }
            );
            assert!(diagnostics.is_empty());
        }
        let (windows, diagnostics) = grok_windows(
            &json!({"config":{"creditUsagePercent":"invalid","onDemandCap":{"val":2500}}}),
            now,
        )
        .unwrap();
        assert_eq!(windows[0].quota, Quota::Unknown);
        assert!(matches!(
            windows[1].quota,
            Quota::Limit { amount: 2500.0, .. }
        ));
        assert_eq!(diagnostics[0].source, "grok_credits");
        let (windows, diagnostics) = grok_windows(
            &json!({"config":{"creditUsagePercent":0,"onDemandCap":{"val":-1}}}),
            now,
        )
        .unwrap();
        assert_eq!(windows[0].quota, Quota::from_used(Some(0.0)));
        assert_eq!(windows[1].quota, Quota::Unknown);
        assert_eq!(diagnostics[0].source, "grok_extra_usage");
        assert!(
            !Quota::Limit {
                amount: f64::NAN,
                unit: "units".into()
            }
            .is_valid()
        );
        assert!(
            !Quota::Limit {
                amount: 0.0,
                unit: "units".into()
            }
            .is_valid()
        );
    }

    #[tokio::test]
    async fn grok_settings_failures_do_not_remove_billing_quota() {
        for status in [200, 500] {
            let (billing, billing_server) = fixture::server(vec![
                json!({"config":{"creditUsagePercent":25,"onDemandCap":{"val":2500}}}),
            ])
            .await;
            let (settings, settings_server) = fixture::server_status(vec![(
                status,
                json!({"subscription_tier_display":"SuperGrok"}),
            )])
            .await;
            let usage = fetch_grok_complete_at(&context(), &billing, Some(&settings))
                .await
                .unwrap();
            assert_eq!(
                usage.account.plan.as_deref(),
                if status == 200 {
                    Some("SuperGrok")
                } else {
                    None
                }
            );
            assert_eq!(usage.diagnostics.len(), usize::from(status != 200));
            assert!(matches!(
                usage.windows[1].quota,
                Quota::Limit { amount: 2500.0, .. }
            ));
            assert!(
                !serde_json::to_string(&usage)
                    .unwrap()
                    .contains("grok-native-token")
            );
            let request = settings_server.await.unwrap().pop().unwrap();
            assert!(request.starts_with("GET / HTTP/1.1"));
            assert!(
                request
                    .to_ascii_lowercase()
                    .contains("x-xai-token-auth: xai-grok-cli")
            );
            billing_server.await.unwrap();
        }
    }

    #[test]
    fn grok_native_auth_requires_one_fresh_oidc_entry() {
        let token = json!({
            "https://auth.x.ai::fixture-client": {
                "key": "grok-native-token",
                "expires_at": "2026-09-12T00:00:00Z"
            }
        })
        .to_string();
        assert_eq!(
            grok_native_token_from_bytes(token.as_bytes(), OffsetDateTime::UNIX_EPOCH)
                .unwrap()
                .0,
            "grok-native-token"
        );
        let multiple = json!({
            "https://auth.x.ai::one": {"key": "one", "expires_at": "2026-09-12T00:00:00Z"},
            "https://auth.x.ai::two": {"key": "two", "expires_at": "2026-09-12T00:00:00Z"}
        })
        .to_string();
        assert_eq!(
            grok_native_token_from_bytes(multiple.as_bytes(), OffsetDateTime::UNIX_EPOCH).err(),
            Some(ProviderError::Authentication)
        );
        let expired = json!({
            "https://auth.x.ai::fixture-client": {
                "key": "expired-token",
                "expires_at": "1970-01-01T00:00:00Z"
            }
        })
        .to_string();
        assert_eq!(
            grok_native_token_from_bytes(expired.as_bytes(), OffsetDateTime::UNIX_EPOCH).err(),
            Some(ProviderError::Authentication)
        );
    }

    #[test]
    fn grok_does_not_make_missing_percent_zero() {
        let (windows, _) = grok_windows(&json!({"config":{}}), OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(windows[0].quota, Quota::Unknown);
        assert_eq!(windows[1].quota, Quota::Unknown);
    }

    #[tokio::test]
    async fn kimi_uses_code_key_without_web_session() {
        let (base, server) = fixture::server(vec![json!({
            "usage": {
                "limit": "100",
                "used": "25",
                "reset_time": "2026-09-12T00:00:00Z"
            },
            "limits": [{
                "window": {"duration": 5, "timeUnit": "TIME_UNIT_HOUR"},
                "detail": {"limit": 20, "remaining": 15, "resetAt": "2026-09-06T05:00:00Z"}
            }]
        })])
        .await;
        let usage = fetch_kimi_at(&context(), &format!("{base}/coding/v1/usages"))
            .await
            .unwrap();
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].label, "Code 7-day");
        assert_eq!(usage.windows[1].label, "Rate limit (5 hours)");
        let request = server.await.unwrap().pop().unwrap();
        let lower = request.to_ascii_lowercase();
        assert!(request.starts_with("GET /coding/v1/usages HTTP/1.1"));
        assert!(lower.contains("authorization: bearer kimi-code-key"));
        assert!(!lower.contains("\r\ncookie:"));
    }

    #[test]
    fn kimi_rejects_web_tokens_and_missing_counts() {
        assert_eq!(
            validate_kimi_code_key(Secret("header.payload.signature".into())).err(),
            Some(ProviderError::Authentication)
        );
        assert_eq!(
            kimi_windows(
                &json!({"usage": {"limit": 100}}),
                OffsetDateTime::UNIX_EPOCH
            )
            .err(),
            Some(ProviderError::InvalidData)
        );
    }
}
