use quotio::{
    domain::*,
    error::ProviderError,
    fetch::*,
    providers::{mock::MockProvider, *},
};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use time::{OffsetDateTime, macros::datetime};
struct FixedClock;
impl Clock for FixedClock {
    fn now(&self) -> OffsetDateTime {
        datetime!(2026-01-01 0:00 UTC)
    }
}
struct NoCredentials;
impl CredentialStore for NoCredentials {
    fn get(&self, _: &str) -> Option<Secret> {
        None
    }
}
fn collector() -> Collector {
    Collector {
        context: ProviderContext {
            http: reqwest::Client::new(),
            clock: Arc::new(FixedClock),
            credentials: Arc::new(NoCredentials),
        },
    }
}
struct Fake {
    delay: Duration,
    error: ProviderError,
    calls: Arc<AtomicUsize>,
    retry: bool,
}
impl ProviderAdapter for Fake {
    fn id(&self) -> ProviderId {
        ProviderId("fake".into())
    }
    fn idempotent(&self) -> bool {
        self.retry
    }
    fn fetch<'a>(&'a self, _: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(self.delay).await;
            Err(self.error)
        })
    }
}
fn request(providers: Vec<Arc<dyn ProviderAdapter>>) -> CollectRequest {
    CollectRequest {
        providers,
        timeout: Duration::from_secs(1),
        cancellation: Cancellation::default(),
    }
}
#[test]
fn normalize_and_preserve_unknown() {
    assert_eq!(Quota::from_used(None), Quota::Unknown);
    assert_eq!(Quota::from_used(Some(f64::NAN)), Quota::Unknown);
    assert_eq!(Quota::from_used(Some(f64::INFINITY)), Quota::Unknown);
    assert_eq!(Quota::from_used(Some(-5.0)), Quota::from_used(Some(0.0)));
    assert_eq!(Quota::from_used(Some(105.0)), Quota::from_used(Some(100.0)));
    assert_ne!(Quota::from_used(None), Quota::from_remaining(Some(0.0)));
    assert_eq!(
        Quota::from_remaining(Some(75.0)),
        Quota::from_used(Some(25.0))
    );
}
#[tokio::test(start_paused = true)]
async fn partial_failure_and_multiple_windows() {
    let bad = Fake {
        delay: Duration::ZERO,
        error: ProviderError::Authentication,
        calls: Arc::default(),
        retry: true,
    };
    let report = collector()
        .collect(request(vec![Arc::new(MockProvider), Arc::new(bad)]))
        .await;
    assert_eq!(report.exit_code(), 1);
    assert_eq!(report.providers[0].windows.len(), 3);
    assert_eq!(report.failures[0].code, ProviderError::Authentication);
    assert_eq!(report.generated_at, FixedClock.now());
}
#[tokio::test(start_paused = true)]
async fn deadline_and_cancellation() {
    let slow = || {
        Arc::new(Fake {
            delay: Duration::from_secs(10),
            error: ProviderError::Transient,
            calls: Arc::default(),
            retry: true,
        }) as Arc<dyn ProviderAdapter>
    };
    let report = collector().collect(request(vec![slow()])).await;
    assert_eq!(report.failures[0].code, ProviderError::Timeout);
    assert_eq!(report.exit_code(), 3);
    let req = request(vec![slow()]);
    req.cancellation.cancel();
    let report = collector().collect(req).await;
    assert_eq!(report.failures[0].code, ProviderError::Cancelled);
}
#[tokio::test(start_paused = true)]
async fn retry_is_bounded_and_only_idempotent_transient() {
    for (retry, error, expected) in [
        (true, ProviderError::Transient, 3),
        (false, ProviderError::Transient, 1),
        (true, ProviderError::Authentication, 1),
    ] {
        let calls = Arc::new(AtomicUsize::new(0));
        let fake = Fake {
            delay: Duration::ZERO,
            error,
            calls: calls.clone(),
            retry,
        };
        collector().collect(request(vec![Arc::new(fake)])).await;
        assert_eq!(calls.load(Ordering::SeqCst), expected);
    }
}
#[tokio::test(start_paused = true)]
async fn requests_run_concurrently() {
    let fake = || {
        Arc::new(Fake {
            delay: Duration::from_millis(700),
            error: ProviderError::Authentication,
            calls: Arc::default(),
            retry: false,
        }) as Arc<dyn ProviderAdapter>
    };
    let start = tokio::time::Instant::now();
    collector().collect(request(vec![fake(), fake()])).await;
    assert!(start.elapsed() < Duration::from_secs(1));
}
#[tokio::test]
async fn success_and_empty_exit_codes() {
    assert_eq!(
        collector()
            .collect(request(vec![Arc::new(MockProvider)]))
            .await
            .exit_code(),
        0
    );
    assert_eq!(collector().collect(request(vec![])).await.exit_code(), 3);
}

