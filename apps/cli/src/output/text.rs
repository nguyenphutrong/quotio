use crate::{
    contract::{Account, Freshness, Metric, Snapshot},
    domain::{Confidence, ProviderFailure, Quota, ResetCredits},
};
use clap::ValueEnum;
use std::{collections::BTreeMap, fmt::Write, io::IsTerminal};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

#[derive(Clone, Copy)]
pub struct Options {
    pub width: usize,
    pub color: bool,
    pub verbose: bool,
    pub now: OffsetDateTime,
}
impl Options {
    pub fn terminal(no_color: bool, verbose: bool) -> Self {
        let terminal = std::io::stdout().is_terminal();
        Self {
            width: terminal_size::terminal_size().map_or(100, |(width, _)| usize::from(width.0)),
            color: terminal
                && !no_color
                && std::env::var_os("NO_COLOR").is_none()
                && std::env::var("TERM").is_ok_and(|term| term != "dumb"),
            verbose,
            now: OffsetDateTime::now_utc(),
        }
    }
}

// Provider metadata must not inject terminal commands, lines or bidi overrides.
pub(super) fn safe(value: &str) -> String {
    value.chars().filter_map(|c| {
        if c.is_whitespace() { Some(' ') }
        else if c.is_control() || matches!(c, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}') { None }
        else { Some(c) }
    }).collect()
}
pub(super) fn timestamp(value: OffsetDateTime) -> String {
    value.format(&Rfc3339).unwrap_or_else(|_| "unknown".into())
}
pub(super) fn duration(seconds: i64) -> String {
    let seconds = seconds.max(0);
    if seconds < 60 {
        return format!("{seconds}s");
    }
    let minutes = seconds / 60;
    if minutes < 60 {
        return format!("{minutes}m");
    }
    let hours = minutes / 60;
    if hours < 24 {
        return format!("{hours}h {}m", minutes % 60);
    }
    format!("{}d {}h", hours / 24, hours % 24)
}
pub(super) fn reset(metric: &Metric, now: OffsetDateTime) -> Option<String> {
    if let Some(at) = metric.resets_at {
        let seconds = (at - now).whole_seconds();
        return Some(if seconds > 0 {
            format!("resets in {}", duration(seconds))
        } else {
            "reset due".into()
        });
    }
    metric
        .reset_description
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .map(|description| format!("reset {}", safe(description)))
}
pub(super) fn percent(quota: &Quota) -> Option<f64> {
    match quota {
        Quota::Available { used_percent, .. } | Quota::Exhausted { used_percent, .. } => {
            Some(*used_percent)
        }
        _ => None,
    }
}
pub(super) fn detail(metric: &Metric, now: OffsetDateTime) -> String {
    let mut detail = match &metric.quota {
        Quota::Available { used_percent, .. } | Quota::Exhausted { used_percent, .. } => {
            format!("{used_percent:.1}% used")
        }
        Quota::Disabled => "disabled".into(),
        Quota::Unlimited => "unlimited".into(),
        Quota::Limit { amount, unit } => format!("limit {amount:.2} {}", safe(unit)),
        Quota::Unknown if metric.amounts.is_some() || metric.consumption.is_some() => String::new(),
        Quota::Unknown => "usage unknown".into(),
    };
    if let Some(value) = reset(metric, now) {
        if !detail.is_empty() {
            detail.push_str(" · ");
        }
        detail.push_str(&value);
    }
    detail
}
pub(super) fn amount(metric: &Metric) -> Option<String> {
    if let Some(amounts) = &metric.amounts {
        let unit = safe(&amounts.unit);
        Some(if let Some(limit) = amounts.limit {
            let used = metric
                .consumption
                .as_ref()
                .map(|c| c.used)
                .or_else(|| (limit >= amounts.remaining).then_some(limit - amounts.remaining));
            match used {
                Some(used) => format!(
                    "{used:.2} / {limit:.2} {unit} used · {:.2} {unit} left",
                    amounts.remaining
                ),
                None => format!(
                    "{:.2} {unit} left · limit {limit:.2} {unit}",
                    amounts.remaining
                ),
            }
        } else {
            format!("{:.2} {unit} left", amounts.remaining)
        })
    } else {
        metric
            .consumption
            .as_ref()
            .map(|amount| format!("{:.2} {} used", amount.used, safe(&amount.unit)))
    }
}
pub(super) fn source(metric: &Metric) -> String {
    format!(
        "source {} · {:?} · fetched {}",
        safe(&metric.provenance.source),
        metric.provenance.confidence,
        timestamp(metric.fetched_at)
    )
}
pub(super) fn groups(snapshot: &Snapshot) -> BTreeMap<&str, Vec<&Account>> {
    let mut groups: BTreeMap<&str, Vec<&Account>> = BTreeMap::new();
    for account in &snapshot.accounts {
        groups
            .entry(&account.provider_id)
            .or_default()
            .push(account);
    }
    groups
}
pub(super) fn provider_heading(provider: &str, accounts: usize) -> String {
    let name = crate::cli::Provider::from_str(provider, false)
        .ok()
        .map(|p| crate::providers::capabilities::ProviderDescriptor::new(p, &[]).display_name)
        .unwrap_or(provider);
    format!(
        "{name} · {accounts} {}",
        if accounts == 1 { "account" } else { "accounts" }
    )
}
pub(super) fn freshness(freshness: &Freshness) -> Option<&'static str> {
    match freshness {
        Freshness::Fresh => None,
        Freshness::Stale => Some("stale"),
        Freshness::NotLoaded => Some("not loaded"),
        Freshness::Unavailable => Some("unavailable"),
    }
}
pub(super) fn fetched(at: OffsetDateTime, now: OffsetDateTime) -> String {
    format!("fetched {} ago", duration((now - at).whole_seconds()))
}
pub(super) fn account_detail(account: &Account) -> String {
    format!("account {} · {:?}", safe(&account.id), account.state)
}
pub(super) fn subscription(status: &str) -> String {
    format!("subscription {}", safe(status))
}
pub(super) fn saved_resets(credits: &ResetCredits, now: OffsetDateTime) -> String {
    let mut text = format!(
        "{} saved {}",
        credits.available_count,
        if credits.available_count == 1 {
            "reset"
        } else {
            "resets"
        }
    );
    if let Some(at) = credits.earliest_expires_at {
        let seconds = (at - now).whole_seconds();
        let _ = write!(
            text,
            " · {}",
            if seconds > 0 {
                format!("soonest expires in {}", duration(seconds))
            } else {
                "expiry due".into()
            }
        );
    }
    text
}
pub(super) const NO_ACCOUNTS: &str = "No accounts returned usage.";
pub(super) const NO_USAGE: &str = "No usage data.";
pub(super) const NO_QUOTA: &str = "No quota reported.";

