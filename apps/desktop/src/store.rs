//! Shared quota state. Views observe this entity; it polls the host and runs commands.
use std::{sync::Arc, time::Duration};

use gpui_kit::{Context, SharedString};
use time::{OffsetDateTime, UtcOffset};

use crate::host::HostClient;
use crate::model::{self, Overview};

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
    pub overview: Option<Overview>,
    pub error: Option<SharedString>,
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
            error: None,
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
                self.overview = Some(model::overview(&snapshot, self.now(), self.offset));
                self.error = None;
            }
            Err(error) => self.error = Some(format!("{error:#}").into()),
        }
        cx.notify();
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