struct InvalidProvider(Option<Consumption>);
impl ProviderAdapter for InvalidProvider {
    fn id(&self) -> ProviderId {
        ProviderId("mock".into())
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            let mut usage = MockProvider.fetch(context).await?;
            if let Some(consumption) = &self.0 {
                usage.windows[0].consumption = Some(consumption.clone());
            } else {
                usage.windows[0].quota = Quota::Available {
                    used_percent: f64::NAN,
                    remaining_percent: 50.0,
                };
            }
            Ok(usage)
        })
    }
}
#[tokio::test]
async fn invalid_adapter_data_is_a_provider_failure() {
    let report = collector()
        .collect(request(vec![Arc::new(InvalidProvider(None))]))
        .await;
    assert_eq!(report.exit_code(), 3);
    assert_eq!(report.failures[0].code, ProviderError::InvalidData);
    assert!(report.providers.is_empty());
    assert!(
        !Quota::Exhausted {
            used_percent: 10.0,
            remaining_percent: 90.0
        }
        .is_valid()
    );
    assert!(
        !Quota::Available {
            used_percent: 50.0,
            remaining_percent: 40.0
        }
        .is_valid()
    );
    let json = serde_json::to_string_pretty(&report).unwrap();
    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(
        value["failures"][0],
        serde_json::json!({"provider":"mock", "code":"invalid_data", "message":"provider returned invalid usage"})
    );
}
struct DropFlag(Arc<AtomicUsize>);
impl Drop for DropFlag {
    fn drop(&mut self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}
struct PendingProvider(Arc<AtomicUsize>);
impl ProviderAdapter for PendingProvider {
    fn id(&self) -> ProviderId {
        ProviderId("pending".into())
    }
    fn fetch<'a>(&'a self, _: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            let _guard = DropFlag(self.0.clone());
            std::future::pending().await
        })
    }
}
#[tokio::test(start_paused = true)]
async fn cancellation_drops_inflight_work_and_keeps_success() {
    let drops = Arc::new(AtomicUsize::new(0));
    let req = request(vec![
        Arc::new(MockProvider),
        Arc::new(PendingProvider(drops.clone())),
    ]);
    let cancellation = req.cancellation.clone();
    let collect = collector();
    let (report, ()) = tokio::join!(collect.collect(req), async {
        tokio::time::sleep(Duration::from_millis(100)).await;
        cancellation.cancel();
    });
    assert_eq!(drops.load(Ordering::SeqCst), 1);
    assert_eq!(report.exit_code(), 1);
    assert_eq!(report.failures[0].code, ProviderError::Cancelled);
}
#[tokio::test(start_paused = true)]
async fn deadline_drops_inflight_work() {
    let drops = Arc::new(AtomicUsize::new(0));
    let report = collector()
        .collect(request(vec![Arc::new(PendingProvider(drops.clone()))]))
        .await;
    assert_eq!(drops.load(Ordering::SeqCst), 1);
    assert_eq!(report.failures[0].code, ProviderError::Timeout);
}

