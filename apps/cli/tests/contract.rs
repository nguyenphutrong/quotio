//! Offline conformance checks shared by CLI and HTTP serializers.
use clap::ValueEnum;
use quotio::{
    cli::Provider,
    domain::UsageReport,
    providers::{Clock, CredentialStore, ProviderContext, Secret, capabilities::ProviderList},
};
use serde_json::{Value, json};
use std::sync::Arc;
use time::{OffsetDateTime, macros::datetime};

fn validator(name: &str) -> jsonschema::Validator {
    let document: Value = serde_json::from_str(include_str!("../docs/openapi.json")).unwrap();
    jsonschema::draft202012::options()
        .should_validate_formats(true)
        .build(&json!({
            "$ref":format!("#/components/schemas/{name}"),
            "components": document["components"]
        }))
        .unwrap()
}

#[test]
fn source_patch_contract_matches_runtime_scope_and_null_rules() {
    use quotio::accounts::api::SourcePatch;
    let schema = validator("V2SourcePatch");
    for (value, valid) in [
        (json!({"enabled":false}), true),
        (
            json!({"api_key":"replacement", "settings":null, "region":null}),
            true,
        ),
        (
            json!({"api_key":"replacement", "organization":"team", "enabled":true}),
            true,
        ),
        (json!({}), false),
        (json!({"enabled":null}), false),
        (json!({"api_key":null}), false),
        (json!({"enabled":true, "settings":{}}), false),
        (json!({"label":"group label"}), false),
        (json!({"active":true}), false),
    ] {
        assert_eq!(schema.is_valid(&value), valid);
        let runtime = serde_json::from_value::<SourcePatch>(value)
            .ok()
            .and_then(|patch| patch.into_account_patch().ok());
        assert_eq!(runtime.is_some(), valid);
    }
}

#[test]
fn every_registered_provider_conforms_to_the_public_contract() {
    let value = serde_json::to_value(ProviderList::new(&[Provider::Mock])).unwrap();
    validator("ProviderList").validate(&value).unwrap();
    let providers = value["providers"].as_array().unwrap();
    assert_eq!(providers.len(), Provider::value_variants().len());
    for provider in Provider::value_variants() {
        let rows: Vec<_> = providers
            .iter()
            .filter(|row| row["id"] == provider.id())
            .collect();
        assert_eq!(rows.len(), 1, "{}", provider.id());
        assert_eq!(rows[0]["id"], rows[0]["capabilities"]["provider"]);
        let icons = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../macos/Quotio/Assets.xcassets/ProviderIcons");
        let svg = |name: &str| icons.join(format!("{name}.imageset/{name}.svg"));
        match rows[0]["icon"].as_str() {
            Some(icon) => {
                let logo = std::fs::read_to_string(svg(icon)).expect(icon);
                assert!(logo.contains("currentColor"), "{icon} must be tintable");
            }
            None => assert!(!svg(provider.id()).exists(), "{} has a logo", provider.id()),
        }
        assert!(
            rows[0]["capabilities"]["operations"]
                .as_array()
                .unwrap()
                .contains(&json!("usage"))
        );
    }
    let mut invalid = value.clone();
    invalid["providers"][0]["enabled"] = json!("true");
    assert!(!validator("ProviderList").is_valid(&invalid));
}

#[test]
fn provider_coverage_table_matches_the_runtime_registry() {
    let catalog = serde_json::to_value(ProviderList::new(&[])).unwrap();
    let joined = |values: Vec<String>| {
        if values.is_empty() {
            "—".into()
        } else {
            values.join(", ")
        }
    };
    let mut table = String::from(
        "| Provider | Authentication | Sources (ownership) | Account storage OS |\n| --- | --- | --- | --- |\n",
    );
    for row in catalog["providers"].as_array().unwrap() {
        let capability = &row["capabilities"];
        let strings = |key: &str| {
            capability[key]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap().to_owned())
                .collect()
        };
        let sources = capability["source_references"]
            .as_array()
            .unwrap()
            .iter()
            .map(|source| {
                format!(
                    "{} ({})",
                    source["kind"].as_str().unwrap(),
                    source["origin"].as_str().unwrap()
                )
            })
            .collect();
        table.push_str(&format!(
            "| {} | {} | {} | {} |\n",
            row["id"].as_str().unwrap(),
            joined(strings("auth")),
            joined(sources),
            joined(strings("account_storage_platforms"))
        ));
    }
    let document = include_str!("../docs/provider-coverage.md");
    for document in [
        document.to_owned(),
        document.replace("\r\n", "\n").replace('\n', "\r\n"),
    ] {
        assert_eq!(
            document
                .replace("\r\n", "\n")
                .split_once("<!-- registry-table -->\n")
                .unwrap()
                .1,
            table
        );
    }
}

