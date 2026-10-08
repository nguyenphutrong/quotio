use super::{FetchFuture, ProviderAdapter, ProviderContext, process};
use crate::{accounts::Credential, domain::*, error::ProviderError};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::BTreeMap, path::PathBuf};
use time::OffsetDateTime;
use tokio::io::{AsyncWriteExt, BufReader};

pub struct CodexProvider {
    pub executable: PathBuf,
}
impl Default for CodexProvider {
    fn default() -> Self {
        Self {
            executable: "codex".into(),
        }
    }
}
#[derive(Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Account {
    #[serde(rename = "type")]
    kind: String,
    email: Option<String>,
    plan_type: Option<String>,
}
#[derive(Deserialize)]
struct AccountResponse {
    account: Option<Account>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Window {
    used_percent: Option<f64>,
    window_duration_mins: Option<u64>,
    resets_at: Option<i64>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Bucket {
    limit_id: Option<String>,
    limit_name: Option<String>,
    primary: Option<Window>,
    secondary: Option<Window>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Limits {
    rate_limits: Option<Bucket>,
    rate_limits_by_limit_id: Option<BTreeMap<String, Bucket>>,
}

fn account(value: Value) -> Result<Account, ProviderError> {
    let value: AccountResponse =
        serde_json::from_value(value).map_err(|_| ProviderError::InvalidData)?;
    let account = value.account.ok_or(ProviderError::Authentication)?;
    if account.kind != "chatgpt" {
        return Err(ProviderError::Authentication);
    }
    if account
        .email
        .as_ref()
        .is_none_or(|email| email.trim().is_empty())
    {
        return Err(ProviderError::InvalidData);
    }
    Ok(account)
}
pub(crate) fn metric_segment(value: &str) -> String {
    let mut normalized = String::new();
    let mut separator = false;
    for character in value.chars().flat_map(char::to_lowercase) {
        if character.is_ascii_alphanumeric() {
            if separator && !normalized.is_empty() {
                normalized.push('-');
            }
            normalized.push(character);
            separator = false;
        } else {
            separator = true;
        }
    }
    let normalized = normalized.trim_end_matches('-');
    if normalized.is_empty() {
        "codex".into()
    } else {
        normalized.into()
    }
}
fn parse(
    account: Account,
    value: Value,
    now: OffsetDateTime,
) -> Result<ProviderUsage, ProviderError> {
    let credits = value
        .get("rateLimitResetCredits")
        .filter(|v| !v.is_null())
        .cloned();
    let limits: Limits = serde_json::from_value(value).map_err(|_| ProviderError::InvalidData)?;
    let buckets = match limits.rate_limits_by_limit_id {
        Some(map) if !map.is_empty() => map,
        _ => {
            let bucket = limits.rate_limits.ok_or(ProviderError::InvalidData)?;
            BTreeMap::from([(
                bucket.limit_id.clone().unwrap_or_else(|| "codex".into()),
                bucket,
            )])
        }
    };
    let mut windows = Vec::new();
    for (id, bucket) in buckets {
        let name = bucket
            .limit_name
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| id.clone());
        let prefix = if id == "codex" {
            String::new()
        } else if name.to_ascii_lowercase().contains("codex-spark") || name == "Codex Spark" {
            "Codex Spark ".into()
        } else {
            format!("{name} ")
        };
        let durations = [
            bucket.primary.as_ref().and_then(|w| w.window_duration_mins),
            bucket
                .secondary
                .as_ref()
                .and_then(|w| w.window_duration_mins),
        ];
        let mut bucket_windows = Vec::new();
        for (index, window) in [bucket.primary, bucket.secondary].into_iter().enumerate() {
            let Some(window) = window else { continue };
            let (order, period) = match durations[index] {
                Some(300) => (0, "Session"),
                Some(10080) => (1, "Weekly"),
                None => match durations[1 - index] {
                    Some(10080) => (0, "Session"),
                    Some(300) => (1, "Weekly"),
                    _ if index == 0 => (0, "Session"),
                    _ => (1, "Weekly"),
                },
                Some(_) => (2, "Quota"),
            };
            let quota = Quota::from_used(window.used_percent);
            let reset = window
                .resets_at
                .map(OffsetDateTime::from_unix_timestamp)
                .transpose()
                .map_err(|_| ProviderError::InvalidData)?;
            let label = if period == "Quota" {
                format!("{prefix}Quota {}", index + 1)
            } else {
                format!("{prefix}{period}")
            };
            let bucket_id = metric_segment(&id);
            let metric_period = if period == "Quota" {
                format!("quota-{}", index + 1)
            } else {
                period.to_ascii_lowercase()
            };
            let confidence = if quota == Quota::Unknown {
                Confidence::Unknown
            } else {
                Confidence::Exact
            };
            bucket_windows.push((
                order,
                QuotaWindow {
                    note: None,
                    metric_id: Some(format!("{bucket_id}-{metric_period}")),
                    consumption: None,
                    reset_description: None,
                    amounts: None,
                    label,
                    quota,
                    resets_at: reset,
                    fetched_at: now,
                    provenance: Provenance {
                        source: "codex_app_server".into(),
                        confidence,
                    },
                },
            ));
        }
        bucket_windows.sort_by_key(|(order, _)| *order);
        windows.extend(bucket_windows.into_iter().map(|(_, window)| window));
    }
    let email = account.email.ok_or(ProviderError::InvalidData)?;
    let mut usage = ProviderUsage {
        fresh_observation: false,
        history_identity: None,
        reset_credits: None,
        antigravity_subscription: None,
        codex_profile: None,
        codex_reset_credits: None,
        diagnostics: vec![],
        account_ref: None,
        provider: ProviderId("codex".into()),
        account: AccountIdentity {
            verified: None,
            subscription_status: None,
            plan: account.plan_type,
            id: email.clone(),
            label: email,
        },
        windows,
    };
    if let Some(credits) = credits {
        super::codex_reset_credits::attach(
            &mut usage,
            super::codex_reset_credits::parse(credits, true, now),
        );
    }
    Ok(usage)
}
pub(crate) fn parse_direct(
    email: &str,
    value: Value,
    now: OffsetDateTime,
) -> Result<ProviderUsage, ProviderError> {
    parse(
        Account {
            kind: "chatgpt".into(),
            email: Some(email.into()),
            plan_type: None,
        },
        value,
        now,
    )
}
async fn rpc(
    reader: &mut BufReader<tokio::process::ChildStdout>,
    writer: &mut tokio::process::ChildStdin,
    id: u64,
    method: &str,
    params: Value,
) -> Result<Value, ProviderError> {
    let request = format!("{}\n", json!({"id":id,"method":method,"params":params}));
    writer
        .write_all(request.as_bytes())
        .await
        .map_err(|_| ProviderError::Unavailable)?;
    // Notifications are allowed, but a peer cannot flood us indefinitely.
    for _ in 0..128 {
        let value: Value = serde_json::from_slice(&process::line(reader).await?)
            .map_err(|_| ProviderError::InvalidData)?;
        if value.get("id").and_then(Value::as_u64) != Some(id) {
            continue;
        }
        if value.get("error").is_some() {
            return Err(ProviderError::Unavailable);
        }
        return value
            .get("result")
            .cloned()
            .ok_or(ProviderError::InvalidData);
    }
    Err(ProviderError::InvalidData)
}
impl CodexProvider {
    async fn connect(
        &self,
    ) -> Result<
        (
            tokio::process::Child,
            tokio::process::ChildStdin,
            BufReader<tokio::process::ChildStdout>,
        ),
        ProviderError,
    > {
        let mut child = process::spawn(&self.executable, &["app-server", "--stdio"])?;
        let mut writer = child.stdin.take().ok_or(ProviderError::Internal)?;
        let mut reader = BufReader::new(child.stdout.take().ok_or(ProviderError::Internal)?);
        rpc(&mut reader, &mut writer, 1, "initialize", json!({"clientInfo":{"name":"quotio","version":env!("CARGO_PKG_VERSION")},"capabilities":{"experimentalApi":false}})).await?;
        writer
            .write_all(b"{\"method\":\"initialized\"}\n")
            .await
            .map_err(|_| ProviderError::Unavailable)?;
        Ok((child, writer, reader))
    }

    async fn local_credential() -> Result<Credential, ProviderError> {
        let location = if std::env::var_os("CODEX_HOME").is_some() {
            crate::accounts::sources::CodexLocation::CodexHome
        } else {
            crate::accounts::sources::CodexLocation::Default
        };
        let source = crate::accounts::sources::CodexNativeReference::system(location)
            .map_err(|_| ProviderError::Authentication)?;
        let cap = std::time::Duration::from_secs(1);
        let budget = super::remaining_fetch_time().map_or(cap, |remaining| {
            remaining
                .saturating_sub(std::time::Duration::from_millis(100))
                .min(cap)
        });
        if budget.is_zero() {
            return Err(ProviderError::Timeout);
        }
        let resolved = tokio::time::timeout(budget, source.resolve())
            .await
            .map_err(|_| ProviderError::Timeout)?
            .map_err(|_| ProviderError::Authentication)?;
        resolved
            .credentials
            .into_iter()
            .next()
            .ok_or(ProviderError::Authentication)
    }

    async fn attach_supplemental(
        context: &ProviderContext,
        usage: &mut ProviderUsage,
        credential: Credential,
    ) {
        super::codex_api::supplement(context, &credential, usage).await;
    }
}
impl ProviderAdapter for CodexProvider {
    fn cache_identity<'a>(
        &'a self,
        _: &'a ProviderContext,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<String>> + Send + 'a>> {
        Box::pin(async move {
            let (mut child, mut writer, mut reader) = self.connect().await.ok()?;
            let identity = account(
                rpc(
                    &mut reader,
                    &mut writer,
                    2,
                    "account/read",
                    json!({"refreshToken":false}),
                )
                .await
                .ok()?,
            )
            .ok()?;
            child.kill().await.ok()?;
            // The native protocol exposes email and plan, but no workspace ID.
            // An email identifies a personal login only; workspaces must fetch.
            if !matches!(
                identity.plan_type.as_deref(),
                Some("free" | "plus" | "pro" | "go")
            ) {
                return None;
            }
            Some(crate::cache::fingerprint(&[
                "codex-personal",
                &identity.email?.to_ascii_lowercase(),
                identity.plan_type.as_deref()?,
            ]))
        })
    }

    fn account_ref(&self) -> Option<AccountRef> {
        Some(AccountRef {
            origin: None,
            id: "local".into(),
            label: "Local Codex".into(),
        })
    }
    fn id(&self) -> ProviderId {
        ProviderId("codex".into())
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            let (mut child, mut writer, mut reader) = self.connect().await?;
            let before = account(
                rpc(
                    &mut reader,
                    &mut writer,
                    2,
                    "account/read",
                    json!({"refreshToken":false}),
                )
                .await?,
            )?;
            let limits = rpc(
                &mut reader,
                &mut writer,
                3,
                "account/rateLimits/read",
                json!({}),
            )
            .await?;
            let after = account(
                rpc(
                    &mut reader,
                    &mut writer,
                    4,
                    "account/read",
                    json!({"refreshToken":false}),
                )
                .await?,
            )?;
            if before != after {
                return Err(ProviderError::InvalidData);
            }
            let result = parse(after, limits, context.clock.now());
            child.kill().await.map_err(|_| ProviderError::Unavailable)?;
            let mut usage = result?;
            if self.executable == std::path::Path::new("codex")
                && let Ok(credential) = Self::local_credential().await
            {
                Self::attach_supplemental(context, &mut usage, credential).await;
            }
            Ok(usage)
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::http;
    fn identity() -> Account {
        account(json!({"account":{"type":"chatgpt","email":"demo@example.com","planType":"pro"}}))
            .unwrap()
    }
    #[test]
    fn prefer_all_buckets_and_omit_missing_windows() {
        let report = parse(identity(), json!({"rateLimits":{"primary":{"usedPercent":90}},"rateLimitsByLimitId":{"a":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1780000000}},"b":{"primary":{"usedPercent":100},"secondary":{"usedPercent":0}}}}), OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(report.windows.len(), 3);
        assert_eq!(report.account.plan.as_deref(), Some("pro"));
        assert_eq!(report.windows[0].quota, Quota::from_used(Some(25.0)));
        assert_eq!(report.windows[1].quota, Quota::from_used(Some(100.0)));
        assert_eq!(report.windows[2].quota, Quota::from_used(Some(0.0)));
    }
    #[test]
    fn reject_unknown_identity_and_invalid_payload() {
        assert!(account(json!({"account":{"type":"chatgpt"}})).is_err());
        assert!(parse(identity(), json!({}), OffsetDateTime::UNIX_EPOCH).is_err());
        assert!(
            parse(
                identity(),
                json!({"rateLimits":{"primary":{"usedPercent":"bad"}}}),
                OffsetDateTime::UNIX_EPOCH
            )
            .is_err()
        );
    }
    #[test]
    fn compact_labels_omit_absent_session_and_preserve_weekly_primary() {
        let report = parse(identity(), json!({"rateLimitsByLimitId":{
            "codex":{"primary":{"usedPercent":70,"windowDurationMins":10080}},
            "gpt-reserve":{"limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":25,"windowDurationMins":300},"secondary":{"usedPercent":40,"windowDurationMins":10080}}
        }}), OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(
            report
                .windows
                .iter()
                .map(|w| w.label.as_str())
                .collect::<Vec<_>>(),
            vec!["Weekly", "Codex Spark Session", "Codex Spark Weekly"]
        );
        assert_eq!(
            report
                .windows
                .iter()
                .map(|w| w.metric_id.as_deref().unwrap())
                .collect::<Vec<_>>(),
            vec!["codex-weekly", "gpt-reserve-session", "gpt-reserve-weekly"]
        );
        assert_eq!(report.windows[0].quota, Quota::from_used(Some(70.0)));
        assert_eq!(report.windows[1].quota, Quota::from_used(Some(25.0)));
        assert_eq!(report.windows[2].quota, Quota::from_used(Some(40.0)));
    }
    #[test]
    fn labels_keep_other_buckets_and_do_not_misname_unusual_durations() {
        let report = parse(identity(),json!({"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300},"secondary":{"usedPercent":20,"windowDurationMins":10080}}}),OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(report.windows[0].label, "Session");
        assert_eq!(report.windows[1].label, "Weekly");
        let report = parse(identity(),json!({"rateLimitsByLimitId":{"other":{"limitName":"Other model","primary":{"usedPercent":10,"windowDurationMins":60}}}}),OffsetDateTime::UNIX_EPOCH).unwrap();
        assert!(
            report
                .windows
                .iter()
                .any(|w| w.label == "Other model Quota 1")
        );
    }
    #[test]
    fn absent_windows_are_omitted_but_present_unknown_usage_is_kept() {
        for value in [
            json!({"rateLimits":{"primary":null,"secondary":null}}),
            json!({"rateLimits":{}}),
        ] {
            assert!(
                parse(identity(), value, OffsetDateTime::UNIX_EPOCH)
                    .unwrap()
                    .windows
                    .is_empty()
            );
        }
        let report = parse(
            identity(),
            json!({"rateLimits":{"primary":{"windowDurationMins":300},"secondary":null}}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(report.windows.len(), 1);
        assert_eq!(report.windows[0].label, "Session");
        assert_eq!(report.windows[0].quota, Quota::Unknown);
        let report = parse(
            identity(),
            json!({"rateLimits":{"primary":{"usedPercent":15,"windowDurationMins":43200}}}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(report.windows.len(), 1);
        assert_eq!(report.windows[0].quota, Quota::from_used(Some(15.0)));
        assert!(!matches!(
            report.windows[0].label.as_str(),
            "Session" | "Weekly"
        ));
    }

    #[tokio::test]
    async fn local_usage_attaches_supplemental_data_without_exposing_credentials() {
        let (usage_url, usage_task) =
            http::fixture::server(vec![json!({"credits":{"balance":0}})]).await;
        let (inventory_url, inventory_task) = http::fixture::server(vec![json!({
            "available_count": 2,
            "credits": [{"id":"private-credit-id","status":"available"}]
        })])
        .await;
        let (profile_url, profile_task) = http::fixture::server(vec![json!({
            "stats": {"lifetime_tokens": 42}
        })])
        .await;
        let context = http::fixture::context();
        let mut usage = parse(
            identity(),
            json!({"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300}}}),
            context.clock.now(),
        )
        .unwrap();
        let credential = Credential::CodexOAuth {
            access_token: "private-access-token".into(),
            refresh_token: String::new(),
            id_token: String::new(),
            account_id: "workspace-a".into(),
            email: "demo@example.com".into(),
            expires_at: i64::MAX,
        };
        super::super::codex_api::TEST_ENDPOINTS
            .scope(
                (usage_url, inventory_url, profile_url),
                CodexProvider::attach_supplemental(&context, &mut usage, credential),
            )
            .await;
        assert_eq!(usage.windows.len(), 2);
        let extra = usage
            .windows
            .iter()
            .find(|window| window.metric_id.as_deref() == Some("codex-extra-usage"))
            .unwrap();
        assert_eq!(extra.amounts.as_ref().unwrap().remaining, 0.0);
        assert_eq!(
            usage.codex_reset_credits.as_ref().unwrap().available_count,
            2
        );
        assert_eq!(
            usage.codex_profile.as_ref().unwrap().lifetime_tokens,
            Some(42)
        );
        let serialized = serde_json::to_string(&usage).unwrap();
        assert!(!serialized.contains("private-access-token"));
        assert!(!serialized.contains("private-credit-id"));
        usage_task.await.unwrap();
        inventory_task.await.unwrap();
        profile_task.await.unwrap();
    }

    #[tokio::test]
    async fn local_supplemental_failure_preserves_app_server_quota() {
        let (usage_url, usage_task) =
            http::fixture::server_status(vec![(503, json!({"error":"private-usage-error"}))]).await;
        let (inventory_url, inventory_task) =
            http::fixture::server_status(vec![(503, json!({"error":"private-inventory-error"}))])
                .await;
        let (profile_url, profile_task) =
            http::fixture::server_status(vec![(503, json!({"error":"private-profile-error"}))])
                .await;
        let mut usage = parse(
            identity(),
            json!({"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300}}}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        let credential = Credential::CodexOAuth {
            access_token: "private-access-token".into(),
            refresh_token: String::new(),
            id_token: String::new(),
            account_id: "workspace-a".into(),
            email: "demo@example.com".into(),
            expires_at: i64::MAX,
        };
        let context = http::fixture::context();
        super::super::codex_api::TEST_ENDPOINTS
            .scope(
                (usage_url, inventory_url, profile_url),
                CodexProvider::attach_supplemental(&context, &mut usage, credential),
            )
            .await;
        assert_eq!(usage.windows.len(), 1);
        assert_eq!(usage.windows[0].provenance.source, "codex_app_server");
        assert!(usage.codex_reset_credits.is_none());
        assert!(usage.codex_profile.is_none());
        assert_eq!(usage.diagnostics.len(), 3);
        assert!(
            usage
                .diagnostics
                .iter()
                .all(|diagnostic| diagnostic.code == ProviderError::Transient)
        );
        let serialized = serde_json::to_string(&usage).unwrap();
        assert!(!serialized.contains("private-access-token"));
        assert!(!serialized.contains("private-usage-error"));
        assert!(!serialized.contains("private-inventory-error"));
        assert!(!serialized.contains("private-profile-error"));
        usage_task.await.unwrap();
        inventory_task.await.unwrap();
        profile_task.await.unwrap();
    }
}
