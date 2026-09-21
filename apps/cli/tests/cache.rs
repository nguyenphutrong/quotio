use quotio::{
    cache::UsageCache,
    domain::{AccountRef, ProviderId},
    error::ProviderError,
    fetch::{Cancellation, CollectRequest, Collector},
    providers::{
        Clock, CredentialStore, FetchFuture, ProviderAdapter, ProviderContext, Secret,
        mock::MockProvider,
    },
};
use std::{
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering},
    },
    time::Duration,
};
use time::OffsetDateTime;

struct TestClock(AtomicI64);
impl Clock for TestClock {
    fn now(&self) -> OffsetDateTime {
        OffsetDateTime::from_unix_timestamp(self.0.load(Ordering::SeqCst)).unwrap()
    }
}
struct NoCredentials;
impl CredentialStore for NoCredentials {
    fn get(&self, _: &str) -> Option<Secret> {
        None
    }
}
struct Adapter {
    account: String,
    provider: String,
    stall: AtomicBool,
    switch_during_fetch: AtomicBool,
    login: Mutex<String>,
    calls: AtomicUsize,
    fails: AtomicBool,
    partial: AtomicBool,
    reset_credits: Mutex<Option<quotio::domain::ResetCredits>>,
}
impl Adapter {
    fn new(account: &str) -> Arc<Self> {
        Arc::new(Self {
            account: account.into(),
            provider: "mock".into(),
            stall: AtomicBool::new(false),
            switch_during_fetch: AtomicBool::new(false),
            login: Mutex::new(account.into()),
            calls: AtomicUsize::new(0),
            fails: AtomicBool::new(false),
            partial: AtomicBool::new(false),
            reset_credits: Mutex::new(None),
        })
    }
}
impl ProviderAdapter for Adapter {
    fn id(&self) -> ProviderId {
        ProviderId(self.provider.clone())
    }
    fn account_ref(&self) -> Option<AccountRef> {
        Some(AccountRef {
            origin: None,
            id: self.account.clone(),
            label: self.account.clone(),
        })
    }
    fn cache_identity<'a>(
        &'a self,
        _: &'a ProviderContext,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<String>> + Send + 'a>> {
        Box::pin(async { Some(self.login.lock().unwrap().clone()) })
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if self.stall.load(Ordering::SeqCst) {
                std::future::pending::<()>().await;
            }
            if self.switch_during_fetch.load(Ordering::SeqCst) {
                *self.login.lock().unwrap() = "changed-during-fetch".into();
            }

            if self.fails.load(Ordering::SeqCst) {
                return Err(ProviderError::Unavailable);
            }
            let mut usage = MockProvider.fetch(context).await?;
            usage.provider = self.id();
            usage.reset_credits = self.reset_credits.lock().unwrap().clone();
            if self.partial.load(Ordering::SeqCst) {
                usage.diagnostics.push(quotio::domain::UsageDiagnostic {
                    source: "fixture_endpoint".into(),
                    code: ProviderError::Transient,
                });
            }
            usage.account.id = self.login.lock().unwrap().clone();
            for window in &mut usage.windows {
                window.fetched_at = context.clock.now();
            }
            Ok(usage)
        })
    }
}
struct Fixture {
    dir: PathBuf,
    clock: Arc<TestClock>,
    collector: Collector,
    cache: UsageCache,
}
impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "quotio-cache-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let clock = Arc::new(TestClock(AtomicI64::new(1800000000)));
        let collector = Collector {
            context: ProviderContext {
                http: reqwest::Client::new(),
                clock: clock.clone(),
                credentials: Arc::new(NoCredentials),
            },
        };
        Self {
            cache: UsageCache::new(dir.clone(), Duration::from_secs(300)),
            dir,
            clock,
            collector,
        }
    }
    async fn collect(
        &self,
        adapters: Vec<Arc<dyn ProviderAdapter>>,
        force: bool,
    ) -> quotio::domain::UsageReport {
        self.cache
            .collect(
                &self.collector,
                CollectRequest {
                    providers: adapters,
                    timeout: Duration::from_secs(3),
                    cancellation: Cancellation::default(),
                },
                force,
            )
            .await
    }
    fn json(&self) -> PathBuf {
        std::fs::read_dir(&self.dir)
            .unwrap()
            .map(|p| p.unwrap().path())
            .find(|p| p.extension().is_some_and(|e| e == "json"))
            .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[tokio::test]
async fn reset_credit_cache_preserves_age_isolates_accounts_and_drops_stale_balance() {
    let f = Fixture::new();
    let a = Adapter::new("a");
    let b = Adapter::new("b");
    let now = f.clock.now();
    for (adapter, count) in [(&a, 2), (&b, 5)] {
        *adapter.reset_credits.lock().unwrap() = Some(quotio::domain::ResetCredits {
            available_count: count,
            earliest_expires_at: Some(now + time::Duration::seconds(100)),
            fetched_at: now,
            source: "codex_api".into(),
        });
    }
    f.collect(vec![a.clone(), b.clone()], false).await;
    f.clock.0.fetch_add(99, Ordering::SeqCst);
    let cached = f.collect(vec![b.clone(), a.clone()], false).await;
    assert_eq!(
        cached.providers[0]
            .reset_credits
            .as_ref()
            .unwrap()
            .available_count,
        5
    );
    assert_eq!(
        cached.providers[1]
            .reset_credits
            .as_ref()
            .unwrap()
            .available_count,
        2
    );
    assert_eq!(
        cached.providers[1]
            .reset_credits
            .as_ref()
            .unwrap()
            .fetched_at,
        now
    );
    assert_eq!(a.calls.load(Ordering::SeqCst), 1);
    // Expiry forces fetch before the quota TTL. A failed fetch retains quota only.
    f.clock.0.fetch_add(1, Ordering::SeqCst);
    a.fails.store(true, Ordering::SeqCst);
    let expired = f.collect(vec![a.clone()], false).await;
    assert_eq!(a.calls.load(Ordering::SeqCst), 2);
    assert!(!expired.providers[0].windows.is_empty());
    assert!(expired.providers[0].reset_credits.is_none());
    assert_eq!(expired.providers[0].windows[0].fetched_at, now);
    // Login change never restores the previous login's credits or quota.
    *a.login.lock().unwrap() = "new-login".into();
    assert!(f.collect(vec![a.clone()], false).await.providers.is_empty());
    // An optional lookup failure replaces an old success, not just its windows.
    *b.reset_credits.lock().unwrap() = None;
    b.partial.store(true, Ordering::SeqCst);
    let partial = f.collect(vec![b.clone()], true).await;
    assert!(partial.providers[0].reset_credits.is_none());
    assert_eq!(partial.exit_code(), 1);
    assert!(
        f.collect(vec![b.clone()], false).await.providers[0]
            .reset_credits
            .is_none()
    );
}

#[tokio::test]
async fn fresh_persistent_expiry_boundary_force_and_clock_rollback() {
    let mut f = Fixture::new();
    let a = Adapter::new("a");
    let first = f.collect(vec![a.clone()], false).await;
    let fetched_at = first.providers[0].windows[0].fetched_at;
    // A new service instance reads the persisted snapshot.
    f.cache = UsageCache::new(f.dir.clone(), Duration::from_secs(300));
    f.clock.0.fetch_add(299, Ordering::SeqCst);
    assert_eq!(
        f.collect(vec![a.clone()], false).await.providers[0].windows[0].fetched_at,
        fetched_at
    );
    assert_eq!(a.calls.load(Ordering::SeqCst), 1);
    f.clock.0.fetch_add(1, Ordering::SeqCst);
    f.collect(vec![a.clone()], false).await;
    assert_eq!(a.calls.load(Ordering::SeqCst), 2);
    f.collect(vec![a.clone()], true).await;
    assert_eq!(a.calls.load(Ordering::SeqCst), 3);
    f.clock.0.fetch_sub(1, Ordering::SeqCst);
    f.collect(vec![a.clone()], false).await;
    assert_eq!(a.calls.load(Ordering::SeqCst), 4);
}
#[tokio::test]
async fn missing_corrupt_invalid_and_unreadable_cache_fetch_without_crashing() {
    let f = Fixture::new();
    let a = Adapter::new("a");
    f.collect(vec![a.clone()], false).await;
    let path = f.json();
    for bytes in [b"not json".as_slice(), b"{}".as_slice()] {
        std::fs::write(&path, bytes).unwrap();
        assert!(f.collect(vec![a.clone()], false).await.failures.is_empty());
    }
    let mut payload: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    payload["windows"][0]["quota"]["used_percent"] = (-1).into();
    std::fs::write(&path, serde_json::to_vec(&payload).unwrap()).unwrap();
    f.collect(vec![a.clone()], false).await;
    std::fs::remove_file(&path).unwrap();
    std::fs::create_dir(&path).unwrap();
    assert!(f.collect(vec![a.clone()], false).await.failures.is_empty());
    assert_eq!(a.calls.load(Ordering::SeqCst), 5);
}
#[tokio::test]
async fn login_change_never_returns_previous_accounts_snapshot() {
    let f = Fixture::new();
    let a = Adapter::new("local");
    f.collect(vec![a.clone()], false).await;
    *a.login.lock().unwrap() = "new-login".into();
    a.fails.store(true, Ordering::SeqCst);
    let failed = f.collect(vec![a.clone()], false).await;
    assert!(failed.providers.is_empty());
    assert_eq!(failed.failures.len(), 1);
    a.fails.store(false, Ordering::SeqCst);
    let next = f.collect(vec![a.clone()], false).await;
    assert_eq!(next.providers[0].account.id, "new-login");
    assert_eq!(a.calls.load(Ordering::SeqCst), 3);
}
#[tokio::test]
async fn partial_failure_preserves_timestamp_and_only_refreshes_due_accounts() {
    let f = Fixture::new();
    let a = Adapter::new("a");
    let b = Adapter::new("b");
    let first = f.collect(vec![a.clone()], false).await;
    let timestamp = first.providers[0].windows[0].fetched_at;
    f.clock.0.fetch_add(200, Ordering::SeqCst);
    f.collect(vec![b.clone()], false).await;
    f.clock.0.fetch_add(100, Ordering::SeqCst);
    a.fails.store(true, Ordering::SeqCst);
    let report = f.collect(vec![a.clone(), b.clone()], false).await;
    assert_eq!(report.providers.len(), 2);
    assert_eq!(report.providers[0].windows[0].fetched_at, timestamp);
    assert_eq!(report.failures[0].account_ref.as_ref().unwrap().id, "a");
    assert_eq!(report.exit_code(), 1);
    assert_eq!(a.calls.load(Ordering::SeqCst), 2);
    assert_eq!(b.calls.load(Ordering::SeqCst), 1);
    f.collect(vec![a.clone(), b.clone()], false).await;
    assert_eq!(a.calls.load(Ordering::SeqCst), 3);
    assert_eq!(b.calls.load(Ordering::SeqCst), 1);
}
#[tokio::test]
async fn concurrent_tasks_recheck_freshness_under_the_account_lock() {
    let f = Fixture::new();
    let a = Adapter::new("a");
    let (left, right) = tokio::join!(
        f.collect(vec![a.clone()], false),
        f.collect(vec![a.clone()], false)
    );
    assert!(left.failures.is_empty() && right.failures.is_empty());
    assert_eq!(a.calls.load(Ordering::SeqCst), 1);
    let value: serde_json::Value =
        serde_json::from_slice(&std::fs::read(f.json()).unwrap()).unwrap();
    assert_eq!(value.as_object().unwrap().len(), 4);
    assert!(value.get("credentials").is_none());
}
#[tokio::test]
async fn configured_ttl_and_zero_disable_reuse() {
    let mut f = Fixture::new();
    let a = Adapter::new("a");
    f.cache = UsageCache::new(f.dir.clone(), Duration::from_secs(10));
    f.collect(vec![a.clone()], false).await;
    f.clock.0.fetch_add(10, Ordering::SeqCst);
    f.collect(vec![a.clone()], false).await;
    assert_eq!(a.calls.load(Ordering::SeqCst), 2);
    f.cache = UsageCache::new(f.dir.clone(), Duration::ZERO);
    f.collect(vec![a.clone()], false).await;
    assert_eq!(a.calls.load(Ordering::SeqCst), 3);
}

// Run this same offline test executable in separate OS processes to exercise flock.
#[test]
fn cache_process_worker() {
    let Some(path) = std::env::var_os("QUOTIO_TEST_CACHE") else {
        return;
    };
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        let mut f = Fixture::new();
        f.cache = UsageCache::new(PathBuf::from(path), Duration::from_secs(300));
        let a = Adapter::new("shared");
        for _ in 0..8 {
            let report = f.collect(vec![a.clone()], true).await;
            assert_eq!(report.providers.len(), 1);
            assert!(report.failures.is_empty());
        }
    });
}
#[test]
fn concurrent_process_writes_leave_a_complete_normalized_snapshot() {
    let f = Fixture::new();
    let mut children: Vec<_> = (0..4)
        .map(|_| {
            std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "cache_process_worker", "--nocapture"])
                .env("QUOTIO_TEST_CACHE", &f.dir)
                .stdout(std::process::Stdio::null())
                .spawn()
                .unwrap()
        })
        .collect();
    for child in &mut children {
        assert!(child.wait().unwrap().success());
    }
    let payload: quotio::domain::ProviderUsage =
        serde_json::from_slice(&std::fs::read(f.json()).unwrap()).unwrap();
    assert_eq!(payload.account.id, "shared");
    assert_eq!(payload.windows.len(), 3);
    assert!(
        std::fs::read_dir(&f.dir)
            .unwrap()
            .all(|p| p.unwrap().path().extension().unwrap() != "tmp")
    );
}