struct Renderer {
    text: String,
    options: Options,
}
impl Renderer {
    fn line(&mut self, indent: usize, value: &str, style: &str) {
        let width = self.options.width.max(20).saturating_sub(indent).max(2);
        let value = safe(value);
        let mut rest = value.trim();
        while !rest.is_empty() {
            let mut cells = 0;
            let mut end = rest.len();
            let mut space = None;
            for (index, c) in rest.char_indices() {
                cells += c.width().unwrap_or(0);
                if cells > width {
                    end = space.filter(|&i| i > 0).unwrap_or(index);
                    break;
                }
                if c == ' ' {
                    space = Some(index);
                }
            }
            let (part, tail) = rest.split_at(end);
            let _ = write!(self.text, "{:indent$}", "");
            if self.options.color && !style.is_empty() {
                let _ = writeln!(self.text, "\x1b[{style}m{part}\x1b[0m");
            } else {
                let _ = writeln!(self.text, "{part}");
            }
            rest = tail.trim_start();
        }
    }
    fn metric(&mut self, metric: &Metric, label_width: usize) {
        let label = safe(&metric.display_name);
        let percent = percent(&metric.quota);
        let style = match percent {
            Some(p) if p >= 100.0 => "31",
            Some(p) if p >= 80.0 => "33",
            Some(_) => "32",
            None => "2",
        };
        let detail = detail(metric, self.options.now);
        let bar = percent.map(|p| {
            let filled = (p.clamp(0.0, 100.0) / 100.0 * 16.0).round() as usize;
            format!("[{}{}]", "#".repeat(filled), "-".repeat(16 - filled))
        });
        let padding = label_width.saturating_sub(label.width());
        let row = format!(
            "{label}{}  {}{detail}",
            " ".repeat(padding),
            bar.as_ref().map_or(String::new(), |b| format!("{b}  "))
        );
        if row.width() + 4 <= self.options.width.max(20) {
            self.line(4, &row, style);
        } else {
            self.line(4, &label, "1");
            if let Some(bar) = bar {
                self.line(6, &bar, style);
            }
            self.line(6, &detail, style);
        }
        if let Some(amount) = amount(metric) {
            self.line(6, &amount, "2");
        }
        if let Some(note) = &metric.note {
            self.line(6, note, "2");
        }
        if matches!(metric.provenance.confidence, Confidence::Estimated) {
            self.line(6, "estimated", "2");
        }
        if self.options.verbose {
            self.line(6, &source(metric), "2");
        }
    }
}