struct Fixture;
impl Clock for Fixture {
    fn now(&self) -> OffsetDateTime {
        datetime!(2026-01-01 0:00 UTC)
    }
}
impl CredentialStore for Fixture {
    fn get(&self, _: &str) -> Option<Secret> {
        panic!("mock contract must not read credentials")
    }
}

#[tokio::test]
async fn mock_serializer_matches_the_shared_frontend_fixture() {
    let context = ProviderContext {
        http: reqwest::Client::new(),
        clock: Arc::new(Fixture),
        credentials: Arc::new(Fixture),
    };
    let report = UsageReport {
        schema_version: 1,
        generated_at: context.clock.now(),
        providers: vec![Provider::Mock.adapter().fetch(&context).await.unwrap()],
        failures: vec![],
    };
    let value = serde_json::to_value(&report).unwrap();
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/contracts/usage-v1.json")).unwrap();
    assert_eq!(value, fixture);
    validator("UsageReport").validate(&value).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&serde_json::to_string_pretty(&report).unwrap()).unwrap(),
        value
    );
    let mut invalid = value;
    invalid["providers"][0]["windows"][0]["quota"]["state"] = json!("invented");
    assert!(!validator("UsageReport").is_valid(&invalid));
}

#[test]
fn resolved_v2_snapshot_roundtrips_and_enforces_account_source_boundaries() {
    use quotio::contract::Snapshot;
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/contracts/snapshot-v2.json")).unwrap();
    validator("V2Snapshot").validate(&fixture).unwrap();
    let snapshot: Snapshot = serde_json::from_value(fixture.clone()).unwrap();
    snapshot.validate().unwrap();
    assert_eq!(serde_json::to_value(&snapshot).unwrap(), fixture);
    assert!(snapshot.usage[0].metrics.is_empty()); // Valid plan-only account.
    assert_eq!(snapshot.accounts[1].sources.len(), 2); // One account, two sources.
    for mutate in [
        |s: &mut Snapshot| s.accounts[1].id = s.accounts[0].id.clone(),
        |s: &mut Snapshot| s.accounts[1].sources[0].id = s.accounts[0].sources[0].id.clone(),
        |s: &mut Snapshot| s.usage[0].account_id = "missing".into(),
        |s: &mut Snapshot| s.accounts[1].sources[1].selected = true,
        |s: &mut Snapshot| s.accounts[0].enabled = false,
        |s: &mut Snapshot| s.schema_version = 1,
        |s: &mut Snapshot| s.usage[0].fetched_at = None,
        |s: &mut Snapshot| {
            s.account_redirects.insert("old".into(), "missing".into());
        },
        |s: &mut Snapshot| s.accounts[0].id = "invalid/id".into(),
    ] {
        let mut invalid = snapshot.clone();
        mutate(&mut invalid);
        assert!(invalid.validate().is_err());
    }
    let mut missing = fixture.clone();
    missing["accounts"][0]
        .as_object_mut()
        .unwrap()
        .remove("display_name");
    assert!(!validator("V2Snapshot").is_valid(&missing));
    let mut invalid = fixture;
    invalid["usage"][0]["freshness"] = json!("invented");
    assert!(!validator("V2Snapshot").is_valid(&invalid));
}

#[test]
fn resolved_read_projection_matches_the_frontend_fixture() {
    use quotio::accounts::{Credential, Document, LabelOrigin, resolved::Registry};
    let mut document = Document::empty();
    for (id, label, origin) in [
        ("source-a", "Work", LabelOrigin::User),
        ("source-b", "Generated", LabelOrigin::Generated),
    ] {
        document
            .add_named(
                Provider::Amp,
                label,
                origin,
                id.into(),
                Credential::ApiKey {
                    token: "fixture-secret".into(),
                    region: None,
                    organization: None,
                },
            )
            .unwrap();
        document.accounts.last_mut().unwrap().id = id.into();
    }
    let mut registry = Registry::new(&document.accounts).unwrap();
    registry.host_id = "host-fixture".into();
    registry.revision = 7;
    let proof = quotio::domain::VerifiedIdentity {
        subject: "fixture-user".into(),
        tenant: None,
    };
    registry.observe("source-a", &proof).unwrap();
    registry.observe("source-b", &proof).unwrap();
    let accounts = registry.account_list(&document.accounts).unwrap();
    assert_eq!(accounts.host.platform, std::env::consts::OS);
    let mut value = serde_json::to_value(accounts).unwrap();
    validator("V2AccountList").validate(&value).unwrap();
    value["host"]["platform"] = json!("macos"); // Only the platform varies across CI hosts.
    let fixture: Value =
        serde_json::from_str(include_str!("fixtures/contracts/accounts-v2.json")).unwrap();
    assert_eq!(value, fixture);
}

