//! Shared quota state. Views observe this entity; it polls the host and runs commands.
use std::{sync::Arc, time::Duration};

use gpui_kit::{Context, SharedString};
use time::{OffsetDateTime, UtcOffset};

use crate::host::{HostClient, HostError};
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
    offset: UtcOffset,
    /// Tracked accounts, for the tray and popup.
    pub overview: Option<Overview>,
    /// Every account including paused ones, for the settings window.
    pub all: Option<Overview>,
    snapshot: Option<quotio::contract::Snapshot>,
    pub error: Option<SharedString>,
    /// True while the host cannot open its account vault; settings offers to unlock it.
    pub vault_locked: bool,
    pub refreshing: bool,
}

impl QuotaStore {
    pub fn new(
        host: Arc<dyn HostClient>,
        clock: Clock,
        offset: UtcOffset,
        cx: &mut Context<Self>,
    ) -> Self {
        cx.spawn(async move |this, cx| {
            loop {
                let Ok(fetch) = this.update(cx, |this, _| this.host.snapshot()) else {
                    return;
                };
                let result = fetch.await;
                if this.update(cx, |this, cx| this.apply(result, cx)).is_err() {
                    return;
                }
                cx.background_executor().timer(POLL_INTERVAL).await;
            }
        })
        .detach();
        Self {
            host,
            clock,
            offset,
            overview: None,
            all: None,
            snapshot: None,
            error: None,
            vault_locked: false,
            refreshing: false,
        }
    }

    fn now(&self) -> OffsetDateTime {
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
        let now = self.now();
        let used = prefs::get(cx).quota_display == QuotaDisplay::Used;
        self.overview = Some(model::overview(snapshot, now, self.offset, false, used));
        self.all = Some(model::overview(snapshot, now, self.offset, true, used));
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

    /// The local time zone, for times shown to the user.
    pub fn offset(&self) -> UtcOffset {
        self.offset
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
            for delay in [1, 3, 6] {
                cx.background_executor()
                    .timer(Duration::from_secs(delay))
                    .await;
                let Ok(fetch) = this.update(cx, |this, _| this.host.snapshot()) else {
                    return;
                };
                let result = fetch.await;
                let _ = this.update(cx, |this, cx| this.apply(result, cx));
            }
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
