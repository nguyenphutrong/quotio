use super::{AuthKind, Definition, Setting, common};
use crate::{
    domain::{Confidence, ProviderUsage, QuotaWindow},
    error::ProviderError,
    providers::{FetchFuture, ProviderContext, Secret, http},
};
use base64::{
    Engine,
    engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD},
};
use serde_json::{Map, Value, json};

const AIAND_LOGS: &str = "https://api.aiand.com/logs";
const ALIBABA_INTL: &str = "https://modelstudio.console.alibabacloud.com";
const ALIBABA_CN: &str = "https://bailian.console.aliyun.com";
const CLINEPASS_LIMITS: &str = "https://api.cline.bot/api/v1/users/me/plan/usage-limits";
const CODEBUFF_USAGE: &str = "https://www.codebuff.com/api/v1/usage";
const IBM_PROFILE: &str = "https://api.us-east.bob.ibm.com";
const IBM_US_EAST: &str = "https://api.us-east.bob.ibm.com";
const IBM_EU_DE: &str = "https://api.eu-de.bob.ibm.com";
const KILO_TRPC: &str = "https://app.kilo.ai/api/trpc";
const WARP_GRAPHQL: &str = "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo";

const ALIBABA_SETTINGS: &[Setting] = &[Setting {
    name: "region",
    env: "ALIBABA_CODING_PLAN_REGION",
    required: true,
}];
const KILO_SETTINGS: &[Setting] = &[Setting {
    name: "organization_id",
    env: "KILO_ORGANIZATION_ID",
    required: false,
}];

pub const DEFINITIONS: &[Definition] = &[
    Definition {
        id: "aiand",
        name: "ai&",
        key_env: "AIAND_API_KEY",
        auth: AuthKind::ApiKey,
        settings: &[],
        fetch: aiand,
    },
    Definition {
        id: "alibabacodingplan",
        name: "Alibaba Coding Plan",
        key_env: "ALIBABA_CODING_PLAN_API_KEY",
        auth: AuthKind::ApiKey,
        settings: ALIBABA_SETTINGS,
        fetch: alibaba,
    },
    Definition {
        id: "clinepass",
        name: "ClinePass",
        key_env: "CLINEPASS_API_KEY",
        auth: AuthKind::ApiKey,
        settings: &[],
        fetch: clinepass,
    },
    Definition {
        id: "codebuff",
        name: "Codebuff",
        key_env: "CODEBUFF_API_KEY",
        auth: AuthKind::ApiKey,
        settings: &[],
        fetch: codebuff,
    },
    Definition {
        id: "ibmbob",
        name: "IBM Bob",
        key_env: "BOBSHELL_API_KEY",
        auth: AuthKind::ApiKey,
        settings: &[],
        fetch: ibm_bob,
    },
    Definition {
        id: "kilo",
        name: "Kilo",
        key_env: "KILO_API_KEY",
        auth: AuthKind::ApiKey,
        settings: KILO_SETTINGS,
        fetch: kilo,
    },
    Definition {
        id: "warp",
        name: "Warp",
        key_env: "WARP_API_KEY",
        auth: AuthKind::ApiKey,
        settings: &[],
        fetch: warp,
    },
];

fn bearer(key: &Secret) -> Result<reqwest::header::HeaderValue, ProviderError> {
    http::sensitive(&format!("Bearer {}", key.0))
}

fn setting(context: &ProviderContext, env: &str) -> Result<Option<String>, ProviderError> {
    let Some(value) = context.credentials.get(env) else {
        return Ok(None);
    };
    let value = value.0.trim();
    if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
        return Err(ProviderError::InvalidData);
    }
    Ok(Some(value.into()))
}

fn required_number(object: &Map<String, Value>, name: &str) -> Result<f64, ProviderError> {
    common::number(object.get(name))?.ok_or(ProviderError::InvalidData)
}

fn public_name(value: Option<&Value>, fallback: &str) -> Result<String, ProviderError> {
    let value = value.and_then(Value::as_str).unwrap_or(fallback).trim();
    if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
        return Err(ProviderError::InvalidData);
    }
    Ok(value.into())
}

fn url(base: &str) -> Result<reqwest::Url, ProviderError> {
    reqwest::Url::parse(base).map_err(|_| ProviderError::InvalidData)
}

fn append_path(base: &str, segments: &[&str]) -> Result<reqwest::Url, ProviderError> {
    let mut url = url(base)?;
    {
        let mut path = url
            .path_segments_mut()
            .map_err(|_| ProviderError::InvalidData)?;
        for segment in segments {
            path.push(segment);
        }
    }
    Ok(url)
}

fn fixed_path(base: &str, segments: &[&str]) -> Result<reqwest::Url, ProviderError> {
    let mut url = url(base)?;
    {
        let mut path = url
            .path_segments_mut()
            .map_err(|_| ProviderError::InvalidData)?;
        path.clear();
        for segment in segments {
            path.push(segment);
        }
    }
    Ok(url)
}

fn aiand(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(aiand_at(context, AIAND_LOGS))
}

async fn aiand_at(
    context: &ProviderContext,
    endpoint: &str,
) -> Result<ProviderUsage, ProviderError> {
    let key = common::key(context, "AIAND_API_KEY")?;
    let authorization = bearer(&key)?;
    let now = context.clock.now();
    let mut cursor: Option<(String, String)> = None;
    let mut currency: Option<String> = None;
    let mut spend = 0.0;
    let mut partial = false;

    for page in 0..10 {
        let mut request_url = url(endpoint)?;
        {
            let mut query = request_url.query_pairs_mut();
            query.append_pair("range", "30days");
            query.append_pair("limit", "100");
            if let Some((after, after_id)) = &cursor {
                query.append_pair("after", after);
                query.append_pair("after_id", after_id);
            }
        }
        let root: Value = common::json(
            context
                .http
                .get(request_url)
                .header("Authorization", authorization.clone())
                .header("Accept", "application/json"),
            now,
        )
        .await?;
        let object = root.as_object().ok_or(ProviderError::InvalidData)?;
        let rows = object
            .get("data")
            .and_then(Value::as_array)
            .ok_or(ProviderError::InvalidData)?;
        for row in rows {
            let row = row.as_object().ok_or(ProviderError::InvalidData)?;
            let Some(cost) = common::number(row.get("cost"))? else {
                continue;
            };
            let Some(raw_currency) = row.get("currency").and_then(Value::as_str) else {
                return Err(ProviderError::InvalidData);
            };
            let row_currency = raw_currency.trim().to_ascii_uppercase();
            if row_currency.len() != 3
                || !row_currency.bytes().all(|byte| byte.is_ascii_alphabetic())
            {
                return Err(ProviderError::InvalidData);
            }
            match &currency {
                Some(expected) if expected != &row_currency => {
                    return Err(ProviderError::InvalidData);
                }
                Some(_) => (),
                None => currency = Some(row_currency),
            }
            spend += cost;
            if !spend.is_finite() {
                return Err(ProviderError::InvalidData);
            }
        }

        let has_more = object
            .get("has_more")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !has_more {
            break;
        }
        if page == 9 {
            partial = true;
            break;
        }
        let after = public_name(object.get("next_after"), "")?;
        let after_id = public_name(object.get("next_after_id"), "")?;
        cursor = Some((after, after_id));
    }

    let currency = currency.ok_or(ProviderError::QuotaUnavailable)?;
    let mut window = common::window(
        "Last 30 days spend",
        Some(spend),
        None,
        None,
        &currency,
        None,
        "aiand_request_logs",
        now,
    )?;
    if partial {
        window.provenance.confidence = Confidence::Estimated;
        window.reset_description = Some("newest 1,000 request logs; result may be partial".into());
    }
    common::usage("aiand", &key, "organization", vec![window])
}

