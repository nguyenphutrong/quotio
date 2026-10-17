//! Quota history for one account, from the Wonder artboard "Quota history": pick a
//! limit and a range, then read how much was left over time and when it reset.
use std::sync::Arc;

use gpui_kit::component::WindowExt as _;
use gpui_kit::{
    App, Context, FontWeight, InteractiveElement, IntoElement, ParentElement, Render, SharedString,
    StatefulInteractiveElement as _, Styled, Window, div, prelude::FluentBuilder as _, px,
    relative,
};
use serde_json::Value;
use time::format_description::well_known::Rfc3339;
use time::{OffsetDateTime, UtcOffset};

use super::widgets::{segmented, select};
use crate::host::{HostClient, Method};
use crate::model::{AccountView, ago_phrase, compact_reset, tone};
use crate::prefs::{self, QuotaDisplay};
use crate::theme::{Palette, palette};
use crate::ui::{ButtonKind, button, dialog_footer, note, provider_logo, shown_name, tone_color};

#[derive(Clone, Copy, PartialEq)]
enum Range {
    Day,
    Week,
    Month,
}

impl Range {
    fn path(self) -> &'static str {
        match self {
            Range::Day => "24h",
            Range::Week => "7d",
            Range::Month => "30d",
        }
    }
}

enum Load<T> {
    Loading,
    Failed(String),
    Ready(T),
}

pub struct QuotaHistory {
    host: Arc<dyn HostClient>,
    offset: UtcOffset,
    account_id: String,
    provider_id: String,
    title: String,
    /// `GET /v2/accounts/{id}/quota-history`.
    catalog: Load<Value>,
    /// Limits with a percentage, as (id, label).
    metrics: Vec<(String, String)>,
    metric: Option<String>,
    range: Range,
    chart: Load<Value>,
    /// Bin under the pointer, by index in the chart's `bins`.
    hovered: Option<usize>,
}

impl QuotaHistory {
    pub fn new(
        host: Arc<dyn HostClient>,
        offset: UtcOffset,
        account: &AccountView,
        cx: &mut Context<Self>,
    ) -> Self {
        let title = format!(
            "{} · {}",
            crate::providers::display_name(&account.provider_id),
            shown_name(&account.name, cx)
        );
        let this = Self {
            host,
            offset,
            account_id: account.id.clone(),
            provider_id: account.provider_id.clone(),
            title,
            catalog: Load::Loading,
            metrics: Vec::new(),
            metric: None,
            range: Range::Day,
            chart: Load::Loading,
            hovered: None,
        };
        this.load_catalog(cx);
        this
    }

    fn base(&self) -> String {
        format!("/v2/accounts/{}/quota-history", self.account_id)
    }

