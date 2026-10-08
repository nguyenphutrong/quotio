//! Host-owned quota observations. SQLite work is serialized on a bounded worker.
use crate::domain::{Provenance, Quota, QuotaAmounts};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    path::{Path, PathBuf},
    sync::Arc,
};
use time::OffsetDateTime;
use tokio::sync::{mpsc, oneshot};

#[derive(Debug, Clone, Copy, thiserror::Error)]
pub enum Error {
    #[error("history_storage_unavailable")]
    Storage,
    #[error("history_observation_conflict")]
    Conflict,
    #[error("history_cursor_invalid")]
    Cursor,
    #[error("history_metric_not_found")]
    Metric,
}
impl From<rusqlite::Error> for Error {
    fn from(_: rusqlite::Error) -> Self {
        Self::Storage
    }
}
type Result<T, E = Error> = std::result::Result<T, E>;
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Observation {
    pub series_id: String,
    pub basis_id: String,
    #[serde(with = "time::serde::rfc3339")]
    pub fetched_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339::option")]
    pub expires_at: Option<OffsetDateTime>,
    pub quota: Quota,
    pub amounts: Option<QuotaAmounts>,
    #[serde(with = "time::serde::rfc3339::option")]
    pub resets_at: Option<OffsetDateTime>,
    pub reset_description: Option<String>,
    pub provenance: Provenance,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Metric {
    pub id: String,
    pub display_name: String,
    pub group: Option<String>,
    pub current: bool,
    pub has_percentage: bool,
}
#[derive(Serialize)]
pub struct Catalog {
    pub schema_version: u32,
    pub host_id: String,
    pub account_id: String,
    pub history_revision: u64,
    pub recording_enabled: bool,
    pub recording_error: Option<String>,
    #[serde(with = "time::serde::rfc3339::option")]
    pub first_observed_at: Option<OffsetDateTime>,
    #[serde(with = "time::serde::rfc3339::option")]
    pub last_observed_at: Option<OffsetDateTime>,
    pub metrics: Vec<Metric>,
}
#[derive(Serialize)]
pub struct Bin {
    pub id: u32,
    #[serde(with = "time::serde::rfc3339")]
    pub start_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub end_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub first_observed_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub last_observed_at: OffsetDateTime,
    pub sample_count: u64,
    pub latest: Observation,
    pub min_remaining_percent: Option<f64>,
    pub max_remaining_percent: Option<f64>,
    pub states: Vec<String>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Event {
    pub id: String,
    pub kind: String,
    #[serde(with = "time::serde::rfc3339")]
    pub from_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub to_at: OffsetDateTime,
    pub before_remaining_percent: Option<f64>,
    pub after_remaining_percent: Option<f64>,
}
#[derive(Serialize)]
pub struct Chart {
    pub schema_version: u32,
    pub host_id: String,
    pub account_id: String,
    pub metric_id: String,
    pub history_revision: u64,
    pub range: String,
    #[serde(with = "time::serde::rfc3339")]
    pub start_at: OffsetDateTime,
    #[serde(with = "time::serde::rfc3339")]
    pub end_at: OffsetDateTime,
    pub bin_seconds: u32,
    pub recording_enabled: bool,
    pub recording_error: Option<String>,
    pub bins: Vec<Bin>,
    pub events: Vec<Event>,
    pub next_cursor: Option<String>,
    pub latest: Option<Observation>,
    pub lowest_remaining_percent: Option<f64>,
}
#[derive(Serialize)]
pub struct EventsPage {
    pub schema_version: u32,
    pub host_id: String,
    pub account_id: String,
    pub metric_id: String,
    pub history_revision: u64,
    pub events: Vec<Event>,
    pub next_cursor: Option<String>,
}
#[derive(Clone)]
pub struct Account {
    pub host_id: String,
    pub id: String,
    pub epoch: String,
    pub redirects: Vec<String>,
    pub metrics: Vec<Metric>,
}
pub struct Point {
    pub account: Account,
    pub metric: Metric,
    pub basis: String,
    pub observation: Observation,
}
#[derive(Clone)]
pub struct History {
    sender: mpsc::Sender<Job>,
    revision: Arc<std::sync::atomic::AtomicU64>,
}
type Job = Box<dyn FnOnce(&mut Store) + Send>;
#[derive(Clone)]
struct Cursor {
    host: String,
    account: String,
    epoch: String,
    metric: String,
    range: String,
    revision: u64,
    start: OffsetDateTime,
    end: OffsetDateTime,
    offset: usize,
    sequence: i64,
    clock_sequence: i64,
}
struct Store {
    db: Connection,
    revision: Arc<std::sync::atomic::AtomicU64>,
    error: Option<String>,
    last_pruned: OffsetDateTime,
    cursors: HashMap<String, Cursor>,
    #[cfg(windows)]
    _directory_guards: Vec<std::fs::File>,
}
impl History {
    pub async fn open(path: PathBuf, now: OffsetDateTime) -> Result<Self> {
        let (sender, mut receiver) = mpsc::channel::<Job>(32);
        let revision = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let worker_revision = revision.clone();
        let (send, receive) = oneshot::channel();
        std::thread::Builder::new()
            .name("quotio-history".into())
            .spawn(move || {
                let mut store = match Store::open(&path, now, worker_revision) {
                    Ok(s) => s,
                    Err(e) => {
                        let _ = send.send(Err(e));
                        return;
                    }
                };
                let _ = send.send(Ok(()));
                while let Some(job) = receiver.blocking_recv() {
                    job(&mut store);
                }
            })
            .map_err(|_| Error::Storage)?;
        receive.await.map_err(|_| Error::Storage)??;
        Ok(Self { sender, revision })
    }
    pub fn revision(&self) -> u64 {
        self.revision.load(std::sync::atomic::Ordering::SeqCst)
    }
    async fn call<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Store) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let (send, receive) = oneshot::channel();
        self.sender
            .send(Box::new(move |store| {
                let _ = send.send(f(store));
            }))
            .await
            .map_err(|_| Error::Storage)?;
        receive.await.map_err(|_| Error::Storage)?
    }
    pub async fn record(
        &self,
        points: Vec<Point>,
        revision: u64,
        now: OffsetDateTime,
    ) -> Result<()> {
        self.call(move |s| {
            let result = s.record(points, revision, now);
            match &result {
                Err(error) => s.error = Some(error.to_string()),
                Ok(true) => s.error = None,
                Ok(false) => {}
            }
            let _ = s.db.execute(
                "UPDATE history_recording_state SET error=? WHERE account=''",
                [&s.error],
            );
            result.map(|_| ())
        })
        .await
    }
    pub async fn clear(&self, account: Option<Account>, now: OffsetDateTime) -> Result<()> {
        self.call(move |s| s.clear(account, now)).await
    }
    pub async fn note_error(&self, code: &'static str) -> Result<()> {
        self.call(move |s| {
            s.error = Some(code.into());
            let _ = s.db.execute(
                "UPDATE history_recording_state SET error=? WHERE account=''",
                [code],
            );
            Ok(())
        })
        .await
    }
    pub async fn maintain(&self, now: OffsetDateTime) -> Result<()> {
        self.call(move |s| s.prune(now)).await
    }
    pub async fn pause(&self, now: OffsetDateTime) -> Result<()> {
        self.call(move |s| s.advance(now)).await
    }
    pub async fn catalog(
        &self,
        account: Account,
        enabled: bool,
        now: OffsetDateTime,
    ) -> Result<Catalog> {
        self.call(move |s| s.catalog(account, enabled, now)).await
    }
    pub async fn chart(
        &self,
        account: Account,
        metric: String,
        range: String,
        enabled: bool,
        now: OffsetDateTime,
    ) -> Result<Chart> {
        self.call(move |s| s.chart(account, metric, range, enabled, now))
            .await
    }
    pub async fn events(
        &self,
        account: Account,
        metric: String,
        range: String,
        token: String,
        now: OffsetDateTime,
    ) -> Result<EventsPage> {
        self.call(move |s| s.events(account, metric, range, token, now))
            .await
    }
}
fn private_file(path: &Path) -> Result<()> {
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        if meta.file_type().is_symlink() || !meta.is_file() {
            return Err(Error::Storage);
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::{MetadataExt, PermissionsExt};
            if meta.uid() != unsafe { libc::geteuid() } {
                return Err(Error::Storage);
            }
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
                .map_err(|_| Error::Storage)?;
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
            use windows_sys::Win32::Storage::FileSystem::{
                FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
                FILE_SHARE_WRITE,
            };
            if meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
                return Err(Error::Storage);
            }
            let file = std::fs::OpenOptions::new()
                .read(true)
                .access_mode(0x80000000 | 0x00040000)
                .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
                .open(path)
                .map_err(|_| Error::Storage)?;
            crate::accounts::windows_vault::restrict(&file).map_err(|_| Error::Storage)?;
        }
    }
    Ok(())
}
impl Store {
    fn open(
        path: &Path,
        now: OffsetDateTime,
        revision: Arc<std::sync::atomic::AtomicU64>,
    ) -> Result<Self> {
        let parent = path.parent().ok_or(Error::Storage)?;
        for ancestor in parent.ancestors() {
            if let Ok(meta) = std::fs::symlink_metadata(ancestor)
                && meta.file_type().is_symlink()
            {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::MetadataExt;
                    let expected = match ancestor.to_str() {
                        Some("/var") => "/private/var",
                        Some("/tmp") => "/private/tmp",
                        _ => return Err(Error::Storage),
                    };
                    let target = std::fs::canonicalize(ancestor).map_err(|_| Error::Storage)?;
                    let resolved = std::fs::metadata(&target).map_err(|_| Error::Storage)?;
                    if ancestor == parent
                        || meta.uid() != 0
                        || target != Path::new(expected)
                        || resolved.uid() != 0
                    {
                        return Err(Error::Storage);
                    }
                }
                #[cfg(not(unix))]
                {
                    return Err(Error::Storage);
                }
            }
        }
        std::fs::create_dir_all(parent).map_err(|_| Error::Storage)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::{MetadataExt, PermissionsExt};
            let meta = std::fs::metadata(parent).map_err(|_| Error::Storage)?;
            if meta.uid() != unsafe { libc::geteuid() } {
                return Err(Error::Storage);
            }
            std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))
                .map_err(|_| Error::Storage)?;
        }
        #[cfg(windows)]
        let directory_guards = {
            use std::os::windows::fs::OpenOptionsExt;
            use windows_sys::Win32::Storage::FileSystem::{
                FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
                FILE_SHARE_WRITE,
            };
            let guards = crate::accounts::windows_vault::directory_guards(parent)
                .map_err(|_| Error::Storage)?;
            let directory = std::fs::OpenOptions::new()
                .read(true)
                .access_mode(0x80000000 | 0x00040000)
                .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
                .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
                .open(parent)
                .map_err(|_| Error::Storage)?;
            crate::accounts::windows_vault::restrict(&directory).map_err(|_| Error::Storage)?;
            guards
        };
        for suffix in ["", "-wal", "-shm"] {
            private_file(&PathBuf::from(format!("{}{suffix}", path.display())))?;
        }
        let mut options = std::fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        options.open(path).map_err(|_| Error::Storage)?;
        private_file(path)?;
        let db = Connection::open(path)?;
        db.busy_timeout(std::time::Duration::from_secs(2))?;
        db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON;")?;
        let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version > 2 {
            return Err(Error::Storage);
        }
        db.execute_batch("BEGIN IMMEDIATE;
          CREATE TABLE IF NOT EXISTS history_series (id TEXT PRIMARY KEY,host TEXT NOT NULL,account TEXT NOT NULL,epoch TEXT NOT NULL,metric TEXT NOT NULL,metadata TEXT NOT NULL,UNIQUE(host,account,epoch,metric));
          CREATE TABLE IF NOT EXISTS history_observations (sequence INTEGER PRIMARY KEY,series TEXT NOT NULL REFERENCES history_series(id) ON DELETE CASCADE,at INTEGER NOT NULL,payload TEXT NOT NULL,UNIQUE(series,at));
          CREATE INDEX IF NOT EXISTS history_time ON history_observations(at);
          CREATE INDEX IF NOT EXISTS history_range ON history_observations(series,at);
          CREATE TABLE IF NOT EXISTS history_clock_events (sequence INTEGER PRIMARY KEY,series TEXT NOT NULL REFERENCES history_series(id) ON DELETE CASCADE,at INTEGER NOT NULL,fetched_at INTEGER NOT NULL,payload TEXT NOT NULL,UNIQUE(series,fetched_at));
          CREATE INDEX IF NOT EXISTS history_clock_time ON history_clock_events(at);
          CREATE TABLE IF NOT EXISTS history_recording_state (account TEXT PRIMARY KEY,revision INTEGER NOT NULL,cutoff INTEGER NOT NULL);
          INSERT OR IGNORE INTO history_recording_state(account,revision,cutoff) VALUES ('',0,-9223372036854775808);")?;
        if version < 2 {
            db.execute_batch("ALTER TABLE history_recording_state ADD COLUMN error TEXT;")?;
        }
        db.execute_batch("PRAGMA user_version=2; COMMIT;")?;
        for suffix in ["", "-wal", "-shm"] {
            private_file(&PathBuf::from(format!("{}{suffix}", path.display())))?;
        }
        let stored: u64 = db.query_row(
            "SELECT revision FROM history_recording_state WHERE account=''",
            [],
            |r| r.get(0),
        )?;
        revision.store(stored, std::sync::atomic::Ordering::SeqCst);
        let error = db.query_row(
            "SELECT error FROM history_recording_state WHERE account=''",
            [],
            |r| r.get(0),
        )?;
        let mut s = Self {
            db,
            revision,
            error,
            last_pruned: OffsetDateTime::UNIX_EPOCH,
            cursors: HashMap::new(),
            #[cfg(windows)]
            _directory_guards: directory_guards,
        };
        s.prune(now)?;
        Ok(s)
    }
    fn prune(&mut self, now: OffsetDateTime) -> Result<()> {
        if now - self.last_pruned < time::Duration::days(1) {
            return Ok(());
        }
        let cutoff = nanos(now - time::Duration::days(30));
        loop {
            let count=self.db.execute("DELETE FROM history_observations WHERE sequence IN (SELECT sequence FROM history_observations WHERE at<? LIMIT 4096)",[cutoff])?;
            if count < 4096 {
                break;
            }
        }
        loop {
            let count=self.db.execute("DELETE FROM history_clock_events WHERE sequence IN (SELECT sequence FROM history_clock_events WHERE at<? LIMIT 4096)",[cutoff])?;
            if count < 4096 {
                break;
            }
        }
        self.db.execute("DELETE FROM history_series WHERE NOT EXISTS(SELECT 1 FROM history_observations WHERE series=history_series.id) AND NOT EXISTS(SELECT 1 FROM history_clock_events WHERE series=history_series.id)",[])?;
        self.last_pruned = now;
        Ok(())
    }
    fn record(&mut self, points: Vec<Point>, revision: u64, now: OffsetDateTime) -> Result<bool> {
        self.prune(now)?;
        if revision != self.revision.load(std::sync::atomic::Ordering::SeqCst) {
            return Ok(false);
        }
        let tx = self.db.transaction()?;
        let mut accepted = false;
        for mut point in points {
            let cutoff:i64=tx.query_row("SELECT MAX(cutoff) FROM history_recording_state WHERE account='' OR account IN (SELECT value FROM json_each(?))",[aliases(&point.account)],|r|r.get(0))?;
            if nanos(point.observation.fetched_at) <= cutoff
                || point.observation.fetched_at < now - time::Duration::days(30)
            {
                continue;
            }
            accepted = true;
            // A confirmed rename keeps writing to the series recorded under a redirected ID.
            let series:Option<String>=tx.query_row("SELECT id FROM history_series WHERE host=? AND account IN (SELECT value FROM json_each(?)) AND epoch=? AND metric=? ORDER BY account=? DESC LIMIT 1",params![point.account.host_id,aliases(&point.account),point.account.epoch,point.metric.id,point.account.id],|r|r.get(0)).optional()?;
            let id = match series {
                Some(id) => id,
                None => crate::accounts::random_string().map_err(|_| Error::Storage)?,
            };
            point.metric.current = false;
            let metadata = serde_json::to_string(&point.metric).map_err(|_| Error::Storage)?;
            tx.execute("INSERT INTO history_series(id,host,account,epoch,metric,metadata) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata",params![id,point.account.host_id,point.account.id,point.account.epoch,point.metric.id,metadata])?;
            point.observation.series_id = id.clone();
            point.observation.basis_id = point.basis;
            let payload = serde_json::to_string(&point.observation).map_err(|_| Error::Storage)?;
            if point.observation.fetched_at > now {
                let event = Event {
                    id: crate::cache::fingerprint(&[&id, &payload, "clock"]),
                    kind: "clock_changed".into(),
                    from_at: now,
                    to_at: point.observation.fetched_at,
                    before_remaining_percent: None,
                    after_remaining_percent: remaining(&point.observation.quota),
                };
                let previous: Option<String> = tx
                    .query_row(
                        "SELECT payload FROM history_clock_events WHERE series=? AND fetched_at=?",
                        params![id, nanos(point.observation.fetched_at)],
                        |r| r.get(0),
                    )
                    .optional()?;
                if let Some(previous) = previous {
                    let previous: Event =
                        serde_json::from_str(&previous).map_err(|_| Error::Storage)?;
                    if previous.id != event.id {
                        return Err(Error::Conflict);
                    }
                    continue;
                }
                let payload = serde_json::to_string(&event).map_err(|_| Error::Storage)?;
                tx.execute("INSERT INTO history_clock_events(series,at,fetched_at,payload) VALUES(?,?,?,?)",params![id,nanos(now),nanos(point.observation.fetched_at),payload])?;
                continue;
            }
            let previous: Option<String> = tx
                .query_row(
                    "SELECT payload FROM history_observations WHERE series=? AND at=?",
                    params![id, nanos(point.observation.fetched_at)],
                    |r| r.get(0),
                )
                .optional()?;
            match previous {
                Some(old) if old != payload => return Err(Error::Conflict),
                Some(_) => (),
                None => {
                    tx.execute(
                        "INSERT INTO history_observations(series,at,payload) VALUES(?,?,?)",
                        params![id, nanos(point.observation.fetched_at), payload],
                    )?;
                }
            }
        }
        tx.commit()?;
        Ok(accepted)
    }
    fn advance(&mut self, now: OffsetDateTime) -> Result<()> {
        let tx = self.db.transaction()?;
        tx.execute("UPDATE history_recording_state SET revision=revision+1,cutoff=MAX(cutoff,?) WHERE account=''",[nanos(now)])?;
        tx.commit()?;
        self.revision
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.cursors.clear();
        Ok(())
    }
    fn clear(&mut self, account: Option<Account>, now: OffsetDateTime) -> Result<()> {
        let tx = self.db.transaction()?;
        if let Some(account) = account {
            tx.execute("DELETE FROM history_series WHERE account=?", [&account.id])?;
            for old in account.redirects {
                tx.execute("DELETE FROM history_series WHERE account=?", [old])?;
            }
            tx.execute("INSERT INTO history_recording_state(account,revision,cutoff) VALUES(?,0,?) ON CONFLICT(account) DO UPDATE SET cutoff=MAX(cutoff,excluded.cutoff)",params![account.id,nanos(now)])?;
            tx.execute(
                "UPDATE history_recording_state SET revision=revision+1 WHERE account=''",
                [],
            )?;
        } else {
            tx.execute("DELETE FROM history_series", [])?;
            tx.execute("UPDATE history_recording_state SET revision=revision+1,cutoff=MAX(cutoff,?) WHERE account=''",[nanos(now)])?;
        }
        tx.execute(
            "UPDATE history_recording_state SET error=NULL WHERE account=''",
            [],
        )?;
        tx.commit()?;
        self.revision
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.cursors.clear();
        self.error = None;
        Ok(())
    }
    fn catalog(&mut self, account: Account, enabled: bool, now: OffsetDateTime) -> Result<Catalog> {
        self.prune(now)?;
        let mut metrics = account.metrics.clone();
        let mut stmt = self.db.prepare(
            "SELECT metadata,
             EXISTS (SELECT 1 FROM history_observations numeric
                     WHERE numeric.series=history_series.id AND numeric.at>=?4
                     AND json_extract(numeric.payload,'$.quota.state') IN ('available','exhausted'))
             FROM history_series WHERE host=?1
             AND account IN (SELECT value FROM json_each(?2)) AND epoch=?3
             AND (EXISTS (SELECT 1 FROM history_observations o
                          WHERE o.series=history_series.id AND o.at>=?4)
                  OR EXISTS (SELECT 1 FROM history_clock_events e
                             WHERE e.series=history_series.id AND e.at>=?4))
             ORDER BY rowid",
        )?;
        let cutoff = nanos(now - time::Duration::days(30));
        for row in stmt.query_map(
            params![account.host_id, aliases(&account), account.epoch, cutoff],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, bool>(1)?)),
        )? {
            let (metadata, has_percentage) = row?;
            let mut old: Metric = serde_json::from_str(&metadata).map_err(|_| Error::Storage)?;
            old.has_percentage = has_percentage;
            if let Some(current) = metrics.iter_mut().find(|m| m.id == old.id) {
                current.has_percentage |= old.has_percentage;
            } else {
                metrics.push(old)
            }
        }
        let (first,last):(Option<i64>,Option<i64>)=self.db.query_row("SELECT MIN(at),MAX(at) FROM history_observations o JOIN history_series s ON s.id=o.series WHERE s.host=? AND s.account IN (SELECT value FROM json_each(?)) AND s.epoch=? AND o.at>=?",params![account.host_id,aliases(&account),account.epoch,nanos(now-time::Duration::days(30))],|r|Ok((r.get(0)?,r.get(1)?)))?;
        Ok(Catalog {
            schema_version: 2,
            host_id: account.host_id,
            account_id: account.id,
            history_revision: self.revision.load(std::sync::atomic::Ordering::SeqCst),
            recording_enabled: enabled,
            recording_error: self.error.clone(),
            first_observed_at: first.map(from_nanos).transpose()?,
            last_observed_at: last.map(from_nanos).transpose()?,
            metrics,
        })
    }
    fn points(
        &self,
        account: &Account,
        metric: &str,
        start: OffsetDateTime,
        end: OffsetDateTime,
        sequence: i64,
    ) -> Result<Vec<Observation>> {
        let mut stmt=self.db.prepare("WITH selected AS (SELECT o.sequence,o.at,o.payload FROM history_observations o JOIN history_series s ON s.id=o.series WHERE s.host=? AND s.account IN (SELECT value FROM json_each(?)) AND s.epoch=? AND s.metric=? AND o.sequence<=?) SELECT payload FROM selected WHERE at BETWEEN ? AND ? OR sequence=(SELECT MAX(sequence) FROM selected WHERE at<?) ORDER BY sequence")?;
        stmt.query_map(
            params![
                account.host_id,
                aliases(account),
                account.epoch,
                metric,
                sequence,
                nanos(start),
                nanos(end),
                nanos(start)
            ],
            |r| r.get::<_, String>(0),
        )?
        .map(|r| serde_json::from_str(&r?).map_err(|_| Error::Storage))
        .collect()
    }
    fn read_events(
        &self,
        account: &Account,
        metric: &str,
        points: &[Observation],
        start: OffsetDateTime,
        end: OffsetDateTime,
        clock_sequence: i64,
    ) -> Result<Vec<Event>> {
        let first = points.first().map_or(start, |p| p.fetched_at.min(start));
        let mut stmt=self.db.prepare("SELECT payload FROM history_clock_events e JOIN history_series s ON s.id=e.series WHERE s.host=? AND s.account IN (SELECT value FROM json_each(?)) AND s.epoch=? AND s.metric=? AND e.at BETWEEN ? AND ? AND e.sequence<=? ORDER BY e.sequence")?;
        let clocks: Vec<Event> = stmt
            .query_map(
                params![
                    account.host_id,
                    aliases(account),
                    account.epoch,
                    metric,
                    nanos(first),
                    nanos(end),
                    clock_sequence
                ],
                |r| r.get::<_, String>(0),
            )?
            .map(|row| serde_json::from_str(&row?).map_err(|_| Error::Storage))
            .collect::<Result<_>>()?;
        let mut events = derive_events(points);
        events.retain(|event| {
            !matches!(event.kind.as_str(), "reset_inferred" | "quota_increased")
                || !clocks
                    .iter()
                    .any(|clock| clock.from_at > event.from_at && clock.from_at <= event.to_at)
        });
        events.extend(clocks.into_iter().filter(|clock| clock.from_at >= start));
        events.sort_by(|a, b| a.from_at.cmp(&b.from_at).then_with(|| a.id.cmp(&b.id)));
        Ok(events)
    }
    fn chart(
        &mut self,
        account: Account,
        metric: String,
        range: String,
        enabled: bool,
        now: OffsetDateTime,
    ) -> Result<Chart> {
        self.prune(now)?;
        let (duration, width) = range_spec(&range).ok_or(Error::Cursor)?;
        let end = now.to_offset(time::UtcOffset::UTC);
        let start = end - time::Duration::seconds(duration);
        if !self
            .catalog(account.clone(), enabled, now)?
            .metrics
            .iter()
            .any(|m| m.id == metric)
        {
            return Err(Error::Metric);
        }
        let sequence = self.db.query_row(
            "SELECT COALESCE(MAX(sequence),0) FROM history_observations",
            [],
            |r| r.get::<_, i64>(0),
        )?;
        let clock_sequence = self.db.query_row(
            "SELECT COALESCE(MAX(sequence),0) FROM history_clock_events",
            [],
            |r| r.get::<_, i64>(0),
        )?;
        let points = self.points(&account, &metric, start, end, sequence)?;
        let all_events =
            self.read_events(&account, &metric, &points, start, end, clock_sequence)?;
        let points: Vec<_> = points
            .into_iter()
            .filter(|point| point.fetched_at >= start && point.fetched_at <= end)
            .collect();
        let mut bins: BTreeMap<u32, Bin> = BTreeMap::new();
        let lowest = points
            .iter()
            .filter_map(|p| remaining(&p.quota))
            .reduce(f64::min);
        let latest = points.iter().max_by_key(|p| p.fetched_at).cloned();
        for point in points {
            let id = ((point.fetched_at - start).whole_seconds().max(0) as u32 / width).min(359);
            let value = remaining(&point.quota);
            let state = state(&point.quota).to_owned();
            let bin = bins.entry(id).or_insert_with(|| Bin {
                id,
                start_at: start + time::Duration::seconds(i64::from(id * width)),
                end_at: (start + time::Duration::seconds(i64::from((id + 1) * width))).min(end),
                first_observed_at: point.fetched_at,
                last_observed_at: point.fetched_at,
                sample_count: 0,
                latest: point.clone(),
                min_remaining_percent: None,
                max_remaining_percent: None,
                states: vec![],
            });
            bin.sample_count += 1;
            bin.first_observed_at = bin.first_observed_at.min(point.fetched_at);
            bin.last_observed_at = bin.last_observed_at.max(point.fetched_at);
            if point.fetched_at >= bin.latest.fetched_at {
                bin.latest = point
            }
            if let Some(v) = value {
                bin.min_remaining_percent = Some(bin.min_remaining_percent.map_or(v, |n| n.min(v)));
                bin.max_remaining_percent = Some(bin.max_remaining_percent.map_or(v, |n| n.max(v)));
            }
            if !bin.states.contains(&state) {
                bin.states.push(state)
            }
        }
        let revision = self.revision.load(std::sync::atomic::Ordering::SeqCst);
        let (events, next_cursor) = self.page(
            all_events,
            Cursor {
                host: account.host_id.clone(),
                account: account.id.clone(),
                epoch: account.epoch.clone(),
                metric: metric.clone(),
                range: range.clone(),
                revision,
                start,
                end,
                offset: 0,
                sequence,
                clock_sequence,
            },
        )?;
        Ok(Chart {
            schema_version: 2,
            host_id: account.host_id,
            account_id: account.id,
            metric_id: metric,
            history_revision: revision,
            range,
            start_at: start,
            end_at: end,
            bin_seconds: width,
            recording_enabled: enabled,
            recording_error: self.error.clone(),
            bins: bins.into_values().collect(),
            events,
            next_cursor,
            latest,
            lowest_remaining_percent: lowest,
        })
    }
    fn page(
        &mut self,
        events: Vec<Event>,
        mut cursor: Cursor,
    ) -> Result<(Vec<Event>, Option<String>)> {
        let page = events
            .iter()
            .skip(cursor.offset)
            .take(128)
            .cloned()
            .collect();
        let next = if events.len() > cursor.offset + 128 {
            if self.cursors.len() >= 256 {
                self.cursors.clear()
            }
            let token = crate::accounts::random_string().map_err(|_| Error::Storage)?;
            cursor.offset += 128;
            self.cursors.insert(token.clone(), cursor);
            Some(token)
        } else {
            None
        };
        Ok((page, next))
    }
    fn events(
        &mut self,
        account: Account,
        metric: String,
        range: String,
        token: String,
        now: OffsetDateTime,
    ) -> Result<EventsPage> {
        self.prune(now)?;
        let cursor = self.cursors.get(&token).cloned().ok_or(Error::Cursor)?;
        if cursor.host != account.host_id
            || cursor.account != account.id
            || cursor.epoch != account.epoch
            || cursor.metric != metric
            || cursor.range != range
            || cursor.revision != self.revision.load(std::sync::atomic::Ordering::SeqCst)
        {
            return Err(Error::Cursor);
        }
        let points = self.points(&account, &metric, cursor.start, cursor.end, cursor.sequence)?;
        let events = self.read_events(
            &account,
            &metric,
            &points,
            cursor.start,
            cursor.end,
            cursor.clock_sequence,
        )?;
        let revision = cursor.revision;
        let (events, next_cursor) = self.page(events, cursor)?;
        Ok(EventsPage {
            schema_version: 2,
            host_id: account.host_id,
            account_id: account.id,
            metric_id: metric,
            history_revision: revision,
            events,
            next_cursor,
        })
    }
}
fn aliases(account: &Account) -> String {
    serde_json::to_string(
        &std::iter::once(&account.id)
            .chain(account.redirects.iter())
            .collect::<Vec<_>>(),
    )
    .expect("account identifiers serialize")
}
fn nanos(at: OffsetDateTime) -> i64 {
    at.unix_timestamp_nanos()
        .try_into()
        .unwrap_or(if at.year() < 1970 { i64::MIN } else { i64::MAX })
}
fn from_nanos(at: i64) -> Result<OffsetDateTime> {
    OffsetDateTime::from_unix_timestamp_nanos(i128::from(at)).map_err(|_| Error::Storage)
}
pub fn range_spec(range: &str) -> Option<(i64, u32)> {
    match range {
        "24h" => Some((86400, 240)),
        "7d" => Some((604800, 1680)),
        "30d" => Some((2592000, 7200)),
        _ => None,
    }
}
pub fn remaining(quota: &Quota) -> Option<f64> {
    match quota {
        Quota::Available {
            remaining_percent, ..
        }
        | Quota::Exhausted {
            remaining_percent, ..
        } => Some(*remaining_percent),
        _ => None,
    }
}
fn state(quota: &Quota) -> &'static str {
    match quota {
        Quota::Available { .. } => "available",
        Quota::Exhausted { .. } => "exhausted",
        Quota::Unknown => "unknown",
        Quota::Disabled => "disabled",
        Quota::Unlimited => "unlimited",
        Quota::Limit { .. } => "limit",
    }
}
fn derive_events(points: &[Observation]) -> Vec<Event> {
    points
        .windows(2)
        .filter_map(|pair| {
            let (a, b) = (&pair[0], &pair[1]);
            let before = remaining(&a.quota);
            let after = remaining(&b.quota);
            let kind = if b.fetched_at < a.fetched_at {
                "clock_changed"
            } else if a.series_id != b.series_id || a.basis_id != b.basis_id {
                "basis_changed"
            } else if matches!((before,after),(Some(x),Some(y)) if y>x) {
                if a.resets_at.is_some_and(|reset| {
                    reset > a.fetched_at
                        && reset <= b.fetched_at
                        && b.resets_at.is_some_and(|next| next > reset)
                }) {
                    "reset_inferred"
                } else {
                    "quota_increased"
                }
            } else {
                return None;
            };
            Some(Event {
                id: crate::cache::fingerprint(&[
                    &a.series_id,
                    &a.basis_id,
                    &a.fetched_at.unix_timestamp_nanos().to_string(),
                    &b.series_id,
                    &b.basis_id,
                    &b.fetched_at.unix_timestamp_nanos().to_string(),
                    kind,
                ]),
                kind: kind.into(),
                from_at: a.fetched_at,
                to_at: b.fetched_at,
                before_remaining_percent: before,
                after_remaining_percent: after,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests;
