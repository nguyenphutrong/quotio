use super::{AuthKind, Definition, Setting, common};
use crate::{
    domain::{ProviderUsage, QuotaWindow},
    error::ProviderError,
    providers::{FetchFuture, ProviderContext},
};
use serde_json::Value;
use time::OffsetDateTime;

const DEVIN_API_BASE: &str = "https://api.devin.ai";
const OPENCODE_GO_USAGE_URL: &str = "https://opencode.ai/zen/go/v1/usage";

const DEVIN_SETTINGS: &[Setting] = &[Setting {
    name: "organization_id",
    env: "DEVIN_ORG_ID",
    required: true,
}];

pub const DEFINITIONS: &[Definition] = &[
    Definition {
        id: "devin",
        name: "Devin",
        key_env: "DEVIN_API_KEY",
        auth: AuthKind::ApiKey,
        settings: DEVIN_SETTINGS,
        fetch: fetch_devin,
    },
    Definition {
        id: "opencodego",
        name: "OpenCode Go",
        key_env: "OPENCODE_API_KEY",
        auth: AuthKind::ApiKey,
        settings: &[],
        fetch: fetch_opencode_go,
    },
];

fn devin_organization_id(context: &ProviderContext) -> Result<String, ProviderError> {
    let value = context
        .credentials
        .get("DEVIN_ORG_ID")
        .ok_or(ProviderError::InvalidData)?;
    let organization = value.0.trim();
    if organization.len() > 256
        || !organization.starts_with("org-")
        || organization.len() == "org-".len()
        || !organization
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(ProviderError::InvalidData);
    }
    Ok(organization.into())
}

fn devin_windows(root: &Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    let daily = root
        .get("consumption_by_date")
        .and_then(Value::as_array)
        .ok_or(ProviderError::InvalidData)?;
    for entry in daily {
        let entry = entry.as_object().ok_or(ProviderError::InvalidData)?;
        common::number(entry.get("acus"))?.ok_or(ProviderError::InvalidData)?;
    }
    let total = common::number(root.get("total_acus"))?.ok_or(ProviderError::InvalidData)?;
    Ok(vec![common::window(
        "Organization ACU consumption",
        Some(total),
        None,
        None,
        "ACU",
        None,
        "devin_organization_consumption_api",
        now,
    )?])
}

async fn fetch_devin_at(
    context: &ProviderContext,
    api_base: &str,
) -> Result<ProviderUsage, ProviderError> {
    let key = common::key(context, "DEVIN_API_KEY")?;
    let organization = devin_organization_id(context)?;
    let now = context.clock.now();
    let root: Value = common::json(
        context
            .http
            .get(format!(
                "{api_base}/v3/organizations/{organization}/consumption/daily"
            ))
            .header(
                "Authorization",
                crate::providers::http::sensitive(&format!("Bearer {}", key.0))?,
            )
            .header("Accept", "application/json"),
        now,
    )
    .await?;
    common::usage(
        "devin",
        &key,
        &format!("organization:{organization}"),
        devin_windows(&root, now)?,
    )
}

fn fetch_devin<'a>(context: &'a ProviderContext) -> FetchFuture<'a> {
    Box::pin(fetch_devin_at(context, DEVIN_API_BASE))
}

fn opencode_go_windows(
    root: &Value,
    now: OffsetDateTime,
) -> Result<Vec<QuotaWindow>, ProviderError> {
    let usage = root
        .get("usage")
        .and_then(Value::as_object)
        .ok_or(ProviderError::InvalidData)?;
    let mut windows = Vec::with_capacity(3);
    for (field, label, metric_id) in [
        ("rolling", "5-hour", "opencodego-five-hour"),
        ("weekly", "Weekly", "opencodego-weekly"),
        ("monthly", "Monthly", "opencodego-monthly"),
    ] {
        let window = usage
            .get(field)
            .and_then(Value::as_object)
            .ok_or(ProviderError::InvalidData)?;
        match window.get("status").and_then(Value::as_str) {
            Some("ok" | "rate-limited") => (),
            _ => return Err(ProviderError::InvalidData),
        }
        let percent = common::number(window.get("percent"))?.ok_or(ProviderError::InvalidData)?;
        if percent > 100.0 {
            return Err(ProviderError::InvalidData);
        }
        let resets_at = common::date(window.get("resetsAt"))?.ok_or(ProviderError::InvalidData)?;
        let mut window = common::window(
            label,
            Some(percent),
            Some(100.0),
            None,
            "percent",
            Some(resets_at),
            "opencode_go_usage_api",
            now,
        )?;
        window.metric_id = Some(metric_id.into());
        windows.push(window);
    }
    Ok(windows)
}

async fn fetch_opencode_go_at(
    context: &ProviderContext,
    usage_url: &str,
) -> Result<ProviderUsage, ProviderError> {
    let key = common::key(context, "OPENCODE_API_KEY")?;
    let now = context.clock.now();
    let root: Value = common::json(
        context
            .http
            .get(usage_url)
            .header(
                "Authorization",
                crate::providers::http::sensitive(&format!("Bearer {}", key.0))?,
            )
            .header("Accept", "application/json"),
        now,
    )
    .await?;
    common::usage("opencodego", &key, "go", opencode_go_windows(&root, now)?)
}

