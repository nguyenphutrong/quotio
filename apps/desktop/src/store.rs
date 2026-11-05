//! Shared quota state. Views observe this entity; it polls the host and runs commands.
use std::{sync::Arc, time::Duration};

use gpui_kit::{Context, SharedString};
use time::{OffsetDateTime, UtcOffset, format_description::well_known::Rfc3339};

use crate::host::{HostClient, HostError, Method};
use crate::model::{self, Overview};
use crate::prefs::{self, QuotaDisplay};

const POLL_INTERVAL: Duration = Duration::from_secs(15);

pub enum Clock {
    System,
    /// Fixture mode renders relative times against the snapshot, not the wall clock.
    Frozen(OffsetDateTime),
}

pub struct QuotaStore {
    host: Arc<dyn HostClient>,
    clock: Clock,
    /// Tracked accounts, for the tray and popup.
    pub overview: Option<Overview>,
    /// Every account including paused ones, for the settings window.
    pub all: Option<Overview>,
    snapshot: Option<quotio::contract::Snapshot>,
    pub error: Option<SharedString>,
    /// True while the host cannot open its account vault; settings offers to unlock it.
    pub vault_locked: bool,
    pub refreshing: bool,
    /// When the host refreshes next, from `/v2/status`; `None` when refresh is manual.
    pub next_refresh: Option<OffsetDateTime>,
}

impl QuotaStore {
    pub fn new(host: Arc<dyn HostClient>, clock: Clock, cx: &mut Context<Self>) -> Self {
        cx.spawn(async move |this, cx| {
            loop {
                let Ok(fetch) = this.update(cx, |this, _| this.host.snapshot()) else {
                    return;
                };
                let result = fetch.await;
                if this.update(cx, |this, cx| this.apply(result, cx)).is_err() {
                    return;
                }
                let Ok(status) = this.update(cx, |this, _| {
                    this.host.call(Method::GET, "/v2/status".into(), None)
                }) else {
                    return;
                };
                let next = status.await.ok().and_then(|status| {
                    let at = status["next_refresh_at"].as_str()?;
                    OffsetDateTime::parse(at, &Rfc3339).ok()
                });
                let _ = this.update(cx, |this, cx| {
                    if this.next_refresh != next {
                        this.next_refresh = next;
                        cx.notify();
                    }
                });
                cx.background_executor().timer(POLL_INTERVAL).await;
            }
        })
        .detach();
        Self {
            host,
            clock,
            overview: None,
            all: None,
            snapshot: None,
            error: None,
            vault_locked: false,
            refreshing: false,
            next_refresh: None,
        }
    }

    pub fn now(&self) -> OffsetDateTime {
        match self.clock {
            Clock::System => OffsetDateTime::now_utc(),
            Clock::Frozen(at) => at,
        }
    }

    fn apply(
        &mut self,
        result: anyhow::Result<quotio::contract::Snapshot>,
        cx: &mut Context<Self>,
    ) {
        match result {
            Ok(snapshot) => {
                // Polls, reloads and refreshes overlap; a late answer must not undo a newer one.
                if self
                    .snapshot
                    .as_ref()
                    .is_some_and(|current| snapshot.revision < current.revision)
                {
                    return;
                }
                // A merged login keeps its menu-bar place under the account it joined.
                let pinned = &prefs::get(cx).menu_bar.accounts;
                if pinned
                    .iter()
                    .any(|id| snapshot.account_redirects.contains_key(id))
                {
                    let mut remapped: Vec<String> = Vec::new();
                    for id in pinned {
                        let id = snapshot.account_redirects.get(id).unwrap_or(id);
                        if !remapped.contains(id) {
                            remapped.push(id.clone());
                        }
                    }
                    prefs::update(cx, |prefs| prefs.menu_bar.accounts = remapped);
                }
                self.snapshot = Some(snapshot);
                self.rebuild(cx);
                self.error = None;
                self.vault_locked = false;
            }
            Err(error) => {
                self.vault_locked = matches!(
                    HostError::code(&error),
                    Some("credential_storage_unavailable" | "account_storage_disabled")
                );
                self.error = Some(format!("{error:#}").into());
            }
        }
        cx.notify();
    }