#[cfg(unix)]
#[tokio::test]
async fn codex_stdio_protocol_is_exercised_offline() {
    use quotio::providers::codex::CodexProvider;
    use std::os::unix::fs::PermissionsExt;
    let directory = std::env::temp_dir().join(format!("quotio-codex-{}", std::process::id()));
    std::fs::create_dir(&directory).unwrap();
    let script = directory.join("codex-fixture");
    std::fs::write(&script, r#"#!/bin/sh
# Regress startup slower than the collector unit tests' one-second budget.
sleep 2
while IFS= read -r request; do
case "$request" in
*'"id":1,'*) printf '%s\n' '{"id":1,"result":{}}';;
*'"id":2,'*) printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt","email":"demo@example.com","planType":"pro"}}}';;
*'"id":3,'*) printf '%s\n' '{"method":"account/rateLimits/updated","params":{}}' '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":25}}}}';;
*'"id":4,'*) printf '%s\n' '{"id":4,"result":{"account":{"type":"chatgpt","email":"demo@example.com","planType":"pro"}}}';;
esac
done
"#).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut req = request(vec![Arc::new(CodexProvider {
        executable: script.clone(),
    })]);
    // This tests real subprocess I/O, not the collector's deadline. Allow startup
    // under load; deadline behavior is covered separately with paused time.
    req.timeout = Duration::from_secs(10);
    let report = collector().collect(req).await;
    assert_eq!(report.exit_code(), 0, "{:?}", report.failures);
    assert_eq!(
        report.providers[0].windows[0].quota,
        Quota::from_used(Some(25.0))
    );
    std::fs::remove_file(script).unwrap();
    std::fs::remove_dir(directory).unwrap();
}

struct AccountCandidate {
    provider: &'static str,
    selector: &'static str,
    identity: &'static str,
    email: &'static str,
    plan: Option<&'static str>,
    delay: Duration,
}
impl ProviderAdapter for AccountCandidate {
    fn id(&self) -> ProviderId {
        ProviderId(self.provider.into())
    }
    fn account_ref(&self) -> Option<AccountRef> {
        Some(AccountRef {
            origin: None,
            id: self.selector.into(),
            label: format!("Label {}", self.selector),
        })
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            tokio::time::sleep(self.delay).await;
            let mut usage = MockProvider.fetch(context).await?;
            usage.provider = self.id();
            usage.account.id = self.identity.into();
            usage.account.label = self.email.into();
            usage.account.plan = self.plan.map(str::to_owned);
            Ok(usage)
        })
    }
}
fn candidate(
    selector: &'static str,
    identity: &'static str,
    email: &'static str,
    plan: Option<&'static str>,
) -> Arc<dyn ProviderAdapter> {
    Arc::new(AccountCandidate {
        provider: "codex",
        selector,
        identity,
        email,
        plan,
        delay: Duration::ZERO,
    })
}
#[tokio::test(start_paused = true)]
async fn local_and_distinct_saved_accounts_are_all_reported() {
    let report = collector()
        .collect(request(vec![
            candidate(
                "local",
                "local@example.com",
                "local@example.com",
                Some("pro"),
            ),
            candidate("saved-a", "account-a", "a@example.com", Some("pro")),
            candidate("saved-b", "account-b", "b@example.com", Some("pro")),
        ]))
        .await;
    assert_eq!(report.exit_code(), 0);
    assert_eq!(report.providers.len(), 3);
    assert_eq!(
        report
            .providers
            .iter()
            .map(|p| p.account_ref.as_ref().unwrap().id.as_str())
            .collect::<Vec<_>>(),
        vec!["local", "saved-a", "saved-b"]
    );
}
#[tokio::test(start_paused = true)]
async fn collection_preserves_sources_with_matching_emails_plans_and_legacy_ids() {
    for (local_id, saved_id, local_plan, saved_plan, expected) in [
        ("same-id", "same-id", Some("business"), Some("business"), 2),
        (
            "demo@example.com",
            "account-id",
            Some("pro"),
            Some("pro"),
            2,
        ),
        (
            "demo@example.com",
            "workspace-id",
            Some("business"),
            Some("business"),
            2,
        ),
        ("demo@example.com", "account-id", None, Some("pro"), 2),
    ] {
        let report = collector()
            .collect(request(vec![
                candidate("local", local_id, "demo@example.com", local_plan),
                candidate("saved", saved_id, "demo@example.com", saved_plan),
            ]))
            .await;
        assert_eq!(report.providers.len(), expected);
    }
    let report = collector()
        .collect(request(vec![
            candidate("local", "demo@example.com", "demo@example.com", Some("pro")),
            candidate("one", "id-one", "demo@example.com", Some("pro")),
            candidate("two", "id-two", "demo@example.com", Some("pro")),
        ]))
        .await;
    assert_eq!(report.providers.len(), 3);
}
#[tokio::test(start_paused = true)]
async fn account_timeout_preserves_other_accounts_and_identifies_the_failure() {
    let slow = Arc::new(AccountCandidate {
        provider: "codex",
        selector: "saved-slow",
        identity: "slow-id",
        email: "slow@example.com",
        plan: Some("pro"),
        delay: Duration::from_secs(10),
    });
    let report = collector()
        .collect(request(vec![
            candidate(
                "local",
                "local@example.com",
                "local@example.com",
                Some("pro"),
            ),
            slow,
        ]))
        .await;
    assert_eq!(report.exit_code(), 1);
    assert_eq!(report.providers.len(), 1);
    assert_eq!(report.failures[0].code, ProviderError::Timeout);
    assert_eq!(
        report.failures[0].account_ref.as_ref().unwrap().id,
        "saved-slow"
    );
    let json = serde_json::to_string_pretty(&report).unwrap();
    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert_eq!(value["failures"][0]["account_ref"]["id"], "saved-slow");
}