#[tokio::test]
async fn provider_names_isolate_identical_account_ids() {
    let f = Fixture::new();
    let a = Adapter::new("same");
    let mut b = Adapter::new("same");
    Arc::get_mut(&mut b).unwrap().provider = "another-provider".into();
    let report = f.collect(vec![a.clone(), b.clone()], false).await;
    assert_eq!(report.providers.len(), 2);
    f.collect(vec![b.clone(), a.clone()], false).await;
    assert_eq!(a.calls.load(Ordering::SeqCst), 1);
    assert_eq!(b.calls.load(Ordering::SeqCst), 1);
}
#[tokio::test]
async fn timeout_retains_stale_snapshot_and_cancellation_releases_lock() {
    let f = Fixture::new();
    let a = Adapter::new("a");
    let first = f.collect(vec![a.clone()], false).await;
    a.stall.store(true, Ordering::SeqCst);
    let report = f
        .cache
        .collect(
            &f.collector,
            CollectRequest {
                providers: vec![a.clone()],
                timeout: Duration::from_millis(100),
                cancellation: Cancellation::default(),
            },
            true,
        )
        .await;
    assert_eq!(report.failures[0].code, ProviderError::Timeout);
    assert_eq!(
        report.providers[0].windows[0].fetched_at,
        first.providers[0].windows[0].fetched_at
    );
    let cancellation = Cancellation::default();
    cancellation.cancel();
    let cancelled = f
        .cache
        .collect(
            &f.collector,
            CollectRequest {
                providers: vec![a.clone()],
                timeout: Duration::from_secs(3),
                cancellation,
            },
            false,
        )
        .await;
    assert_eq!(cancelled.failures[0].code, ProviderError::Cancelled);
    a.stall.store(false, Ordering::SeqCst);
    assert!(f.collect(vec![a.clone()], true).await.failures.is_empty());
}
#[tokio::test]
async fn login_change_during_failed_refresh_cannot_restore_old_usage() {
    let f = Fixture::new();
    let a = Adapter::new("local");
    f.collect(vec![a.clone()], false).await;
    a.switch_during_fetch.store(true, Ordering::SeqCst);
    a.fails.store(true, Ordering::SeqCst);
    let report = f.collect(vec![a.clone()], true).await;
    assert!(report.providers.is_empty());
    assert_eq!(report.failures.len(), 1);
}
#[cfg(unix)]
#[tokio::test]
async fn fifo_cache_is_rejected_without_waiting_for_a_writer() {
    let f = Fixture::new();
    let a = Adapter::new("a");
    f.collect(vec![a.clone()], false).await;
    let path = f.json();
    std::fs::remove_file(&path).unwrap();
    use std::os::unix::ffi::OsStrExt;
    let cpath = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(cpath.as_ptr(), 0o600) }, 0);
    let report = tokio::time::timeout(Duration::from_secs(2), f.collect(vec![a.clone()], false))
        .await
        .unwrap();
    assert!(report.failures.is_empty());
    assert_eq!(a.calls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn environment_key_and_scope_changes_invalidate_without_persisting_secrets() {
    struct Keys {
        key: String,
        org: String,
    }
    impl CredentialStore for Keys {
        fn get(&self, name: &str) -> Option<Secret> {
            match name {
                "FACTORY_API_KEY" => Some(Secret(self.key.clone())),
                "FACTORY_ORG_ID" => Some(Secret(self.org.clone())),
                _ => None,
            }
        }
    }
    struct EnvAdapter(AtomicUsize);
    impl ProviderAdapter for EnvAdapter {
        fn id(&self) -> ProviderId {
            ProviderId("factory".into())
        }
        fn fetch<'a>(&'a self, c: &'a ProviderContext) -> FetchFuture<'a> {
            Box::pin(async {
                self.0.fetch_add(1, Ordering::SeqCst);
                let mut usage = MockProvider.fetch(c).await?;
                usage.provider = self.id();
                for w in &mut usage.windows {
                    w.fetched_at = c.clock.now();
                }
                Ok(usage)
            })
        }
    }
    let mut f = Fixture::new();
    let a = Arc::new(EnvAdapter(AtomicUsize::new(0)));
    for (key, org) in [
        ("secret-sentinel-one", "org-a"),
        ("secret-sentinel-one", "org-b"),
        ("secret-sentinel-two", "org-b"),
    ] {
        f.collector.context.credentials = Arc::new(Keys {
            key: key.into(),
            org: org.into(),
        });
        f.collect(vec![a.clone()], false).await;
        f.collect(vec![a.clone()], false).await;
    }
    assert_eq!(a.0.load(Ordering::SeqCst), 3);
    for entry in std::fs::read_dir(&f.dir).unwrap() {
        let path = entry.unwrap().path();
        assert!(
            !path
                .file_name()
                .unwrap()
                .to_string_lossy()
                .contains("secret-sentinel")
        );
        let bytes = std::fs::read(path).unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains("secret-sentinel"));
    }
}

