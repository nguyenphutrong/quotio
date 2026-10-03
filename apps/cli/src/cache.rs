//! Persistent normalized usage, shared by CLI and REST refresh cycles.
use crate::{
    domain::*,
    fetch::{CollectRequest, Collector, reconcile_accounts},
    providers::{ProviderAdapter, ProviderContext},
};
use std::{
    fs::{File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::task::JoinSet;

pub fn fingerprint(parts: &[&str]) -> String {
    let mut digest = ring::digest::Context::new(&ring::digest::SHA256);
    for part in parts {
        digest.update(&(part.len() as u64).to_be_bytes());
        digest.update(part.as_bytes());
    }
    digest
        .finish()
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

// Only a digest is used as a filename. Never serialize credential material.
pub(crate) fn environment_identity(id: &str, context: &ProviderContext) -> Option<String> {
    use clap::ValueEnum;
    let provider = crate::cli::Provider::from_str(id, false).ok()?;
    if id == "mock" {
        return Some("mock-v1".into());
    }
    let mut names = Vec::new();
    if let Some(definition) = provider.catalog() {
        names.push(definition.key_env);
        names.extend(definition.settings.iter().map(|s| s.env));
    } else {
        names.push(provider.api_key_name()?);
        match id {
            "amp" => names.push("AMP_URL"),
            "factory" => names.extend(["FACTORY_REGION", "FACTORY_ORG_ID"]),
            _ => {
                if let Some(name) = provider.key_api().and_then(|kind| kind.region_key()) {
                    names.push(name);
                }
            }
        }
    }
    let key = context.credentials.get(names[0])?;
    if key.0.trim().is_empty() {
        return None;
    }
    let values: Vec<_> = names
        .iter()
        .map(|name| context.credentials.get(name).map(|s| s.0))
        .collect();
    let encoded = serde_json::to_string(&values).ok()?;
    Some(fingerprint(&[id, &encoded]))
}

#[derive(Clone)]
pub struct UsageCache {
    directory: Option<PathBuf>,
    ttl: Duration,
}
impl UsageCache {
    pub fn new(directory: PathBuf, ttl: Duration) -> Self {
        Self {
            directory: Some(directory),
            ttl,
        }
    }
    pub fn platform(ttl: Duration) -> Self {
        Self {
            directory: std::env::var_os("QUOTIO_CACHE_DIR")
                .map(PathBuf::from)
                .or_else(|| {
                    directories::ProjectDirs::from("", "", "quotio")
                        .map(|dirs| dirs.cache_dir().join("usage-v1"))
                }),
            ttl,
        }
    }
    pub async fn collect(
        &self,
        collector: &Collector,
        request: CollectRequest,
        force: bool,
    ) -> UsageReport {
        let mut tasks = JoinSet::new();
        let mut refs = Vec::new();
        let mut order = std::collections::HashMap::new();
        for (index, adapter) in request.providers.into_iter().enumerate() {
            refs.push((adapter.id(), adapter.account_ref()));
            let cache = self.clone();
            let context = collector.context.clone();
            let cancellation = request.cancellation.clone();
            let timeout = request.timeout;
            let handle = tasks.spawn(async move {
                cache
                    .one(context, adapter, timeout, cancellation, force)
                    .await
            });
            order.insert(handle.id(), index);
        }
        let mut results = Vec::new();
        while let Some(result) = tasks.join_next_with_id().await {
            match result {
                Ok((id, report)) => results.push((order[&id], report)),
                Err(error) => {
                    let index = order[&error.id()];
                    let code = crate::error::ProviderError::Internal;
                    results.push((
                        index,
                        UsageReport {
                            schema_version: 1,
                            generated_at: collector.context.clock.now(),
                            providers: vec![],
                            failures: vec![ProviderFailure {
                                provider: refs[index].0.clone(),
                                account_ref: refs[index].1.clone(),
                                code,
                                message: code.to_string(),
                            }],
                        },
                    ));
                }
            }
        }
        results.sort_by_key(|(index, _)| *index);
        let mut report = UsageReport {
            schema_version: 1,
            generated_at: collector.context.clock.now(),
            providers: vec![],
            failures: vec![],
        };
        for (_, next) in results {
            report.providers.extend(next.providers);
            report.failures.extend(next.failures);
        }
        for usage in &mut report.providers {
            if usage
                .reset_credits
                .as_ref()
                .is_some_and(|c| !c.valid_at(report.generated_at))
            {
                usage.reset_credits = None;
            }
        }
        reconcile_accounts(&mut report.providers);
        report.include_diagnostics();
        report
    }
    async fn one(
        &self,
        context: ProviderContext,
        adapter: Arc<dyn ProviderAdapter>,
        timeout: Duration,
        cancellation: crate::fetch::Cancellation,
        force: bool,
    ) -> UsageReport {
        let deadline = tokio::time::Instant::now() + timeout;
        let prepare = async {
            let identity = adapter.cache_identity(&context).await?;
            let key = fingerprint(&[
                "usage-v1",
                &adapter.id().0,
                &adapter.account_ref().map(|a| a.id).unwrap_or_default(),
                &identity,
            ]);
            let directory = self.directory.clone()?;
            loop {
                let directory = directory.clone();
                let key = key.clone();
                match tokio::task::spawn_blocking(move || LockedEntry::open(&directory, &key)).await
                {
                    Ok(Ok(entry)) => return Some((identity, entry)),
                    Ok(Err(error)) if error.kind() == io::ErrorKind::WouldBlock => {
                        tokio::time::sleep(Duration::from_millis(20)).await
                    }
                    _ => {
                        diagnostic("could not open usage cache; fetching usage");
                        return None;
                    }
                }
            }
        };
        let prepared = tokio::select! {
            biased;
            _ = cancellation.cancelled() => None,
            result = tokio::time::timeout_at(deadline, prepare) => result.unwrap_or_else(|_| { diagnostic("usage cache identity or lock timed out; fetching usage"); None }),
        };
        let (identity, entry) = match prepared {
            Some((id, entry)) => (Some(id), Some(entry)),
            None => (None, None),
        };
        let mut snapshot = None;
        if let Some(entry) = &entry {
            let path = entry.path.clone();
            snapshot = match tokio::task::spawn_blocking(move || read(&path)).await {
                Ok(Ok(value)) => value.filter(|usage| {
                    usage.provider == adapter.id()
                        && usage.account_ref.as_ref().map(|a| &a.id)
                            == adapter.account_ref().as_ref().map(|a| &a.id)
                        && valid(usage)
                        && adapter.cacheable(usage)
                }),
                _ => {
                    diagnostic("could not read usage cache; fetching usage");
                    None
                }
            };
            if snapshot.is_none() && entry.path.exists() {
                diagnostic("invalid usage cache; fetching usage");
            }
        }
        // Recheck after waiting for another process and before serving a snapshot.
        let same_identity = identity.is_some()
            && checked_identity(&*adapter, &context, deadline, &cancellation).await == identity;
        if !same_identity {
            snapshot = None;
        }
        if !force
            && tokio::time::Instant::now() < deadline
            && snapshot
                .as_ref()
                .is_some_and(|usage| self.fresh(usage, context.clock.now()))
        {
            let mut usage = snapshot.unwrap();
            usage.account_ref = adapter.account_ref();
            return UsageReport {
                schema_version: 1,
                generated_at: context.clock.now(),
                providers: vec![usage],
                failures: vec![],
            };
        }
        let collector = Collector {
            context: context.clone(),
        };
        let mut report = collector
            .collect(CollectRequest {
                providers: vec![adapter.clone()],
                timeout: deadline.saturating_duration_since(tokio::time::Instant::now()),
                cancellation: cancellation.clone(),
            })
            .await;
        // A login change during fetch must never populate the previous login's entry.
        let same_identity = same_identity
            && checked_identity(
                &*adapter,
                &context,
                tokio::time::Instant::now() + timeout,
                &cancellation,
            )
            .await
                == identity;
        if same_identity {
            if let Some(usage) = report.providers.first() {
                if !adapter.cacheable(usage) {
                    return report;
                }
                if let Some(entry) = entry {
                    let usage = usage.clone();
                    if !matches!(
                        tokio::task::spawn_blocking(move || entry.write(&usage)).await,
                        Ok(Ok(()))
                    ) {
                        diagnostic("could not write usage cache; returning fetched usage");
                    }
                }
            } else if let Some(mut usage) = snapshot {
                usage.account_ref = adapter.account_ref();
                // Stale quota remains useful, but do not advertise an old banked balance.
                usage.reset_credits = None;
                usage.diagnostics.clear();
                report.providers.push(usage);
            }
        }
        report
    }
    fn fresh(&self, usage: &ProviderUsage, now: time::OffsetDateTime) -> bool {
        !usage.windows.is_empty()
            && usage
                .reset_credits
                .as_ref()
                .is_none_or(|c| c.valid_at(now) && now - c.fetched_at < self.ttl)
            && usage.windows.iter().all(|w| {
                let age = now - w.fetched_at;
                !age.is_negative() && age < self.ttl
            })
    }
}
async fn checked_identity(
    adapter: &dyn ProviderAdapter,
    context: &ProviderContext,
    deadline: tokio::time::Instant,
    cancellation: &crate::fetch::Cancellation,
) -> Option<String> {
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => None,
        result = tokio::time::timeout_at(deadline, adapter.cache_identity(context)) => result.ok().flatten(),
    }
}
fn diagnostic(message: &str) {
    eprintln!("quotio: {message}");
}
fn valid(usage: &ProviderUsage) -> bool {
    !usage.windows.is_empty()
        && usage.windows.iter().all(|w| {
            w.quota.is_valid()
                && w.consumption.as_ref().is_none_or(|c| {
                    c.used.is_finite() && c.used >= 0.0 && !c.unit.trim().is_empty()
                })
                && w.amounts
                    .as_ref()
                    .is_none_or(|a| a.remaining.is_finite() && a.limit.is_none_or(f64::is_finite))
        })
}
fn read(path: &Path) -> io::Result<Option<ProviderUsage>> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    if !file.metadata()?.is_file() {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut bytes = Vec::new();
    file.take(4 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err(io::ErrorKind::InvalidData.into());
    }
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|_| io::ErrorKind::InvalidData.into())
}
struct LockedEntry {
    path: PathBuf,
    _lock: File,
}
impl LockedEntry {
    fn open(directory: &Path, key: &str) -> io::Result<Self> {
        let mut builder = std::fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(directory)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let lock = options.open(directory.join(format!("{key}.lock")))?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
                return Err(io::Error::last_os_error());
            }
        }
        #[cfg(not(unix))]
        return Err(io::ErrorKind::Unsupported.into());
        #[cfg(unix)]
        Ok(Self {
            path: directory.join(format!("{key}.json")),
            _lock: lock,
        })
    }
    fn write(self, usage: &ProviderUsage) -> io::Result<()> {
        // The per-entry OS lock covers read, fetch and rename. It is released on
        // cancellation/crash and never unlinked, so waiters lock the same inode.
        let temp = self.path.with_extension("tmp");
        let result = (|| {
            let mut options = OpenOptions::new();
            options.write(true).create(true).truncate(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
            }
            let mut file = options.open(&temp)?;
            serde_json::to_writer(&mut file, usage).map_err(|_| io::ErrorKind::InvalidData)?;
            file.flush()?;
            file.sync_all()?;
            std::fs::rename(&temp, &self.path)?;
            File::open(self.path.parent().unwrap())?.sync_all()
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(temp);
        }
        result
    }
}
