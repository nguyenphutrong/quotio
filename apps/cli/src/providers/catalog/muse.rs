//! Muse Code (Meta) subscription quota.
//!
//! The Muse Code CLI keeps a pointer at `~/.config/muse/auth.json` that carries no
//! secret and stores the credential in the login keychain under service
//! `ai.meta.dev.credentials`, account `meta`. That payload holds two values: the Model
//! API key the CLI sends to `api.meta.ai/v1`, and the Meta account access token from the
//! device grant. Only the account token reads subscription usage, so the Model API key
//! is never read here.
//!
//! Meta publishes no quota endpoint. The one machine-readable snapshot is the
//! `subs_usage` object returned by the subscription-key endpoint, which makes this an
//! auth-plane read rather than a metered inference call. The response body also carries
//! the key itself, so only the usage, tier and subscription-state fields are parsed out
//! of it.

use super::{AuthKind, Definition, common};
use crate::{
    domain::{ProviderUsage, QuotaWindow, UsageDiagnostic},
    error::ProviderError,
    providers::{FetchFuture, ProviderContext, Secret, http},
};
use serde_json::Value;
use std::time::Duration;
use time::OffsetDateTime;

const KEY_URL: &str = "https://api.meta.ai/muse-code/key";
const KEYCHAIN_SERVICE: &str = "ai.meta.dev.credentials";
const KEYCHAIN_ACCOUNT: &str = "meta";
/// Meta rejects the subscription-key endpoint without it.
const API_VERSION: &str = "1.0.0";
/// Meta's rolling window, identified by its declared duration rather than assumed.
const FIVE_HOUR_WINDOW_MINS: f64 = 300.0;
/// Measured live (2026-09-16) against this Keychain item: the first read of any
/// process's lifetime took 4.68s before returning successfully, then 4ms on every read
/// after — a one-time authorization-evaluation cost, not a per-call one. Cursor's and
/// Grok's shared 1s budget (oauth_editors.rs) is tuned for their own items and is too
/// tight for this one; kept as a separate constant so raising it cannot change their
/// behavior.
const NATIVE_READ_TIMEOUT: Duration = Duration::from_secs(10);

pub const DEFINITIONS: &[Definition] = &[Definition {
    id: "muse",
    name: "Muse Code",
    key_env: "MUSE_OAUTH_TOKEN",
    auth: AuthKind::OAuth,
    settings: &[],
    fetch: muse,
}];

fn muse(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(async move { fetch_muse_at(context, KEY_URL).await })
}

pub(super) async fn cache_token(context: &ProviderContext) -> Option<Secret> {
    token(context).await.ok()
}

async fn fetch_muse_at(
    context: &ProviderContext,
    endpoint: &str,
) -> Result<ProviderUsage, ProviderError> {
    let key = token(context).await?;
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
            .header("x-api-version", API_VERSION)
            // No `onboard`: this is a read. Onboarding on a poll would be a side effect
            // on the user's account.
            .body("{}"),
        now,
    )
    .await?;
    usage(&root, &key, now)
}

fn usage(root: &Value, key: &Secret, now: OffsetDateTime) -> Result<ProviderUsage, ProviderError> {
    let active = root.get("is_subs_active").and_then(Value::as_bool);
    // A confirmed-inactive subscription reports its state instead of inventing windows;
    // anything else builds both fixed windows even when Meta's response carries neither.
    // Measured live against a real, active "Muse Code High Usage" subscription: the
    // subscription-key endpoint answered is_subs_active: true with no subs_usage object
    // at all. Meta appears to only attach it around a mint, not on every read, so that
    // shape is a normal "not observed yet" state, not a fetch failure.
    let (windows, diagnostics) = if active == Some(false) {
        (Vec::new(), Vec::new())
    } else {
        windows(root.get("subs_usage"), now)?
    };
    let mut account = common::account_identity("muse", key, "cli-oauth");
    account.label = "Muse Code subscription".into();
    account.plan = text(root.get("subs_tier_name"), 128);
    account.subscription_status =
        active.map(|active| if active { "active" } else { "inactive" }.to_owned());
    Ok(ProviderUsage {
        reset_credits: None,
        antigravity_subscription: None,
        codex_profile: None,
        codex_reset_credits: None,
        provider: crate::domain::ProviderId("muse".into()),
        account,
        account_ref: None,
        windows,
        diagnostics,
    })
}

