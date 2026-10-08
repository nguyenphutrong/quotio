//! The versioned OpenAPI description of Quotio's local HTTP API.

use axum::Json;
use serde_json::Value;

/// Return the checked-in API contract. Keeping the source as JSON makes it
/// useful to clients and avoids duplicating the domain serializers here.
pub(super) async fn document() -> Json<Value> {
    Json(serde_json::from_str(include_str!("../../docs/openapi.json")).expect("valid OpenAPI JSON"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn document_value() -> Value {
        serde_json::from_str(include_str!("../../docs/openapi.json")).unwrap()
    }

    #[test]
    fn document_is_openapi_31_and_resolves_local_references() {
        let document = document_value();
        assert_eq!(document["openapi"], "3.1.0");
        assert!(document["paths"].as_object().is_some_and(|p| p.len() >= 16));

        fn visit(value: &Value, root: &Value) {
            match value {
                Value::Object(map) => {
                    if let Some(reference) = map.get("$ref").and_then(Value::as_str) {
                        assert!(reference.starts_with("#/"), "external ref: {reference}");
                        let mut current = root;
                        for part in reference[2..].split('/') {
                            let part = part.replace("~1", "/").replace("~0", "~");
                            current = &current[part];
                            assert!(!current.is_null(), "unresolved ref: {reference}");
                        }
                    }
                    for child in map.values() {
                        visit(child, root);
                    }
                }
                Value::Array(values) => {
                    for child in values {
                        visit(child, root);
                    }
                }
                _ => {}
            }
        }
        visit(&document, &document);
    }

    #[test]
    fn document_covers_routes_schemas_statuses_nullable_fields_and_auth() {
        let d = document_value();
        let paths = d["paths"].as_object().unwrap();
        for path in [
            "/openapi.json",
            "/health",
            "/v2/status",
            "/v2/clients",
            "/v2/clients/{id}",
            "/v2/providers",
            "/v2/providers/{id}",
            "/v2/snapshot",
            "/v2/accounts",
            "/v2/accounts/{id}",
            "/v2/sources/{id}",
            "/v2/auth/sessions",
            "/v2/auth/sessions/{id}",
            "/v2/auth/sessions/{id}/callback",
            "/v2/settings",
            "/v2/refresh",
            "/v2/operations/{id}",
        ] {
            assert!(paths.contains_key(path), "missing path {path}");
        }
        for status in ["running", "completed", "failed"] {
            assert!(
                d["components"]["schemas"]["Operation"]["properties"]["status"]["enum"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|v| v == status)
            );
        }
        for schema in [
            "Quota",
            "QuotaAmounts",
            "UsageReport",
            "SettingsView",
            "SettingsPatch",
            "Session",
        ] {
            assert!(
                d["components"]["schemas"].get(schema).is_some(),
                "missing {schema}"
            );
        }
        assert_eq!(
            d["components"]["schemas"]["QuotaWindow"]["properties"]["resets_at"]["type"][1],
            "null"
        );
        assert_eq!(
            d["components"]["schemas"]["QuotaAmounts"]["properties"]["limit"]["type"][1],
            "null"
        );
        assert!(
            d["components"]["schemas"]["Operation"]["properties"]["message"]["type"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v == "null")
        );
        assert!(
            paths["/v2/accounts"]["post"]["security"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s["bearerAuth"].is_array())
        );
        assert!(
            paths["/v2/snapshot"]["get"]["security"]
                .as_array()
                .unwrap()
                .iter()
                .any(|value| value.as_object().is_some_and(|object| object.is_empty()))
        );
        assert!(
            paths["/v2/accounts"]["post"]["parameters"]
                .as_array()
                .unwrap()
                .iter()
                .any(|p| p["name"] == "Idempotency-Key")
        );
        let account_refresh = &d["components"]["schemas"]["RefreshRequest"]["allOf"][0];
        assert_eq!(account_refresh["if"]["required"][0], "account_id");
        assert_eq!(
            account_refresh["if"]["properties"]["account_id"]["type"],
            "string"
        );
        assert_eq!(account_refresh["then"]["required"][0], "providers");
        assert_eq!(
            account_refresh["then"]["properties"]["providers"]["minItems"],
            1
        );
        assert_eq!(
            account_refresh["then"]["properties"]["providers"]["maxItems"],
            1
        );
    }

    #[test]
    fn provider_routes_match_runtime_envelope() {
        let d = document_value();
        let provider = serde_json::to_value(super::super::provider_value(
            crate::cli::Provider::Codex,
            &[],
        ))
        .unwrap();
        validate(
            &d["components"]["schemas"]["ProviderList"],
            &serde_json::json!({"schema_version":2,"providers":[provider.clone()]}),
            &d,
            "providers",
        );
        validate(
            &d["paths"]["/v2/providers/{id}"]["get"]["responses"]["200"]["content"]["application/json"]
                ["schema"],
            &provider,
            &d,
            "provider",
        );
    }

    fn validate(schema: &Value, value: &Value, root: &Value, path: &str) {
        let mut schema = schema.clone();
        schema["components"] = root["components"].clone();
        let validator = jsonschema::draft202012::options()
            .should_validate_formats(true)
            .build(&schema)
            .unwrap();
        let errors: Vec<_> = validator
            .iter_errors(value)
            .map(|error| error.to_string())
            .collect();
        assert!(errors.is_empty(), "{path}: {}", errors.join("; "));
    }

    #[test]
    fn schemas_validate_runtime_serialized_values() {
        let document = document_value();
        let schemas = &document["components"]["schemas"];
        for capability in crate::providers::capabilities::all() {
            let value = serde_json::to_value(capability).unwrap();
            validate(
                &schemas["ProviderCapability"],
                &value,
                &document,
                "capability",
            );
        }
        let mut operations = crate::server::operations::Operations::default();
        let (operation, _) = operations
            .start("owner", "refresh", None, "runtime".into())
            .unwrap();
        validate(
            &schemas["Operation"],
            &serde_json::to_value(operation).unwrap(),
            &document,
            "operation",
        );
        let account = crate::accounts::api::AccountDto {
            source_kind: Some("claude_native"),
            source_location: Some("code_keychain".into()),
            source_id: Some("opaque-source-id".into()),
            enabled: true,
            origin: crate::accounts::AccountOrigin::Owned,
            id: "synthetic-account".into(),
            provider: crate::cli::Provider::Mock,
            label: "Demo".into(),
            active: true,
        };
        validate(
            &schemas["Account"],
            &serde_json::to_value(account).unwrap(),
            &document,
            "account",
        );
        let now = time::OffsetDateTime::UNIX_EPOCH;
        let report = crate::domain::UsageReport {
            schema_version: 1,
            generated_at: now,
            providers: vec![crate::domain::ProviderUsage {
                fresh_observation: false,
                history_identity: None,
                reset_credits: Some(crate::domain::ResetCredits {
                    available_count: 2,
                    earliest_expires_at: Some(now + time::Duration::days(1)),
                    fetched_at: now,
                    source: "codex_api".into(),
                }),
                antigravity_subscription: Some(
                    serde_json::from_str(include_str!(
                        "../providers/fixtures/antigravity-subscription-expected.json"
                    ))
                    .unwrap(),
                ),
                codex_profile: Some(crate::domain::CodexProfileAnalytics {
                    daily_usage: vec![crate::domain::CodexDailyUsage {
                        date: "1970-01-01".into(),
                        tokens: 0,
                    }],
                    latest_30_buckets_tokens: 0,
                    lifetime_tokens: Some(42),
                    peak_daily_tokens: None,
                    longest_running_turn_seconds: Some(60),
                    current_streak_days: Some(0),
                    longest_streak_days: None,
                    fetched_at: now,
                }),
                codex_reset_credits: Some(crate::domain::CodexResetCreditInventory {
                    available_count: 2,
                    credits: vec![crate::domain::CodexResetCredit {
                        id: "a".repeat(64),
                        expires_at: None,
                    }],
                    fetched_at: now,
                }),
                diagnostics: vec![crate::domain::UsageDiagnostic {
                    source: "fixture".into(),
                    code: crate::error::ProviderError::Transient,
                }],
                account_ref: None,
                provider: crate::domain::ProviderId("mock".into()),
                account: crate::domain::AccountIdentity {
                    verified: None,
                    subscription_status: None,
                    plan: None,
                    id: "demo".into(),
                    label: "Demo".into(),
                },
                windows: vec![crate::domain::QuotaWindow {
                    note: None,
                    metric_id: None,
                    consumption: None,
                    label: "daily".into(),
                    quota: crate::domain::Quota::Unknown,
                    amounts: None,
                    resets_at: None,
                    reset_description: None,
                    provenance: crate::domain::Provenance {
                        source: "fixture".into(),
                        confidence: crate::domain::Confidence::Unknown,
                    },
                    fetched_at: now,
                }],
            }],
            failures: vec![],
        };
        let mut report = serde_json::to_value(report).unwrap();
        let expected: Value = serde_json::from_str(include_str!(
            "../providers/fixtures/antigravity-subscription-expected.json"
        ))
        .unwrap();
        assert_eq!(report["providers"][0]["antigravity_subscription"], expected);
        validate(&schemas["UsageReport"], &report, &document, "usage");
        report["providers"][0]
            .as_object_mut()
            .unwrap()
            .remove("antigravity_subscription");
        validate(&schemas["UsageReport"], &report, &document, "legacy usage");
        for name in [
            "AntigravitySubscriptionInfo",
            "AntigravitySubscriptionTier",
            "AntigravityPrivacyNotice",
        ] {
            assert_eq!(schemas[name]["additionalProperties"], false);
            validate(&schemas[name], &serde_json::json!({}), &document, name);
        }
        let settings = crate::settings::SettingsView {
            revision: "runtime".into(),
            values: crate::config::Config::default(),
            overridden: vec![],
        };
        validate(
            &schemas["SettingsView"],
            &serde_json::to_value(settings).unwrap(),
            &document,
            "settings",
        );
        for status in [
            crate::accounts::oauth::SessionStatus::Waiting,
            crate::accounts::oauth::SessionStatus::Processing,
            crate::accounts::oauth::SessionStatus::Completed,
            crate::accounts::oauth::SessionStatus::Failed,
            crate::accounts::oauth::SessionStatus::Cancelled,
            crate::accounts::oauth::SessionStatus::Expired,
        ] {
            let session = crate::accounts::oauth::SessionDto {
                provider: crate::cli::Provider::Codex,
                workflow: crate::accounts::oauth::Workflow::BrowserCallback,
                user_code: None,
                id: "runtime-session".into(),
                url: "https://auth.openai.com/oauth/authorize".into(),
                expires_at: 1,
                status,
                account_id: None,
                error_code: None,
            };
            validate(
                &schemas["Session"],
                &serde_json::to_value(session).unwrap(),
                &document,
                "session",
            );
        }
    }
}