struct AmpCandidate {
    selector: &'static str,
    email: &'static str,
    balance: f64,
    fail: bool,
}
impl ProviderAdapter for AmpCandidate {
    fn id(&self) -> ProviderId {
        ProviderId("amp".into())
    }
    fn account_ref(&self) -> Option<AccountRef> {
        Some(AccountRef {
            origin: None,
            id: self.selector.into(),
            label: self.selector.into(),
        })
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            if self.fail {
                return Err(ProviderError::Authentication);
            }
            let mut usage = MockProvider.fetch(context).await?;
            usage.provider = self.id();
            usage.account.id = self.email.into();
            usage.account.label = self.email.into();
            usage.windows[0].amounts = Some(QuotaAmounts {
                remaining: self.balance,
                limit: None,
                unit: "USD".into(),
            });
            if self.selector == "local" {
                usage.windows[0].fetched_at += time::Duration::seconds(1);
            }
            Ok(usage)
        })
    }
}
#[tokio::test]
async fn amp_collection_preserves_sources_even_with_identical_email_and_quota() {
    for (local_email, saved_email, local_balance, saved_balance, expected) in [
        (
            "local@example.invalid",
            "saved@example.invalid",
            10.0,
            10.0,
            2,
        ),
        (
            "same@example.invalid",
            "same@example.invalid",
            10.0,
            10.0,
            2,
        ),
        (
            "same@example.invalid",
            "same@example.invalid",
            10.0,
            20.0,
            2,
        ),
    ] {
        let report = collector()
            .collect(request(vec![
                Arc::new(AmpCandidate {
                    selector: "local",
                    email: local_email,
                    balance: local_balance,
                    fail: false,
                }),
                Arc::new(AmpCandidate {
                    selector: "saved",
                    email: saved_email,
                    balance: saved_balance,
                    fail: false,
                }),
            ]))
            .await;
        assert_eq!(report.providers.len(), expected);
        assert_eq!(report.exit_code(), 0);
    }
}
#[tokio::test]
async fn amp_local_failure_keeps_saved_usage_and_failure_identity() {
    let report = collector()
        .collect(request(vec![
            Arc::new(AmpCandidate {
                selector: "local",
                email: "local@example.invalid",
                balance: 0.0,
                fail: true,
            }),
            Arc::new(AmpCandidate {
                selector: "saved",
                email: "saved@example.invalid",
                balance: 10.0,
                fail: false,
            }),
        ]))
        .await;
    assert_eq!(report.exit_code(), 1);
    assert_eq!(report.providers.len(), 1);
    assert_eq!(report.failures[0].account_ref.as_ref().unwrap().id, "local");
    assert_eq!(
        report.providers[0].account_ref.as_ref().unwrap().id,
        "saved"
    );
}