/// Reads the rolling and weekly windows.
///
/// Always returns both, even when `usage` is absent or carries neither sub-object: a
/// window with no readable percentage is reported as `Quota::Unknown`, this codebase's
/// existing "not observed" state (see e.g. `grok_windows`'s fixed pair below), rather
/// than omitted. Omitting it would read as "this account has no such window" instead of
/// "this read did not carry it".
///
/// A window whose declared duration is not the five-hour one is carried under its own
/// label rather than filed as the session window: reporting a longer window as the
/// five-hour one would understate usage by the ratio between them.
fn windows(
    usage: Option<&Value>,
    now: OffsetDateTime,
) -> Result<(Vec<QuotaWindow>, Vec<UsageDiagnostic>), ProviderError> {
    let mut diagnostics = Vec::new();
    let mut read = |value: Option<&Value>, source: &str| match value.map(percentage) {
        Some(Ok(value)) => value,
        Some(Err(code)) => {
            diagnostics.push(UsageDiagnostic {
                source: source.into(),
                code,
            });
            None
        }
        None => None,
    };

    let session = usage
        .and_then(|u| u.get("window"))
        .filter(|v| v.is_object());
    let used = read(session.and_then(|s| s.get("used_percent")), "muse_window");
    let minutes = common::number(session.and_then(|s| s.get("window_duration_mins")))?;
    let (id, label) = match minutes {
        None | Some(FIVE_HOUR_WINDOW_MINS) => ("muse-session".to_owned(), "Session".to_owned()),
        Some(minutes) => (
            format!("muse-window-{}", minutes as i64),
            duration_label(minutes),
        ),
    };
    let mut windows = vec![percent_window(
        &label,
        &id,
        used,
        common::date(session.and_then(|s| s.get("resets_at")))?,
        now,
    )?];

    let weekly = usage
        .and_then(|u| u.get("weekly"))
        .filter(|v| v.is_object());
    let used = read(weekly.and_then(|w| w.get("used_percent")), "muse_weekly");
    windows.push(percent_window(
        "Weekly",
        "muse-weekly",
        used,
        common::date(weekly.and_then(|w| w.get("resets_at")))?,
        now,
    )?);
    Ok((windows, diagnostics))
}

fn percent_window(
    label: &str,
    id: &str,
    used: Option<f64>,
    resets_at: Option<OffsetDateTime>,
    now: OffsetDateTime,
) -> Result<QuotaWindow, ProviderError> {
    let mut window = common::window(
        label,
        used,
        Some(100.0),
        None,
        "percent",
        resets_at,
        "muse_cli_oauth",
        now,
    )?;
    window.metric_id = Some(id.into());
    Ok(window)
}

fn duration_label(minutes: f64) -> String {
    let minutes = minutes as i64;
    if minutes > 0 && minutes % 60 == 0 {
        format!("{}h window", minutes / 60)
    } else {
        format!("{minutes}m window")
    }
}

fn percentage(value: &Value) -> Result<Option<f64>, ProviderError> {
    match common::number(Some(value))? {
        Some(value) if (0.0..=100.0).contains(&value) => Ok(Some(value)),
        Some(_) => Err(ProviderError::InvalidData),
        None => Ok(None),
    }
}

fn text(value: Option<&Value>, limit: usize) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty() && s.len() <= limit && !s.chars().any(char::is_control))
        .map(str::to_owned)
}

async fn token(context: &ProviderContext) -> Result<Secret, ProviderError> {
    if context.credentials.get("MUSE_OAUTH_TOKEN").is_some() {
        return secret(&common::key(context, "MUSE_OAUTH_TOKEN")?.0);
    }
    blocking(|| {
        let bytes = common::read_keychain(KEYCHAIN_SERVICE, Some(KEYCHAIN_ACCOUNT))?
            .ok_or(ProviderError::Authentication)?;
        account_token(&bytes)
    })
    .await
}

/// The keychain payload also holds the Model API key; it is deliberately not read.
fn account_token(bytes: &[u8]) -> Result<Secret, ProviderError> {
    let root: Value = serde_json::from_slice(bytes).map_err(|_| ProviderError::InvalidData)?;
    let token = root
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or(ProviderError::Authentication)?;
    secret(token)
}

