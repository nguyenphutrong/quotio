use super::{FetchFuture, ProviderAdapter, ProviderContext, Secret, http};
use crate::{domain::*, error::ProviderError};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::BTreeMap, io::Read, path::Path};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

#[path = "antigravity_subscription.rs"]
mod subscription_metadata;

const BASE: &str = "https://cloudcode-pa.googleapis.com/v1internal:";
pub struct AntigravityProvider;
#[derive(Deserialize)]
struct AuthFile {
    access_token: String,
}
fn read_auth(path: &Path) -> Result<Secret, ProviderError> {
    let before = std::fs::symlink_metadata(path).map_err(|_| ProviderError::Authentication)?;
    if !before.is_file() || before.is_symlink() || before.len() > 1024 * 1024 {
        return Err(ProviderError::Authentication);
    }
    let file = std::fs::File::open(path).map_err(|_| ProviderError::Authentication)?;
    let opened = file.metadata().map_err(|_| ProviderError::Authentication)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if before.dev() != opened.dev() || before.ino() != opened.ino() {
            return Err(ProviderError::Authentication);
        }
    }
    if !opened.is_file() {
        return Err(ProviderError::Authentication);
    }
    let mut bytes = Vec::new();
    file.take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ProviderError::Authentication)?;
    if bytes.len() > 1024 * 1024 {
        return Err(ProviderError::Authentication);
    }
    let auth: AuthFile =
        serde_json::from_slice(&bytes).map_err(|_| ProviderError::Authentication)?;
    if auth.access_token.trim().is_empty() {
        return Err(ProviderError::Authentication);
    }
    Ok(Secret(auth.access_token))
}
impl AntigravityProvider {
    pub(crate) async fn fetch_native_reference(
        &self,
        context: &ProviderContext,
    ) -> Result<ProviderUsage, ProviderError> {
        self.fetch_direct(context, &mut None, None).await
    }
    pub(crate) async fn fetch_from_store(
        &self,
        context: &ProviderContext,
        store: std::sync::Arc<dyn super::antigravity_auth::Store>,
    ) -> Result<ProviderUsage, ProviderError> {
        self.fetch_direct(context, &mut None, Some(store)).await
    }
    async fn fetch_direct(
        &self,
        context: &ProviderContext,
        expected: &mut Option<Identity>,
        store: Option<std::sync::Arc<dyn super::antigravity_auth::Store>>,
    ) -> Result<ProviderUsage, ProviderError> {
        let mut last = ProviderError::QuotaUnavailable;
        for base in [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:",
            BASE,
        ] {
            match self
                .fetch_api_for_account(
                    context,
                    base,
                    "https://www.googleapis.com/oauth2/v2/userinfo",
                    expected,
                    store.clone(),
                )
                .await
            {
                Ok(usage) => return Ok(usage),
                Err(error) => {
                    last = error;
                    if !matches!(
                        error,
                        ProviderError::QuotaUnavailable | ProviderError::Unavailable
                    ) {
                        break;
                    }
                }
            }
        }
        Err(last)
    }
    fn token(&self, context: &ProviderContext) -> Result<Secret, ProviderError> {
        if let Some(token) = context.credentials.get("ANTIGRAVITY_ACCESS_TOKEN") {
            return if token.0.trim().is_empty() {
                Err(ProviderError::Authentication)
            } else {
                Ok(token)
            };
        }
        if let Some(path) = context.credentials.get("ANTIGRAVITY_AUTH_FILE") {
            return read_auth(Path::new(&path.0));
        }
        Err(ProviderError::Authentication)
    }
}
#[derive(Clone, Deserialize, PartialEq)]
struct Identity {
    id: String,
    email: String,
}
fn identity_valid(identity: &Identity) -> bool {
    !identity.id.trim().is_empty() && !identity.email.trim().is_empty()
}
fn field<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    keys.iter().find_map(|key| value.get(key))
}
fn string(value: Option<&Value>) -> Option<&str> {
    value.and_then(Value::as_str).filter(|s| !s.is_empty())
}
fn subscription_plan(value: &Value) -> Option<String> {
    ["paidTier", "currentTier"].into_iter().find_map(|tier| {
        let name = value.get(tier)?.get("name")?.as_str()?;
        if name.len() > 128 || name.chars().any(char::is_control) {
            return None;
        }
        let name = name.trim();
        (!name.is_empty()).then(|| name.to_owned())
    })
}
pub(super) fn fraction(value: Option<&Value>) -> Result<Option<f64>, ProviderError> {
    let Some(value) = value.filter(|v| !v.is_null()) else {
        return Ok(None);
    };
    let n = value
        .as_f64()
        .or_else(|| value.as_str().and_then(|s| s.parse().ok()))
        .ok_or(ProviderError::InvalidData)?;
    if !n.is_finite() || !(0.0..=1.0).contains(&n) {
        return Err(ProviderError::InvalidData);
    }
    Ok(Some(n))
}
pub(super) fn window(
    label: String,
    remaining: Option<f64>,
    reset: Option<&Value>,
    source: &str,
    now: OffsetDateTime,
) -> Result<QuotaWindow, ProviderError> {
    let reset = match reset {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if s.is_empty() => None,
        Some(Value::String(s)) => {
            Some(OffsetDateTime::parse(s, &Rfc3339).map_err(|_| ProviderError::InvalidData)?)
        }
        _ => return Err(ProviderError::InvalidData),
    };
    Ok(QuotaWindow {
        note: None,
        metric_id: None,
        consumption: None,
        reset_description: None,
        label,
        quota: Quota::from_remaining(remaining.map(|v| v * 100.0)),
        amounts: None,
        resets_at: reset,
        fetched_at: now,
        provenance: Provenance {
            source: source.into(),
            confidence: if remaining.is_some() {
                Confidence::Exact
            } else {
                Confidence::Unknown
            },
        },
    })
}
fn summary(value: &Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    let groups = value
        .get("groups")
        .or_else(|| value.pointer("/response/groups"))
        .or_else(|| value.pointer("/summary/groups"))
        .and_then(Value::as_array)
        .ok_or(ProviderError::InvalidData)?;
    let mut windows = Vec::new();
    for group in groups {
        let name =
            string(field(group, &["displayName", "name"])).ok_or(ProviderError::InvalidData)?;
        for bucket in group
            .get("buckets")
            .and_then(Value::as_array)
            .ok_or(ProviderError::InvalidData)?
        {
            if bucket.get("disabled").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            let label = string(field(
                bucket,
                &["bucketId", "id", "displayName", "name", "window"],
            ))
            .ok_or(ProviderError::InvalidData)?;
            let remaining =
                field(bucket, &["remainingFraction", "remaining_fraction"]).or_else(|| {
                    bucket.get("remaining").and_then(|r| {
                        field(r, &["remainingFraction", "remaining_fraction"]).or_else(|| {
                            if string(r.get("case")) == Some("remainingFraction") {
                                r.get("value")
                            } else {
                                None
                            }
                        })
                    })
                });
            windows.push(window(
                format!("{name} {label}"),
                fraction(remaining)?,
                field(bucket, &["resetTime", "reset_time", "resetAt", "reset_at"]),
                "antigravity_api_summary",
                now,
            )?);
        }
    }
    if windows.is_empty() {
        return Err(ProviderError::InvalidData);
    }
    Ok(windows)
}
fn models(value: Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    let models: BTreeMap<String, Value> = serde_json::from_value(
        value
            .get("models")
            .cloned()
            .ok_or(ProviderError::InvalidData)?,
    )
    .map_err(|_| ProviderError::InvalidData)?;
    let mut windows = Vec::new();
    for (id, model) in models {
        let label = string(model.get("displayName")).unwrap_or(&id).to_owned();
        let info = model.get("quotaInfo");
        windows.push(window(
            label,
            fraction(info.and_then(|i| i.get("remainingFraction")))?,
            info.and_then(|i| i.get("resetTime")),
            "antigravity_api_models",
            now,
        )?);
    }
    if windows.is_empty() {
        return Err(ProviderError::InvalidData);
    }
    Ok(windows)
}
fn quota_buckets(value: Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    let buckets = value
        .get("buckets")
        .and_then(Value::as_array)
        .ok_or(ProviderError::InvalidData)?;
    let mut windows = Vec::new();
    for bucket in buckets {
        let label = string(bucket.get("modelId")).ok_or(ProviderError::InvalidData)?;
        windows.push(window(
            label.into(),
            fraction(bucket.get("remainingFraction"))?,
            bucket.get("resetTime"),
            "antigravity_api_quota",
            now,
        )?);
    }
    if windows.is_empty() || windows.iter().all(|w| w.quota == Quota::Unknown) {
        return Err(ProviderError::QuotaUnavailable);
    }
    Ok(windows)
}
async fn quota_json<T: serde::de::DeserializeOwned>(
    request: reqwest::RequestBuilder,
    now: OffsetDateTime,
) -> Result<T, ProviderError> {
    let response = request.send().await.map_err(|error| {
        if error.is_timeout() {
            ProviderError::Timeout
        } else {
            ProviderError::Transient
        }
    })?;
    // Userinfo already authenticated this token. A quota endpoint can deny scope
    // while other quota endpoints remain available; refreshing will not grant it.
    if response.status() == reqwest::StatusCode::FORBIDDEN {
        return Err(ProviderError::QuotaUnavailable);
    }
    http::json_response(response, now).await
}
impl AntigravityProvider {
    #[cfg(test)]
    async fn fetch_api(
        &self,
        context: &ProviderContext,
        base: &str,
        user_info: &str,
    ) -> Result<ProviderUsage, ProviderError> {
        self.fetch_api_for_account(context, base, user_info, &mut None, None)
            .await
    }
    async fn fetch_api_for_account(
        &self,
        context: &ProviderContext,
        base: &str,
        user_info: &str,
        expected: &mut Option<Identity>,
        store: Option<std::sync::Arc<dyn super::antigravity_auth::Store>>,
    ) -> Result<ProviderUsage, ProviderError> {
        let explicit = context
            .credentials
            .get("ANTIGRAVITY_ACCESS_TOKEN")
            .is_some()
            || context.credentials.get("ANTIGRAVITY_AUTH_FILE").is_some();
        if explicit && store.is_none() {
            return self
                .fetch_with_token(context, base, user_info, &self.token(context)?, expected)
                .await;
        }
        let mut session = super::antigravity_auth::Session::load(
            store.unwrap_or_else(|| std::sync::Arc::new(super::antigravity_auth::NativeStore)),
            context,
        )
        .await?;
        let mut result = self
            .fetch_with_token(context, base, user_info, &session.token, expected)
            .await;
        if matches!(result, Err(ProviderError::Authentication)) {
            session.refresh(context).await?;
            result = self
                .fetch_with_token(context, base, user_info, &session.token, expected)
                .await;
        }
        if result.is_ok() {
            session.verify().await?;
        }
        result
    }
    async fn fetch_with_token(
        &self,
        context: &ProviderContext,
        base: &str,
        user_info: &str,
        token: &Secret,
        expected: &mut Option<Identity>,
    ) -> Result<ProviderUsage, ProviderError> {
        let authorization = http::sensitive(&format!("Bearer {}", token.0))?;
        let before: Result<Identity, _> = http::json(
            context
                .http
                .get(user_info)
                .header("Authorization", authorization.clone()),
            context.clock.now(),
        )
        .await;
        tracing::debug!(result = ?before.as_ref().map(|_| ()), "Antigravity userinfo response");
        let before = before?;
        if !identity_valid(&before) {
            return Err(ProviderError::InvalidData);
        }
        if expected
            .as_ref()
            .is_some_and(|previous| previous != &before)
        {
            return Err(ProviderError::Authentication);
        }
        *expected = Some(before.clone());
        let post = |method: &str, payload: Value| {
            context
                .http
                .post(format!("{base}{method}"))
                .header("Authorization", authorization.clone())
                .header(
                    "User-Agent",
                    if matches!(method, "loadCodeAssist" | "retrieveUserQuota") {
                        "agy"
                    } else {
                        "antigravity"
                    },
                )
                .json(&payload)
        };
        // Subscription metadata is optional; reserve the remaining time for quota.
        let cap = std::time::Duration::from_secs(2);
        let budget =
            super::remaining_fetch_time().map_or(cap, |remaining| remaining.mul_f64(0.25).min(cap));
        let subscription: Result<Value, _> = tokio::time::timeout(
            budget,
            quota_json(
                post(
                    "loadCodeAssist",
                    json!({"metadata":{"ideType":"ANTIGRAVITY"}}),
                ),
                context.clock.now(),
            ),
        )
        .await
        .unwrap_or(Err(ProviderError::Timeout));
        tracing::debug!(result = ?subscription.as_ref().map(|_| ()), "Antigravity subscription response");
        let subscription = match subscription {
            Ok(value) => value,
            Err(
                ProviderError::Unavailable
                | ProviderError::InvalidData
                | ProviderError::QuotaUnavailable
                | ProviderError::Transient
                | ProviderError::Timeout,
            ) => json!({}),
            Err(error) => return Err(error),
        };
        let (antigravity_subscription, invalid_metadata) =
            subscription_metadata::parse(&subscription);
        let owner_project = context.credentials.get("ANTIGRAVITY_PROJECT");
        let project = antigravity_subscription
            .as_ref()
            .and_then(|info| info.cloudaicompanion_project.as_deref())
            .or_else(|| {
                owner_project
                    .as_ref()
                    .map(|project| project.0.as_str())
                    .filter(|project| {
                        project.len() <= 1024 && !project.chars().any(char::is_control)
                    })
                    .map(str::trim)
                    .filter(|project| !project.is_empty())
            });
        let payload = project
            .map(|p| json!({"project":p}))
            .unwrap_or_else(|| json!({}));
        let attempts = if project.is_some() {
            vec![payload.clone(), json!({})]
        } else {
            vec![payload.clone()]
        };
        let mut selected = None;
        for body in attempts {
            let result: Result<Value, _> =
                quota_json(post("retrieveUserQuotaSummary", body), context.clock.now()).await;
            tracing::debug!(result = ?result.as_ref().map(|_| ()), "Antigravity quota summary response");
            match result {
                Ok(value) => {
                    if let Ok(windows) = summary(&value, context.clock.now()) {
                        selected = Some(windows);
                        break;
                    }
                }
                Err(
                    ProviderError::Unavailable
                    | ProviderError::InvalidData
                    | ProviderError::QuotaUnavailable,
                ) => (),
                Err(error) => return Err(error),
            }
        }
        let windows = match selected {
            Some(windows) => windows,
            None => {
                let result = quota_json(
                    post("fetchAvailableModels", payload.clone()),
                    context.clock.now(),
                )
                .await;
                let model_windows = match result {
                    Ok(value) => Some(models(value, context.clock.now())?),
                    Err(ProviderError::QuotaUnavailable | ProviderError::Unavailable) => None,
                    Err(error) => return Err(error),
                };
                // The catalog can advertise every model as full even when quota
                // access is denied. Require a quota response to corroborate it.
                match model_windows {
                    Some(windows) if windows.iter().any(|w| matches!(w.quota, Quota::Exhausted { used_percent, .. } | Quota::Available { used_percent, .. } if used_percent > 0.0)) => windows,
                    _ => quota_buckets(quota_json(post("retrieveUserQuota", payload), context.clock.now()).await?, context.clock.now())?,
                }
            }
        };
        Ok(ProviderUsage {
            fresh_observation: false,
            history_identity: None,
            reset_credits: None,
            antigravity_subscription,
            codex_profile: None,
            codex_reset_credits: None,
            diagnostics: if invalid_metadata {
                vec![UsageDiagnostic {
                    source: "antigravity_subscription".into(),
                    code: ProviderError::InvalidData,
                }]
            } else {
                vec![]
            },
            account_ref: None,
            provider: self.id(),
            account: AccountIdentity {
                verified: None,
                subscription_status: None,
                plan: subscription_plan(&subscription),
                id: before.id,
                label: before.email,
            },
            windows,
        })
    }
}
impl ProviderAdapter for AntigravityProvider {
    fn cacheable(&self, usage: &ProviderUsage) -> bool {
        // A local-service fallback may use a different login from Keychain.
        usage
            .windows
            .iter()
            .all(|w| w.provenance.source != "antigravity_local_service")
    }