#[derive(Clone, Copy)]
enum AlibabaRegion {
    International,
    ChinaMainland,
}

impl AlibabaRegion {
    fn from_setting(value: &str) -> Result<Self, ProviderError> {
        match value {
            "intl" => Ok(Self::International),
            "cn" => Ok(Self::ChinaMainland),
            _ => Err(ProviderError::InvalidData),
        }
    }

    fn endpoint(self) -> &'static str {
        match self {
            Self::International => ALIBABA_INTL,
            Self::ChinaMainland => ALIBABA_CN,
        }
    }

    fn region_id(self) -> &'static str {
        match self {
            Self::International => "ap-southeast-1",
            Self::ChinaMainland => "cn-beijing",
        }
    }

    fn commodity_code(self) -> &'static str {
        match self {
            Self::International => "sfm_codingplan_public_intl",
            Self::ChinaMainland => "sfm_codingplan_public_cn",
        }
    }

    fn scope(self) -> &'static str {
        match self {
            Self::International => "intl",
            Self::ChinaMainland => "cn",
        }
    }

    fn referer(self) -> &'static str {
        match self {
            Self::International => {
                "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan"
            }
            Self::ChinaMainland => "https://bailian.console.aliyun.com/cn-beijing/?tab=model",
        }
    }
}

fn alibaba(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(async move {
        let region = setting(context, "ALIBABA_CODING_PLAN_REGION")?
            .ok_or(ProviderError::InvalidData)
            .and_then(|value| AlibabaRegion::from_setting(&value))?;
        alibaba_at(context, region.endpoint(), region).await
    })
}

async fn alibaba_at(
    context: &ProviderContext,
    base: &str,
    region: AlibabaRegion,
) -> Result<ProviderUsage, ProviderError> {
    let key = common::key(context, "ALIBABA_CODING_PLAN_API_KEY")?;
    let authorization = bearer(&key)?;
    let mut endpoint = fixed_path(base, &["data", "api.json"])?;
    {
        let mut query = endpoint.query_pairs_mut();
        query.append_pair(
            "action",
            "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2",
        );
        query.append_pair("product", "broadscope-bailian");
        query.append_pair("api", "queryCodingPlanInstanceInfoV2");
        query.append_pair("currentRegionId", region.region_id());
    }
    let now = context.clock.now();
    let root: Value = common::json(
        context
            .http
            .post(endpoint)
            .header("Authorization", authorization)
            .header("x-api-key", http::sensitive(&key.0)?)
            .header("X-DashScope-API-Key", http::sensitive(&key.0)?)
            .header("Accept", "application/json")
            .header("Origin", region.endpoint())
            .header("Referer", region.referer())
            .json(&json!({
                "queryCodingPlanInstanceInfoRequest": {
                    "commodityCode": region.commodity_code()
                }
            })),
        now,
    )
    .await?;
    let root = root.as_object().ok_or(ProviderError::InvalidData)?;
    alibaba_response_status(root)?;
    let quota = alibaba_quota_object(root).ok_or(ProviderError::QuotaUnavailable)?;
    let mut windows = Vec::new();
    for (label, used, total, reset) in [
        (
            "5 hours",
            "per5HourUsedQuota",
            "per5HourTotalQuota",
            "per5HourQuotaNextRefreshTime",
        ),
        (
            "Weekly",
            "perWeekUsedQuota",
            "perWeekTotalQuota",
            "perWeekQuotaNextRefreshTime",
        ),
        (
            "Monthly",
            "perBillMonthUsedQuota",
            "perBillMonthTotalQuota",
            "perBillMonthQuotaNextRefreshTime",
        ),
    ] {
        let used = common::number(quota.get(used))?;
        let total = common::number(quota.get(total))?;
        if used.is_none() && total.is_none() {
            continue;
        }
        let used = used.ok_or(ProviderError::InvalidData)?;
        let total = total.ok_or(ProviderError::InvalidData)?;
        if total <= 0.0 || used > total {
            return Err(ProviderError::InvalidData);
        }
        windows.push(common::window(
            label,
            Some(used),
            Some(total),
            None,
            "requests",
            common::date(quota.get(reset))?,
            "alibaba_coding_plan_api",
            now,
        )?);
    }
    if windows.is_empty() {
        return Err(ProviderError::QuotaUnavailable);
    }
    common::usage("alibabacodingplan", &key, region.scope(), windows)
}

fn alibaba_response_status(root: &Map<String, Value>) -> Result<(), ProviderError> {
    if root.get("success").and_then(Value::as_bool) == Some(false) {
        return Err(ProviderError::InvalidData);
    }
    if let Some(code) = root.get("code") {
        if let Some(code) = code.as_i64() {
            if !matches!(code, 0 | 200) {
                return Err(ProviderError::InvalidData);
            }
        } else if let Some(code) = code.as_str() {
            let code = code.trim().to_ascii_lowercase();
            if code.contains("login") || code.contains("needlogin") {
                return Err(ProviderError::QuotaUnavailable);
            }
            if !code.is_empty() && code != "0" && code != "200" && code != "success" {
                return Err(ProviderError::InvalidData);
            }
        } else {
            return Err(ProviderError::InvalidData);
        }
    }
    if root
        .get("message")
        .and_then(Value::as_str)
        .is_some_and(|message| message.to_ascii_lowercase().contains("login"))
    {
        return Err(ProviderError::QuotaUnavailable);
    }
    Ok(())
}