    /// Recompute the views from the last snapshot, for instance after the user
    /// switches between remaining and used percentages.
    pub fn rebuild(&mut self, cx: &mut Context<Self>) {
        let Some(snapshot) = &self.snapshot else {
            return;
        };
        let (now, offset) = (self.now(), self.offset());
        let prefs = prefs::get(cx);
        let (used, total_usage, aggregation) = (
            prefs.quota_display == QuotaDisplay::Used,
            prefs.total_usage,
            prefs.model_aggregation,
        );
        let overview = |with_paused| {
            model::overview(
                snapshot,
                now,
                offset,
                with_paused,
                used,
                total_usage,
                aggregation,
            )
        };
        self.overview = Some(overview(false));
        self.all = Some(overview(true));
        cx.notify();
    }

    /// A login from the last snapshot, by source id.
    pub fn source(&self, id: &str) -> Option<quotio::contract::Source> {
        self.snapshot
            .iter()
            .flat_map(|s| &s.accounts)
            .flat_map(|a| &a.sources)
            .find(|s| s.id == id)
            .cloned()
    }

    /// Logins Quotio reads from other apps, with their account's provider.
    pub fn borrowed_sources(&self) -> Vec<(String, quotio::contract::Source)> {
        self.snapshot
            .iter()
            .flat_map(|s| &s.accounts)
            .flat_map(|a| a.sources.iter().map(|s| (a.provider_id.clone(), s)))
            .filter(|(_, s)| s.origin != quotio::domain::AccountOrigin::Owned)
            .map(|(provider, s)| (provider, s.clone()))
            .collect()
    }

    pub fn host(&self) -> Arc<dyn HostClient> {
        self.host.clone()
    }

    /// The local time zone now, for times shown to the user. Read each time, so a
    /// daylight-saving change or a new time zone shows without a restart.
    /// ponytail: one offset for all times shown; a reset across a DST change is an hour off until it passes.
    pub fn offset(&self) -> UtcOffset {
        use chrono::Offset as _;
        // `time` can't read the local zone once threads run; chrono can.
        let seconds = chrono::Local::now().offset().fix().local_minus_utc();
        UtcOffset::from_whole_seconds(seconds).unwrap_or(UtcOffset::UTC)
    }

    /// Re-read the snapshot after an account change. The host re-collects quota in
    /// the background, so look again shortly after.
    pub fn reload(&mut self, cx: &mut Context<Self>) {
        cx.spawn(async move |this, cx| {
            for delay in [0, 2, 6] {
                cx.background_executor()
                    .timer(Duration::from_secs(delay))
                    .await;
                let Ok(fetch) = this.update(cx, |this, _| this.host.snapshot()) else {
                    return;
                };
                let result = fetch.await;
                let _ = this.update(cx, |this, cx| this.apply(result, cx));
            }
        })
        .detach();
    }

    /// Ask the host to refresh, then pick up the result once providers have answered.
    pub fn refresh(&mut self, provider: Option<String>, cx: &mut Context<Self>) {
        if self.refreshing {
            return;
        }
        self.refreshing = true;
        cx.notify();
        let request = self.host.refresh(provider);
        cx.spawn(async move |this, cx| {
            let requested = request.await;
            let Ok(fetch) = this.update(cx, |this, _| this.host.snapshot()) else {
                return;
            };
            let result = fetch.await;
            let _ = this.update(cx, |this, cx| this.apply(result, cx));
            let _ = this.update(cx, |this, cx| {
                this.refreshing = false;
                if let Err(error) = requested {
                    this.error = Some(format!("{error:#}").into());
                }
                cx.notify();
            });
        })
        .detach();
    }
}