#[tokio::test]
async fn snapshot_selects_healthy_sources_and_preserves_quota_semantics() {
    use quotio::{
        contract::{AccountList, ConnectionState, Freshness, snapshot::project},
        domain::{AccountRef, ProviderFailure},
        error::ProviderError,
    };
    let accounts: AccountList =
        serde_json::from_str(include_str!("fixtures/contracts/accounts-v2.json")).unwrap();
    let context = ProviderContext {
        http: reqwest::Client::new(),
        clock: Arc::new(Fixture),
        credentials: Arc::new(Fixture),
    };
    let mut value = Provider::Mock.adapter().fetch(&context).await.unwrap();
    value.provider.0 = "amp".into();
    value.account_ref = Some(AccountRef {
        id: "source-b".into(),
        label: "Ignored source label".into(),
        origin: None,
    });
    value.windows[0].note = Some("Provider detail".into());
    value.windows[0].metric_id = None;
    value.windows[0].label = "Quota 5-hour 日本語".into();
    let mut report = UsageReport {
        schema_version: 1,
        generated_at: context.clock.now(),
        providers: vec![value],
        failures: vec![ProviderFailure {
            provider: quotio::domain::ProviderId("amp".into()),
            account_ref: Some(AccountRef {
                id: "source-a".into(),
                label: "Ignored".into(),
                origin: None,
            }),
            code: ProviderError::Authentication,
            message: "not exposed".into(),
        }],
    };
    let now = context.clock.now();
    let snapshot = project(accounts.clone(), &report, now, time::Duration::minutes(5)).unwrap();
    validator("V2Snapshot")
        .validate(&serde_json::to_value(&snapshot).unwrap())
        .unwrap();
    assert_eq!(snapshot.accounts.len(), 1);
    assert_eq!(snapshot.accounts[0].display_name, "Work");
    assert_eq!(snapshot.accounts[0].state, ConnectionState::Ready);
    assert_eq!(
        snapshot.accounts[0].sources[0].state,
        ConnectionState::NeedsLogin
    );
    assert!(snapshot.accounts[0].sources[1].selected);
    assert_eq!(snapshot.usage[0].freshness, Freshness::Fresh);
    assert!(snapshot.usage[0].issue.is_none());
    assert_eq!(
        snapshot.usage[0].metrics[0].note.as_deref(),
        Some("Provider detail")
    );
    for (metric, window) in snapshot.usage[0]
        .metrics
        .iter()
        .zip(&report.providers[0].windows)
    {
        assert_eq!(metric.quota, window.quota);
        assert_eq!(metric.amounts, window.amounts);
    }
    let stale = project(
        accounts.clone(),
        &report,
        now + time::Duration::minutes(6),
        time::Duration::minutes(5),
    )
    .unwrap();
    assert_eq!(stale.usage[0].freshness, Freshness::Stale);
    report.providers[0].windows.clear();
    report.providers[0].account.plan = Some("Pro".into());
    let plan = project(accounts.clone(), &report, now, time::Duration::minutes(5)).unwrap();
    assert!(plan.usage[0].metrics.is_empty());
    assert_eq!(plan.usage[0].freshness, Freshness::Fresh);
    let mut disabled = accounts;
    disabled.accounts[0].enabled = false;
    let disabled = project(disabled, &report, now, time::Duration::minutes(5)).unwrap();
    assert_eq!(disabled.accounts[0].state, ConnectionState::Disabled);
    assert!(disabled.accounts[0].sources.iter().all(|s| !s.selected));
    assert_eq!(disabled.usage[0].freshness, Freshness::NotLoaded);
}