fn alibaba_quota_object(object: &Map<String, Value>) -> Option<&Map<String, Value>> {
    if let Some(quota) = object.get("codingPlanQuotaInfo").and_then(Value::as_object) {
        return Some(quota);
    }
    if [
        "per5HourUsedQuota",
        "per5HourTotalQuota",
        "perWeekUsedQuota",
        "perWeekTotalQuota",
        "perBillMonthUsedQuota",
        "perBillMonthTotalQuota",
    ]
    .iter()
    .any(|key| object.contains_key(*key))
    {
        return Some(object);
    }
    object.values().find_map(alibaba_quota)
}

fn alibaba_quota(value: &Value) -> Option<&Map<String, Value>> {
    match value {
        Value::Array(values) => values.iter().find_map(alibaba_quota),
        Value::Object(object) => alibaba_quota_object(object),
        _ => None,
    }
}

fn clinepass(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(clinepass_at(context, CLINEPASS_LIMITS))
}

async fn clinepass_at(
    context: &ProviderContext,
    endpoint: &str,
) -> Result<ProviderUsage, ProviderError> {
    let key = common::key(context, "CLINEPASS_API_KEY")?;
    let now = context.clock.now();
    let root: Value = common::json(
        context
            .http
            .get(endpoint)
            .header("Authorization", bearer(&key)?)
            .header("Accept", "application/json"),
        now,
    )
    .await?;
    let root = root.as_object().ok_or(ProviderError::InvalidData)?;
    if root.get("success").and_then(Value::as_bool) != Some(true) {
        return Err(ProviderError::InvalidData);
    }
    let limits = root
        .get("data")
        .and_then(Value::as_object)
        .and_then(|data| data.get("limits"))
        .and_then(Value::as_array)
        .ok_or(ProviderError::InvalidData)?;
    let mut windows = Vec::new();
    let mut diagnostics = Vec::new();
    for (kind, label, metric_id) in [
        ("five_hour", "5 hours", "clinepass-five-hour"),
        ("weekly", "Weekly", "clinepass-weekly"),
        ("monthly", "Monthly", "clinepass-monthly"),
    ] {
        let mut matching = limits
            .iter()
            .filter(|limit| limit.get("type").and_then(Value::as_str) == Some(kind));
        let Some(limit) = matching.next() else {
            continue;
        };
        let duplicate = matching.next().is_some();
        let used = limit
            .get("percentUsed")
            .and_then(Value::as_f64)
            .filter(|v| v.is_finite())
            .filter(|_| !duplicate)
            .map(|v| v.clamp(0.0, 100.0));
        let reset = common::date(limit.get("resetsAt"));
        if used.is_none() || reset.is_err() || duplicate {
            diagnostics.push(crate::domain::UsageDiagnostic {
                source: metric_id.into(),
                code: ProviderError::InvalidData,
            });
        }
        let mut window = common::window(
            label,
            used,
            Some(100.0),
            None,
            "percent",
            if duplicate {
                None
            } else {
                reset.unwrap_or(None)
            },
            "clinepass_usage_limits",
            now,
        )?;
        window.metric_id = Some(metric_id.into());
        windows.push(window);
    }
    if windows.is_empty() {
        return Err(ProviderError::QuotaUnavailable);
    }
    Ok(ProviderUsage {
        fresh_observation: false,
        history_identity: None,
        reset_credits: None,
        antigravity_subscription: None,
        codex_profile: None,
        codex_reset_credits: None,
        provider: crate::domain::ProviderId("clinepass".into()),
        account: common::account_identity("clinepass", &key, "personal"),
        account_ref: None,
        windows,
        diagnostics,
    })
}

fn codebuff(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(codebuff_at(context, CODEBUFF_USAGE))
}

async fn codebuff_at(
    context: &ProviderContext,
    endpoint: &str,
) -> Result<ProviderUsage, ProviderError> {
    let key = common::key(context, "CODEBUFF_API_KEY")?;
    let now = context.clock.now();
    let root: Value = common::json(
        context
            .http
            .post(endpoint)
            .header("Authorization", bearer(&key)?)
            .header("Accept", "application/json")
            .json(&json!({"fingerprintId": "quotio-usage"})),
        now,
    )
    .await?;
    let root = root.as_object().ok_or(ProviderError::InvalidData)?;
    let used = common::number(root.get("usage").or_else(|| root.get("used")))?;
    let limit = common::number(root.get("quota").or_else(|| root.get("limit")))?;
    let remaining = common::number(
        root.get("remainingBalance")
            .or_else(|| root.get("remaining")),
    )?;
    let reset = common::date(root.get("next_quota_reset"))?;
    let window = match (used, limit, remaining) {
        (None, None, None) => return Err(ProviderError::QuotaUnavailable),
        (Some(used), Some(limit), remaining) => common::window(
            "Credit usage",
            Some(used),
            Some(limit),
            remaining,
            "credits",
            reset,
            "codebuff_usage_api",
            now,
        )?,
        (Some(used), None, remaining) => common::window(
            "Credit usage",
            Some(used),
            None,
            remaining,
            "credits",
            reset,
            "codebuff_usage_api",
            now,
        )?,
        (None, Some(limit), Some(remaining)) => common::window(
            "Credit balance",
            None,
            Some(limit),
            Some(remaining),
            "credits",
            reset,
            "codebuff_usage_api",
            now,
        )?,
        (None, Some(_), None) => return Err(ProviderError::QuotaUnavailable),
        (None, None, Some(remaining)) => common::window(
            "Credit balance",
            None,
            None,
            Some(remaining),
            "credits",
            reset,
            "codebuff_usage_api",
            now,
        )?,
    };
    common::usage("codebuff", &key, "api-key", vec![window])
}

#[derive(Clone, Copy)]
enum IbmRegion {
    UsEast,
    EuDe,
}

impl IbmRegion {
    fn base<'a>(self, us_east: &'a str, eu_de: &'a str) -> &'a str {
        match self {
            Self::UsEast => us_east,
            Self::EuDe => eu_de,
        }
    }
}

fn ibm_bob(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(ibm_bob_at(context, IBM_PROFILE, IBM_US_EAST, IBM_EU_DE))
}