    fn load_catalog(&self, cx: &mut Context<Self>) {
        let request = self.host.call(Method::GET, self.base(), None);
        cx.spawn(async move |this, cx| {
            let result = request.await;
            let _ = this.update(cx, |this, cx| {
                match result {
                    Ok(catalog) => {
                        this.metrics = catalog["metrics"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter(|m| m["has_percentage"] == true)
                            .filter_map(|m| Some((m["id"].as_str()?.to_owned(), metric_label(m))))
                            .collect();
                        // Start with the first limit the provider still reports.
                        this.metric = catalog["metrics"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter(|m| m["has_percentage"] == true)
                            .find(|m| m["current"] == true)
                            .and_then(|m| m["id"].as_str())
                            .map(str::to_owned)
                            .or_else(|| this.metrics.first().map(|(id, _)| id.clone()));
                        this.catalog = Load::Ready(catalog);
                        this.load_chart(cx);
                    }
                    Err(error) => this.catalog = Load::Failed(format!("{error:#}")),
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn load_chart(&mut self, cx: &mut Context<Self>) {
        let Some(metric) = &self.metric else {
            return;
        };
        self.chart = Load::Loading;
        self.hovered = None;
        let (metric, range) = (metric.clone(), self.range);
        let path = format!("{}/{metric}/{}", self.base(), range.path());
        let request = self.host.call(Method::GET, path, None);
        cx.spawn(async move |this, cx| {
            let result = request.await;
            let _ = this.update(cx, |this, cx| {
                // Ignore answers for a limit or range the user has moved away from.
                if this.metric.as_deref() != Some(metric.as_str()) || this.range != range {
                    return;
                }
                this.chart = match result {
                    Ok(chart) => Load::Ready(chart),
                    Err(error) => Load::Failed(format!("{error:#}")),
                };
                cx.notify();
            });
        })
        .detach();
        cx.notify();
    }

    fn local(&self, at: OffsetDateTime) -> OffsetDateTime {
        at.to_offset(self.offset)
    }

    fn body(&self, used: bool, p: &Palette, cx: &mut Context<Self>) -> gpui_kit::AnyElement {
        let catalog = match &self.catalog {
            Load::Loading => return centered("Loading history…", p),
            Load::Failed(error) => return centered(format!("Couldn’t load history: {error}."), p),
            Load::Ready(catalog) => catalog,
        };
        if let Some(error) = catalog["recording_error"].as_str() {
            return centered(format!("Quota history can’t be recorded: {error}."), p);
        }
        if self.metrics.is_empty() {
            return centered(
                if catalog["recording_enabled"] == true {
                    "No history yet. Quotio records quota each time it refreshes."
                } else {
                    "Quota history is off. Turn it on in Tray settings."
                },
                p,
            );
        }

        let controls = div()
            .flex()
            .items_center()
            .justify_between()
            .child(select(
                "history-metric",
                self.metrics.clone(),
                self.metric.as_ref().unwrap_or(&String::new()),
                true,
                cx.listener(|this, metric: &String, _, cx| {
                    this.metric = Some(metric.clone());
                    this.load_chart(cx);
                }),
            ))
            .child(segmented(
                "history-range",
                &[
                    (Range::Day, "24 hours"),
                    (Range::Week, "7 days"),
                    (Range::Month, "30 days"),
                ],
                &self.range,
                p,
                cx.listener(|this, range: &Range, _, cx| {
                    this.range = *range;
                    this.load_chart(cx);
                }),
            ));

        let content = match &self.chart {
            Load::Loading => centered("Loading history…", p),
            Load::Failed(error) => centered(format!("Couldn’t load history: {error}."), p),
            Load::Ready(chart) => div()
                .flex()
                .flex_col()
                .gap(px(16.))
                .child(self.summary(chart, used, p))
                .child(self.plot(chart, used, p, cx))
                .child(self.events(chart, p))
                .into_any_element(),
        };
        div()
            .flex()
            .flex_col()
            .gap(px(16.))
            .child(controls)
            .child(content)
            .into_any_element()
    }

    /// Headline, last update, expected reset and the lowest value in the range.
    fn summary(&self, chart: &Value, used: bool, p: &Palette) -> impl IntoElement {
        let latest = &chart["latest"];
        let remaining = latest["quota"]["remaining_percent"].as_f64();
        let headline = remaining.map_or_else(
            || "—".to_owned(),
            |r| format!("{:.0}%", if used { 100. - r } else { r }),
        );
        let now = OffsetDateTime::now_utc();
        let updated = date(&latest["fetched_at"]).map_or_else(
            || "Not observed yet".to_owned(),
            |at| format!("Updated {}", ago_phrase(now - at)),
        );
        let reset = date(&latest["resets_at"])
            .map(|at| compact_reset(at, now, self.offset))
            .or_else(|| latest["reset_description"].as_str().map(str::to_owned))
            .unwrap_or_else(|| "Unknown".to_owned());
        let lowest = chart["lowest_remaining_percent"].as_f64();
        let (extreme_label, extreme) = if used {
            ("Highest used", lowest.map(|l| 100. - l))
        } else {
            ("Lowest observed", lowest)
        };
        let stat = |label: &str, value: String| {
            div()
                .flex()
                .flex_col()
                .gap(px(2.))
                .min_w(px(120.))
                .child(
                    div()
                        .text_size(px(12.))
                        .text_color(p.text_sub)
                        .child(label.to_owned()),
                )
                .child(
                    div()
                        .text_size(px(16.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(p.text_strong)
                        .child(value),
                )
        };
        div()
            .flex()
            .items_end()
            .gap(px(32.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(p.text_sub)
                            .child(if used {
                                "Quota used"
                            } else {
                                "Quota remaining"
                            }),
                    )
                    .child(
                        div()
                            .text_size(px(40.))
                            .line_height(px(44.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(remaining.map_or(p.text_strong, |r| tone_color(tone(r), p)))
                            .child(headline),
                    )
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(p.text_soft)
                            .child(updated),
                    ),
            )
            .child(stat("Expected reset", reset))
            .child(stat(
                extreme_label,
                extreme.map_or_else(|| "—".to_owned(), |v| format!("{v:.0}%")),
            ))
    }

    /// One bar per observed bin, placed by time; stretches nobody observed stay empty.
    fn plot(
        &self,
        chart: &Value,
        used: bool,
        p: &Palette,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let (Some(start), Some(end)) = (date(&chart["start_at"]), date(&chart["end_at"])) else {
            return div().into_any_element();
        };
        let span = (end - start).as_seconds_f64().max(1.);
        let bin = chart["bin_seconds"].as_f64().unwrap_or(span / 360.).max(1.);
        let slots = ((span / bin).round() as usize).clamp(1, 1000);
        let bins: Vec<&Value> = chart["bins"].as_array().into_iter().flatten().collect();
        let mut by_slot: Vec<Option<usize>> = vec![None; slots];
        for (i, b) in bins.iter().enumerate() {
            if let Some(at) = date(&b["start_at"]) {
                let slot = ((at - start).as_seconds_f64() / bin).round() as usize;
                if let Some(cell) = by_slot.get_mut(slot.min(slots - 1)) {
                    *cell = Some(i);
                }
            }
        }
        let reset_slots: Vec<usize> = chart["events"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|e| e["kind"] == "reset_inferred")
            .filter_map(|e| date(&e["to_at"]))
            .map(|at| (((at - start).as_seconds_f64() / bin) as usize).min(slots - 1))
            .collect();

        let bars = div()
            .id("history-bars")
            .flex_1()
            .h(px(180.))
            .flex()
            .items_end()
            .border_b_1()
            .border_color(p.stroke_soft)
            .on_hover(cx.listener(|this, hovering: &bool, _, cx| {
                if !hovering {
                    this.hovered = None;
                    cx.notify();
                }
            }))
            .children(by_slot.iter().enumerate().map(|(slot, index)| {
                let column = div()
                    .id(("history-slot", slot))
                    .flex_1()
                    .h_full()
                    .flex()
                    .flex_col()
                    .justify_end()
                    .when(reset_slots.contains(&slot), |s| {
                        s.bg(p.text_soft.opacity(0.3))
                    });
                let Some(index) = *index else {
                    return column;
                };
                let remaining = bins[index]["latest"]["quota"]["remaining_percent"].as_f64();
                let Some(remaining) = remaining else {
                    return column;
                };
                let shown = if used { 100. - remaining } else { remaining };
                let hovered = self.hovered == Some(index);
                column
                    .on_hover(cx.listener(move |this, hovering: &bool, _, cx| {
                        if *hovering && this.hovered != Some(index) {
                            this.hovered = Some(index);
                            cx.notify();
                        }
                    }))
                    .child(
                        div()
                            .h(relative((shown / 100.).clamp(0.01, 1.) as f32))
                            .bg(tone_color(tone(remaining), p))
                            .when(!hovered && self.hovered.is_some(), |s| s.opacity(0.5)),
                    )
            }));
        let y_axis = div()
            .h(px(180.))
            .w(px(36.))
            .flex()
            .flex_col()
            .justify_between()
            .text_size(px(11.))
            .text_color(p.text_soft)
            .child("100%")
            .child("50%")
            .child("0%");
        let tick = |at: OffsetDateTime| {
            let local = self.local(at);
            if self.range == Range::Day {
                format!("{:02}:{:02}", local.hour(), local.minute())
            } else {
                format!("{} {}", &local.month().to_string()[..3], local.day())
            }
        };
        let x_axis = div()
            .ml(px(36.))
            .flex()
            .justify_between()
            .text_size(px(11.))
            .text_color(p.text_soft)
            .child(tick(start))
            .child(tick(start + (end - start) / 2))
            .child("Now");
        let detail = match self.hovered.and_then(|i| bins.get(i)) {
            Some(b) => {
                let when = date(&b["last_observed_at"])
                    .map(|at| self.when(at))
                    .unwrap_or_default();
                let remaining = b["latest"]["quota"]["remaining_percent"].as_f64();
                let value = remaining.map_or_else(String::new, |r| {
                    if used {
                        format!("{:.0}% used", 100. - r)
                    } else {
                        format!("{r:.0}% left")
                    }
                });
                let samples = b["sample_count"].as_u64().unwrap_or(0);
                let checks = if samples == 1 { "check" } else { "checks" };
                format!("{when} · {value} · {samples} {checks}")
            }
            None => "Point at a bar to see when it was observed.".to_owned(),
        };
        div()
            .flex()
            .flex_col()
            .gap(px(8.))
            .p(px(16.))
            .rounded(px(12.))
            .border_1()
            .border_color(p.stroke_soft)
            .child(div().flex().gap(px(4.)).child(y_axis).child(bars))
            .child(x_axis)
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap(px(16.))
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(p.text_sub)
                            .child(detail),
                    )
                    .child(legend(p)),
            )
            .into_any_element()
    }

    fn events(&self, chart: &Value, p: &Palette) -> impl IntoElement {
        let events: Vec<&Value> = chart["events"].as_array().into_iter().flatten().collect();
        let row = |event: &Value| {
            let kind = match event["kind"].as_str().unwrap_or_default() {
                "reset_inferred" => "Quota reset",
                "quota_increased" => "Quota went up",
                "basis_changed" => "Plan or limit changed",
                "clock_changed" => "Clock changed",
                other => other,
            }
            .to_owned();
            let percent = |key: &str| {
                event[key]
                    .as_f64()
                    .map_or_else(|| "—".to_owned(), |v| format!("{v:.0}%"))
            };
            let when = date(&event["to_at"])
                .map(|at| self.when(at))
                .unwrap_or_default();
            div()
                .flex()
                .items_center()
                .gap(px(12.))
                .py(px(6.))
                .text_size(px(12.))
                .child(
                    div()
                        .flex_1()
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_strong)
                        .child(kind),
                )
                .child(div().text_color(p.text_sub).child(format!(
                    "{} → {} left",
                    percent("before_remaining_percent"),
                    percent("after_remaining_percent")
                )))
                .child(div().w(px(110.)).text_color(p.text_soft).child(when))
        };
        // Newest first; the sheet shows the latest few.
        const SHOWN: usize = 4;
        let more = events.len().saturating_sub(SHOWN);
        div()
            .flex()
            .flex_col()
            .child(
                div()
                    .text_size(px(14.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_strong)
                    .child("Events in this range"),
            )
            .when(events.is_empty(), |s| {
                s.child(note("No resets or other changes in this range.", p.text_sub).pt(px(6.)))
            })
            .children(events.iter().rev().take(SHOWN).map(|e| row(e)))
            .when(more > 0, |s| {
                s.child(note(format!("And {more} earlier."), p.text_soft))
            })
    }

    /// `Oct 17 04:52` in local time.
    fn when(&self, at: OffsetDateTime) -> String {
        let local = self.local(at);
        format!(
            "{} {} {:02}:{:02}",
            &local.month().to_string()[..3],
            local.day(),
            local.hour(),
            local.minute()
        )
    }
}

impl Render for QuotaHistory {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let used = prefs::get(cx).quota_display == QuotaDisplay::Used;
        let header = div()
            .flex()
            .items_center()
            .gap(px(12.))
            .child(provider_logo(&self.provider_id, 32., None, &p))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .min_w_0()
                    .child(
                        div()
                            .text_size(px(16.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(p.text_strong)
                            .child("Quota history"),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(px(12.))
                            .text_color(p.text_sub)
                            .child(self.title.clone()),
                    ),
            );
        div()
            .flex()
            .flex_col()
            .gap(px(20.))
            .child(header)
            .child(self.body(used, &p, cx))
            .child(
                dialog_footer().child(
                    button("done", "Done", ButtonKind::Primary, &p)
                        .on_click(|_, window, cx: &mut App| window.close_dialog(cx)),
                ),
            )
    }
}

/// `Standard · 5 hours` when the provider groups its limits.
fn metric_label(metric: &Value) -> String {
    let name = metric["display_name"].as_str().unwrap_or_default();
    match metric["group"]
        .as_str()
        .filter(|g| !g.is_empty() && *g != name)
    {
        Some(group) => format!("{group} · {name}"),
        None => name.to_owned(),
    }
}

fn date(value: &Value) -> Option<OffsetDateTime> {
    OffsetDateTime::parse(value.as_str()?, &Rfc3339).ok()
}

fn centered(text: impl Into<SharedString>, p: &Palette) -> gpui_kit::AnyElement {
    div()
        .h(px(200.))
        .flex()
        .items_center()
        .justify_center()
        .child(note(text, p.text_sub))
        .into_any_element()
}

fn legend(p: &Palette) -> impl IntoElement {
    let item = |swatch: gpui_kit::Div, label: &'static str| {
        div()
            .flex()
            .items_center()
            .gap(px(6.))
            .child(swatch.size(px(8.)).rounded(px(2.)))
            .child(label)
    };
    div()
        .flex_none()
        .flex()
        .gap(px(12.))
        .text_size(px(11.))
        .text_color(p.text_sub)
        .child(item(div().bg(p.primary), "Observed"))
        .child(item(
            div().border_1().border_color(p.stroke_soft),
            "Not observed",
        ))
        .child(item(div().bg(p.text_soft.opacity(0.3)), "Reset"))
}