#[tokio::test]
async fn snapshot_includes_unregistered_observations_without_reading_credentials() {
    use quotio::contract::{AccountList, Freshness, snapshot::project};
    let mut accounts: AccountList =
        serde_json::from_str(include_str!("fixtures/contracts/accounts-v2.json")).unwrap();
    accounts.accounts.clear();
    accounts.account_redirects.clear();
    let context = ProviderContext {
        http: reqwest::Client::new(),
        clock: Arc::new(Fixture),
        credentials: Arc::new(Fixture),
    };
    let report = UsageReport {
        schema_version: 1,
        generated_at: context.clock.now(),
        providers: vec![Provider::Mock.adapter().fetch(&context).await.unwrap()],
        failures: vec![],
    };
    let result = project(
        accounts.clone(),
        &report,
        context.clock.now(),
        time::Duration::minutes(5),
    )
    .unwrap();
    validator("V2Snapshot")
        .validate(&serde_json::to_value(&result).unwrap())
        .unwrap();
    assert_eq!(result.accounts.len(), 1);
    assert_eq!(result.accounts[0].display_name, "Demo account");
    assert!(result.accounts[0].actions.is_empty());
    assert_eq!(result.usage[0].freshness, Freshness::Fresh);
    assert_eq!(
        result.accounts[0].id,
        project(
            accounts,
            &report,
            context.clock.now(),
            time::Duration::minutes(5)
        )
        .unwrap()
        .accounts[0]
            .id
    );
}

#[tokio::test]
async fn snapshot_groups_external_sources_only_with_matching_verified_identity() {
    use quotio::{
        contract::{AccountList, snapshot::project},
        domain::{AccountOrigin, AccountRef, VerifiedIdentity},
    };
    let mut accounts: AccountList =
        serde_json::from_str(include_str!("fixtures/contracts/accounts-v2.json")).unwrap();
    accounts.accounts[0].sources.truncate(1);
    accounts.account_redirects.clear();
    let context = ProviderContext {
        http: reqwest::Client::new(),
        clock: Arc::new(Fixture),
        credentials: Arc::new(Fixture),
    };
    let mut native = Provider::Mock.adapter().fetch(&context).await.unwrap();
    native.provider.0 = "amp".into();
    native.account.id = "same@example.com".into();
    native.account_ref = Some(AccountRef {
        id: "source-a".into(),
        label: "Amp CLI login".into(),
        origin: Some(AccountOrigin::BorrowedNative),
    });
    let verified = Some(VerifiedIdentity {
        subject: "provider-user-id".into(),
        tenant: Some("work".into()),
    });
    for (native_identity, local_identity, should_merge) in [
        (None, None, false),
        (verified.clone(), None, false),
        (None, verified.clone(), false),
        (verified.clone(), verified.clone(), true),
        (
            verified.clone(),
            Some(VerifiedIdentity {
                subject: "different-user-id".into(),
                tenant: Some("work".into()),
            }),
            false,
        ),
        (
            verified.clone(),
            Some(VerifiedIdentity {
                subject: "provider-user-id".into(),
                tenant: Some("personal".into()),
            }),
            false,
        ),
    ] {
        let mut native = native.clone();
        native.account.verified = native_identity;
        native.account.plan = Some("Native plan".into());
        let mut local = native.clone();
        local.account.verified = local_identity;
        local.account.plan = Some("Local plan".into());
        if should_merge {
            local.account.id = "provider-specific-id".into();
        }
        local.account_ref = Some(AccountRef {
            id: "local".into(),
            label: "Local login".into(),
            origin: Some(AccountOrigin::BorrowedNative),
        });
        let report = UsageReport {
            schema_version: 1,
            generated_at: context.clock.now(),
            providers: vec![native, local],
            failures: vec![],
        };

        let snapshot = project(
            accounts.clone(),
            &report,
            context.clock.now(),
            time::Duration::minutes(5),
        )
        .unwrap();

        let registered = snapshot
            .accounts
            .iter()
            .find(|account| account.id == "source-a")
            .unwrap();
        if should_merge {
            assert_eq!(snapshot.accounts.len(), 1);
            assert_eq!(registered.sources.len(), 2);
        } else {
            assert_eq!(snapshot.accounts.len(), 2);
            assert_eq!(registered.sources.len(), 1);
            let external = snapshot
                .accounts
                .iter()
                .find(|account| account.id != "source-a")
                .unwrap();
            assert_eq!(external.sources.len(), 1);
            let native_usage = snapshot
                .usage
                .iter()
                .find(|usage| usage.account_id == registered.id)
                .unwrap();
            let local_usage = snapshot
                .usage
                .iter()
                .find(|usage| usage.account_id == external.id)
                .unwrap();
            assert_eq!(native_usage.plan.as_deref(), Some("Native plan"));
            assert_eq!(local_usage.plan.as_deref(), Some("Local plan"));
        }
    }

    let mut different = native.clone();
    different.account.id = "different@example.com".into();
    different.account_ref = Some(AccountRef {
        id: "local".into(),
        label: "Local login".into(),
        origin: Some(AccountOrigin::BorrowedNative),
    });
    let report = UsageReport {
        schema_version: 1,
        generated_at: context.clock.now(),
        providers: vec![native, different],
        failures: vec![],
    };
    let snapshot = project(
        accounts,
        &report,
        context.clock.now(),
        time::Duration::minutes(5),
    )
    .unwrap();
    assert_eq!(snapshot.accounts.len(), 2);
}