async fn ibm_bob_at(
    context: &ProviderContext,
    profile_base: &str,
    us_east_base: &str,
    eu_de_base: &str,
) -> Result<ProviderUsage, ProviderError> {
    let key = common::key(context, "BOBSHELL_API_KEY")?;
    let authorization = ibm_authorization(&key)?;
    let now = context.clock.now();
    let profile: Value = common::json(
        context
            .http
            .get(append_path(profile_base, &["admin", "v1", "profile"])?)
            .header("Authorization", authorization.clone())
            .header("Accept", "application/json"),
        now,
    )
    .await?;
    let instances = profile
        .get("instances")
        .and_then(Value::as_array)
        .ok_or(ProviderError::InvalidData)?;
    let mut windows = Vec::new();

    for instance in instances {
        let instance = instance.as_object().ok_or(ProviderError::InvalidData)?;
        let instance_id = public_name(instance.get("instance_id"), "")?;
        let user_id = public_name(instance.get("user_id"), "")?;
        let region = ibm_region(instance.get("region_domain"))?;
        let teams = instance
            .get("teams")
            .and_then(Value::as_array)
            .ok_or(ProviderError::InvalidData)?;
        let instance_name = public_name(
            instance
                .get("instance_name")
                .or_else(|| instance.get("name")),
            &instance_id,
        )?;
        let reset = common::date(instance.get("refresh_at"))?;

        for team in teams {
            let team = team.as_object().ok_or(ProviderError::InvalidData)?;
            let team_id = public_name(team.get("id"), "")?;
            let team_name = public_name(team.get("name"), &team_id)?;
            let endpoint = append_path(
                region.base(us_east_base, eu_de_base),
                &["admin", "v1", "teams", &team_id, "users", &user_id],
            )?;
            let budget: Value = common::json(
                context
                    .http
                    .get(endpoint)
                    .header("Authorization", authorization.clone())
                    .header("Accept", "application/json")
                    .header("x-instance-id", http::sensitive(&instance_id)?)
                    .header("x-team-id", http::sensitive(&team_id)?),
                now,
            )
            .await?;
            let budget = budget.as_object().ok_or(ProviderError::InvalidData)?;
            let used = common::number(budget.get("usage"))?
                .or(common::number(team.get("usage"))?)
                .ok_or(ProviderError::InvalidData)?;
            let limit = common::number(budget.get("budget_limit"))?
                .or(common::number(team.get("budget_limit"))?);
            let label = if instance_name == team_name {
                format!("Bobcoins — {team_name}")
            } else {
                format!("Bobcoins — {instance_name} · {team_name}")
            };
            windows.push(common::window(
                &label,
                Some(used),
                limit,
                None,
                "Bobcoins",
                reset,
                "ibm_bob_team_budget",
                now,
            )?);
        }
    }

    if windows.is_empty() {
        return Err(ProviderError::QuotaUnavailable);
    }
    common::usage("ibmbob", &key, "profile", windows)
}

fn ibm_authorization(key: &Secret) -> Result<reqwest::header::HeaderValue, ProviderError> {
    let scheme = if is_jwt(&key.0) { "Bearer" } else { "Apikey" };
    http::sensitive(&format!("{scheme} {}", key.0))
}

fn is_jwt(value: &str) -> bool {
    let mut parts = value.split('.');
    let (Some(_), Some(payload), Some(_), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return false;
    };
    URL_SAFE_NO_PAD
        .decode(payload)
        .or_else(|_| URL_SAFE.decode(payload))
        .ok()
        .and_then(|payload| serde_json::from_slice::<Value>(&payload).ok())
        .is_some_and(|payload| payload.is_object())
}

fn ibm_region(value: Option<&Value>) -> Result<IbmRegion, ProviderError> {
    let Some(value) = value else {
        return Ok(IbmRegion::UsEast);
    };
    if value.is_null() {
        return Ok(IbmRegion::UsEast);
    }
    let domain = value.as_str().ok_or(ProviderError::InvalidData)?.trim();
    if domain.is_empty() || domain.len() > 253 || domain.chars().any(char::is_control) {
        return Err(ProviderError::InvalidData);
    }
    let normalized = if domain.starts_with("api.") {
        domain.to_ascii_lowercase()
    } else {
        format!("api.{}", domain.to_ascii_lowercase())
    };
    match normalized.as_str() {
        "api.us-east.bob.ibm.com" => Ok(IbmRegion::UsEast),
        "api.eu-de.bob.ibm.com" => Ok(IbmRegion::EuDe),
        _ => Err(ProviderError::InvalidData),
    }
}

const KILO_PROCEDURES: [&str; 3] = [
    "user.getCreditBlocks",
    "kiloPass.getState",
    "user.getAutoTopUpPaymentMethod",
];

fn kilo(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(async move {
        let organization = kilo_organization(context)?;
        kilo_at(context, KILO_TRPC, organization.as_deref()).await
    })
}

async fn kilo_at(
    context: &ProviderContext,
    base: &str,
    organization: Option<&str>,
) -> Result<ProviderUsage, ProviderError> {
    let key = common::key(context, "KILO_API_KEY")?;
    let mut endpoint = append_path(base, &[&KILO_PROCEDURES.join(",")])?;
    {
        let mut query = endpoint.query_pairs_mut();
        query.append_pair("batch", "1");
        query.append_pair(
            "input",
            &json!({
                "0": {"json": null},
                "1": {"json": null},
                "2": {"json": null},
            })
            .to_string(),
        );
    }
    let now = context.clock.now();
    let mut request = context
        .http
        .get(endpoint)
        .header("Authorization", bearer(&key)?)
        .header("Accept", "application/json");
    if let Some(organization) = organization {
        request = request.header("X-KILOCODE-ORGANIZATIONID", http::sensitive(organization)?);
    }
    let root: Value = common::json(request, now).await?;
    let credit_payload = kilo_payload(&root, 0)?;
    let pass_payload = kilo_payload(&root, 1)?;
    let mut windows = Vec::new();
    if let Some(window) = kilo_credit_window(credit_payload, now)? {
        windows.push(window);
    }
    if let Some(window) = kilo_pass_window(pass_payload, now)? {
        windows.push(window);
    }
    if windows.is_empty() {
        return Err(ProviderError::QuotaUnavailable);
    }
    let scope = organization
        .map(|organization| format!("organization:{organization}"))
        .unwrap_or_else(|| "personal".into());
    common::usage("kilo", &key, &scope, windows)
}