fn fetch_opencode_go<'a>(context: &'a ProviderContext) -> FetchFuture<'a> {
    Box::pin(fetch_opencode_go_at(context, OPENCODE_GO_USAGE_URL))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        domain::Quota,
        providers::{CredentialStore, Secret, http},
    };
    use serde_json::json;
    use std::sync::Arc;

    struct Keys(Vec<(&'static str, &'static str)>);

    impl CredentialStore for Keys {
        fn get(&self, name: &str) -> Option<Secret> {
            self.0
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| Secret((*value).into()))
        }
    }

    fn context(keys: &[(&'static str, &'static str)]) -> ProviderContext {
        let mut context = http::fixture::context();
        context.credentials = Arc::new(Keys(keys.to_vec()));
        context
    }

    #[test]
    fn production_usage_endpoints_are_fixed_https_routes() {
        assert_eq!(
            format!("{DEVIN_API_BASE}/v3/organizations/org-fixture/consumption/daily"),
            "https://api.devin.ai/v3/organizations/org-fixture/consumption/daily",
        );
        assert_eq!(OPENCODE_GO_USAGE_URL, "https://opencode.ai/zen/go/v1/usage");
    }

    #[test]
    fn devin_reports_source_consumption_without_inventing_a_cap() {
        let windows = devin_windows(
            &json!({
                "consumption_by_date": [{"date": 1_788_696_000, "acus": 1.25}],
                "total_acus": 1.25,
            }),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();

        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].label, "Organization ACU consumption");
        assert_eq!(windows[0].quota, Quota::Unknown);
        assert_eq!(windows[0].consumption.as_ref().unwrap().used, 1.25);
        assert_eq!(windows[0].consumption.as_ref().unwrap().unit, "ACU");
        assert!(windows[0].amounts.is_none());
    }

    #[test]
    fn opencode_go_requires_all_documented_windows_and_percent_units() {
        let windows = opencode_go_windows(
            &json!({
                "usage": {
                    "rolling": {"status": "ok", "percent": 12.5, "resetsAt": "2026-09-05T05:00:00Z"},
                    "weekly": {"status": "rate-limited", "percent": 100, "resetsAt": "2026-09-08T00:00:00Z"},
                    "monthly": {"status": "ok", "percent": 3, "resetsAt": "2026-10-01T00:00:00Z"},
                }
            }),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();

        assert_eq!(windows.len(), 3);
        assert_eq!(windows[0].label, "5-hour");
        assert_eq!(
            windows
                .iter()
                .map(|window| window.metric_id.as_deref())
                .collect::<Vec<_>>(),
            [
                Some("opencodego-five-hour"),
                Some("opencodego-weekly"),
                Some("opencodego-monthly"),
            ]
        );
        assert_eq!(windows[0].quota, Quota::from_used(Some(12.5)));
        assert_eq!(windows[1].quota, Quota::from_used(Some(100.0)));
        assert_eq!(windows[2].consumption.as_ref().unwrap().unit, "percent");
        assert!(opencode_go_windows(
            &json!({"usage": {"rolling": {"status": "ok", "percent": 1, "resetsAt": "2026-09-05T05:00:00Z"}}}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .is_err());
    }

    #[tokio::test]
    async fn devin_uses_the_documented_organization_consumption_route() {
        let (base, task) = http::fixture::server(vec![json!({
            "consumption_by_date": [{"date": 1_788_696_000, "acus": 2}],
            "total_acus": 2,
        })])
        .await;
        let context = context(&[
            ("DEVIN_API_KEY", "devin-test-key"),
            ("DEVIN_ORG_ID", "org-fixture"),
        ]);

        let usage = fetch_devin_at(&context, &base).await.unwrap();
        assert_eq!(usage.provider.0, "devin");
        assert_eq!(usage.windows[0].consumption.as_ref().unwrap().used, 2.0);
        let requests = task.await.unwrap();
        assert!(requests[0].starts_with("GET /v3/organizations/org-fixture/consumption/daily "));
        assert!(
            requests[0]
                .to_lowercase()
                .contains("authorization: bearer devin-test-key")
        );
    }

    #[tokio::test]
    async fn opencode_go_uses_its_fixed_usage_route() {
        let (base, task) = http::fixture::server(vec![json!({
            "usage": {
                "rolling": {"status": "ok", "percent": 10, "resetsAt": "2026-09-05T05:00:00Z"},
                "weekly": {"status": "ok", "percent": 20, "resetsAt": "2026-09-08T00:00:00Z"},
                "monthly": {"status": "ok", "percent": 30, "resetsAt": "2026-10-01T00:00:00Z"},
            }
        })])
        .await;
        let context = context(&[("OPENCODE_API_KEY", "opencode-test-key")]);

        let usage_url = format!("{base}/zen/go/v1/usage");
        let usage = fetch_opencode_go_at(&context, &usage_url).await.unwrap();
        assert_eq!(usage.provider.0, "opencodego");
        assert_eq!(usage.windows[2].quota, Quota::from_used(Some(30.0)));
        let requests = task.await.unwrap();
        assert!(requests[0].starts_with("GET /zen/go/v1/usage "));
        assert!(
            requests[0]
                .to_lowercase()
                .contains("authorization: bearer opencode-test-key")
        );
    }
}
