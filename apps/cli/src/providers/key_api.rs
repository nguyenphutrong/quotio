use super::{FetchFuture, ProviderAdapter, ProviderContext, http};
use crate::{domain::*, error::ProviderError};
use serde_json::Value;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

#[derive(Clone, Copy)]
pub enum Kind {
    Synthetic,
    OpenRouter,
    Zai,
    MiniMax,
}
impl Kind {
    pub fn id(self) -> &'static str {
        match self {
            Self::Synthetic => "synthetic",
            Self::OpenRouter => "openrouter",
            Self::Zai => "zai",
            Self::MiniMax => "minimax",
        }
    }
    pub fn key(self) -> &'static str {
        match self {
            Self::Synthetic => "SYNTHETIC_API_KEY",
            Self::OpenRouter => "OPENROUTER_API_KEY",
            Self::Zai => "ZAI_API_KEY",
            Self::MiniMax => "MINIMAX_API_KEY",
        }
    }
    pub fn region_key(self) -> Option<&'static str> {
        match self {
            Self::Zai => Some("ZAI_REGION"),
            Self::MiniMax => Some("MINIMAX_REGION"),
            _ => None,
        }
    }
    fn endpoint(self, region: &str) -> Result<&'static str, ProviderError> {
        match (self, region) {
            (Self::Synthetic, "global") => Ok("https://api.synthetic.new/v2/quotas"),
            (Self::OpenRouter, "global") => Ok("https://openrouter.ai/api/v1/key"),
            (Self::Zai, "global") => Ok("https://api.z.ai/api/monitor/usage/quota/limit"),
            (Self::Zai, "cn") => Ok("https://open.bigmodel.cn/api/monitor/usage/quota/limit"),
            (Self::MiniMax, "global") => Ok("https://www.minimax.io/v1/token_plan/remains"),
            (Self::MiniMax, "cn") => Ok("https://api.minimaxi.com/v1/token_plan/remains"),
            _ => Err(ProviderError::InvalidData),
        }
    }
}
pub struct KeyApiProvider(pub Kind);
pub(crate) fn number(value: Option<&Value>) -> Result<Option<f64>, ProviderError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(v) => {
            let n = v
                .as_f64()
                .or_else(|| {
                    v.as_str()
                        .filter(|s| s.len() <= 64)
                        .and_then(|s| s.trim().parse().ok())
                })
                .ok_or(ProviderError::InvalidData)?;
            if !n.is_finite() || n < 0.0 {
                return Err(ProviderError::InvalidData);
            }
            Ok(Some(n))
        }
    }
}
fn currency(value: Option<&Value>) -> Result<Option<f64>, ProviderError> {
    if let Some(Value::String(s)) = value
        && let Some(n) = s.trim().strip_prefix('$')
    {
        return number(Some(&Value::String(n.into())));
    }
    number(value)
}
pub(crate) fn date(value: Option<&Value>) -> Result<Option<OffsetDateTime>, ProviderError> {
    match value {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => OffsetDateTime::parse(s, &Rfc3339)
            .map(Some)
            .map_err(|_| ProviderError::InvalidData),
        Some(v) => {
            let n = v.as_i64().ok_or(ProviderError::InvalidData)?;
            let seconds = if n >= 100_000_000_000 { n / 1000 } else { n };
            OffsetDateTime::from_unix_timestamp(seconds)
                .map(Some)
                .map_err(|_| ProviderError::InvalidData)
        }
    }
}
#[allow(clippy::too_many_arguments)]
fn window(
    label: &str,
    used: Option<f64>,
    limit: Option<f64>,
    remaining: Option<f64>,
    unit: &str,
    reset: Option<OffsetDateTime>,
    source: &str,
    now: OffsetDateTime,
) -> QuotaWindow {
    let remaining = remaining.or_else(|| limit.zip(used).map(|(cap, used)| (cap - used).max(0.0)));
    let quota = limit
        .filter(|v| *v > 0.0)
        .zip(remaining)
        .map(|(cap, left)| Quota::from_remaining(Some(left / cap * 100.0)))
        .unwrap_or(Quota::Unknown);
    QuotaWindow {
        note: None,
        metric_id: None,
        label: label.into(),
        quota,
        consumption: used.map(|used| Consumption {
            used,
            unit: unit.into(),
        }),
        amounts: remaining.map(|remaining| QuotaAmounts {
            remaining,
            limit,
            unit: unit.into(),
        }),
        resets_at: reset,
        reset_description: None,
        provenance: Provenance {
            source: source.into(),
            confidence: if limit.is_some() || used.is_some() || remaining.is_some() {
                Confidence::Exact
            } else {
                Confidence::Unknown
            },
        },
        fetched_at: now,
    }
}
fn percentage(
    window: &mut QuotaWindow,
    percent: Option<f64>,
    remaining: bool,
) -> Result<(), ProviderError> {
    if let Some(n) = percent {
        if n > 100.0 {
            return Err(ProviderError::InvalidData);
        }
        window.quota = if remaining {
            Quota::from_remaining(Some(n))
        } else {
            Quota::from_used(Some(n))
        };
        window.provenance.confidence = Confidence::Exact;
    }
    Ok(())
}
fn synthetic(root: &Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    let mut windows = Vec::new();
    for (path, label) in [
        ("/rollingFiveHourLimit", "Session"),
        ("/weeklyTokenLimit", "Weekly"),
        ("/search/hourly", "Search hourly"),
        ("/subscription", "Subscription"),
    ] {
        if path == "/subscription"
            && root
                .get("rollingFiveHourLimit")
                .is_some_and(|v| !v.is_null())
        {
            continue;
        }
        let Some(slot) = root.pointer(path).filter(|v| !v.is_null()) else {
            continue;
        };
        if !slot.is_object() {
            return Err(ProviderError::InvalidData);
        }
        let credits = slot.get("maxCredits").is_some() || slot.get("remainingCredits").is_some();
        let limit = if credits {
            currency(slot.get("maxCredits"))?
        } else {
            number(slot.get("limit"))?
        };
        let used = if credits {
            None
        } else {
            number(slot.get("requests"))?
        };
        let remaining = if credits {
            currency(slot.get("remainingCredits"))?
        } else {
            None
        };
        let mut w = window(
            label,
            used,
            limit,
            remaining,
            if credits { "USD" } else { "requests" },
            date(slot.get("renewsAt"))?,
            "synthetic_api",
            now,
        );
        percentage(&mut w, number(slot.get("percentRemaining"))?, true)?;
        if let Some(at) = date(slot.get("nextRegenAt"))? {
            w.reset_description = Some(format!(
                "next replenishment {}",
                at.format(&Rfc3339)
                    .map_err(|_| ProviderError::InvalidData)?
            ));
        }
        windows.push(w);
    }
    Ok(windows)
}
pub(crate) fn openrouter(
    root: &Value,
    now: OffsetDateTime,
) -> Result<Vec<QuotaWindow>, ProviderError> {
    let data = root
        .get("data")
        .filter(|v| v.is_object())
        .ok_or(ProviderError::InvalidData)?;
    let mut windows = Vec::new();
    let limit = number(data.get("limit"))?;
    let remaining = number(data.get("limit_remaining"))?;
    if let Some(limit) = limit {
        if remaining.is_some_and(|r| r > limit) {
            return Err(ProviderError::InvalidData);
        }
        let mut w = window(
            "Key spending limit",
            remaining.map(|r| limit - r),
            Some(limit),
            remaining,
            "USD",
            None,
            "openrouter_key_api",
            now,
        );
        w.reset_description = data
            .get("limit_reset")
            .and_then(Value::as_str)
            .map(str::to_owned);
        windows.push(w);
    }
    for (key, label) in [
        ("usage", "Lifetime spend"),
        ("usage_daily", "Daily spend"),
        ("usage_weekly", "Weekly spend"),
        ("usage_monthly", "Monthly spend"),
    ] {
        if let Some(used) = number(data.get(key))? {
            windows.push(window(
                label,
                Some(used),
                None,
                None,
                "USD",
                None,
                "openrouter_key_api",
                now,
            ));
        }
    }
    Ok(windows)
}
fn zai(root: &Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    if root.get("success").and_then(Value::as_bool) == Some(false)
        || root
            .get("code")
            .and_then(Value::as_i64)
            .is_some_and(|code| code != 200)
    {
        return Err(ProviderError::InvalidData);
    }
    let limits = root
        .pointer("/data/limits")
        .and_then(Value::as_array)
        .ok_or(ProviderError::InvalidData)?;
    let mut windows = Vec::new();
    for slot in limits {
        let kind = slot
            .get("type")
            .or_else(|| slot.get("name"))
            .and_then(Value::as_str)
            .ok_or(ProviderError::InvalidData)?;
        if !matches!(kind, "TOKENS_LIMIT" | "CREDIT_LIMIT" | "TIME_LIMIT") {
            continue;
        }
        let n = slot.get("number").and_then(Value::as_f64);
        let unit = slot.get("unit").and_then(Value::as_f64);
        let period = match (unit, n) {
            (Some(3.0), Some(5.0)) => "Session".into(),
            (Some(6.0), Some(1.0)) => "Weekly".into(),
            (Some(5.0), Some(1.0)) => "Monthly".into(),
            (Some(u), Some(n)) if matches!(u, 3.0 | 4.0 | 5.0 | 6.0) => format!(
                "{n} {}",
                match u {
                    3.0 => "hours",
                    4.0 => "days",
                    5.0 => "months",
                    _ => "weeks",
                }
            ),
            _ => "Quota".into(),
        };
        let label = if kind == "TIME_LIMIT" {
            format!("MCP {period}")
        } else {
            period
        };
        // GLM defines nextResetTime in milliseconds, even for small or fractional values.
        let reset = match slot.get("nextResetTime") {
            None | Some(Value::Null) => None,
            Some(value) => {
                let millis = value.as_f64().ok_or(ProviderError::InvalidData)?;
                Some(
                    OffsetDateTime::from_unix_timestamp_nanos((millis * 1_000_000.0) as i128)
                        .map_err(|_| ProviderError::InvalidData)?,
                )
            }
        };
        let mut w = if kind == "TIME_LIMIT" {
            window(
                &label,
                number(slot.get("currentValue"))?,
                number(slot.get("usage"))?,
                None,
                "searches",
                reset,
                "zai_quota_api",
                now,
            )
        } else {
            window(
                &label,
                None,
                None,
                None,
                "tokens",
                reset,
                "zai_quota_api",
                now,
            )
        };
        if kind != "TIME_LIMIT" {
            percentage(&mut w, number(slot.get("percentage"))?, false)?;
        }
        w.metric_id = if kind == "TIME_LIMIT" {
            Some("zai-web-searches".into())
        } else {
            match (unit, n) {
                (Some(3.0), Some(n)) if n > 0.0 => {
                    Some(if n < 24.0 { "zai-session" } else { "zai-daily" }.into())
                }
                (Some(4.0), Some(n)) if n > 0.0 => Some(
                    if n <= 1.0 {
                        "zai-daily"
                    } else if n < 28.0 {
                        "zai-weekly"
                    } else {
                        "zai-monthly"
                    }
                    .into(),
                ),
                (Some(5.0), Some(n)) if n > 0.0 => Some("zai-monthly".into()),
                (Some(6.0), Some(n)) if n > 0.0 => {
                    Some(if n < 4.0 { "zai-weekly" } else { "zai-monthly" }.into())
                }
                _ => None,
            }
        };
        windows.push(w);
    }
    Ok(windows)
}
fn minimax(root: &Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    let data = root.get("data").filter(|v| v.is_object()).unwrap_or(root);
    let status = root
        .pointer("/base_resp/status_code")
        .or_else(|| data.pointer("/base_resp/status_code"));
    if let Some(status) = status {
        match status.as_i64() {
            Some(0) => (),
            Some(1004) => return Err(ProviderError::Authentication),
            _ => return Err(ProviderError::InvalidData),
        }
    }
    let models = data
        .get("model_remains")
        .and_then(Value::as_array)
        .ok_or(ProviderError::InvalidData)?;
    let mut windows = Vec::new();
    for model in models {
        let name = model
            .get("model_name")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or(ProviderError::InvalidData)?;
        for (prefix, label, reset) in [
            ("current_interval", "Session", "end_time"),
            ("current_weekly", "Weekly", "weekly_end_time"),
        ] {
            if let Some(status) = model.get(format!("{prefix}_status")) {
                match status.as_i64() {
                    Some(1) => (),
                    // Status3 lanes can be unavailable or unlimited, not metered quota.
                    Some(3) => continue,
                    _ => return Err(ProviderError::InvalidData),
                }
            }
            let total = format!("{prefix}_total_count");
            let left = format!("{prefix}_usage_count");
            let percent = format!("{prefix}_remaining_percent");
            if [total.as_str(), left.as_str(), percent.as_str()]
                .iter()
                .all(|k| model.get(*k).is_none_or(Value::is_null))
            {
                continue;
            }
            let mut limit = number(model.get(&total))?;
            let pct = number(model.get(&percent))?;
            if pct.is_some() && limit == Some(0.0) {
                limit = None;
            }
            let remaining = if let Some(pct) = pct {
                if pct > 100.0 {
                    return Err(ProviderError::InvalidData);
                }
                limit.map(|l| l * (pct / 100.0))
            } else {
                number(model.get(&left))?
            };
            let mut w = window(
                &format!("{name} {label}"),
                None,
                limit,
                remaining,
                "units",
                date(model.get(reset))?,
                "minimax_token_plan_api",
                now,
            );
            percentage(&mut w, pct, true)?;
            windows.push(w);
        }
    }
    Ok(windows)
}
impl KeyApiProvider {
    async fn fetch_zai_at(
        &self,
        context: &ProviderContext,
        quota_endpoint: &str,
        subscription_endpoint: &str,
        region: &str,
    ) -> Result<ProviderUsage, ProviderError> {
        let key = context
            .credentials
            .get("ZAI_API_KEY")
            .ok_or(ProviderError::Authentication)?;
        if key.0.trim().is_empty() || key.0.len() > 16_384 || key.0.chars().any(char::is_control) {
            return Err(ProviderError::Authentication);
        }
        let subscription = async {
            let key = context
                .credentials
                .get("ZAI_API_KEY")
                .ok_or(ProviderError::Authentication)?;
            let value: Value = http::json(
                context
                    .http
                    .get(subscription_endpoint)
                    .header(
                        "Authorization",
                        http::sensitive(&format!("Bearer {}", key.0))?,
                    )
                    .header("Accept", "application/json"),
                context.clock.now(),
            )
            .await?;
            let rows = value
                .get("data")
                .and_then(Value::as_array)
                .ok_or(ProviderError::InvalidData)?;
            if rows.is_empty() {
                return Ok(None);
            }
            let name = rows[0]
                .get("productName")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| {
                    !name.is_empty() && name.len() <= 256 && !name.chars().any(char::is_control)
                })
                .ok_or(ProviderError::InvalidData)?;
            Ok::<_, ProviderError>(Some(name.to_owned()))
        };
        let (quota, subscription) = tokio::join!(
            self.fetch_at(context, quota_endpoint, region),
            tokio::time::timeout(
                crate::providers::remaining_fetch_time()
                    .map(|remaining| remaining / 2)
                    .unwrap_or(std::time::Duration::from_secs(5))
                    .min(std::time::Duration::from_secs(5)),
                subscription
            )
        );
        let mut usage = quota?;
        match subscription.unwrap_or(Err(ProviderError::Timeout)) {
            Ok(plan) => usage.account.plan = plan,
            Err(code) => usage.diagnostics.push(UsageDiagnostic {
                source: "zai_subscription_api".into(),
                code,
            }),
        }
        Ok(usage)
    }
    async fn fetch_at(
        &self,
        context: &ProviderContext,
        endpoint: &str,
        region: &str,
    ) -> Result<ProviderUsage, ProviderError> {
        let key = context
            .credentials
            .get(self.0.key())
            .ok_or(ProviderError::Authentication)?;
        if key.0.trim().is_empty() || key.0.len() > 16_384 || key.0.chars().any(char::is_control) {
            return Err(ProviderError::Authentication);
        }
        let root: Value = http::json(
            context
                .http
                .get(endpoint)
                .header(
                    "Authorization",
                    http::sensitive(&format!("Bearer {}", key.0))?,
                )
                .header("Accept", "application/json")
                .header("Content-Type", "application/json"),
            context.clock.now(),
        )
        .await?;
        let windows = match self.0 {
            Kind::Synthetic => synthetic(&root, context.clock.now()),
            Kind::OpenRouter => openrouter(&root, context.clock.now()),
            Kind::Zai => zai(&root, context.clock.now()),
            Kind::MiniMax => minimax(&root, context.clock.now()),
        }?;
        if windows.is_empty()
            || windows.iter().all(|w| {
                w.quota == Quota::Unknown && w.consumption.is_none() && w.amounts.is_none()
            })
            || windows.iter().any(|w| {
                w.amounts
                    .as_ref()
                    .is_some_and(|a| a.limit.is_some_and(|limit| a.remaining > limit))
            })
        {
            return Err(ProviderError::InvalidData);
        }
        // These endpoints may identify only a key. Do not invent an account email
        // or merge distinct keys with different limits under one creator identity.
        let digest = ring::digest::digest(
            &ring::digest::SHA256,
            format!("{}\0{region}\0{}", self.0.id(), key.0).as_bytes(),
        );
        let fingerprint: String = digest.as_ref()[..16]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        Ok(ProviderUsage {
            reset_credits: None,
            antigravity_subscription: None,
            codex_profile: None,
            codex_reset_credits: None,
            diagnostics: vec![],
            account_ref: None,
            provider: self.id(),
            account: AccountIdentity {
                verified: None,
                subscription_status: None,
                id: format!("key:{fingerprint}"),
                label: format!("{} API key", self.0.id()),
                plan: None,
            },
            windows,
        })
    }
}
impl ProviderAdapter for KeyApiProvider {
    fn id(&self) -> ProviderId {
        ProviderId(self.0.id().into())
    }
    fn account_ref(&self) -> Option<AccountRef> {
        Some(AccountRef {
            origin: None,
            id: "local".into(),
            label: "Environment API key".into(),
        })
    }
    fn idempotent(&self) -> bool {
        true
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            let region = self
                .0
                .region_key()
                .and_then(|name| context.credentials.get(name))
                .map(|s| s.0)
                .unwrap_or_else(|| "global".into());
            let endpoint = self.0.endpoint(&region)?;
            if matches!(self.0, Kind::OpenRouter) {
                return super::openrouter::fetch(context).await;
            }
            if matches!(self.0, Kind::Zai) {
                let subscription = match region.as_str() {
                    "global" => "https://api.z.ai/api/biz/subscription/list",
                    "cn" => "https://open.bigmodel.cn/api/biz/subscription/list",
                    _ => return Err(ProviderError::InvalidData),
                };
                return self
                    .fetch_zai_at(context, endpoint, subscription, &region)
                    .await;
            }
            self.fetch_at(context, endpoint, &region).await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Arc;
    struct Keys(Kind);
    impl super::super::CredentialStore for Keys {
        fn get(&self, name: &str) -> Option<super::super::Secret> {
            (name == self.0.key()).then(|| super::super::Secret("synthetic-test-key".into()))
        }
    }
    fn context(kind: Kind) -> ProviderContext {
        let mut c = http::fixture::context();
        c.credentials = Arc::new(Keys(kind));
        c
    }
    #[test]
    fn synthetic_preserves_percent_units_and_replenishment() {
        let windows = synthetic(
            &json!({"subscription":{"limit":100,"requests":25,"renewsAt":"2026-09-06T12:00:00Z"}}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(windows[0].quota, Quota::from_used(Some(25.0)));
        let windows=synthetic(&json!({"weeklyTokenLimit":{"percentRemaining":1,"maxCredits":"$100","remainingCredits":"$1","nextRegenAt":"2026-09-06T12:00:00Z"},"search":{"hourly":{"limit":250,"requests":2}}}),OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].label, "Weekly");
        assert_eq!(windows[0].quota, Quota::from_remaining(Some(1.0)));
        assert!(windows[0].resets_at.is_none());
        assert!(
            windows[0]
                .reset_description
                .as_ref()
                .unwrap()
                .starts_with("next replenishment")
        );
        assert_eq!(windows[1].consumption.as_ref().unwrap().used, 2.0);
    }
    #[test]
    fn openrouter_cap_uses_remaining_not_lifetime_spend() {
        let windows=openrouter(&json!({"data":{"limit":100,"limit_remaining":75,"limit_reset":"monthly","usage":900,"usage_monthly":25}}),OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(windows[0].quota, Quota::from_used(Some(25.0)));
        assert_eq!(windows[0].consumption.as_ref().unwrap().used, 25.0);
        assert_eq!(windows[0].reset_description.as_deref(), Some("monthly"));
        assert!(windows[0].resets_at.is_none());
        assert_eq!(windows[1].consumption.as_ref().unwrap().used, 900.0);
        assert!(windows[1].amounts.is_none());
        assert_eq!(windows[1].quota, Quota::Unknown);
    }
    #[test]
    fn openrouter_uncapped_spend_does_not_invent_remaining_credit() {
        let windows = openrouter(
            &json!({"data":{"limit":null,"usage":12.5}}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].quota, Quota::Unknown);
        assert!(windows[0].amounts.is_none());
        let report = UsageReport {
            schema_version: 1,
            generated_at: OffsetDateTime::UNIX_EPOCH,
            providers: vec![ProviderUsage {
                reset_credits: None,
                antigravity_subscription: None,
                codex_profile: None,
                codex_reset_credits: None,
                diagnostics: vec![],
                account_ref: None,
                provider: ProviderId("openrouter".into()),
                account: AccountIdentity {
                    verified: None,
                    subscription_status: None,
                    id: "key:test".into(),
                    label: "Key".into(),
                    plan: None,
                },
                windows,
            }],
            failures: vec![],
        };
        let json = serde_json::to_string_pretty(&report).unwrap();
        assert!(json.contains("consumption"));
        let unknown = openrouter(
            &json!({"data":{"limit":100,"limit_remaining":null,"usage":10}}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(unknown[0].quota, Quota::Unknown);
        assert!(unknown[0].amounts.is_none());
    }
    #[tokio::test]
    async fn zai_subscription_failure_preserves_quota_and_success_preserves_plan() {
        for success in [true, false] {
            let (quota_url, quota_server) = http::fixture::server(vec![json!({"success":true,"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":20}]}})]).await;
            let (plan_url, plan_server) = http::fixture::server_status(vec![(
                if success { 200 } else { 500 },
                json!({"data":[{"productName":" GLM Pro "}]}),
            )])
            .await;
            let mut context = http::fixture::context();
            struct ZaiKey;
            impl crate::providers::CredentialStore for ZaiKey {
                fn get(&self, name: &str) -> Option<crate::providers::Secret> {
                    (name == "ZAI_API_KEY")
                        .then(|| crate::providers::Secret("fixture-zai-key".into()))
                }
            }
            context.credentials = std::sync::Arc::new(ZaiKey);
            let usage = KeyApiProvider(Kind::Zai)
                .fetch_zai_at(&context, &quota_url, &plan_url, "global")
                .await
                .unwrap();
            assert_eq!(usage.windows[0].metric_id.as_deref(), Some("zai-session"));
            assert_eq!(usage.windows[0].quota, Quota::from_used(Some(20.0)));
            assert_eq!(usage.account.plan.as_deref(), success.then_some("GLM Pro"));
            assert_eq!(usage.diagnostics.len(), usize::from(!success));
            for request in [
                quota_server.await.unwrap().remove(0),
                plan_server.await.unwrap().remove(0),
            ] {
                assert!(request.contains("Bearer fixture-zai-key"));
            }
            assert!(
                !serde_json::to_string(&usage)
                    .unwrap()
                    .contains("fixture-zai-key")
            );
        }
    }
    #[test]
    fn zai_search_counts_override_unrelated_percentage_and_zero_limit_stays_unknown() {
        let windows = zai(
            &json!({"data":{"limits":[
                {"name":"TIME_LIMIT","currentValue":2,"usage":10,"percentage":99},
                {"type":"TIME_LIMIT","currentValue":0,"usage":0}
            ]}}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(windows[0].quota, Quota::from_used(Some(20.0)));
        assert_eq!(windows[1].quota, Quota::Unknown);
        assert!(windows.iter().all(|w| w.resets_at.is_none()));
        assert!(
            zai(
                &json!({"code":401,"data":{"limits":[]}}),
                OffsetDateTime::UNIX_EPOCH
            )
            .is_err()
        );
    }
    #[test]
    fn zai_accepts_double_periods_and_explicit_millisecond_resets() {
        let windows = zai(
            &json!({"data":{"limits":[
                {"type":"TOKENS_LIMIT","unit":3.0,"number":5.0,"percentage":20,"nextResetTime":1500.5},
                {"type":"CREDIT_LIMIT","unit":4.0,"number":1.5,"percentage":10,"nextResetTime":1788696000123.5},
                {"type":"TIME_LIMIT","currentValue":2,"usage":10,"nextResetTime":1000}
            ]}}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(windows[0].metric_id.as_deref(), Some("zai-session"));
        assert_eq!(windows[0].label, "Session");
        assert_eq!(windows[1].metric_id.as_deref(), Some("zai-weekly"));
        assert_eq!(windows[1].label, "1.5 days");
        assert_eq!(
            windows[0].resets_at.unwrap().unix_timestamp_nanos(),
            1_500_500_000
        );
        assert_eq!(
            windows[1].resets_at.unwrap().unix_timestamp(),
            1_788_696_000
        );
        assert_eq!(windows[2].resets_at.unwrap().unix_timestamp(), 1);
        assert_eq!(windows[2].metric_id.as_deref(), Some("zai-web-searches"));
        assert_eq!(windows[2].consumption.as_ref().unwrap().unit, "searches");
        assert_eq!(windows[2].amounts.as_ref().unwrap().unit, "searches");
        for invalid in [json!("1500"), json!(true), json!({}), json!(1e100)] {
            assert!(zai(
                &json!({"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":20,"nextResetTime":invalid}]}}),
                OffsetDateTime::UNIX_EPOCH,
            ).is_err());
        }
    }
    #[test]
    fn zai_uses_real_periods_and_separate_mcp_counts() {
        let windows=zai(&json!({"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":20},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":10},{"type":"TIME_LIMIT","unit":5,"number":1,"currentValue":2,"usage":100,"nextResetTime":1788696000000u64},{"type":"TOKENS_LIMIT","unit":4,"number":3,"percentage":5}]}}),OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(
            windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(),
            vec!["Session", "Weekly", "MCP Monthly", "3 days"]
        );
        assert_eq!(windows[0].quota, Quota::from_used(Some(20.0)));
        assert_eq!(windows[2].quota, Quota::from_used(Some(2.0)));
        assert_eq!(windows[2].resets_at.unwrap().unix_timestamp(), 1788696000);
        assert!(
            zai(
                &json!({"success":false,"data":{"limits":[]}}),
                OffsetDateTime::UNIX_EPOCH
            )
            .is_err()
        );
    }
    #[test]
    fn minimax_usage_count_is_remaining_and_modern_percent_overrides_placeholders() {
        let windows=minimax(&json!({"base_resp":{"status_code":0},"model_remains":[{"model_name":"Test model","current_interval_total_count":100,"current_interval_usage_count":75,"current_weekly_total_count":500,"current_weekly_usage_count":400,"end_time":1788696000000u64}]}),OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(windows[0].quota, Quota::from_used(Some(25.0)));
        assert_eq!(windows[1].quota, Quota::from_used(Some(20.0)));
        let modern=minimax(&json!({"data":{"model_remains":[{"model_name":"Test model","current_interval_total_count":0,"current_interval_usage_count":0,"current_interval_remaining_percent":96}]}}),OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(modern[0].quota, Quota::from_remaining(Some(96.0)));
        assert!(modern[0].amounts.is_none());
        assert_eq!(modern.len(), 1);
        let unavailable=minimax(&json!({"model_remains":[{"model_name":"video","current_interval_status":3,"current_interval_total_count":0,"current_interval_remaining_percent":100}]}),OffsetDateTime::UNIX_EPOCH).unwrap();
        assert!(unavailable.is_empty());
        assert!(matches!(
            minimax(
                &json!({"base_resp":{"status_code":1004},"model_remains":[]}),
                OffsetDateTime::UNIX_EPOCH
            ),
            Err(ProviderError::Authentication)
        ));
    }
    #[test]
    fn invalid_numbers_and_regions_fail_closed() {
        for value in [
            json!(-1),
            json!("NaN"),
            json!("bad"),
            json!(true),
            json!("$10"),
        ] {
            assert!(number(Some(&value)).is_err());
        }
        assert!(Kind::OpenRouter.endpoint("cn").is_err());
        assert!(Kind::Zai.endpoint("eu").is_err());
        assert_eq!(
            Kind::Zai.endpoint("cn").unwrap(),
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
        );
        assert_eq!(
            Kind::MiniMax.endpoint("global").unwrap(),
            "https://www.minimax.io/v1/token_plan/remains"
        );
    }
    #[tokio::test]
    async fn all_adapters_use_bearer_and_return_key_scoped_identity() {
        for (kind, value) in [
            (
                Kind::Synthetic,
                json!({"subscription":{"limit":100,"requests":25}}),
            ),
            (
                Kind::OpenRouter,
                json!({"data":{"usage":10,"label":"synthetic-test-key"}}),
            ),
            (
                Kind::Zai,
                json!({"data":{"limits":[{"type":"TOKENS_LIMIT","percentage":25}]}}),
            ),
            (
                Kind::MiniMax,
                json!({"model_remains":[{"model_name":"Test","current_interval_remaining_percent":75}]}),
            ),
        ] {
            let (base, server) = http::fixture::server(vec![value]).await;
            let usage = KeyApiProvider(kind)
                .fetch_at(&context(kind), &base, "global")
                .await
                .unwrap();
            assert!(usage.account.id.starts_with("key:"));
            assert!(
                !serde_json::to_string(&usage)
                    .unwrap()
                    .contains("synthetic-test-key")
            );
            let requests = server.await.unwrap();
            assert_eq!(requests.len(), 1);
            assert!(requests[0].starts_with("GET "));
            assert!(requests[0].contains("Bearer synthetic-test-key"));
        }
    }
    #[tokio::test]
    async fn empty_recognized_slots_and_business_errors_do_not_validate_keys() {
        for (kind, value) in [
            (Kind::Synthetic, json!({"subscription":{}})),
            (Kind::OpenRouter, json!({"data":{}})),
            (
                Kind::Zai,
                json!({"data":{"limits":[{"type":"TOKENS_LIMIT"}]}}),
            ),
            (
                Kind::MiniMax,
                json!({"base_resp":{"status_code":999},"model_remains":[]}),
            ),
        ] {
            let (base, server) = http::fixture::server(vec![value]).await;
            assert!(
                KeyApiProvider(kind)
                    .fetch_at(&context(kind), &base, "global")
                    .await
                    .is_err()
            );
            server.await.unwrap();
        }
    }
    #[tokio::test]
    async fn http_auth_rate_limit_and_server_failures_remain_typed() {
        for (status, expected) in [
            (401, ProviderError::Authentication),
            (403, ProviderError::Authentication),
            (429, ProviderError::RateLimited),
            (503, ProviderError::Transient),
        ] {
            let (base, server) =
                http::fixture::server_status(vec![(status, json!({"secret":"never print this"}))])
                    .await;
            assert_eq!(
                KeyApiProvider(Kind::Synthetic)
                    .fetch_at(&context(Kind::Synthetic), &base, "global")
                    .await
                    .unwrap_err(),
                expected
            );
            server.await.unwrap();
        }
    }
}