pub fn render_snapshot(snapshot: &Snapshot, options: Options) -> String {
    let mut renderer = Renderer {
        text: String::new(),
        options,
    };
    renderer.line(
        0,
        &format!("Usage · {}", timestamp(snapshot.generated_at)),
        "1",
    );
    let groups = groups(snapshot);
    if groups.is_empty() {
        renderer.line(0, NO_ACCOUNTS, "2");
    }
    for (provider, accounts) in groups {
        renderer.text.push('\n');
        renderer.line(0, &provider_heading(provider, accounts.len()), "1;36");
        let label_width = snapshot
            .usage
            .iter()
            .filter(|u| accounts.iter().any(|a| a.id == u.account_id))
            .flat_map(|u| &u.metrics)
            .map(|m| safe(&m.display_name).width())
            .max()
            .unwrap_or(0);
        for account in accounts {
            let usage = snapshot.usage.iter().find(|u| u.account_id == account.id);
            let mut header = safe(&account.display_name);
            if let Some(usage) = usage {
                if let Some(plan) = &usage.plan {
                    let _ = write!(header, " · plan {}", safe(plan));
                }
                if let Some(freshness) = freshness(&usage.freshness) {
                    let _ = write!(header, " · {freshness}");
                }
                if let Some(at) = usage.fetched_at {
                    let _ = write!(header, " · {}", fetched(at, options.now));
                }
            }
            renderer.line(2, &header, "1");
            if options.verbose {
                renderer.line(4, &account_detail(account), "2");
            }
            let Some(usage) = usage else {
                renderer.line(4, NO_USAGE, "2");
                continue;
            };
            if let Some(status) = &usage.subscription_status {
                renderer.line(4, &subscription(status), "2");
            }
            if let Some(credits) = &usage.reset_credits {
                renderer.line(4, &saved_resets(credits, options.now), "36");
            }
            if usage.metrics.is_empty() {
                renderer.line(4, NO_QUOTA, "2");
            }
            for metric in &usage.metrics {
                renderer.metric(metric, label_width);
            }
            if let Some(issue) = &usage.issue {
                renderer.line(4, &format!("Issue: {}", safe(&issue.code)), "33");
            }
        }
    }
    renderer.text
}