#[test]
fn failed_native_probes_do_not_invent_accounts_but_discovered_proxy_sources_stay_visible() {
    use quotio::{
        contract::{AccountList, snapshot::project},
        domain::{AccountOrigin, AccountRef, ProviderFailure, ProviderId},
        error::ProviderError,
    };
    let mut accounts: AccountList =
        serde_json::from_str(include_str!("fixtures/contracts/accounts-v2.json")).unwrap();
    accounts.accounts.clear();
    accounts.account_redirects.clear();
    for reference in [
        None,
        Some(AccountRef {
            id: "borrowed-probe".into(),
            label: "Work".into(),
            origin: Some(AccountOrigin::BorrowedProxy),
        }),
    ] {
        let borrowed_proxy = reference.is_some();
        let report = UsageReport {
            schema_version: 1,
            generated_at: datetime!(2026-01-01 0:00 UTC),
            providers: vec![],
            failures: vec![ProviderFailure {
                account_ref: reference,
                provider: ProviderId("mock".into()),
                code: ProviderError::Authentication,
                message: "internal detail must not escape".into(),
            }],
        };
        let snapshot = project(
            accounts.clone(),
            &report,
            report.generated_at,
            time::Duration::minutes(5),
        )
        .unwrap();
        if borrowed_proxy {
            assert_eq!(snapshot.accounts.len(), 1);
            assert_eq!(snapshot.accounts[0].display_name, "Work");
            assert!(snapshot.accounts[0].actions.is_empty());
            assert!(snapshot.accounts[0].sources[0].actions.is_empty());
            assert_eq!(
                snapshot.usage[0].freshness,
                quotio::contract::Freshness::Unavailable
            );
            assert!(snapshot.usage[0].metrics.is_empty());
            assert_eq!(
                snapshot.usage[0].issue.as_ref().unwrap().code,
                "authentication"
            );
        } else {
            assert!(snapshot.accounts.is_empty());
            assert!(snapshot.usage.is_empty());
            assert_eq!(snapshot.provider_issues["mock"].code, "authentication");
        }
        let value = serde_json::to_value(&snapshot).unwrap();
        validator("V2Snapshot").validate(&value).unwrap();
        assert!(!value.to_string().contains("internal detail"));
    }
}

#[test]
fn recovery_actions_distinguish_owner_login_from_host_retry() {
    use quotio::{
        contract::{AccountList, InteractionLocation, snapshot::project},
        domain::{ProviderFailure, ProviderId},
        error::ProviderError,
    };
    let mut accounts: AccountList =
        serde_json::from_str(include_str!("fixtures/contracts/accounts-v2.json")).unwrap();
    accounts.accounts.clear();
    accounts.account_redirects.clear();
    for (code, kind, interaction) in [
        (
            ProviderError::OwnerRefreshRequired,
            "refresh_in_source_app",
            InteractionLocation::HostUser,
        ),
        (ProviderError::Timeout, "retry", InteractionLocation::Host),
    ] {
        let report = UsageReport {
            schema_version: 1,
            generated_at: datetime!(2026-01-01 0:00 UTC),
            providers: vec![],
            failures: vec![ProviderFailure {
                account_ref: None,
                provider: ProviderId("mock".into()),
                code,
                message: code.to_string(),
            }],
        };
        let snapshot = project(
            accounts.clone(),
            &report,
            report.generated_at,
            time::Duration::minutes(5),
        )
        .unwrap();
        let action = snapshot.provider_issues["mock"].action.as_ref().unwrap();
        assert_eq!(action.kind, kind);
        assert_eq!(action.interaction, interaction);
        assert!(action.available);
    }
}