fn kilo_organization(context: &ProviderContext) -> Result<Option<String>, ProviderError> {
    let Some(organization) = setting(context, "KILO_ORGANIZATION_ID")? else {
        return Ok(None);
    };
    if organization.len() > 128
        || !organization
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(ProviderError::InvalidData);
    }
    Ok(Some(organization))
}

fn kilo_payload(root: &Value, index: usize) -> Result<Option<&Value>, ProviderError> {
    let entry = match root {
        Value::Array(entries) => entries.get(index),
        Value::Object(entries) => entries.get(&index.to_string()),
        _ => return Err(ProviderError::InvalidData),
    };
    let Some(entry) = entry else {
        return Ok(None);
    };
    let entry = entry.as_object().ok_or(ProviderError::InvalidData)?;
    if entry.contains_key("error") {
        return if index == 2 {
            Ok(None)
        } else {
            Err(ProviderError::InvalidData)
        };
    }
    let data = entry
        .get("result")
        .and_then(Value::as_object)
        .and_then(|result| result.get("data"))
        .ok_or(ProviderError::InvalidData)?;
    let data_object = data.as_object().ok_or(ProviderError::InvalidData)?;
    if let Some(json) = data_object.get("json").filter(|value| !value.is_null()) {
        return Ok(Some(json));
    }
    Ok(Some(data))
}

fn kilo_credit_window(
    payload: Option<&Value>,
    now: time::OffsetDateTime,
) -> Result<Option<QuotaWindow>, ProviderError> {
    let Some(payload) = payload else {
        return Ok(None);
    };
    let payload = payload.as_object().ok_or(ProviderError::InvalidData)?;
    if let Some(blocks) = payload.get("creditBlocks").and_then(Value::as_array)
        && !blocks.is_empty()
    {
        let mut total = 0.0;
        let mut remaining = 0.0;
        for block in blocks {
            let block = block.as_object().ok_or(ProviderError::InvalidData)?;
            total += required_number(block, "amount_mUsd")? / 1_000_000.0;
            remaining += required_number(block, "balance_mUsd")? / 1_000_000.0;
        }
        if !total.is_finite() || !remaining.is_finite() {
            return Err(ProviderError::InvalidData);
        }
        return common::window(
            "Prepaid credit balance",
            Some((total - remaining).max(0.0)),
            Some(total),
            Some(remaining),
            "USD",
            None,
            "kilo_trpc",
            now,
        )
        .map(Some);
    }
    let used = common::number(
        payload
            .get("creditsUsed")
            .or_else(|| payload.get("usedCredits")),
    )?;
    let remaining = common::number(
        payload
            .get("creditsRemaining")
            .or_else(|| payload.get("remainingCredits")),
    )?;
    let total = common::number(
        payload
            .get("creditsTotal")
            .or_else(|| payload.get("totalCredits")),
    )?;
    if used.is_some() || remaining.is_some() || total.is_some() {
        let total = total.or_else(|| {
            used.zip(remaining)
                .map(|(used, remaining)| used + remaining)
        });
        if total.is_some() || used.is_some() || remaining.is_some() {
            return common::window(
                "Prepaid credit balance",
                used,
                total,
                remaining,
                "USD",
                None,
                "kilo_trpc",
                now,
            )
            .map(Some);
        }
    }
    let balance =
        common::number(payload.get("totalBalance_mUsd"))?.map(|balance| balance / 1_000_000.0);
    balance
        .map(|balance| {
            common::window(
                "Prepaid credit balance",
                None,
                None,
                Some(balance),
                "USD",
                None,
                "kilo_trpc",
                now,
            )
        })
        .transpose()
}

fn kilo_pass_window(
    payload: Option<&Value>,
    now: time::OffsetDateTime,
) -> Result<Option<QuotaWindow>, ProviderError> {
    let Some(payload) = payload else {
        return Ok(None);
    };
    let payload = payload.as_object().ok_or(ProviderError::InvalidData)?;
    let subscription = payload
        .get("subscription")
        .filter(|subscription| subscription.is_object())
        .unwrap_or(&Value::Null);
    let subscription = subscription.as_object().unwrap_or(payload);
    let used = common::number(subscription.get("currentPeriodUsageUsd"))?;
    let base = common::number(subscription.get("currentPeriodBaseCreditsUsd"))?;
    let bonus = common::number(subscription.get("currentPeriodBonusCreditsUsd"))?;
    let total = base.map(|base| base + bonus.unwrap_or(0.0)).or(bonus);
    if used.is_none() {
        return Ok(None);
    }
    let remaining = total.zip(used).map(|(total, used)| (total - used).max(0.0));
    common::window(
        "Kilo Pass credits",
        used,
        total,
        remaining,
        "USD",
        common::date(
            subscription
                .get("nextBillingAt")
                .or_else(|| subscription.get("nextRenewalAt"))
                .or_else(|| subscription.get("renewsAt")),
        )?,
        "kilo_trpc",
        now,
    )
    .map(Some)
}

fn warp(context: &ProviderContext) -> FetchFuture<'_> {
    Box::pin(warp_at(context, WARP_GRAPHQL))
}

async fn warp_at(
    context: &ProviderContext,
    endpoint: &str,
) -> Result<ProviderUsage, ProviderError> {
    let key = common::key(context, "WARP_API_KEY")?;
    let now = context.clock.now();
    let root: Value = common::json(
        context
            .http
            .post(endpoint)
            .header("Authorization", bearer(&key)?)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .header("x-warp-client-id", "warp-app")
            .header("x-warp-client-version", "v0.2026.01.07.08.13.stable_01")
            .header("User-Agent", "Warp/1.0")
            .json(&json!({
                "query": r#"query GetRequestLimitInfo($requestContext: RequestContext!) {
                    user(requestContext: $requestContext) {
                        __typename
                        ... on UserOutput {
                            user {
                                requestLimitInfo {
                                    isUnlimited
                                    nextRefreshTime
                                    requestLimit
                                    requestsUsedSinceLastRefresh
                                }
                                bonusGrants {
                                    createdAt
                                    reason
                                    userFacingMessage
                                    requestCreditsGranted
                                    requestCreditsRemaining
                                    expiration
                                }
                                workspaces {
                                    uid
                                    bonusGrantsInfo {
                                        grants {
                                            createdAt
                                            reason
                                            userFacingMessage
                                            requestCreditsGranted
                                            requestCreditsRemaining
                                            expiration
                                        }
                                    }
                                }
                            }
                        }
                    }
                }"#,
                "operationName": "GetRequestLimitInfo",
                "variables": {
                    "requestContext": {
                        "clientContext": {},
                        "osContext": {
                            "category": warp_platform(),
                            "name": warp_platform(),
                            "version": "0"
                        }
                    }
                }
            })),
        now,
    )
    .await?;
    let (windows, diagnostics) = warp_windows(&root, now)?;
    let mut usage = common::usage("warp", &key, "account", windows)?;
    usage.diagnostics = diagnostics;
    Ok(usage)
}

