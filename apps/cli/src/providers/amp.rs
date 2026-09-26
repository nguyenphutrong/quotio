use super::{FetchFuture, ProviderAdapter, ProviderContext, process};
use crate::{domain::*, error::ProviderError};
use std::{
    io::Read,
    path::{Path, PathBuf},
    sync::Arc,
};
use time::OffsetDateTime;

pub struct AmpProvider {
    pub executable: PathBuf,
    pub credential_path: Option<PathBuf>,
}
impl Default for AmpProvider {
    fn default() -> Self {
        Self {
            executable: "amp".into(),
            credential_path: directories::BaseDirs::new()
                .map(|dirs| dirs.home_dir().join(".local/share/amp/secrets.json")),
        }
    }
}
fn number(input: &str) -> Result<f64, ProviderError> {
    let value: f64 = input
        .trim()
        .replace(',', "")
        .parse()
        .map_err(|_| ProviderError::InvalidData)?;
    if !value.is_finite() || value < 0.0 {
        return Err(ProviderError::InvalidData);
    }
    Ok(value)
}
fn percent(input: &str) -> Result<f64, ProviderError> {
    let prefix = input.split_once('%').ok_or(ProviderError::InvalidData)?.0;
    let numeric = prefix.trim();
    if numeric.is_empty() || !numeric.chars().all(|c| c.is_ascii_digit() || c == '.') {
        return Err(ProviderError::InvalidData);
    }
    let value = number(numeric)?;
    if value > 100.0 {
        return Err(ProviderError::InvalidData);
    }
    Ok(value)
}
fn window(
    label: &str,
    quota: Quota,
    amounts: Option<QuotaAmounts>,
    now: OffsetDateTime,
    reset_description: Option<String>,
) -> QuotaWindow {
    let metric_id = match label {
        "Amp Free daily" => "amp-free".into(),
        "Agent Usage" => "amp-agent-usage".into(),
        "Orb Usage" => "amp-orb-usage".into(),
        "Individual credits" => "amp-individual-credits".into(),
        _ => {
            let name = label
                .strip_prefix("Workspace ")
                .and_then(|v| v.strip_suffix(" credits"))
                .unwrap_or(label);
            let digest =
                ring::digest::digest(&ring::digest::SHA256, name.trim().to_lowercase().as_bytes());
            format!(
                "amp-workspace-{}",
                digest.as_ref()[..8]
                    .iter()
                    .map(|b| format!("{b:02x}"))
                    .collect::<String>()
            )
        }
    };
    QuotaWindow {
        note: None,
        metric_id: Some(metric_id),
        consumption: amounts.as_ref().and_then(|a| {
            a.limit.map(|limit| Consumption {
                used: limit - a.remaining,
                unit: a.unit.clone(),
            })
        }),
        reset_description,
        label: label.into(),
        provenance: Provenance {
            source: "amp_cli_usage".into(),
            confidence: if quota == Quota::Unknown && amounts.is_none() {
                Confidence::Unknown
            } else {
                Confidence::Estimated
            },
        },
        quota,
        amounts,
        resets_at: None,
        fetched_at: now,
    }
}
fn reset_description(text: &str) -> Option<String> {
    if text.contains("(resets daily)") {
        return Some("daily".into());
    }
    if let Some((_, rest)) = text.split_once("resets upon renewal in ") {
        let mut words = rest.split_whitespace();
        if let (Some(count), Some(unit)) = (words.next(), words.next()) {
            let unit = unit.trim_end_matches([',', '.']);
            if count.bytes().all(|c| c.is_ascii_digit())
                && count.parse::<u32>().is_ok()
                && matches!(
                    unit,
                    "minute"
                        | "minutes"
                        | "hour"
                        | "hours"
                        | "day"
                        | "days"
                        | "week"
                        | "weeks"
                        | "month"
                        | "months"
                        | "year"
                        | "years"
                )
            {
                return Some(format!("upon renewal in {count} {unit}"));
            }
        }
    }
    let (_, period) = text.split_once(" - period ")?;
    let (_, end) = period.split_once(" to ")?;
    let date = end.split_whitespace().next()?.trim_end_matches(',');
    time::Date::parse(
        date,
        time::macros::format_description!("[year]-[month]-[day]"),
    )
    .ok()?;
    Some(format!("billing period ends {date} (timezone unspecified)"))
}
fn balance(input: &str, unit: &str) -> Result<QuotaAmounts, ProviderError> {
    let (remaining, rest) = input.split_once(unit).ok_or(ProviderError::InvalidData)?;
    let limit = rest
        .strip_prefix(" of ")
        .map(|rest| {
            rest.split_once(unit)
                .ok_or(ProviderError::InvalidData)
                .and_then(|(value, _)| number(value))
        })
        .transpose()?;
    Ok(QuotaAmounts {
        remaining: number(remaining)?,
        limit,
        unit: "hours".into(),
    })
}
fn dollars(input: &str) -> Result<QuotaAmounts, ProviderError> {
    let input = input.trim_start();
    let rest = input.strip_prefix('$').unwrap_or(input);
    let (remaining, rest) = rest
        .split_once(char::is_whitespace)
        .ok_or(ProviderError::InvalidData)?;
    let limit = rest
        .trim_start()
        .strip_prefix("of $")
        .map(|rest| {
            rest.split_once(' ')
                .ok_or(ProviderError::InvalidData)
                .and_then(|(value, _)| number(value))
        })
        .transpose()?;
    Ok(QuotaAmounts {
        remaining: number(remaining)?,
        limit,
        unit: "USD".into(),
    })
}
fn quota(amounts: &QuotaAmounts) -> Quota {
    Quota::from_remaining(
        amounts
            .limit
            .filter(|limit| *limit > 0.0)
            .map(|limit| 100.0 * amounts.remaining / limit),
    )
}
pub(crate) fn parse(input: &str, now: OffsetDateTime) -> Result<ProviderUsage, ProviderError> {
    let mut clean = String::new();
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            for c in chars.by_ref() {
                if ('@'..='~').contains(&c) {
                    break;
                }
            }
        } else {
            clean.push(c);
        }
    }
    let input = clean.as_str();
    let identity = input
        .lines()
        .find_map(|line| line.trim().strip_prefix("Signed in as "))
        .ok_or(ProviderError::Authentication)?;
    let email = identity
        .split(" (")
        .next()
        .filter(|s| s.contains('@') && !s.contains(char::is_whitespace))
        .ok_or(ProviderError::InvalidData)?;
    let mut plan = identity
        .split_once(" (")
        .and_then(|(_, rest)| rest.strip_suffix(')'))
        .map(str::to_owned);
    let mut windows = Vec::new();
    for raw_line in input.lines() {
        let normalized = raw_line.replace("**", "");
        let line = normalized.trim();
        if let Some(rest) = line.strip_prefix("Amp Free:") {
            let rest = rest.trim_start();
            let (quota, amounts, reset) = if let Some((remaining, limit)) = rest
                .split_once("remaining")
                .and_then(|(amounts, _)| amounts.split_once('/'))
            {
                let amounts = QuotaAmounts {
                    remaining: number(
                        remaining
                            .trim()
                            .strip_prefix('$')
                            .unwrap_or(remaining.trim()),
                    )?,
                    limit: Some(number(
                        limit.trim().strip_prefix('$').unwrap_or(limit.trim()),
                    )?),
                    unit: "USD".into(),
                };
                if amounts
                    .limit
                    .is_none_or(|l| l <= 0.0 || amounts.remaining > l)
                {
                    return Err(ProviderError::InvalidData);
                }
                let reset = rest
                    .split_once("(replenishes +")
                    .and_then(|(_, r)| r.split_once("/hour)"))
                    .and_then(|(rate, _)| number(rate.trim_start_matches('$')).ok())
                    .map(|rate| format!("replenishes +${rate}/hour"));
                (quota(&amounts), Some(amounts), reset)
            } else {
                (
                    Quota::from_remaining(Some(percent(rest)?)),
                    None,
                    reset_description(rest),
                )
            };
            windows.push(window("Amp Free daily", quota, amounts, now, reset));
        } else if let Some((name, rest)) = line.strip_prefix("Amp ").and_then(|s| {
            s.split_once(" Subscription: ")
                .or_else(|| s.split_once(" Tier: "))
        }) {
            if name.trim().is_empty() {
                return Err(ProviderError::InvalidData);
            }
            plan = Some(name.trim().into());
            if !rest.starts_with("agent usage ") {
                let (agent, orb) = rest.split_once(" and ").ok_or(ProviderError::InvalidData)?;
                if !(agent.contains("% other usage") || agent.contains("% agent usage"))
                    || !orb.contains("% orb usage remaining")
                {
                    return Err(ProviderError::InvalidData);
                }
                windows.push(window(
                    "Agent Usage",
                    Quota::from_remaining(Some(percent(agent)?)),
                    None,
                    now,
                    reset_description(rest),
                ));
                windows.push(window(
                    "Orb Usage",
                    Quota::from_remaining(Some(percent(orb)?)),
                    None,
                    now,
                    reset_description(rest),
                ));
                continue;
            }
            let rest = rest.strip_prefix("agent usage ").unwrap();
            let amounts = dollars(rest)?;
            if amounts
                .limit
                .is_none_or(|l| l <= 0.0 || amounts.remaining > l)
            {
                return Err(ProviderError::InvalidData);
            }
            windows.push(window(
                "Agent Usage",
                quota(&amounts),
                Some(amounts),
                now,
                reset_description(rest),
            ));
            if let Some((_, rest)) = rest.split_once(", orb usage ") {
                let amounts = balance(rest, "h")?;
                if amounts
                    .limit
                    .is_none_or(|l| l <= 0.0 || amounts.remaining > l)
                {
                    return Err(ProviderError::InvalidData);
                }
                windows.push(window(
                    "Orb Usage",
                    quota(&amounts),
                    Some(amounts),
                    now,
                    reset_description(rest),
                ));
            }
        } else if let Some(rest) = line.strip_prefix("Individual credits:") {
            let amounts = dollars(rest)?;
            windows.push(window(
                "Individual credits",
                Quota::Unknown,
                Some(amounts),
                now,
                None,
            ));
        } else if let Some(rest) = line.strip_prefix("Workspace ") {
            let (name, rest) = rest.split_once(':').ok_or(ProviderError::InvalidData)?;
            let amounts = dollars(rest)?;
            windows.push(window(
                &format!("Workspace {name} credits"),
                Quota::Unknown,
                Some(amounts),
                now,
                None,
            ));
        } else if raw_line.starts_with("**") || line.starts_with("Amp ") && !line.trim().is_empty()
        {
            // Do not silently omit a newly introduced quota category.
            return Err(ProviderError::InvalidData);
        }
    }
    if windows.is_empty() {
        return Err(ProviderError::InvalidData);
    }
    Ok(ProviderUsage {
        reset_credits: None,
        antigravity_subscription: None,
        codex_profile: None,
        codex_reset_credits: None,
        diagnostics: vec![],
        account_ref: None,
        provider: ProviderId("amp".into()),
        account: AccountIdentity {
            verified: None,
            subscription_status: None,
            plan,
            id: email.into(),
            label: email.into(),
        },
        windows,
    })
}
pub struct AmpApiProvider;
impl AmpApiProvider {
    pub(crate) async fn fetch_api(
        &self,
        context: &ProviderContext,
        endpoint: &str,
    ) -> Result<ProviderUsage, ProviderError> {
        let key = context
            .credentials
            .get("AMP_API_KEY")
            .ok_or(ProviderError::Authentication)?;
        let response: serde_json::Value = super::http::json(
            context
                .http
                .post(endpoint)
                .header(
                    "Authorization",
                    super::http::sensitive(&format!("Bearer {}", key.0))?,
                )
                .header("Accept", "application/json")
                .json(&serde_json::json!({"method":"userDisplayBalanceInfo","params":{}})),
            context.clock.now(),
        )
        .await?;
        if response
            .pointer("/error/code")
            .and_then(serde_json::Value::as_str)
            == Some("auth-required")
        {
            return Err(ProviderError::Authentication);
        }
        if response.get("ok").and_then(serde_json::Value::as_bool) == Some(false) {
            return Err(ProviderError::InvalidData);
        }
        let text = response
            .pointer("/result/displayText")
            .and_then(serde_json::Value::as_str)
            .ok_or(ProviderError::InvalidData)?;
        let mut usage = parse(text, context.clock.now())?;
        for window in &mut usage.windows {
            window.provenance.source = "amp_api".into();
        }
        Ok(usage)
    }
}
impl ProviderAdapter for AmpApiProvider {
    fn id(&self) -> ProviderId {
        ProviderId("amp".into())
    }
    fn idempotent(&self) -> bool {
        true
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(self.fetch_api(
            context,
            "https://ampcode.com/api/internal?userDisplayBalanceInfo",
        ))
    }
}
struct ApiKey(String);
impl super::CredentialStore for ApiKey {
    fn get(&self, name: &str) -> Option<super::Secret> {
        (name == "AMP_API_KEY").then(|| super::Secret(self.0.clone()))
    }
}
pub(crate) fn local_key(path: &Path) -> Result<Option<String>, ProviderError> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(ProviderError::Authentication),
    };
    let metadata = file.metadata().map_err(|_| ProviderError::Authentication)?;
    if !metadata.is_file() || metadata.len() > 1024 * 1024 {
        return Err(ProviderError::InvalidData);
    }
    let mut bytes = Vec::new();
    file.take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ProviderError::Authentication)?;
    if bytes.len() > 1024 * 1024 {
        return Err(ProviderError::InvalidData);
    }
    let value: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| ProviderError::InvalidData)?;
    let mut present = false;
    for name in ["apiKey@https://ampcode.com/", "apiKey@https://ampcode.com"] {
        if let Some(value) = value.get(name) {
            present = true;
            if let Some(token) = value
                .as_str()
                .map(str::trim)
                .filter(|s| !s.is_empty() && s.len() <= 16_384 && !s.chars().any(char::is_control))
            {
                return Ok(Some(token.into()));
            }
        }
    }
    if present {
        Err(ProviderError::Authentication)
    } else {
        Ok(None)
    }
}
impl AmpProvider {
    pub(crate) fn has_local_key(&self) -> Result<bool, ProviderError> {
        self.credential_path
            .as_ref()
            .map_or(Ok(false), |path| local_key(path).map(|key| key.is_some()))
    }
    async fn api_context(
        &self,
        context: &ProviderContext,
    ) -> Result<Option<ProviderContext>, ProviderError> {
        if context
            .credentials
            .get("AMP_URL")
            .is_some_and(|url| url.0.trim_end_matches('/') != "https://ampcode.com")
        {
            return Ok(None);
        }
        if context.credentials.get("AMP_API_KEY").is_some() {
            return Ok(Some(context.clone()));
        }
        let Some(path) = self.credential_path.clone() else {
            return Ok(None);
        };
        let key = tokio::task::spawn_blocking(move || local_key(&path))
            .await
            .map_err(|_| ProviderError::Internal)??;
        Ok(key.map(|key| ProviderContext {
            http: context.http.clone(),
            clock: context.clock.clone(),
            credentials: Arc::new(ApiKey(key)),
        }))
    }
}
impl ProviderAdapter for AmpProvider {
    fn cache_identity<'a>(
        &'a self,
        context: &'a ProviderContext,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<String>> + Send + 'a>> {
        Box::pin(async move {
            let context = self.api_context(context).await.ok()??;
            crate::cache::environment_identity("amp", &context)
        })
    }

