use super::text::{self, Options, safe};
use crate::{
    contract::{Account, Freshness, Metric, Snapshot, Usage},
    domain::Confidence,
};
use tern_sdk::{
    Node,
    ui::{self, Thresholds, Token, Tone, View},
};

fn muted(key: &str, value: impl Into<String>) -> Node {
    ui::text(ui::span(value).style(Token::Muted))
        .key(key)
        .into()
}

fn metric(metric: &Metric, options: Options) -> Node {
    let mut label = vec![ui::span(safe(&metric.display_name))];
    let detail = text::detail(metric, options.now);
    if !detail.is_empty() {
        label.push(ui::span(format!(" · {detail}")).style(Token::Muted));
    }
    let mut rows: Vec<Node> = vec![ui::text(label).key("name").into()];
    if let Some(used) = text::percent(&metric.quota) {
        rows.push(
            ui::meter()
                .value((used / 100.0).clamp(0.0, 1.0))
                .thresholds(Thresholds {
                    warn: Some(0.8),
                    bad: Some(1.0),
                })
                .size("md")
                .key("meter")
                .into(),
        );
    }
    if let Some(amount) = text::amount(metric) {
        rows.push(muted("amount", amount));
    }
    if let Some(note) = &metric.note {
        rows.push(muted("note", safe(note)));
    }
    if matches!(metric.provenance.confidence, Confidence::Estimated) {
        rows.push(muted("estimated", "estimated"));
    }
    if options.verbose {
        rows.push(muted("source", text::source(metric)));
    }
    ui::col()
        .children(rows)
        .key(format!("m-{}", metric.id))
        .into()
}

fn account(account: &Account, usage: Option<&Usage>, options: Options) -> Node {
    let mut rows = Vec::new();
    if let Some(usage) = usage {
        let mut badges = Vec::<Node>::new();
        if let Some(plan) = &usage.plan {
            badges.push(ui::badge(safe(plan)).tone(Tone::Muted).key("plan").into());
        }
        if let Some(label) = text::freshness(&usage.freshness) {
            let tone = match usage.freshness {
                Freshness::Stale => Tone::Warning,
                Freshness::Unavailable => Tone::Error,
                Freshness::Fresh | Freshness::NotLoaded => Tone::Muted,
            };
            badges.push(ui::badge(label).tone(tone).key("freshness").into());
        }
        if let Some(issue) = &usage.issue {
            badges.push(
                ui::badge(safe(&issue.code))
                    .tone(Tone::Warning)
                    .key("issue")
                    .into(),
            );
        }
        if let Some(at) = usage.fetched_at {
            badges.push(muted("fetched", text::fetched(at, options.now)));
        }
        if !badges.is_empty() {
            rows.push(
                ui::row()
                    .gap("sm")
                    .align("center")
                    .wrap(true)
                    .children(badges)
                    .key("badges")
                    .into(),
            );
        }
    }
    if options.verbose {
        rows.push(muted("account", text::account_detail(account)));
    }
    match usage {
        None => rows.push(muted("none", text::NO_USAGE)),
        Some(usage) => {
            if let Some(status) = &usage.subscription_status {
                rows.push(muted("subscription", text::subscription(status)));
            }
            if let Some(credits) = &usage.reset_credits {
                rows.push(
                    ui::text(ui::span(text::saved_resets(credits, options.now)).style(Token::Info))
                        .key("resets")
                        .into(),
                );
            }
            if usage.metrics.is_empty() {
                rows.push(muted("none", text::NO_QUOTA));
            }
            rows.extend(usage.metrics.iter().map(|m| metric(m, options)));
        }
    }
    ui::card()
        .head(safe(&account.display_name))
        .children(rows)
        .key(account.id.as_str())
        .into()
}

pub fn render_snapshot(snapshot: &Snapshot, options: Options) -> View {
    let mut nodes = vec![
        ui::text(
            ui::span(format!(
                "Usage · {}",
                text::timestamp(snapshot.generated_at)
            ))
            .style(Token::Strong),
        )
        .key("title")
        .into(),
    ];
    let groups = text::groups(snapshot);
    if groups.is_empty() {
        nodes.push(muted("empty", text::NO_ACCOUNTS));
    }
    for (provider, accounts) in groups {
        let head = text::provider_heading(provider, accounts.len());
        let cards = accounts.into_iter().map(|a| {
            let usage = snapshot.usage.iter().find(|u| u.account_id == a.id);
            account(a, usage, options)
        });
        nodes.push(
            ui::section()
                .head(head)
                .children(cards)
                .key(format!("p-{provider}"))
                .into(),
        );
    }
    View::new().main(ui::col().gap("md").children(nodes))
}
