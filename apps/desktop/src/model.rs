//! Projects a host `/v2` snapshot into render-ready rows. Pure functions only, so the
//! wording and thresholds are testable without a window.
use quotio::contract::{Account, Action, ConnectionState, Freshness, Metric, Snapshot, Usage};
use quotio::domain::Quota;
use time::{Duration, OffsetDateTime, UtcOffset};

use crate::providers;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tone {
    Good,
    Warning,
    Critical,
    Neutral,
}

/// Same thresholds as the macOS app: more than 50% left is fine, more than 20% is a warning.
pub fn tone(remaining_percent: f64) -> Tone {
    if remaining_percent > 50. {
        Tone::Good
    } else if remaining_percent > 20. {
        Tone::Warning
    } else {
        Tone::Critical
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct MetricView {
    pub label: String,
    pub value: String,
    /// Remaining share in `0.0..=1.0`, when the quota is a percentage.
    pub remaining: Option<f32>,
    /// Bar length in `0.0..=1.0`: the remaining share, or the used share when the
    /// user shows percentages as used.
    pub fill: Option<f32>,
    pub tone: Tone,
    /// Compact reset, such as `1h 42m`, `Mon 09:00`, or `at 07:00` for a daily window.
    pub reset: Option<String>,
}

impl MetricView {
    /// Sentence form for wide layouts: `Resets in 1h 42m`, `Resets Mon 09:00` or `Resets at 07:00`.
    pub fn reset_sentence(&self) -> Option<String> {
        let reset = self.reset.as_deref()?;
        Some(if reset.starts_with(|c: char| c.is_ascii_digit()) {
            format!("Resets in {reset}")
        } else {
            format!("Resets {reset}")
        })
    }
}

/// What the issue's button does.
#[derive(Clone, Debug, PartialEq)]
pub enum Fix {
    /// Sign in to the provider again.
    SignIn,
    /// Let Quotio read a login it found; carries the source to authorize.
    Authorize(String),
    /// Let Quotio open its own store of saved sign-ins.
    UnlockVault,
    /// Refresh the account.
    Retry,
    /// Enter a new API key for the account.
    ReplaceKey,
}

#[derive(Clone, Debug, PartialEq)]
pub struct IssueView {
    pub title: String,
    pub detail: String,
    pub action: String,
    pub fix: Fix,
}

/// Changes the host allows for an account, from its `actions`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Allowed {
    pub rename: bool,
    pub set_enabled: bool,
    pub remove: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AccountView {
    pub id: String,
    pub provider_id: String,
    pub name: String,
    /// Name the user chose, when it replaces the provider's.
    pub user_label: Option<String>,
    pub plan: Option<String>,
    pub pinned: bool,
    /// False when the account is paused.
    pub enabled: bool,
    pub allowed: Allowed,
    /// The only API-key source, whose key can be replaced.
    pub key_source: Option<String>,
    pub updated: Option<String>,
    pub metrics: Vec<MetricView>,
    pub issue: Option<IssueView>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ProviderGroup {
    pub provider_id: String,
    pub name: String,
    pub accounts: Vec<AccountView>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Overview {
    pub groups: Vec<ProviderGroup>,
    pub account_count: usize,
    pub updated: Option<String>,
}

impl Overview {
    pub fn attention(&self) -> impl Iterator<Item = (&ProviderGroup, &AccountView, &IssueView)> {
        self.groups.iter().flat_map(|group| {
            group
                .accounts
                .iter()
                .filter_map(move |account| Some((group, account, account.issue.as_ref()?)))
        })
    }

    /// Lowest remaining percentage across healthy accounts, for the tray gauge.
    pub fn lowest_remaining(&self) -> Option<f32> {
        self.groups
            .iter()
            .flat_map(|group| &group.accounts)
            .filter(|account| account.issue.is_none())
            .flat_map(|account| &account.metrics)
            .filter_map(|metric| metric.remaining)
            .reduce(f32::min)
    }

    /// Accounts shown next to the menu bar icon: the pinned ones that still exist, or
    /// the first `max_items` accounts until the user pins or unpins one.
    pub fn menu_bar_accounts(
        &self,
        menu_bar: &crate::prefs::MenuBar,
    ) -> Vec<(&ProviderGroup, &AccountView)> {
        let all = self
            .groups
            .iter()
            .flat_map(|group| group.accounts.iter().map(move |account| (group, account)));
        let max = menu_bar.max_items.clamp(1, 10) as usize;
        if menu_bar.user_modified {
            menu_bar
                .accounts
                .iter()
                .filter_map(|id| all.clone().find(|(_, account)| &account.id == id))
                .take(max)
                .collect()
        } else {
            all.take(max).collect()
        }
    }

    /// Status line under the app name: `4 accounts · updated 2 min ago`.
    pub fn status_line(&self) -> String {
        let count = match self.account_count {
            1 => "1 account".to_owned(),
            n => format!("{n} accounts"),
        };
        match &self.updated {
            Some(updated) => format!("{count} · updated {updated}"),
            None => count,
        }
    }
}

/// `with_paused` keeps paused accounts, for the settings window; the tray and its
/// popup only show accounts that are being tracked. `used` shows percentages as
/// used instead of remaining.
pub fn overview(
    snapshot: &Snapshot,
    now: OffsetDateTime,
    offset: UtcOffset,
    with_paused: bool,
    used: bool,
) -> Overview {
    let mut groups: Vec<ProviderGroup> = Vec::new();
    let accounts: Vec<&Account> = snapshot
        .accounts
        .iter()
        .filter(|a| with_paused || a.enabled)
        .collect();
    for account in &accounts {
        let usage = snapshot.usage.iter().find(|u| u.account_id == account.id);
        let siblings = accounts
            .iter()
            .filter(|a| a.provider_id == account.provider_id)
            .count();
        let view = account_view(account, usage, siblings > 1, now, offset, used);
        match groups
            .iter_mut()
            .find(|g| g.provider_id == account.provider_id)
        {
            Some(group) => group.accounts.push(view),
            None => groups.push(ProviderGroup {
                provider_id: account.provider_id.clone(),
                name: providers::display_name(&account.provider_id),
                accounts: vec![view],
            }),
        }
    }
    Overview {
        account_count: accounts.len(),
        updated: Some(ago_phrase(now - snapshot.generated_at)),
        groups,
    }
}

fn account_view(
    account: &Account,
    usage: Option<&Usage>,
    has_siblings: bool,
    now: OffsetDateTime,
    offset: UtcOffset,
    used: bool,
) -> AccountView {
    let issue = issue(account, usage, now);
    let metrics = match (&issue, usage) {
        _ if !account.enabled => Vec::new(),
        // A stale quota next to "sign in again" reads as current; hide it.
        (None, Some(usage)) => usage
            .metrics
            .iter()
            .map(|m| metric_view(m, now, offset, used))
            .collect(),
        _ => Vec::new(),
    };
    let allowed =
        |actions: &[Action], kind: &str| actions.iter().any(|a| a.kind == kind && a.available);
    let key_sources: Vec<&str> = account
        .sources
        .iter()
        .filter(|s| allowed(&s.actions, "replace_api_key"))
        .map(|s| s.id.as_str())
        .collect();
    let key_source = match key_sources[..] {
        [only] => Some(only.to_owned()),
        _ => None,
    };
    // Signing in again would add a second account; a rejected key is replaced.
    let issue = issue.map(|issue| match issue.fix {
        Fix::SignIn if key_source.is_some() => IssueView {
            title: "API key rejected".into(),
            action: "Replace key".into(),
            fix: Fix::ReplaceKey,
            ..issue
        },
        _ => issue,
    });
    AccountView {
        id: account.id.clone(),
        provider_id: account.provider_id.clone(),
        name: account.display_name.clone(),
        user_label: account.user_label.clone(),
        plan: usage.and_then(|u| u.plan.clone()),
        pinned: has_siblings && account.active,
        enabled: account.enabled,
        allowed: Allowed {
            rename: allowed(&account.actions, "rename"),
            set_enabled: allowed(&account.actions, "set_enabled"),
            remove: allowed(&account.actions, "remove"),
        },
        key_source,
        updated: usage
            .and_then(|u| u.fetched_at)
            .map(|at| compact_ago(now - at)),
        metrics,
        issue,
    }
}

fn issue(account: &Account, usage: Option<&Usage>, now: OffsetDateTime) -> Option<IssueView> {
    let refresh_failed = |at: Option<OffsetDateTime>| IssueView {
        title: "Couldn’t refresh".into(),
        detail: match at {
            Some(at) => format!(
                "The last refresh failed {}. Retrying won’t sign you out.",
                ago_phrase(now - at)
            ),
            None => "The last refresh failed. Retrying won’t sign you out.".into(),
        },
        action: "Retry".into(),
        fix: Fix::Retry,
    };
    // The source that needs attention says how to fix it.
    let source_fix = |kind: &str| {
        account.sources.iter().find_map(|source| {
            let action = source.issue.as_ref()?.action.as_ref()?;
            (action.kind == kind && action.available).then(|| source.id.clone())
        })
    };
    let vault_locked = account.sources.iter().any(|s| {
        s.issue
            .as_ref()
            .is_some_and(|i| i.code == "credential_storage")
    });
    // Quotio's own logins are renewed here; borrowed ones in the provider's app.
    let renew_here = source_fix("sign_in").is_some()
        || account
            .sources
            .iter()
            .any(|s| s.origin == quotio::domain::AccountOrigin::Owned);
    match account.state {
        ConnectionState::NeedsLogin if renew_here => Some(IssueView {
            title: "Sign-in expired".into(),
            detail: "Quota is no longer updating.".into(),
            action: "Sign in again".into(),
            fix: Fix::SignIn,
        }),
        ConnectionState::NeedsLogin => Some(IssueView {
            title: "Sign-in expired".into(),
            detail: format!(
                "Sign in again in {}, then retry.",
                providers::display_name(&account.provider_id)
            ),
            action: "Retry".into(),
            fix: Fix::Retry,
        }),
        // `credential_storage` is Quotio's own store; `local_credential_storage`
        // is the provider app's login, which needs the source authorized.
        ConnectionState::NeedsAuthorization if vault_locked => Some(IssueView {
            title: "Allow access to saved sign-ins".into(),
            detail: "Quotio can’t open the sign-in it saved for this account.".into(),
            action: "Grant access".into(),
            fix: Fix::UnlockVault,
        }),
        ConnectionState::NeedsAuthorization => Some(match source_fix("authorize") {
            Some(source) => IssueView {
                title: format!(
                    "Allow access to the {} login",
                    providers::display_name(&account.provider_id)
                ),
                detail: "Quotio found this login but can’t read it yet.".into(),
                action: "Grant access".into(),
                fix: Fix::Authorize(source),
            },
            None => IssueView {
                title: format!(
                    "Allow access to the {} login",
                    providers::display_name(&account.provider_id)
                ),
                detail: "Quotio found this login but can’t read it yet.".into(),
                action: "Retry".into(),
                fix: Fix::Retry,
            },
        }),
        ConnectionState::Disabled => None,
        ConnectionState::Unavailable => Some(refresh_failed(usage.and_then(|u| u.fetched_at))),
        _ => match usage {
            // A failed refresh keeps the last quota as `Stale`; don't present it as current.
            Some(u)
                if matches!(u.freshness, Freshness::Unavailable | Freshness::Stale)
                    && u.issue.is_some() =>
            {
                Some(refresh_failed(u.fetched_at))
            }
            _ => None,
        },
    }
}

fn metric_view(metric: &Metric, now: OffsetDateTime, offset: UtcOffset, used: bool) -> MetricView {
    let (value, remaining, tone) = match &metric.quota {
        Quota::Available {
            remaining_percent, ..
        }
        | Quota::Exhausted {
            remaining_percent, ..
        } => {
            let remaining = remaining_percent.clamp(0., 100.);
            let shown = if used { 100. - remaining } else { remaining };
            (
                format!("{shown:.0}%"),
                Some((remaining / 100.) as f32),
                // Color follows what is left either way, as on macOS.
                tone(remaining),
            )
        }
        Quota::Unlimited => ("Unlimited".into(), None, Tone::Neutral),
        Quota::Limit { amount, unit } => (format!("{amount} {unit}"), None, Tone::Neutral),
        Quota::Unknown => ("—".into(), None, Tone::Neutral),
        Quota::Disabled => ("Off".into(), None, Tone::Neutral),
    };
    let reset = metric
        .resets_at
        .map(|at| match metric.window_seconds {
            // A daily window resets at the same time every day.
            Some(86_400) if at > now => {
                let local = at.to_offset(offset);
                format!("at {:02}:{:02}", local.hour(), local.minute())
            }
            _ => compact_reset(at, now, offset),
        })
        .or_else(|| metric.reset_description.clone());
    MetricView {
        label: metric.display_name.clone(),
        value,
        remaining,
        fill: remaining.map(|r| if used { 1. - r } else { r }),
        tone,
        reset,
    }
}

/// Within a day: a countdown (`1h 42m`, `42m`). Later: weekday and local time.
pub fn compact_reset(at: OffsetDateTime, now: OffsetDateTime, offset: UtcOffset) -> String {
    let left = at - now;
    if left <= Duration::ZERO {
        return "now".into();
    }
    if left < Duration::DAY {
        let minutes = left.whole_minutes().max(1);
        return match (minutes / 60, minutes % 60) {
            (0, m) => format!("{m}m"),
            (h, m) => format!("{h}h {m:02}m"),
        };
    }
    let local = at.to_offset(offset);
    format!(
        "{} {:02}:{:02}",
        &local.weekday().to_string()[..3],
        local.hour(),
        local.minute()
    )
}

/// `********@*****.com` for an email, stars otherwise, as the macOS app masks
/// names when sensitive information is hidden.
pub fn mask(name: &str) -> String {
    let stars = |n: usize| "*".repeat(n);
    if let Some((local, domain)) = name.split_once('@') {
        let local = stars(local.chars().count().min(8));
        return match domain.split_once('.') {
            Some((host, rest)) => format!("{local}@{}.{rest}", stars(host.chars().count().min(5))),
            None => format!("{local}@{}", stars(5)),
        };
    }
    stars(name.chars().count().clamp(4, 12))
}

/// Card corner label: `now`, `2m`, `3h`, `2d`.
pub fn compact_ago(elapsed: Duration) -> String {
    let minutes = elapsed.whole_minutes();
    if minutes < 1 {
        "now".into()
    } else if minutes < 60 {
        format!("{minutes}m")
    } else if minutes < 60 * 24 {
        format!("{}h", minutes / 60)
    } else {
        format!("{}d", minutes / (60 * 24))
    }
}

/// Prose form for status lines: `just now`, `2 min ago`, `3 h ago`.
pub fn ago_phrase(elapsed: Duration) -> String {
    let minutes = elapsed.whole_minutes();
    if minutes < 1 {
        "just now".into()
    } else if minutes < 60 {
        format!("{minutes} min ago")
    } else if minutes < 60 * 24 {
        format!("{} h ago", minutes / 60)
    } else {
        format!("{} d ago", minutes / (60 * 24))
    }
}