#[tokio::test]
async fn key_scoped_collection_preserves_every_source() {
    for provider in ["synthetic", "openrouter", "zai", "minimax"] {
        for saved_id in ["key:local", "key:other"] {
            let candidates: Vec<Arc<dyn ProviderAdapter>> =
                [("local", "key:local"), ("saved", saved_id)]
                    .into_iter()
                    .map(|(selector, identity)| {
                        Arc::new(AccountCandidate {
                            provider,
                            selector,
                            identity,
                            email: "same-owner",
                            plan: None,
                            delay: Duration::ZERO,
                        }) as Arc<dyn ProviderAdapter>
                    })
                    .collect();
            let report = collector().collect(request(candidates)).await;
            assert_eq!(report.providers.len(), 2);
        }
    }
}

#[tokio::test]
async fn invalid_consumption_cannot_enter_json_reports() {
    for (used, unit) in [(f64::NAN, "USD"), (-1.0, "USD"), (1.0, "")] {
        let report = collector()
            .collect(request(vec![Arc::new(InvalidProvider(Some(
                Consumption {
                    used,
                    unit: unit.into(),
                },
            )))]))
            .await;
        assert_eq!(report.exit_code(), 3);
        assert_eq!(report.failures[0].code, ProviderError::InvalidData);
    }
}

struct PlanOnly(Option<&'static str>);
impl ProviderAdapter for PlanOnly {
    fn id(&self) -> ProviderId {
        ProviderId("mock".into())
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            let mut usage = MockProvider.fetch(context).await?;
            usage.windows.clear();
            usage.account.plan = self.0.map(str::to_owned);
            Ok(usage)
        })
    }
}

#[tokio::test]
async fn plan_only_responses_are_successful_without_inventing_metrics() {
    for plan in [Some("Pro"), Some(" "), None] {
        let report = collector()
            .collect(request(vec![Arc::new(PlanOnly(plan))]))
            .await;
        if plan == Some("Pro") {
            assert_eq!(report.exit_code(), 0);
            assert_eq!(report.providers[0].account.plan.as_deref(), plan);
            assert!(report.providers[0].windows.is_empty());
            assert!(report.failures.is_empty());
        } else {
            assert!(report.providers.is_empty());
            assert_eq!(report.failures[0].code, ProviderError::InvalidData);
        }
    }
}

struct DuplicateMetrics;
impl ProviderAdapter for DuplicateMetrics {
    fn id(&self) -> ProviderId {
        ProviderId("invalid-fixture".into())
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            let mut usage = MockProvider.fetch(context).await?;
            usage.provider = self.id();
            usage.windows.push(usage.windows[0].clone());
            Ok(usage)
        })
    }
}

#[tokio::test]
async fn malformed_source_metrics_do_not_discard_another_providers_usage() {
    let report = collector()
        .collect(request(vec![
            Arc::new(MockProvider),
            Arc::new(DuplicateMetrics),
        ]))
        .await;
    assert_eq!(report.providers.len(), 1);
    assert_eq!(report.providers[0].provider.0, "mock");
    assert_eq!(report.failures.len(), 1);
    assert_eq!(report.failures[0].code, ProviderError::InvalidData);
}