#[tokio::test]
async fn partial_diagnostics_survive_fresh_cache_without_refetching() {
    let fixture = Fixture::new();
    let adapter = Adapter::new("partial-account");
    adapter.partial.store(true, Ordering::SeqCst);
    for _ in 0..2 {
        let report = fixture
            .cache
            .collect(
                &fixture.collector,
                CollectRequest {
                    providers: vec![adapter.clone()],
                    timeout: Duration::from_secs(2),
                    cancellation: Cancellation::default(),
                },
                false,
            )
            .await;
        assert_eq!(report.providers.len(), 1);
        assert_eq!(report.failures.len(), 1);
        assert_eq!(
            report.providers[0].diagnostics[0].source,
            "fixture_endpoint"
        );
        assert_eq!(report.failures[0].code, ProviderError::Transient);
    }
    assert_eq!(adapter.calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn failed_refresh_clears_diagnostics_from_retained_usage() {
    let fixture = Fixture::new();
    let adapter = Adapter::new("partial-account");
    adapter.partial.store(true, Ordering::SeqCst);
    for fails in [false, true] {
        adapter.fails.store(fails, Ordering::SeqCst);
        let report = fixture.collect(vec![adapter.clone()], true).await;
        assert_eq!(report.providers.len(), 1);
        assert_eq!(report.failures.len(), 1);
        assert_eq!(report.providers[0].diagnostics.is_empty(), fails);
        assert_eq!(
            report.failures[0].code,
            if fails {
                ProviderError::Unavailable
            } else {
                ProviderError::Transient
            }
        );
    }
}