    fn account_ref(&self) -> Option<AccountRef> {
        Some(AccountRef {
            origin: None,
            id: "local".into(),
            label: "Local Amp account".into(),
        })
    }
    fn id(&self) -> ProviderId {
        ProviderId("amp".into())
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            if let Some(api_context) = self.api_context(context).await? {
                return AmpApiProvider.fetch(&api_context).await;
            }
            let bytes = process::output(&self.executable, &["usage"]).await?;
            let text = std::str::from_utf8(&bytes).map_err(|_| ProviderError::InvalidData)?;
            parse(text, context.clock.now())
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    const FIXTURE: &str = "Signed in as demo@example.com (demo)\n**Amp Free:** 75% remaining today (resets daily) - https://ampcode.com/settings#amp-free\n**Amp Megawatt Subscription:** agent usage $12 of $20 remaining (60%), orb usage 500.5h of 750h a1.small orb hours remaining (67%) - period 2026-08-19 to 2026-09-19, resets upon renewal in 13 days\n**Individual credits:** $10.25 remaining (set up auto-reload to avoid running out) - https://ampcode.com/settings\n**Workspace Example:** $0 remaining - https://ampcode.com/workspaces/example\n";
    #[test]
    fn amp_displays_email_and_short_usage_labels() {
        let usage = parse(FIXTURE, OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(usage.account.label, "demo@example.com");
        assert_eq!(usage.account.plan.as_deref(), Some("Megawatt"));
        for (id, label) in [
            ("amp-agent-usage", "Agent Usage"),
            ("amp-orb-usage", "Orb Usage"),
        ] {
            assert_eq!(
                usage
                    .windows
                    .iter()
                    .find(|window| window.metric_id.as_deref() == Some(id))
                    .unwrap()
                    .label,
                label
            );
        }
    }
    #[test]
    fn current_tier_label_is_supported() {
        let usage = parse(
            &FIXTURE.replace("Megawatt Subscription:", "Megawatt Tier:"),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(usage.account.plan.as_deref(), Some("Megawatt"));
        assert_eq!(usage.windows.len(), 5);
    }
    #[test]
    fn swift_amount_free_and_named_subscription_keep_ids_consumption_and_reset_description() {
        let text = "\x1b[32mSigned in as demo@example.com (Pro)\x1b[0m\nAmp Free: $2.50 / $10.00 remaining (replenishes +$0.50/hour)\nAmp Kilowatt Subscription: 60% agent usage and 25% orb usage remaining - resets upon renewal in 2 days\nIndividual credits: $0 remaining\nWorkspace Example: $12.50 remaining";
        let usage = parse(text, OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(usage.account.plan.as_deref(), Some("Kilowatt"));
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|w| w.metric_id.as_deref().unwrap())
                .collect::<Vec<_>>()[..4],
            [
                "amp-free",
                "amp-agent-usage",
                "amp-orb-usage",
                "amp-individual-credits"
            ]
        );
        assert_eq!(usage.windows[0].consumption.as_ref().unwrap().used, 7.5);
        assert_eq!(usage.windows[0].quota, Quota::from_remaining(Some(25.0)));
        assert_eq!(usage.windows[1].label, "Agent Usage");
        assert_eq!(usage.windows[2].quota, Quota::from_remaining(Some(25.0)));
        assert!(usage.windows.iter().all(|w| w.resets_at.is_none()));
        assert_eq!(
            usage.windows[0].reset_description.as_deref(),
            Some("replenishes +$0.5/hour")
        );
        assert_eq!(
            usage.windows[1].reset_description.as_deref(),
            Some("upon renewal in 2 days")
        );
        assert_eq!(usage.windows[3].quota, Quota::Unknown);
        let alternate = parse(
            &text.replace("Workspace Example:", "Workspace EXAMPLE:"),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(usage.windows[4].metric_id, alternate.windows[4].metric_id);
    }
    #[test]
    fn flexible_amount_spacing_and_optional_credit_currency_preserve_uncertainty() {
        for separator in ["/", " /", "/ ", "  /  ", "\t/\t"] {
            for currency in ["", "$"] {
                let text = format!(
                    "Signed in as demo@example.com\nAmp Free:\t$2.50{separator}$10.00 remaining (replenishes +$0.50/hour)\nIndividual credits:\t{currency}1,234.50\tremaining\nWorkspace Example:{currency}12.50 remaining"
                );
                let usage = parse(&text, OffsetDateTime::UNIX_EPOCH).unwrap();
                assert_eq!(usage.windows.len(), 3);
                assert_eq!(usage.windows[0].quota, Quota::from_remaining(Some(25.0)));
                assert_eq!(
                    usage.windows[0].reset_description.as_deref(),
                    Some("replenishes +$0.5/hour")
                );
                assert_eq!(usage.windows[1].amounts.as_ref().unwrap().remaining, 1234.5);
                assert_eq!(usage.windows[2].amounts.as_ref().unwrap().remaining, 12.5);
                for window in &usage.windows[1..] {
                    assert_eq!(window.quota, Quota::Unknown);
                    assert!(window.amounts.as_ref().unwrap().limit.is_none());
                    assert!(window.reset_description.is_none());
                }
                assert!(
                    usage
                        .windows
                        .iter()
                        .all(|window| window.resets_at.is_none())
                );
            }
        }
    }
    #[test]
    fn flexible_amounts_still_reject_invalid_values() {
        for value in ["-1", "NaN", "inf", "1e999", "bad", "$$1"] {
            for line in [
                format!("Individual credits: {value} remaining"),
                format!("Workspace Example: {value} remaining"),
                format!("Amp Free: {value}/$10 remaining"),
                format!("Amp Free: $1/{value} remaining"),
            ] {
                assert!(
                    parse(
                        &format!("Signed in as demo@example.com\n{line}"),
                        OffsetDateTime::UNIX_EPOCH,
                    )
                    .is_err(),
                    "accepted {line}"
                );
            }
        }
    }
    #[test]
    fn rejects_inconsistent_amounts_instead_of_clamping_to_available() {
        for text in [
            "Amp Free: $11 / $10 remaining",
            "Amp Free: $0 / $0 remaining",
            "Amp Kilowatt Subscription: agent usage $21 of $20 remaining (100%), orb usage 1h of 2h remaining",
        ] {
            assert!(
                parse(
                    &format!("Signed in as demo@example.com\n{text}"),
                    OffsetDateTime::UNIX_EPOCH
                )
                .is_err()
            );
        }
    }
    #[test]
    fn empty_slash_key_can_use_the_native_non_slash_alias_without_writes() {
        let dir = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("secrets.json");
        let bytes =
            br#"{"apiKey@https://ampcode.com/":" ","apiKey@https://ampcode.com":"fixture-key"}"#;
        std::fs::write(&path, bytes).unwrap();
        assert_eq!(local_key(&path).unwrap().as_deref(), Some("fixture-key"));
        assert_eq!(std::fs::read(&path).unwrap(), bytes);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn local_discovery_requires_a_public_host_key() {
        let path =
            std::env::temp_dir().join(format!("quotio-amp-discovery-{}.json", std::process::id()));
        let provider = AmpProvider {
            executable: "missing-amp".into(),
            credential_path: Some(path.clone()),
        };
        for contents in [
            r#"{}"#,
            r#"{"apiKey@https://custom.example.invalid/":"synthetic"}"#,
        ] {
            std::fs::write(&path, contents).unwrap();
            assert!(!provider.has_local_key().unwrap());
        }
        std::fs::write(&path, r#"{"apiKey@https://ampcode.com/":"synthetic"}"#).unwrap();
        assert!(provider.has_local_key().unwrap());
        std::fs::write(&path, "invalid-json").unwrap();
        assert!(provider.has_local_key().is_err());
        std::fs::remove_file(&path).unwrap();
        assert!(!provider.has_local_key().unwrap());
    }
    #[test]
    fn parse_all_categories_without_inventing_credit_quota() {
        let usage = parse(FIXTURE, OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(usage.windows.len(), 5);
        assert_eq!(usage.windows[0].quota, Quota::from_used(Some(25.0)));
        assert_eq!(usage.windows[1].quota, Quota::from_used(Some(40.0)));
        assert_eq!(usage.windows[2].amounts.as_ref().unwrap().remaining, 500.5);
        assert_eq!(usage.windows[4].quota, Quota::Unknown);
        assert_eq!(usage.windows[4].amounts.as_ref().unwrap().remaining, 0.0);
        assert!(usage.windows.iter().all(|w| w.resets_at.is_none()));
    }
    #[test]
    fn format_drift_and_missing_identity_fail() {
        assert!(
            parse(
                "Signed in as demo@example.com (demo)\n**New quota:** 50%",
                OffsetDateTime::UNIX_EPOCH
            )
            .is_err()
        );
        assert!(parse("Please log in", OffsetDateTime::UNIX_EPOCH).is_err());
        assert!(
            parse(
                &FIXTURE.replace("75%", "unknown%"),
                OffsetDateTime::UNIX_EPOCH
            )
            .is_err()
        );
    }
    #[test]
    fn reject_malformed_percentage_tokens() {
        for token in ["-5%", "1e2%", "1,2%", "105%"] {
            assert!(
                parse(&FIXTURE.replace("75%", token), OffsetDateTime::UNIX_EPOCH).is_err(),
                "accepted malformed percentage"
            );
        }
    }
    #[tokio::test]
    async fn api_uses_bearer_and_preserves_parsed_balances() {
        use std::sync::Arc;
        struct Keys;
        impl super::super::CredentialStore for Keys {
            fn get(&self, name: &str) -> Option<super::super::Secret> {
                (name == "AMP_API_KEY").then(|| super::super::Secret("synthetic-key".into()))
            }
        }
        let (url, task) = super::super::http::fixture::server(vec![
            serde_json::json!({"ok":true,"result":{"displayText":FIXTURE.replace("**", "")}}),
        ])
        .await;
        let mut context = super::super::http::fixture::context();
        context.credentials = Arc::new(Keys);
        let usage = AmpApiProvider.fetch_api(&context, &url).await.unwrap();
        assert_eq!(usage.windows.len(), 5);
        assert_eq!(usage.windows[0].provenance.source, "amp_api");
        let requests = task.await.unwrap();
        assert!(requests[0].starts_with("POST / "));
        assert!(requests[0].contains("Bearer synthetic-key"));
        assert!(requests[0].contains("userDisplayBalanceInfo"));
        assert!(!requests[0].to_lowercase().contains("cookie:"));
    }
    #[test]
    fn plain_api_response_preserves_subscription_usage_and_balances() {
        let api_text = FIXTURE.replace("**", "");
        let usage = parse(&api_text, OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(usage.windows.len(), 5);
        assert_eq!(usage.windows[1].quota, Quota::from_used(Some(40.0)));
        assert_eq!(usage.windows[2].amounts.as_ref().unwrap().remaining, 500.5);
    }
    #[test]
    fn balance_only_text_does_not_claim_unknown_usage() {
        let usage = parse(&FIXTURE.replace("**", ""), OffsetDateTime::UNIX_EPOCH).unwrap();
        let text = crate::output::text::render(&UsageReport {
            schema_version: 1,
            generated_at: OffsetDateTime::UNIX_EPOCH,
            providers: vec![usage],
            failures: vec![],
        });
        assert!(text.contains("used 8.00 of 20 USD"));
        let balance = text
            .lines()
            .find(|line| line.contains("Individual credits:"))
            .unwrap();
        assert!(balance.contains("balance 10.25 USD remaining"));
        assert!(!balance.contains("unknown"));
        assert!(text.contains("Workspace Example credits: balance 0.00 USD remaining"));
    }
    #[tokio::test]
    async fn local_key_is_bounded_and_used_only_for_public_amp_host() {
        let directory = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("secrets.json");
        std::fs::write(
            &path,
            br#"{"apiKey@https://ampcode.com/":"synthetic-local-key"}"#,
        )
        .unwrap();
        let provider = AmpProvider {
            executable: PathBuf::from("not-used"),
            credential_path: Some(path.clone()),
        };
        let original = std::fs::read(&path).unwrap();
        let api = provider
            .api_context(&super::super::http::fixture::context())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            api.credentials.get("AMP_API_KEY").unwrap().0,
            "synthetic-local-key"
        );
        assert_eq!(std::fs::read(&path).unwrap(), original);
        #[cfg(unix)]
        {
            let link = directory.join("link.json");
            std::os::unix::fs::symlink(&path, &link).unwrap();
            assert!(local_key(&link).is_err());
            std::fs::remove_file(link).unwrap();
        }
        struct CustomHost;
        impl super::super::CredentialStore for CustomHost {
            fn get(&self, name: &str) -> Option<super::super::Secret> {
                (name == "AMP_URL").then(|| super::super::Secret("https://example.invalid".into()))
            }
        }
        let mut context = super::super::http::fixture::context();
        context.credentials = Arc::new(CustomHost);
        assert!(provider.api_context(&context).await.unwrap().is_none());
        std::fs::write(&path, vec![b'x'; 1024 * 1024 + 1]).unwrap();
        assert!(local_key(&path).is_err());
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }
    #[test]
    fn reset_descriptions_are_preserved_without_fabricating_timestamps() {
        for text in [FIXTURE.to_owned(), FIXTURE.replace("**", "")] {
            let usage = parse(&text, OffsetDateTime::UNIX_EPOCH).unwrap();
            assert_eq!(usage.windows[0].reset_description.as_deref(), Some("daily"));
            for window in &usage.windows[1..3] {
                assert_eq!(
                    window.reset_description.as_deref(),
                    Some("upon renewal in 13 days")
                );
            }
            assert!(usage.windows.iter().all(|w| w.resets_at.is_none()));
            assert!(
                usage.windows[3..]
                    .iter()
                    .all(|w| w.reset_description.is_none())
            );
            let value = serde_json::to_value(&usage).unwrap();
            assert!(value["windows"][1]["resets_at"].is_null());
            assert_eq!(
                value["windows"][1]["reset_description"],
                "upon renewal in 13 days"
            );
            let rendered = crate::output::text::render(&UsageReport {
                schema_version: 1,
                generated_at: OffsetDateTime::UNIX_EPOCH,
                providers: vec![usage],
                failures: vec![],
            });
            assert!(rendered.contains("reset daily"));
            assert!(rendered.contains("reset upon renewal in 13 days"));
            assert!(!rendered.contains("reset unknown"));
        }
    }
    #[test]
    fn reset_description_uses_date_only_fallback_and_keeps_missing_unknown() {
        assert_eq!(
            reset_description("remaining - period 2026-01-01 to 2026-02-01"),
            Some("billing period ends 2026-02-01 (timezone unspecified)".into())
        );
        assert!(reset_description("remaining - period 2026-01-01 to 2026-02-31").is_none());
        assert!(reset_description("remaining").is_none());
        assert!(reset_description("resets upon renewal in many days").is_none());
        let mut usage = parse(FIXTURE, OffsetDateTime::UNIX_EPOCH).unwrap();
        usage.windows[0].resets_at = Some(OffsetDateTime::UNIX_EPOCH);
        let rendered = crate::output::text::render(&UsageReport {
            schema_version: 1,
            generated_at: OffsetDateTime::UNIX_EPOCH,
            providers: vec![usage],
            failures: vec![],
        });
        assert!(rendered.contains("reset 1970-01-01T00:00:00Z"));
        assert!(!rendered.contains("reset daily"));
    }
}