fn warp_platform() -> &'static str {
    match std::env::consts::OS {
        "macos" => "macOS",
        "linux" => "Linux",
        other => other,
    }
}
fn warp_windows(
    root: &Value,
    now: time::OffsetDateTime,
) -> Result<(Vec<QuotaWindow>, Vec<crate::domain::UsageDiagnostic>), ProviderError> {
    use crate::domain::{Quota, UsageDiagnostic};
    let mut diagnostics = Vec::new();
    if root
        .get("errors")
        .and_then(Value::as_array)
        .is_some_and(|errors| !errors.is_empty())
    {
        diagnostics.push(UsageDiagnostic {
            source: "warp_graphql".into(),
            code: ProviderError::InvalidData,
        });
    }
    let user = root
        .pointer("/data/user/user")
        .and_then(Value::as_object)
        .ok_or(ProviderError::InvalidData)?;
    let info = user
        .get("requestLimitInfo")
        .and_then(Value::as_object)
        .ok_or(ProviderError::InvalidData)?;
    let unlimited = info.get("isUnlimited").and_then(Value::as_bool) == Some(true);
    let used = common::number(info.get("requestsUsedSinceLastRefresh"))?;
    let limit = if unlimited {
        None
    } else {
        common::number(info.get("requestLimit"))?
    };
    let mut primary = common::window(
        "Requests",
        used,
        limit,
        None,
        "requests",
        if unlimited {
            None
        } else {
            common::date(info.get("nextRefreshTime"))?
        },
        "warp_graphql",
        now,
    )?;
    primary.metric_id = Some("warp-usage".into());
    if unlimited {
        primary.quota = Quota::Unlimited;
        primary.provenance.confidence = crate::domain::Confidence::Exact;
    }
    let mut windows = vec![primary];
    let mut grants: Vec<(String, &Value)> = Vec::new();
    if let Some(entries) = user.get("bonusGrants").filter(|v| !v.is_null()) {
        grants.extend(
            entries
                .as_array()
                .ok_or(ProviderError::InvalidData)?
                .iter()
                .map(|grant| ("user".into(), grant)),
        );
    }
    if let Some(workspaces) = user.get("workspaces").filter(|v| !v.is_null()) {
        for (index, workspace) in workspaces
            .as_array()
            .ok_or(ProviderError::InvalidData)?
            .iter()
            .enumerate()
        {
            let scope = workspace
                .get("uid")
                .and_then(Value::as_str)
                .map(|uid| format!("workspace:{uid}"))
                .unwrap_or_else(|| format!("workspace:{index}"));
            if let Some(entries) = workspace
                .pointer("/bonusGrantsInfo/grants")
                .filter(|v| !v.is_null())
            {
                grants.extend(
                    entries
                        .as_array()
                        .ok_or(ProviderError::InvalidData)?
                        .iter()
                        .map(|grant| (scope.clone(), grant)),
                );
            }
        }
    }
    let mut occurrences = std::collections::HashMap::<String, usize>::new();
    for (index, (scope, grant)) in grants.into_iter().enumerate() {
        let parsed = (|| {
            let object = grant.as_object().ok_or(ProviderError::InvalidData)?;
            let total = common::number(object.get("requestCreditsGranted"))?
                .ok_or(ProviderError::InvalidData)?;
            let remaining = common::number(object.get("requestCreditsRemaining"))?
                .ok_or(ProviderError::InvalidData)?;
            if total <= 0.0 || remaining > total {
                return Err(ProviderError::InvalidData);
            }
            let mut window = common::window(
                &format!("Bonus credits {}", index + 1),
                Some(total - remaining),
                Some(total),
                Some(remaining),
                "credits",
                common::date(object.get("expiration"))?,
                "warp_graphql",
                now,
            )?;
            let identity = crate::cache::fingerprint(&[
                &scope,
                &object.get("createdAt").unwrap_or(&Value::Null).to_string(),
                &object.get("reason").unwrap_or(&Value::Null).to_string(),
                &object.get("expiration").unwrap_or(&Value::Null).to_string(),
                &total.to_string(),
            ]);
            let occurrence = occurrences.entry(identity.clone()).or_default();
            window.metric_id = Some(format!("warp-bonus-{identity}-{}", *occurrence));
            *occurrence += 1;
            window.note = object
                .get("userFacingMessage")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|s| !s.is_empty() && s.len() <= 1024)
                .map(str::to_owned);
            Ok(window)
        })();
        match parsed {
            Ok(window) => windows.push(window),
            Err(code) => diagnostics.push(UsageDiagnostic {
                source: format!("warp_bonus_{}", index + 1),
                code,
            }),
        }
    }
    Ok((windows, diagnostics))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::{CredentialStore, Secret};
    use serde_json::json;
    use std::sync::Arc;

    struct Keys(Vec<(&'static str, &'static str)>);

    impl CredentialStore for Keys {
        fn get(&self, name: &str) -> Option<Secret> {
            self.0
                .iter()
                .find(|(candidate, _)| *candidate == name)
                .map(|(_, value)| Secret((*value).into()))
        }
    }

    fn context(entries: &[(&'static str, &'static str)]) -> ProviderContext {
        let mut context = http::fixture::context();
        context.credentials = Arc::new(Keys(entries.to_vec()));
        context
    }

    #[tokio::test]
    async fn aiand_sums_paginated_log_spend_from_a_fixture() {
        let (base, server) = http::fixture::server(vec![
            json!({
                "data": [{"cost": "1.25", "currency": "usd"}],
                "has_more": true,
                "next_after": "2026-09-05T00:00:00Z",
                "next_after_id": "row-1"
            }),
            json!({"data": [{"cost": 2, "currency": "USD"}], "has_more": false}),
        ])
        .await;
        let usage = aiand_at(
            &context(&[("AIAND_API_KEY", "test-key")]),
            &format!("{base}/logs"),
        )
        .await
        .unwrap();
        assert_eq!(usage.windows.len(), 1);
        assert_eq!(usage.windows[0].consumption.as_ref().unwrap().used, 3.25);
        assert_eq!(usage.windows[0].consumption.as_ref().unwrap().unit, "USD");
        let requests = server.await.unwrap();
        assert!(requests[0].starts_with("GET /logs?range=30days&limit=100 "));
        assert!(requests[1].contains("after=2026-09-05T00%3A00%3A00Z"));
        assert!(requests.iter().all(|request| {
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer test-key")
        }));
    }

    #[tokio::test]
    async fn alibaba_uses_the_selected_region_and_nested_quota_fixture() {
        let (base, server) = http::fixture::server(vec![json!({
            "success": true,
            "data": {
                "codingPlanInstanceInfos": [{
                    "codingPlanQuotaInfo": {
                        "per5HourUsedQuota": 25,
                        "per5HourTotalQuota": 100,
                        "per5HourQuotaNextRefreshTime": "2026-09-06T00:00:00Z",
                        "perWeekUsedQuota": 10,
                        "perWeekTotalQuota": 200
                    }
                }]
            }
        })])
        .await;
        let usage = alibaba_at(
            &context(&[("ALIBABA_CODING_PLAN_API_KEY", "test-key")]),
            &base,
            AlibabaRegion::International,
        )
        .await
        .unwrap();
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].amounts.as_ref().unwrap().remaining, 75.0);
        assert!(AlibabaRegion::from_setting("auto").is_err());
        let request = server.await.unwrap().pop().unwrap();
        assert!(request.starts_with("POST /data/api.json?action="));
        assert!(request.contains("currentRegionId=ap-southeast-1"));
        assert!(request.to_ascii_lowercase().contains("x-api-key: test-key"));
        assert!(request.contains("sfm_codingplan_public_intl"));
    }

    #[tokio::test]
    async fn clinepass_maps_subscription_percentages_from_a_fixture() {
        let (base, server) = http::fixture::server(vec![json!({
            "success": true,
            "data": {"limits": [
                {"type": "five_hour", "percentUsed": 25, "resetsAt": "2026-09-06T00:00:00Z"},
                {"type": "weekly", "percentUsed": 50},
                {"type": "ignored", "percentUsed": 5}
            ]}
        })])
        .await;
        let usage = clinepass_at(
            &context(&[("CLINEPASS_API_KEY", "test-key")]),
            &format!("{base}/limits"),
        )
        .await
        .unwrap();
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].consumption.as_ref().unwrap().used, 25.0);
        let request = server.await.unwrap().pop().unwrap();
        assert!(request.starts_with("GET /limits "));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer test-key")
        );
    }

    #[tokio::test]
    async fn clinepass_preserves_unknown_and_successful_windows_with_scoped_diagnostics() {
        let (base, server) = http::fixture::server(vec![json!({"success":true,"data":{"limits":[
            {"type":"five_hour","percentUsed":0},
            {"type":"weekly","resetsAt":"not-a-date"},
            {"type":"monthly","percentUsed":120,"resetsAt":"2020-01-01T00:00:00Z"}
        ]}})])
        .await;
        let usage = clinepass_at(
            &context(&[("CLINEPASS_API_KEY", "fixture-key")]),
            &format!("{base}/limits"),
        )
        .await
        .unwrap();
        assert_eq!(
            usage.windows[0].metric_id.as_deref(),
            Some("clinepass-five-hour")
        );
        assert!(matches!(
            usage.windows[0].quota,
            crate::domain::Quota::Available {
                remaining_percent: 100.0,
                ..
            }
        ));
        assert_eq!(usage.windows[1].quota, crate::domain::Quota::Unknown);
        assert!(usage.windows[1].resets_at.is_none());
        assert!(matches!(
            usage.windows[2].quota,
            crate::domain::Quota::Exhausted { .. }
        ));
        assert_eq!(usage.windows[2].resets_at.unwrap().year(), 2020);
        assert_eq!(usage.diagnostics.len(), 1);
        assert_eq!(usage.diagnostics[0].source, "clinepass-weekly");
        server.await.unwrap();
    }
    #[tokio::test]
    async fn clinepass_duplicate_or_missing_percent_is_unknown_not_zero() {
        let (base, server) = http::fixture::server(vec![json!({"success":true,"data":{"limits":[
            {"type":"five_hour","percentUsed":20}, {"type":"five_hour","percentUsed":30},
            {"type":"weekly"}
        ]}})])
        .await;
        let usage = clinepass_at(
            &context(&[("CLINEPASS_API_KEY", "fixture-key")]),
            &format!("{base}/limits"),
        )
        .await
        .unwrap();
        assert_eq!(usage.windows.len(), 2);
        assert!(
            usage
                .windows
                .iter()
                .all(|w| w.quota == crate::domain::Quota::Unknown && w.consumption.is_none())
        );
        assert_eq!(usage.diagnostics.len(), 2);
        assert!(
            !serde_json::to_string(&usage)
                .unwrap()
                .contains("fixture-key")
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn codebuff_reads_credit_balance_from_its_key_endpoint_fixture() {
        let (base, server) = http::fixture::server(vec![json!({
            "usage": 5,
            "quota": 20,
            "remainingBalance": 15,
            "next_quota_reset": "2026-09-06T00:00:00Z"
        })])
        .await;
        let usage = codebuff_at(
            &context(&[("CODEBUFF_API_KEY", "test-key")]),
            &format!("{base}/api/v1/usage"),
        )
        .await
        .unwrap();
        assert_eq!(usage.windows[0].consumption.as_ref().unwrap().used, 5.0);
        assert_eq!(usage.windows[0].amounts.as_ref().unwrap().remaining, 15.0);
        let request = server.await.unwrap().pop().unwrap();
        assert!(request.starts_with("POST /api/v1/usage "));
        assert!(request.contains("quotio-usage"));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer test-key")
        );
    }

    #[tokio::test]
    async fn ibm_bob_uses_only_the_fixed_regional_host_mapping() {
        let (base, server) = http::fixture::server(vec![
            json!({"instances": [
                {
                    "instance_id": "instance-one",
                    "user_id": "user-one",
                    "name": "Personal",
                    "region_domain": "us-east.bob.ibm.com",
                    "teams": [{"id": "team-one", "name": "Solo", "budget_limit": 40}]
                },
                {
                    "instance_id": "instance-two",
                    "user_id": "user-two",
                    "name": "Work",
                    "region_domain": "api.eu-de.bob.ibm.com",
                    "teams": [{"id": "team-two", "name": "Platform", "budget_limit": 160}]
                }
            ]}),
            json!({"usage": 10}),
            json!({"usage": 25}),
        ])
        .await;
        let usage = ibm_bob_at(
            &context(&[("BOBSHELL_API_KEY", "test-key")]),
            &base,
            &base,
            &base,
        )
        .await
        .unwrap();
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].consumption.as_ref().unwrap().used, 10.0);
        assert_eq!(usage.windows[1].amounts.as_ref().unwrap().remaining, 135.0);
        assert!(ibm_region(Some(&json!("evil.example"))).is_err());
        assert!(ibm_region(Some(&json!("us-east.bob.ibm.com:443"))).is_err());
        let requests = server.await.unwrap();
        assert!(requests[0].starts_with("GET /admin/v1/profile "));
        assert!(requests[1].starts_with("GET /admin/v1/teams/team-one/users/user-one "));
        assert!(requests[2].starts_with("GET /admin/v1/teams/team-two/users/user-two "));
        assert!(requests.iter().all(|request| {
            request
                .to_ascii_lowercase()
                .contains("authorization: apikey test-key")
        }));
    }

    #[tokio::test]
    async fn kilo_reads_personal_or_explicit_organization_credit_data() {
        let (base, server) = http::fixture::server(vec![json!([
            {"result": {"data": {"creditBlocks": [
                {"amount_mUsd": 20_000_000, "balance_mUsd": 15_000_000}
            ]}}},
            {"result": {"data": {"subscription": {
                "currentPeriodUsageUsd": 3,
                "currentPeriodBaseCreditsUsd": 19,
                "currentPeriodBonusCreditsUsd": 1,
                "nextBillingAt": "2026-09-06T00:00:00Z"
            }}}},
            {"result": {"data": {"enabled": false}}}
        ])])
        .await;
        let usage = kilo_at(
            &context(&[("KILO_API_KEY", "test-key")]),
            &format!("{base}/api/trpc"),
            Some("org_42"),
        )
        .await
        .unwrap();
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].amounts.as_ref().unwrap().remaining, 15.0);
        assert_eq!(usage.windows[1].amounts.as_ref().unwrap().remaining, 17.0);
        assert!(kilo_organization(&context(&[("KILO_ORGANIZATION_ID", "bad/value")])).is_err());
        let request = server.await.unwrap().pop().unwrap();
        assert!(request.starts_with("GET /api/trpc/"));
        assert!(request.contains("user.getCreditBlocks"));
        assert!(request.contains("kiloPass.getState"));
        assert!(request.contains("batch=1"));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("x-kilocode-organizationid: org_42")
        );
    }

    #[test]
    fn warp_preserves_unlimited_grant_notes_and_scope_identity() {
        let grant = json!({"createdAt":"2026-01-01T00:00:00Z","reason":"fixture","expiration":"2027-01-01T00:00:00Z","userFacingMessage":"Bonus allowance","requestCreditsGranted":100,"requestCreditsRemaining":80});
        let mut root = json!({"data":{"user":{"user":{"requestLimitInfo":{"isUnlimited":true,"requestsUsedSinceLastRefresh":7},"bonusGrants":[grant.clone()],"workspaces":[{"uid":"workspace-a","bonusGrantsInfo":{"grants":[grant]}}]}}}});
        let (windows, failures) = warp_windows(&root, time::OffsetDateTime::UNIX_EPOCH).unwrap();
        assert!(failures.is_empty());
        assert_eq!(windows[0].quota, crate::domain::Quota::Unlimited);
        assert!(windows[0].resets_at.is_none());
        assert_eq!(windows[0].consumption.as_ref().unwrap().used, 7.0);
        assert_eq!(windows[1].note.as_deref(), Some("Bonus allowance"));
        assert_ne!(windows[1].metric_id, windows[2].metric_id);
        root["data"]["user"]["user"]["bonusGrants"][0]["requestCreditsRemaining"] = 70.into();
        let (updated, _) = warp_windows(&root, time::OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(windows[1].metric_id, updated[1].metric_id);
    }
    #[test]
    fn warp_keeps_valid_requests_when_bonus_or_graphql_field_fails() {
        let root = json!({"errors":[{"message":"fixture"}],"data":{"user":{"user":{"requestLimitInfo":{"isUnlimited":false,"requestLimit":10,"requestsUsedSinceLastRefresh":2},"bonusGrants":[{}]}}}});
        let (windows, failures) = warp_windows(&root, time::OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(windows.len(), 1);
        assert_eq!(
            windows[0].quota,
            crate::domain::Quota::from_used(Some(20.0))
        );
        assert_eq!(failures.len(), 2);
    }
    #[tokio::test]
    async fn warp_maps_request_and_bonus_credit_windows_from_a_fixture() {
        let (base, server) = http::fixture::server(vec![json!({
            "data": {"user": {"user": {
                "requestLimitInfo": {
                    "isUnlimited": false,
                    "nextRefreshTime": "2026-09-06T00:00:00Z",
                    "requestLimit": 100,
                    "requestsUsedSinceLastRefresh": 25
                },
                "bonusGrants": [{
                    "requestCreditsGranted": 20,
                    "requestCreditsRemaining": 10,
                    "expiration": "2026-10-01T00:00:00Z"
                }],
                "workspaces": []
            }}}
        })])
        .await;
        let usage = warp_at(
            &context(&[("WARP_API_KEY", "test-key")]),
            &format!("{base}/graphql/v2?op=GetRequestLimitInfo"),
        )
        .await
        .unwrap();
        assert_eq!(usage.windows.len(), 2);
        assert_eq!(usage.windows[0].amounts.as_ref().unwrap().remaining, 75.0);
        assert_eq!(usage.windows[1].amounts.as_ref().unwrap().remaining, 10.0);
        let request = server.await.unwrap().pop().unwrap();
        assert!(request.contains(&format!("\"category\":\"{}\"", warp_platform())));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("x-warp-client-id: warp-app")
        );
        assert!(
            request
                .to_ascii_lowercase()
                .contains("x-warp-client-version: v0.2026.01.07.08.13.stable_01")
        );
        assert!(request.starts_with("POST /graphql/v2?op=GetRequestLimitInfo "));
        assert!(request.contains("GetRequestLimitInfo"));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer test-key")
        );
    }
}