pub fn failure(failure: &ProviderFailure) -> String {
    let account = failure
        .account_ref
        .as_ref()
        .map(|a| format!(" [{}: {}]", safe(&a.id), safe(&a.label)))
        .unwrap_or_default();
    format!("{}{account}: {}", safe(&failure.provider.0), failure.code)
}
pub fn snapshot_failures(snapshot: &Snapshot) -> String {
    let mut text = String::new();
    for (provider, issue) in &snapshot.provider_issues {
        let _ = write!(text, "{}: {}", safe(provider), safe(&issue.code));
        // Only app-owned logins that `accounts authorize` supports produce this code.
        if issue.code == "local_credential_storage" {
            let _ = write!(
                text,
                " (run quotio accounts authorize --provider {provider})"
            );
        }
        text.push('\n');
    }
    for account in &snapshot.accounts {
        for source in &account.sources {
            if let Some(issue) = &source.issue {
                let _ = writeln!(
                    text,
                    "{} | {} [{}]: {}",
                    safe(&account.provider_id),
                    safe(&account.display_name),
                    safe(&source.id),
                    safe(&issue.code)
                );
            }
        }
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Consumption, Provenance, QuotaAmounts};
    fn metric() -> Metric {
        Metric {
            id: "quota".into(),
            group: None,
            display_name: "Weekly".into(),
            note: None,
            quota: Quota::Unknown,
            amounts: None,
            consumption: None,
            resets_at: None,
            reset_description: None,
            fetched_at: OffsetDateTime::UNIX_EPOCH,
            provenance: Provenance {
                source: "fixture".into(),
                confidence: Confidence::Exact,
            },
        }
    }
    fn renderer(width: usize) -> Renderer {
        Renderer {
            text: String::new(),
            options: Options {
                width,
                color: false,
                verbose: false,
                now: OffsetDateTime::UNIX_EPOCH,
            },
        }
    }
    #[test]
    fn balances_and_consumption_do_not_invent_quota() {
        let mut value = metric();
        value.amounts = Some(QuotaAmounts {
            remaining: 0.0,
            limit: None,
            unit: "USD".into(),
        });
        let mut output = renderer(100);
        output.metric(&value, 6);
        assert!(output.text.contains("0.00 USD left"));
        assert!(!output.text.contains("%"));
        assert!(!output.text.contains("["));
        value.amounts = None;
        value.consumption = Some(Consumption {
            used: 12.5,
            unit: "USD".into(),
        });
        let mut output = renderer(100);
        output.metric(&value, 6);
        assert!(output.text.contains("12.50 USD used"));
        assert!(!output.text.contains("left"));
    }
    #[test]
    fn timestamp_reset_precedes_description_and_past_reset_is_due() {
        let mut value = metric();
        value.reset_description = Some("daily".into());
        value.resets_at = Some(OffsetDateTime::UNIX_EPOCH + time::Duration::seconds(8100));
        assert_eq!(
            reset(&value, OffsetDateTime::UNIX_EPOCH).as_deref(),
            Some("resets in 2h 15m")
        );
        assert_eq!(
            reset(&value, value.resets_at.unwrap()).as_deref(),
            Some("reset due")
        );
        value.resets_at = None;
        assert_eq!(
            reset(&value, OffsetDateTime::UNIX_EPOCH).as_deref(),
            Some("reset daily")
        );
    }
    #[test]
    fn unicode_rows_wrap_and_metadata_cannot_inject_controls() {
        let mut value = metric();
        value.quota = Quota::from_used(Some(100.0));
        value.display_name = "長い名前と長い quota window".into();
        value.note = Some("note\n\x1b[2J\u{202e}hidden".into());
        let mut output = renderer(40);
        output.metric(&value, 40);
        assert!(output.text.lines().all(|line| line.width() <= 40));
        assert!(output.text.contains("100.0% used"));
        assert!(!output.text.contains('\x1b'));
        assert!(!output.text.contains('\u{202e}'));
    }
}