    fn cache_identity<'a>(
        &'a self,
        context: &'a ProviderContext,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<String>> + Send + 'a>> {
        Box::pin(async move {
            if context
                .credentials
                .get("ANTIGRAVITY_ACCESS_TOKEN")
                .is_some()
                || context.credentials.get("ANTIGRAVITY_AUTH_FILE").is_some()
            {
                let token = self.token(context).ok()?;
                let project = context.credentials.get("ANTIGRAVITY_PROJECT");
                Some(crate::cache::fingerprint(&[
                    "antigravity",
                    &token.0,
                    project.as_ref().map_or("", |project| &project.0),
                ]))
            } else {
                super::antigravity_auth::usage_cache_identity().await
            }
        })
    }

    fn account_ref(&self) -> Option<crate::domain::AccountRef> {
        Some(crate::domain::AccountRef {
            origin: None,
            id: "local".into(),
            label: "Local or environment Antigravity account".into(),
        })
    }
    fn id(&self) -> ProviderId {
        ProviderId("antigravity".into())
    }
    fn idempotent(&self) -> bool {
        true
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            let mut expected = None;
            let last = match self.fetch_direct(context, &mut expected, None).await {
                Ok(usage) => return Ok(usage),
                Err(error) => error,
            };
            if context
                .credentials
                .get("ANTIGRAVITY_ACCESS_TOKEN")
                .is_some()
                || context.credentials.get("ANTIGRAVITY_AUTH_FILE").is_some()
                || matches!(
                    last,
                    ProviderError::Authentication
                        | ProviderError::LocalCredentialStorage
                        | ProviderError::RateLimited
                        | ProviderError::Cancelled
                        | ProviderError::InvalidData
                )
            {
                return Err(last);
            }
            tracing::debug!("Trying Antigravity local service fallback");
            match super::antigravity_local::fetch(
                context,
                expected.as_ref().map(|i| (i.id.as_str(), i.email.as_str())),
            )
            .await
            {
                Ok(usage) => Ok(usage),
                Err(ProviderError::Unavailable) => Err(last),
                Err(error) => Err(error),
            }
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    struct Credentials {
        token: Option<String>,
        file: Option<String>,
    }
    impl super::super::CredentialStore for Credentials {
        fn get(&self, name: &str) -> Option<Secret> {
            match name {
                "ANTIGRAVITY_ACCESS_TOKEN" => self.token.clone().map(Secret),
                "ANTIGRAVITY_AUTH_FILE" => self.file.clone().map(Secret),
                _ => panic!("unexpected credential source"),
            }
        }
    }
    #[test]
    fn credentials_require_explicit_selection_and_prefer_token() {
        let mut context = http::fixture::context();
        context.credentials = std::sync::Arc::new(Credentials {
            token: None,
            file: None,
        });
        assert!(matches!(
            AntigravityProvider.token(&context),
            Err(ProviderError::Authentication)
        ));
        context.credentials = std::sync::Arc::new(Credentials {
            token: Some("synthetic-token".into()),
            file: Some("unread-file.json".into()),
        });
        assert_eq!(
            AntigravityProvider.token(&context).unwrap().0,
            "synthetic-token"
        );
        context.credentials = std::sync::Arc::new(Credentials {
            token: Some(" ".into()),
            file: None,
        });
        assert!(matches!(
            AntigravityProvider.token(&context),
            Err(ProviderError::Authentication)
        ));
    }
    #[tokio::test]
    async fn subscription_plan_is_optional_bounded_and_uses_existing_request() {
        for (status, metadata, plan) in [
            (
                200,
                json!({"paidTier":{"name":" Pro "},"currentTier":{"name":"Free"}}),
                Some("Pro"),
            ),
            (200, json!({"currentTier":{"name":"Free"}}), Some("Free")),
            (
                200,
                json!({"paidTier":{"name":"bad\nname"},"currentTier":{"name":"Free"}}),
                Some("Free"),
            ),
            (200, json!({"paidTier":{"name":"x".repeat(129)}}), None),
            (
                200,
                json!({"paidTier":{"name":42},"currentTier":{"name":" "}}),
                None,
            ),
            (200, json!({}), None),
            (403, json!({}), None),
            (500, json!({}), None),
        ] {
            let (base, task) = http::fixture::server_status(vec![
                (200, json!({"id":"demo-id","email":"demo@example.invalid"})),
                (status, metadata),
                (200, json!({"groups":[{"name":"Gemini","buckets":[{"name":"weekly","remainingFraction":0.5}]}]})),
            ]).await;
            let usage = AntigravityProvider
                .fetch_api(
                    &http::fixture::context(),
                    &format!("{base}/v1internal:"),
                    &format!("{base}/userinfo"),
                )
                .await
                .unwrap();
            assert_eq!(usage.account.plan.as_deref(), plan);
            assert_eq!(usage.windows[0].quota, Quota::from_used(Some(50.0)));
            assert_eq!(task.await.unwrap().len(), 3);
        }
    }
    #[tokio::test]
    async fn borrowed_antigravity_project_fills_missing_subscription_project() {
        struct Borrowed(String);
        impl super::super::CredentialStore for Borrowed {
            fn get(&self, name: &str) -> Option<Secret> {
                match name {
                    "ANTIGRAVITY_ACCESS_TOKEN" => Some(Secret("borrowed-token".into())),
                    "ANTIGRAVITY_PROJECT" => Some(Secret(self.0.clone())),
                    _ => None,
                }
            }
        }
        for (project, owner_project, expected_project) in [
            (None, " borrowed-project ".into(), Some("borrowed-project")),
            (
                Some("live-project"),
                "borrowed-project".into(),
                Some("live-project"),
            ),
            (None, " ".into(), None),
            (None, "bad\nproject".into(), None),
            (None, "x".repeat(1025), None),
        ] {
            let subscription = project
                .map(|project| json!({"cloudaicompanionProject":project}))
                .unwrap_or_else(|| json!({}));
            let (base, task) = http::fixture::server(vec![
                json!({"id":"demo-id","email":"demo@example.invalid"}),
                subscription,
                json!({"groups":[{"name":"Gemini","buckets":[{"name":"weekly","remainingFraction":0.75}]}]}),
            ]).await;
            let mut context = http::fixture::context();
            let credentials = std::sync::Arc::new(Borrowed(owner_project));
            context.credentials = credentials.clone();
            let cache_identity = AntigravityProvider.cache_identity(&context).await;
            context.credentials = std::sync::Arc::new(Borrowed("another-project".into()));
            assert_ne!(
                AntigravityProvider.cache_identity(&context).await,
                cache_identity
            );
            context.credentials = credentials;
            let usage = AntigravityProvider
                .fetch_api(
                    &context,
                    &format!("{base}/v1internal:"),
                    &format!("{base}/userinfo"),
                )
                .await
                .unwrap();
            assert_eq!(usage.windows[0].quota, Quota::from_used(Some(25.0)));
            let requests = task.await.unwrap();
            assert_eq!(requests.len(), 3);
            let payload: Value =
                serde_json::from_str(requests[2].split("\r\n\r\n").nth(1).unwrap()).unwrap();
            assert_eq!(
                payload.get("project").and_then(Value::as_str),
                expected_project
            );
            assert!(
                requests
                    .iter()
                    .all(|request| request.contains("Bearer borrowed-token"))
            );
        }
    }

    #[tokio::test]
    async fn rich_subscription_metadata_reaches_usage_and_quota_request() {
        let subscription =
            serde_json::from_str(include_str!("fixtures/antigravity-subscription.json")).unwrap();
        let (base, task) = http::fixture::server(vec![
            json!({"id":"demo-id","email":"demo@example.invalid"}),
            subscription,
            json!({"groups":[{"name":"Gemini","buckets":[{"name":"weekly","remainingFraction":0.5}]}]}),
        ])
        .await;
        let usage = AntigravityProvider
            .fetch_api(
                &http::fixture::context(),
                &format!("{base}/v1internal:"),
                &format!("{base}/userinfo"),
            )
            .await
            .unwrap();
        assert_eq!(usage.account.plan.as_deref(), Some("Pro"));
        assert_eq!(usage.windows[0].quota, Quota::from_used(Some(50.0)));
        assert!(usage.diagnostics.is_empty());
        let expected: Value = serde_json::from_str(include_str!(
            "fixtures/antigravity-subscription-expected.json"
        ))
        .unwrap();
        let encoded = serde_json::to_value(&usage).unwrap();
        assert_eq!(encoded["antigravity_subscription"], expected);
        let requests = task.await.unwrap();
        assert_eq!(requests.len(), 3);
        assert!(requests[2].contains("\"project\":\"synthetic-project\""));
    }

    #[tokio::test]
    async fn malformed_upgrade_metadata_preserves_quota_and_safe_siblings() {
        let (base, task) = http::fixture::server(vec![
            json!({"id":"demo-id","email":"demo@example.invalid"}),
            json!({"paidTier":{"name":"Pro","upgradeSubscriptionUri":"https://user:secret@example.invalid"},"currentTier":{"name":"Free"},"upgradeSubscriptionUri":"https://example.invalid/upgrade","allowedTiers":[false,{"name":"Ultra"}]}),
            json!({"groups":[{"name":"Gemini","buckets":[{"name":"weekly","remainingFraction":0.5}]}]}),
        ]).await;
        let usage = AntigravityProvider
            .fetch_api(
                &http::fixture::context(),
                &format!("{base}/v1internal:"),
                &format!("{base}/userinfo"),
            )
            .await
            .unwrap();
        assert_eq!(usage.account.plan.as_deref(), Some("Pro"));
        assert_eq!(usage.windows[0].quota, Quota::from_used(Some(50.0)));
        assert_eq!(usage.diagnostics.len(), 1);
        assert_eq!(usage.diagnostics[0].code, ProviderError::InvalidData);
        let metadata = usage.antigravity_subscription.as_ref().unwrap();
        assert!(
            metadata
                .paid_tier
                .as_ref()
                .unwrap()
                .upgrade_subscription_uri
                .is_none()
        );
        assert!(metadata.upgrade_subscription_uri.is_some());
        let mut legacy = serde_json::to_value(&usage).unwrap();
        legacy
            .as_object_mut()
            .unwrap()
            .remove("antigravity_subscription");
        let legacy: ProviderUsage = serde_json::from_value(legacy).unwrap();
        assert!(legacy.antigravity_subscription.is_none());
        assert!(
            !serde_json::to_value(legacy)
                .unwrap()
                .as_object()
                .unwrap()
                .contains_key("antigravity_subscription")
        );
        assert_eq!(task.await.unwrap().len(), 3);
    }
    #[tokio::test]
    async fn slow_subscription_leaves_time_for_quota() {
        let (base, server) = http::fixture::server_status_with_async_action(vec![
            (200, json!({"id":"demo-id","email":"demo@example.invalid"})),
            (200, json!({"paidTier":{"name":"Late"}})),
            (200, json!({"groups":[{"name":"Gemini","buckets":[{"name":"weekly","remainingFraction":0.5}]}]})),
        ], |index| async move {
            if index == 1 { tokio::time::sleep(std::time::Duration::from_millis(150)).await; }
        }).await;
        let context = http::fixture::context();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_millis(400);
        let usage = super::super::FETCH_DEADLINE
            .scope(
                deadline,
                tokio::time::timeout_at(
                    deadline,
                    AntigravityProvider.fetch_api(
                        &context,
                        &format!("{base}/v1internal:"),
                        &format!("{base}/userinfo"),
                    ),
                ),
            )
            .await
            .unwrap()
            .unwrap();
        assert!(usage.account.plan.is_none());
        assert_eq!(usage.windows[0].quota, Quota::from_used(Some(50.0)));
        assert_eq!(server.await.unwrap().len(), 3);
    }
    #[test]
    fn summary_keeps_groups_windows_and_unknown() {
        let value = json!({"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"session","remainingFraction":0.25},{"bucketId":"weekly","remaining":{"case":"remainingFraction","value":"0.75"}}]},{"name":"Claude","buckets":[{"name":"weekly"}]}]});
        let windows = summary(&value, OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(windows.len(), 3);
        assert_eq!(windows[0].quota, Quota::from_used(Some(75.0)));
        assert_eq!(windows[1].quota, Quota::from_used(Some(25.0)));
        assert_eq!(windows[2].quota, Quota::Unknown);
    }
    #[test]
    fn model_fallback_preserves_missing_quota() {
        let windows = models(
            json!({"models":{"a":{"quotaInfo":{"remainingFraction":0}},"b":{}}}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(windows[0].quota, Quota::from_used(Some(100.0)));
        assert_eq!(windows[1].quota, Quota::Unknown);
        assert!(
            models(
                json!({"models":{"a":{"quotaInfo":{"remainingFraction":"bad"}}}}),
                OffsetDateTime::UNIX_EPOCH
            )
            .is_err()
        );
        assert!(summary(&json!({"groups":[]}), OffsetDateTime::UNIX_EPOCH).is_err());
    }
    #[tokio::test]
    async fn direct_api_sequence_and_fallback_use_same_credential() {
        let (base, task) = http::fixture::server(vec![
            json!({"id":"demo-id","email":"demo@example.com"}),
            json!({"cloudaicompanionProject":"demo-project"}),
            json!({}),
            json!({}),
            json!({"models":{"test-model":{"quotaInfo":{"remainingFraction":0.5}}}}),
        ])
        .await;
        let provider = AntigravityProvider;
        let context = http::fixture::context();
        let usage = provider
            .fetch_api(
                &context,
                &format!("{base}/v1internal:"),
                &format!("{base}/userinfo"),
            )
            .await
            .unwrap();
        assert_eq!(usage.windows[0].provenance.source, "antigravity_api_models");
        let requests = task.await.unwrap();
        assert!(requests[0].starts_with("GET /userinfo "));
        for (request, method) in requests[1..].iter().zip([
            "loadCodeAssist",
            "retrieveUserQuotaSummary",
            "retrieveUserQuotaSummary",
            "fetchAvailableModels",
        ]) {
            assert!(request.starts_with(&format!("POST /v1internal:{method} ")));
        }
        assert!(
            requests
                .iter()
                .all(|r| r.contains("Bearer synthetic-token"))
        );
        assert!(requests[2].contains("demo-project"));
        assert!(requests[3].ends_with("{}"));
        assert!(requests[4].contains("demo-project"));
    }
    #[tokio::test]
    async fn optional_subscription_and_projectless_summary_are_supported() {
        for unavailable in [false, true] {
            let mut responses = vec![(200, json!({"id":"demo-id","email":"demo@example.com"}))];
            if unavailable {
                responses.push((404, json!({})));
            } else {
                responses.extend([
                    (200, json!({"cloudaicompanionProject":"demo-project"})),
                    (200, json!({})),
                ]);
            }
            responses.push((200,json!({"groups":[{"name":"Gemini","buckets":[{"name":"weekly","remainingFraction":0.5}]}]})));
            let (base, task) = http::fixture::server_status(responses).await;
            let provider = AntigravityProvider;
            let context = http::fixture::context();
            let usage = provider
                .fetch_api(
                    &context,
                    &format!("{base}/v1internal:"),
                    &format!("{base}/userinfo"),
                )
                .await
                .unwrap();
            assert_eq!(
                usage.windows[0].provenance.source,
                "antigravity_api_summary"
            );
            let requests = task.await.unwrap();
            assert!(
                requests
                    .last()
                    .unwrap()
                    .starts_with("POST /v1internal:retrieveUserQuotaSummary ")
            );
            assert!(requests.last().unwrap().ends_with("{}"));
        }
    }
    #[tokio::test]
    async fn auth_and_rate_limits_do_not_trigger_source_fallback() {
        for (status, expected) in [
            (401, ProviderError::Authentication),
            (429, ProviderError::RateLimited),
        ] {
            let (base, task) = http::fixture::server_status(vec![
                (200, json!({"id":"demo-id","email":"demo@example.com"})),
                (status, json!({})),
            ])
            .await;
            let context = http::fixture::context();
            let provider = AntigravityProvider;
            let result = provider
                .fetch_api(
                    &context,
                    &format!("{base}/v1internal:"),
                    &format!("{base}/userinfo"),
                )
                .await;
            assert_eq!(result.unwrap_err(), expected);
            assert_eq!(task.await.unwrap().len(), 2);
        }
    }
    #[tokio::test]
    async fn denied_summary_falls_back_but_full_catalog_requires_quota_evidence() {
        for (fraction, quota_response, expected) in [
            (0.5, None, Ok(50.0)),
            (
                1.0,
                Some((403, json!({}))),
                Err(ProviderError::QuotaUnavailable),
            ),
            (
                1.0,
                Some((
                    200,
                    json!({"buckets":[{"modelId":"test-model","remainingFraction":0.75}]}),
                )),
                Ok(25.0),
            ),
        ] {
            let mut responses = vec![
                (200, json!({"id":"test-id","email":"test@example.invalid"})),
                (200, json!({})),
                (403, json!({})),
                (
                    200,
                    json!({"models":{"test-model":{"quotaInfo":{"remainingFraction":fraction}}}}),
                ),
            ];
            if let Some(response) = quota_response {
                responses.push(response);
            }
            let count = responses.len();
            let (base, task) = http::fixture::server_status(responses).await;
            let result = AntigravityProvider
                .fetch_api(
                    &http::fixture::context(),
                    &format!("{base}/v1internal:"),
                    &format!("{base}/userinfo"),
                )
                .await;
            match expected {
                Ok(used) => assert_eq!(
                    result.unwrap().windows[0].quota,
                    Quota::from_used(Some(used))
                ),
                Err(error) => assert_eq!(result.unwrap_err(), error),
            }
            assert_eq!(task.await.unwrap().len(), count);
        }
    }
    #[test]
    fn quota_buckets_preserve_missing_fraction() {
        let windows = quota_buckets(
            json!({"buckets":[{"modelId":"first","remainingFraction":0.5},{"modelId":"second"}]}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(windows[1].quota, Quota::Unknown);
        assert_eq!(
            quota_buckets(json!({"buckets":[]}), OffsetDateTime::UNIX_EPOCH).unwrap_err(),
            ProviderError::QuotaUnavailable
        );
    }
    #[test]
    fn credential_files_are_bounded_and_never_rewritten() {
        let directory =
            std::env::temp_dir().join(format!("quotio-antigravity-auth-{}", std::process::id()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("auth.json");
        let contents = br#"{"access_token":"synthetic-token","refresh_token":"untouched"}"#;
        std::fs::write(&path, contents).unwrap();
        let mut context = http::fixture::context();
        context.credentials = std::sync::Arc::new(Credentials {
            token: None,
            file: Some(path.to_str().unwrap().into()),
        });
        assert_eq!(
            AntigravityProvider.token(&context).unwrap().0,
            "synthetic-token"
        );
        assert_eq!(std::fs::read(&path).unwrap(), contents);
        #[cfg(unix)]
        {
            let link = directory.join("link.json");
            std::os::unix::fs::symlink(&path, &link).unwrap();
            assert!(matches!(
                read_auth(&link),
                Err(ProviderError::Authentication)
            ));
            std::fs::remove_file(link).unwrap();
        }
        std::fs::write(&path, vec![b'a'; 1024 * 1024 + 1]).unwrap();
        assert!(matches!(
            read_auth(&path),
            Err(ProviderError::Authentication)
        ));
        std::fs::write(&path, b"not-json-sentinel").unwrap();
        assert!(matches!(
            read_auth(&path),
            Err(ProviderError::Authentication)
        ));
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }
}
