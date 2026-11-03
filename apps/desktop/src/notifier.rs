//! Desktop notifications for low and exhausted quota, as on macOS: each one fires
//! once when an account crosses the line and again only after it recovers.
use std::collections::HashSet;

use gpui_kit::{App, Global, SystemNotification};

use crate::model::{AccountView, MetricView, Overview, mask};
use crate::prefs;

/// Tags of notifications already shown, so a lasting state is not repeated.
#[derive(Default)]
struct Sent(HashSet<String>);

impl Global for Sent {}

/// Compare the latest quota with the user's alert settings.
pub fn check(overview: &Overview, cx: &mut App) {
    let settings = prefs::get(cx).notifications.clone();
    let hide = prefs::get(cx).hide_names;
    if !settings.enabled {
        return;
    }
    let mut pending = Vec::new();
    let sent = &mut cx.default_global::<Sent>().0;
    for group in &overview.groups {
        // Healthy accounts only: a failed refresh leaves the last quota stale.
        for account in group.accounts.iter().filter(|a| a.issue.is_none()) {
            let Some((metric, left)) = lowest(account) else {
                continue;
            };
            let exhausted = left <= 0.;
            let cooling = format!("cooling:{}", account.id);
            let low = format!("low:{}", account.id);
            if exhausted && settings.cooling_down {
                if sent.insert(cooling.clone()) {
                    pending.push(SystemNotification {
                        tag: cooling.into(),
                        title: format!("{} {} limit reached", group.name, label(metric)).into(),
                        body: body(account, metric, hide).into(),
                        actions: Vec::new(),
                    });
                }
            } else if !exhausted {
                sent.remove(&cooling);
            }
            if left <= f32::from(settings.threshold) {
                // The limit-reached alert already says more than "running low".
                let covered = exhausted && settings.cooling_down;
                if settings.quota_low && !covered && sent.insert(low.clone()) {
                    pending.push(SystemNotification {
                        tag: low.into(),
                        title: format!("{} {} quota at {left:.0}%", group.name, label(metric))
                            .into(),
                        body: body(account, metric, hide).into(),
                        actions: Vec::new(),
                    });
                }
            } else {
                sent.remove(&low);
            }
        }
    }
    for notification in pending {
        cx.show_system_notification(notification);
    }
}

/// The metric with the least left, and that share in percent.
fn lowest(account: &AccountView) -> Option<(&MetricView, f32)> {
    account
        .metrics
        .iter()
        .filter_map(|m| m.remaining.map(|r| (m, r * 100.)))
        .min_by(|a, b| a.1.total_cmp(&b.1))
}

fn label(metric: &MetricView) -> String {
    metric.label.to_lowercase()
}

/// `phutrong.it@gmail.com · resets Thu 14:20`
fn body(account: &AccountView, metric: &MetricView, hide: bool) -> String {
    let name = if hide {
        mask(&account.name)
    } else {
        account.name.clone()
    };
    match metric.reset_sentence() {
        Some(reset) => format!("{name} · r{}", &reset[1..]),
        None => name,
    }
}