fn secret(value: &str) -> Result<Secret, ProviderError> {
    let value = value.trim();
    if value.is_empty() || value.len() > 16_384 || value.chars().any(char::is_control) {
        return Err(ProviderError::Authentication);
    }
    Ok(Secret(value.into()))
}

async fn blocking<T: Send + 'static>(
    operation: impl FnOnce() -> Result<T, ProviderError> + Send + 'static,
) -> Result<T, ProviderError> {
    match tokio::time::timeout(NATIVE_READ_TIMEOUT, tokio::task::spawn_blocking(operation)).await {
        Ok(Ok(result)) => result,
        Ok(Err(_)) | Err(_) => Err(ProviderError::CredentialStorage),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::Quota;
    use crate::providers::{Clock, CredentialStore, http::fixture};
    use serde_json::json;
    use std::sync::Arc;

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
                "MUSE_OAUTH_TOKEN" => Some(Secret("meta-account-token".into())),
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

    fn key() -> Secret {
        Secret("meta-account-token".into())
    }

    #[tokio::test]
    async fn posts_the_account_token_and_reads_both_windows() {
        let (base, server) = fixture::server(vec![json!({
            "api_key": "LLM|1234567890|key-material",
            "is_subs_active": true,
            "subs_tier_name": "Muse Code Pro",
            "subs_usage": {
                "tier": "1234567890",
                "window": {"used_percent": 12, "resets_at": 1788431188, "window_duration_mins": 300},
                "weekly": {"used_percent": 40, "resets_at": 1788739200}
            }
        })])
        .await;

        let usage = fetch_muse_at(&context(), &format!("{base}/muse-code/key"))
            .await
            .unwrap();

        assert_eq!(usage.account.plan.as_deref(), Some("Muse Code Pro"));
        assert_eq!(usage.account.subscription_status.as_deref(), Some("active"));
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|w| w.metric_id.as_deref().unwrap())
                .collect::<Vec<_>>(),
            ["muse-session", "muse-weekly"]
        );
        assert_eq!(usage.windows[0].quota, Quota::from_remaining(Some(88.0)));
        assert_eq!(usage.windows[1].quota, Quota::from_remaining(Some(60.0)));
        assert_eq!(
            usage.windows[0].resets_at,
            Some(OffsetDateTime::from_unix_timestamp(1_788_431_188).unwrap())
        );

        let request = server.await.unwrap().pop().unwrap();
        let lower = request.to_ascii_lowercase();
        assert!(request.starts_with("POST /muse-code/key HTTP/1.1"));
        // The account token reads usage; the Model API key alongside it must not be sent.
        assert!(lower.contains("authorization: bearer meta-account-token"));
        assert!(lower.contains("x-api-version: 1.0.0"));
        assert!(request.ends_with("{}"));
        assert!(!request.contains("onboard"));
    }

    #[test]
    fn never_carries_the_model_api_key_out_of_the_response() {
        let usage = usage(
            &json!({
                "api_key": "LLM|1234567890|key-material",
                "is_subs_active": true,
                "subs_tier_name": "Muse Code Pro",
                "subs_usage": {"weekly": {"used_percent": 1, "resets_at": 1788739200}}
            }),
            &key(),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();

        let rendered = serde_json::to_string(&usage).unwrap();
        assert!(!rendered.contains("LLM|"));
        assert!(!rendered.contains("key-material"));
    }

    #[test]
    fn carries_a_window_of_another_duration_under_its_own_label() {
        let usage = usage(
            &json!({
                "is_subs_active": true,
                "subs_usage": {
                    "window": {"used_percent": 25, "resets_at": 1788431188, "window_duration_mins": 600}
                }
            }),
            &key(),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();

        assert_eq!(
            usage.windows[0].metric_id.as_deref(),
            Some("muse-window-600")
        );
        assert_eq!(usage.windows[0].label, "10h window");
        assert_eq!(usage.windows[0].quota, Quota::from_remaining(Some(75.0)));
    }

    #[test]
    fn a_window_without_a_declared_duration_stays_the_session_window() {
        let usage = usage(
            &json!({"subs_usage": {"window": {"used_percent": 0}}}),
            &key(),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();

        assert_eq!(usage.windows[0].metric_id.as_deref(), Some("muse-session"));
        assert!(usage.windows[0].resets_at.is_none());
    }

    #[test]
    fn an_inactive_subscription_reports_its_state_instead_of_inventing_windows() {
        let usage = usage(
            &json!({"is_subs_active": false, "subs_tier_name": "Muse Code Free"}),
            &key(),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();

        assert!(usage.windows.is_empty());
        assert_eq!(
            usage.account.subscription_status.as_deref(),
            Some("inactive")
        );
        assert_eq!(usage.account.plan.as_deref(), Some("Muse Code Free"));
    }

    /// Reproduces the real response of an active "Muse Code High Usage" subscription,
    /// measured live 2026-09-16: `is_subs_active: true` with no `subs_usage` object at
    /// all. Meta appears to only attach it around a mint, not on every read. Both fixed
    /// windows must still be reported, as Unknown rather than as a fetch failure — the
    /// account and plan were read correctly.
    #[test]
    fn an_active_subscription_with_no_subs_usage_reports_unknown_windows_not_an_error() {
        let usage = usage(
            &json!({
                "is_subs_active": true,
                "subs_tier_name": "Muse Code High Usage",
                "user_email": "user@example.test"
            }),
            &key(),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();

        assert_eq!(usage.account.subscription_status.as_deref(), Some("active"));
        assert_eq!(usage.account.plan.as_deref(), Some("Muse Code High Usage"));
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|w| w.metric_id.as_deref().unwrap())
                .collect::<Vec<_>>(),
            ["muse-session", "muse-weekly"]
        );
        assert!(usage.windows.iter().all(|w| w.quota == Quota::Unknown));
        assert!(
            usage.diagnostics.is_empty(),
            "an absent field is not malformed data"
        );
    }

    #[test]
    fn an_active_subscription_with_an_empty_subs_usage_object_is_the_same_as_absent() {
        let usage = usage(
            &json!({"is_subs_active": true, "subs_usage": {}}),
            &key(),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();

        assert!(usage.windows.iter().all(|w| w.quota == Quota::Unknown));
    }

    #[test]
    fn one_window_present_and_the_other_absent_are_reported_independently() {
        let usage = usage(
            &json!({
                "is_subs_active": true,
                "subs_usage": {"weekly": {"used_percent": 10, "resets_at": 1_788_739_200}}
            }),
            &key(),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();

        assert_eq!(
            usage.windows[0].quota,
            Quota::Unknown,
            "session was not reported"
        );
        assert_eq!(usage.windows[1].quota, Quota::from_remaining(Some(90.0)));
        assert!(usage.windows[1].resets_at.is_some());
    }

    #[test]
    fn an_out_of_range_percentage_is_reported_as_a_diagnostic_not_a_quota() {
        let usage = usage(
            &json!({
                "is_subs_active": true,
                "subs_usage": {
                    "window": {"used_percent": 250, "window_duration_mins": 300},
                    "weekly": {"used_percent": 10}
                }
            }),
            &key(),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();

        assert_eq!(usage.windows[0].quota, Quota::Unknown);
        assert_eq!(usage.diagnostics[0].source, "muse_window");
        assert_eq!(usage.windows[1].quota, Quota::from_remaining(Some(90.0)));
    }

    #[test]
    fn the_keychain_payload_yields_the_account_token_and_rejects_anything_else() {
        assert_eq!(
            account_token(br#"{"api_key":"LLM|1|k","access_token":"meta-account-token"}"#)
                .unwrap()
                .0,
            "meta-account-token"
        );
        assert!(matches!(
            account_token(br#"{"api_key":"LLM|1|k"}"#),
            Err(ProviderError::Authentication)
        ));
        assert!(matches!(
            account_token(b"not json"),
            Err(ProviderError::InvalidData)
        ));
        assert!(matches!(
            account_token(br#"{"access_token":"  "}"#),
            Err(ProviderError::Authentication)
        ));
    }

    #[test]
    fn duration_labels_prefer_whole_hours() {
        assert_eq!(duration_label(600.0), "10h window");
        assert_eq!(duration_label(90.0), "90m window");
        assert_eq!(duration_label(0.0), "0m window");
    }
}
