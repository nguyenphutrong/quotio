//! Tray popup, built from the Wonder artboard "Menu Bar Quota Menu" (360 px wide).
use gpui_kit::assets::IconName;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FocusHandle, FontWeight, Hsla,
    InteractiveElement, IntoElement, KeyDownEvent, ParentElement, Render, SharedString,
    StatefulInteractiveElement, Styled, Subscription, Window, div, prelude::FluentBuilder as _, px,
    relative, size,
};

use std::collections::HashMap;

use gpui_kit::{HighlightStyle, PathBuilder, StyledText, canvas, point};
use time::format_description::well_known::Rfc3339;
use time::{Duration, OffsetDateTime, UtcOffset};

use super::{icon, progress, provider_logo, shown_name, tone_color, value_color};
use crate::host::Method;
use crate::model::{AccountView, MetricView, Overview, Pace, ProviderGroup, weekday_time};
use crate::prefs::Density;
use crate::store::QuotaStore;
use crate::theme::{FONT_FAMILY, Palette, palette};

pub const WIDTH: f32 = 360.;

pub struct QuotaMenu {
    store: Entity<QuotaStore>,
    filter: Option<String>,
    focus: FocusHandle,
    was_active: bool,
    /// Recorded (time, remaining %) per (account, limit), for Detailed burn charts.
    history: History,
    _subscriptions: Vec<Subscription>,
}

type History = HashMap<(String, String), Vec<(OffsetDateTime, f64)>>;

impl QuotaMenu {
    pub fn new(store: Entity<QuotaStore>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        // The system may have switched theme while no window was open to hear it.
        crate::theme::system_changed(window.appearance(), cx);
        let subscriptions = vec![
            cx.observe(&store, |this: &mut Self, _, cx| {
                this.load_history(cx);
                cx.notify()
            }),
            cx.observe_window_appearance(window, |_, window, cx| {
                crate::theme::system_changed(window.appearance(), cx)
            }),
            // Behave like a menu: clicking elsewhere dismisses it. A new window can
            // report "inactive" before the window manager focuses it, so wait for
            // the first activation.
            cx.observe_window_activation(window, |this: &mut Self, window, cx| {
                if window.is_window_active() {
                    this.was_active = true;
                } else if this.was_active {
                    crate::app::note_menu_dismissed(cx);
                    window.remove_window();
                }
            }),
        ];
        let mut this = Self {
            store,
            filter: None,
            focus,
            was_active: false,
            history: HashMap::new(),
            _subscriptions: subscriptions,
        };
        this.load_history(cx);
        this
    }

    /// Fetches recorded quota once per popup for each limit that gets a burn chart.
    /// A failed fetch leaves the chart drawing an even spend up to now.
    fn load_history(&mut self, cx: &mut Context<Self>) {
        if crate::prefs::get(cx).density != Density::Detailed {
            return;
        }
        let (overview, host) = {
            let store = self.store.read(cx);
            (store.overview.clone(), store.host())
        };
        let Some(overview) = overview else { return };
        for account in overview.groups.iter().flat_map(|g| &g.accounts) {
            for metric in &account.metrics {
                let Some(pace) = metric.pace.filter(|p| p.behind) else {
                    continue;
                };
                let key = (account.id.clone(), metric.id.clone());
                if self.history.insert(key.clone(), Vec::new()).is_some() {
                    continue;
                }
                // The shortest range that covers the whole window.
                let range = if pace.window <= Duration::DAY {
                    "24h"
                } else if pace.window <= Duration::days(7) {
                    "7d"
                } else {
                    "30d"
                };
                let path = format!("/v2/accounts/{}/quota-history/{}/{range}", key.0, key.1);
                let request = host.call(Method::GET, path, None);
                cx.spawn(async move |this, cx| {
                    let Ok(chart) = request.await else { return };
                    let points = chart["bins"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(|bin| {
                            let latest = &bin["latest"];
                            let at =
                                OffsetDateTime::parse(latest["fetched_at"].as_str()?, &Rfc3339);
                            Some((at.ok()?, latest["quota"]["remaining_percent"].as_f64()?))
                        })
                        .collect();
                    let _ = this.update(cx, |this, cx| {
                        this.history.insert(key, points);
                        cx.notify();
                    });
                })
                .detach();
            }
        }
    }

    fn on_key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        match keystroke.key.as_str() {
            "escape" => window.remove_window(),
            "," if keystroke.modifiers.secondary() => {
                window.remove_window();
                crate::app::open_settings(cx);
            }
            "q" if keystroke.modifiers.secondary() => crate::app::quit(cx),
            _ => {}
        }
    }

    fn header(&self, overview: Option<&Overview>, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let store = self.store.read(cx);
        let status: SharedString = match (overview, &store.error) {
            (_, Some(error)) => format!("Host unavailable: {error}").into(),
            (Some(overview), None) => overview.status_line().into(),
            (None, None) => "Loading…".into(),
        };
        let refreshing = store.refreshing;
        div()
            .flex()
            .justify_between()
            .items_center()
            .pt(px(8.))
            .pb(px(10.))
            .px(px(10.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .min_w_0()
                    .child(
                        div()
                            .text_size(px(14.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(p.text_strong)
                            .child("Quotio"),
                    )
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(p.text_soft)
                            .truncate()
                            .child(status),
                    ),
            )
            .child(
                div()
                    .id("refresh-all")
                    .size(px(28.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(8.))
                    .border_1()
                    .border_color(p.stroke_soft)
                    .cursor_pointer()
                    .hover(|s| s.bg(p.bg_weak))
                    .when(refreshing, |s| s.opacity(0.5))
                    .child(icon(IconName::RefreshCw, 15., p.text_sub))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.store.update(cx, |store, cx| store.refresh(None, cx));
                    })),
            )
    }

    fn chips(&self, overview: &Overview, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let chip = |id: SharedString,
                    label: SharedString,
                    leading: &dyn Fn(Hsla) -> AnyElement,
                    value: Option<String>,
                    active: bool,
                    cx: &mut Context<Self>| {
            let color = if active { p.on_strong } else { p.text_sub };
            div()
                .id(id)
                .flex()
                .items_center()
                .h(px(28.))
                .px(px(10.))
                .gap(px(6.))
                .rounded_full()
                .text_size(px(12.))
                .font_weight(FontWeight::MEDIUM)
                .cursor_pointer()
                .text_color(color)
                .map(|s| {
                    if active {
                        s.bg(p.text_strong)
                    } else {
                        s.bg(p.bg_weak).hover(|s| s.bg(p.stroke_soft))
                    }
                })
                .child(leading(color))
                .child(label)
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.filter = value.clone();
                    cx.notify();
                }))
        };
        div()
            .flex()
            .flex_wrap()
            .gap(px(6.))
            .px(px(10.))
            .pb(px(10.))
            .border_b_1()
            .border_color(p.stroke_soft)
            .child(chip(
                "chip-all".into(),
                "All".into(),
                &|color| icon(IconName::LayoutGrid, 13., color).into_any_element(),
                None,
                self.filter.is_none(),
                cx,
            ))
            .children(overview.groups.iter().map(|group| {
                chip(
                    format!("chip-{}", group.provider_id).into(),
                    group.name.clone().into(),
                    &|color| provider_logo(&group.provider_id, 12., Some(color), &p),
                    Some(group.provider_id.clone()),
                    self.filter.as_deref() == Some(&group.provider_id),
                    cx,
                )
            }))
    }

    fn group(&self, index: usize, group: &ProviderGroup, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let provider = group.provider_id.clone();
        let density = crate::prefs::get(cx).density;
        let (now, offset) = {
            let store = self.store.read(cx);
            (store.now(), store.offset())
        };
        div()
            .flex()
            .flex_col()
            .pt(px(8.))
            .when(index > 0, |s| s.border_t_1().border_color(p.stroke_soft))
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .px(px(10.))
                    .py(px(6.))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .text_size(px(12.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(p.text_soft)
                            .child(provider_logo(
                                &group.provider_id,
                                12.,
                                Some(p.text_soft),
                                &p,
                            ))
                            .child(group.name.clone()),
                    )
                    .child(
                        div()
                            .id(SharedString::from(format!("refresh-{provider}")))
                            .cursor_pointer()
                            .child(icon(IconName::RefreshCw, 13., p.text_soft))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let provider = provider.clone();
                                this.store
                                    .update(cx, |store, cx| store.refresh(Some(provider), cx));
                            })),
                    ),
            )
            .children(group.accounts.iter().map(|account| {
                let name = shown_name(&account.name, cx);
                match density {
                    Density::Compact => compact_row(account, name, &p),
                    Density::Comfortable => account_card(account, name, None, &p),
                    Density::Detailed => {
                        account_card(account, name, Some((&self.history, now, offset)), &p)
                    }
                }
            }))
            .into_any_element()
    }

    fn footer(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let shortcut = |key: &str| {
            if cfg!(target_os = "macos") {
                format!("⌘{}", key.to_uppercase())
            } else {
                format!("Ctrl+{}", key.to_uppercase())
            }
        };
        let item =
            |id: &'static str, glyph: IconName, label: &'static str, keys: Option<String>| {
                div()
                    .id(id)
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .px(px(10.))
                    .py(px(6.))
                    .rounded(px(8.))
                    .text_size(px(13.))
                    .text_color(p.text_strong)
                    .cursor_pointer()
                    .hover(|s| s.bg(p.bg_weak))
                    .child(icon(glyph, 15., p.text_sub))
                    .child(div().flex_1().child(label))
                    .when_some(keys, |s, keys| {
                        s.child(div().text_size(px(12.)).text_color(p.text_soft).child(keys))
                    })
            };
        div()
            .flex()
            .flex_col()
            .pt(px(6.))
            .border_t_1()
            .border_color(p.stroke_soft)
            .child(
                item("pair-iphone", IconName::Smartphone, "Pair iPhone…", None).on_click(
                    |_, window, cx| {
                        window.remove_window();
                        crate::app::open_settings_at(crate::ui::settings::Page::IphoneSharing, cx);
                    },
                ),
            )
            .child(
                item(
                    "open-quotio",
                    IconName::Settings,
                    "Open Quotio…",
                    Some(shortcut(",")),
                )
                .on_click(|_, window, cx| {
                    window.remove_window();
                    crate::app::open_settings(cx);
                }),
            )
            .child(
                item("quit", IconName::Power, "Quit Quotio", Some(shortcut("q")))
                    .on_click(|_, _, cx| crate::app::quit(cx)),
            )
    }
}

impl Render for QuotaMenu {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let overview = self.store.read(cx).overview.clone();
        let groups: Vec<AnyElement> = match &overview {
            Some(overview) => overview
                .groups
                .iter()
                .filter(|g| self.filter.as_ref().is_none_or(|f| *f == g.provider_id))
                .enumerate()
                .map(|(index, group)| self.group(index, group, cx))
                .collect(),
            None => Vec::new(),
        };
        let empty = overview.as_ref().is_some_and(|o| o.groups.is_empty());
        // Long account lists scroll inside the popup instead of leaving the screen.
        let max_groups = window.display(cx).map_or(px(560.), |d| {
            d.bounds().size.height * 0.85 - px(CHROME_HEIGHT)
        });
        div()
            // Fit the window to the panel's natural height once it is laid out.
            .on_children_prepainted(|bounds, window, _| {
                let Some(panel) = bounds.first() else { return };
                let viewport = window.viewport_size();
                if (viewport.height - panel.size.height).abs() > px(1.) {
                    window.resize(size(viewport.width, panel.size.height));
                }
            })
            .id("quota-menu")
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::on_key_down))
            .size_full()
            .font_family(FONT_FAMILY)
            .line_height(relative(1.45))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .bg(p.bg_white)
                    .border_1()
                    .border_color(p.stroke_soft)
                    .rounded(px(14.))
                    .p(px(6.))
                    .overflow_hidden()
                    .child(self.header(overview.as_ref(), cx))
                    .when_some(overview.as_ref(), |s, overview| {
                        s.child(self.chips(overview, cx))
                    })
                    .child(
                        div()
                            .id("groups")
                            .max_h(max_groups)
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .gap(px(8.))
                            .pb(px(4.))
                            .children(groups)
                            .when(empty, |s| {
                                s.child(
                                    div()
                                        .p(px(16.))
                                        .text_size(px(13.))
                                        .text_color(p.text_sub)
                                        .child("No accounts yet. Open Quotio to add one."),
                                )
                            }),
                    )
                    .child(self.footer(cx)),
            )
    }
}

/// Comfortable shows the limits as tiles; Detailed gives each limit a full-width row.
fn account_card(
    account: &AccountView,
    name: String,
    detail: Option<(&History, OffsetDateTime, UtcOffset)>,
    p: &Palette,
) -> AnyElement {
    let detailed = detail.is_some();
    let group = SharedString::from(format!("card-{}", account.id));
    let mut card = div()
        .id(group.clone())
        .group(group.clone())
        .flex()
        .flex_col()
        .mx(px(4.))
        .p(px(if detailed { 12. } else { 10. }))
        .rounded(px(12.))
        .gap(px(match (detailed, account.issue.is_some()) {
            (_, true) => 8.,
            (true, false) => 12.,
            (false, false) => 10.,
        }))
        .cursor_pointer()
        .hover(|s| s.bg(p.bg_weak))
        .on_click(|_, window, cx| {
            window.remove_window();
            crate::app::open_settings(cx);
        })
        .child(card_header(account, name, &group, p));
    if let Some(issue) = &account.issue {
        card = card.child(
            div()
                .flex()
                .items_center()
                .gap(px(6.))
                .px(px(8.))
                .py(px(6.))
                .rounded(px(8.))
                .bg(p.error_alpha)
                .text_size(px(12.))
                .text_color(p.error)
                .child(icon(IconName::CircleAlert, 13., p.error))
                .child(div().flex_1().child(issue.title.clone()))
                .child(
                    div()
                        .font_weight(FontWeight::MEDIUM)
                        .child(issue.action.clone()),
                ),
        );
    } else if let Some((history, now, offset)) = detail {
        // As in the design, only a limit that is running out gets the chart.
        card = card.children(account.metrics.iter().map(|m| match m.pace {
            Some(pace) if pace.behind => {
                let key = (account.id.clone(), m.id.clone());
                let recorded = history.get(&key).map_or(&[][..], Vec::as_slice);
                burn_card(m, pace, recorded, now, offset, p).into_any_element()
            }
            _ => metric_row(m, p).into_any_element(),
        }));
    } else if !account.metrics.is_empty() {
        let single = account.metrics.len() == 1;
        card = card.child(
            div()
                .grid()
                .grid_cols(if single { 1 } else { 2 })
                .gap(px(8.))
                .children(account.metrics.iter().map(|m| metric_tile(m, &group, p))),
        );
    }
    card.into_any_element()
}

fn card_header(
    account: &AccountView,
    name: String,
    group: &SharedString,
    p: &Palette,
) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap(px(8.))
        .child(
            div()
                .min_w_0()
                .truncate()
                .text_size(px(13.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(p.text_strong)
                .child(name),
        )
        .when(account.pinned, |s| {
            s.child(icon(IconName::Pin, 11., p.text_soft))
        })
        .when_some(account.plan.clone(), |s, plan| {
            s.child(
                div()
                    .flex_none()
                    .px(px(6.))
                    .py(px(2.))
                    .rounded(px(6.))
                    .border_1()
                    .border_color(p.stroke_soft)
                    .bg(p.bg_weak)
                    .group_hover(group.clone(), |s| s.bg(p.bg_white))
                    .text_size(px(11.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_sub)
                    .child(plan),
            )
        })
        .child(div().flex_1())
        .when_some(account.updated.clone(), |s, updated| {
            s.child(
                div()
                    .flex_none()
                    .text_size(px(11.))
                    .text_color(p.text_soft)
                    .child(updated),
            )
        })
        .child(
            div()
                .invisible()
                .group_hover(group.clone(), |s| s.visible())
                .child(icon(IconName::ChevronRight, 14., p.text_soft)),
        )
}

fn metric_tile(metric: &MetricView, group: &SharedString, p: &Palette) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap(px(6.))
        .p(px(8.))
        .rounded(px(10.))
        .bg(p.bg_weak)
        .group_hover(group.clone(), |s| s.bg(p.bg_white))
        .min_w_0()
        .child(
            div()
                .flex()
                .justify_between()
                .items_baseline()
                .gap(px(6.))
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(px(11.))
                        .text_color(p.text_sub)
                        .child(metric.label.clone()),
                )
                .child(
                    div()
                        .flex_none()
                        .text_size(px(13.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(value_color(metric.tone, p))
                        .child(metric.value.clone()),
                ),
        )
        .child(paced_bar(metric, 4., p))
        .map(|s| match (&metric.empties, &metric.reset) {
            // Too narrow for both: the projection matters more than the reset.
            (Some(empty), _) => s.child(
                div()
                    .truncate()
                    .text_size(px(11.))
                    .text_color(p.away)
                    .child(format!("Empty {empty}")),
            ),
            (None, Some(reset)) => s.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .text_size(px(11.))
                    .text_color(p.text_soft)
                    .child(icon(IconName::Clock, 11., p.text_soft))
                    .child(reset.clone()),
            ),
            (None, None) => s,
        })
}

/// The bar with a tick where spending the window evenly would be now.
fn paced_bar(metric: &MetricView, height: f32, p: &Palette) -> impl IntoElement {
    div()
        .relative()
        .py(px(3.))
        .child(progress(metric.fill, metric.tone, px(height), p))
        .when_some(metric.tick, |s, tick| {
            s.child(
                div()
                    .absolute()
                    .top_0()
                    .bottom_0()
                    .left(relative(tick.clamp(0., 1.)))
                    .ml(px(-1.))
                    .w(px(2.))
                    .rounded(px(1.))
                    .bg(p.text_strong),
            )
        })
}

/// Detailed density: one limit across the card, with its reset in words.
fn metric_row(metric: &MetricView, p: &Palette) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap(px(6.))
        .child(
            div()
                .flex()
                .justify_between()
                .items_baseline()
                .gap(px(8.))
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(px(12.))
                        .text_color(p.text_sub)
                        .child(metric.label.clone()),
                )
                .child(
                    div()
                        .flex_none()
                        .text_size(px(13.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(value_color(metric.tone, p))
                        .child(metric.value.clone()),
                ),
        )
        .child(paced_bar(metric, 6., p))
        .child(
            div()
                .flex()
                .justify_between()
                .gap(px(8.))
                .text_size(px(11.))
                .text_color(p.text_soft)
                .children(metric.reset_sentence())
                .when_some(
                    metric
                        .pace
                        .filter(|pace| !pace.behind && pace.used_per_day > 0.),
                    |s, pace| {
                        s.child(
                            div().truncate().child(format!(
                                "{} · lasts to reset",
                                pace.rate(pace.used_per_day)
                            )),
                        )
                    },
                ),
        )
}

const PLOT_HEIGHT: f32 = 56.;

/// A limit running out: the window so far, the even-pace line, where the current
/// rate leads, and what to do about it. From the design's "Detailed card".
fn burn_card(
    metric: &MetricView,
    pace: Pace,
    recorded: &[(OffsetDateTime, f64)],
    now: OffsetDateTime,
    offset: UtcOffset,
    p: &Palette,
) -> impl IntoElement {
    let color = tone_color(metric.tone, p);
    let start = pace.resets_at - pace.window;
    let x = move |at: OffsetDateTime| ((at - start) / pace.window).clamp(0., 1.) as f32;
    // Without recorded values, assume an even spend from a full window to now.
    let mut line: Vec<(f32, f32)> = recorded
        .iter()
        .filter(|(at, _)| *at >= start && *at < now)
        .map(|(at, r)| (x(*at), (*r / 100.) as f32))
        .collect();
    if line.is_empty() {
        line.push((0., 1.));
    }
    line.push((x(now), (pace.remaining / 100.) as f32));
    let end = match pace.projected_empty {
        Some(empty) => (x(empty), 0.),
        None => (1., (pace.remaining_at_reset(now) / 100.) as f32),
    };
    let plot = {
        let (line, p) = (line.clone(), p.clone());
        canvas(
            |_, _, _| (),
            move |bounds, (), window, _| {
                let (w, h) = (bounds.size.width, bounds.size.height);
                let at = |(fx, fr): (f32, f32)| {
                    bounds.origin + point(w * fx, h * (1. - fr.clamp(0., 1.)))
                };
                let current = *line.last().unwrap_or(&(0., 0.));
                let mut area = PathBuilder::fill();
                let mut corners: Vec<_> = vec![at((line[0].0, 0.))];
                corners.extend(line.iter().map(|pt| at(*pt)));
                corners.push(at((current.0, 0.)));
                area.add_polygon(&corners, true);
                if let Ok(area) = area.build() {
                    window.paint_path(area, color.opacity(0.15));
                }
                let mut stroke = |points: &[(f32, f32)], width: f32, dash: &[f32], color| {
                    let mut path = PathBuilder::stroke(px(width));
                    if !dash.is_empty() {
                        let dash: Vec<_> = dash.iter().map(|d| px(*d)).collect();
                        path = path.dash_array(&dash);
                    }
                    path.move_to(at(points[0]));
                    points[1..].iter().for_each(|pt| path.line_to(at(*pt)));
                    if let Ok(path) = path.build() {
                        window.paint_path(path, color);
                    }
                };
                stroke(&[(0., 1.), (1., 0.)], 1., &[1., 3.], p.text_soft);
                stroke(&line, 2., &[], color);
                stroke(&[current, end], 1.5, &[3., 3.], p.error);
                let dot = |center: (f32, f32), size: f32| {
                    gpui_kit::Bounds::centered_at(at(center), gpui_kit::size(px(size), px(size)))
                };
                window.paint_quad(gpui_kit::fill(dot(end, 5.), p.error).corner_radii(px(2.5)));
                window.paint_quad(gpui_kit::fill(
                    gpui_kit::Bounds::new(
                        bounds.origin + point(w - px(1.5), px(0.)),
                        gpui_kit::size(px(1.5), h),
                    ),
                    p.info,
                ));
                window.paint_quad(
                    gpui_kit::fill(dot(current, 8.), p.bg_white)
                        .corner_radii(px(4.))
                        .border_widths(px(1.5))
                        .border_color(color),
                );
            },
        )
        .w_full()
        .h(px(PLOT_HEIGHT))
    };

    // Weekdays repeat inside a short window, so those read as clock times.
    let axis = |at: OffsetDateTime| {
        if pace.window >= Duration::days(2) {
            weekday_time(at, offset)[..3].to_owned()
        } else {
            let local = at.to_offset(offset);
            format!("{:02}:{:02}", local.hour(), local.minute())
        }
    };
    let now_x = x(now);
    let empty_x = pace.projected_empty.map(x);
    // Labels under a point drop out near the edges or when they would collide.
    let inside = |f: f32| f > 0.12 && f < 0.77;
    let label = |f: f32, text: String, color, weight| {
        div()
            .absolute()
            .top_0()
            .left(relative(f))
            .w(px(0.))
            .flex()
            .justify_center()
            .child(
                div()
                    .whitespace_nowrap()
                    .font_weight(weight)
                    .text_color(color)
                    .child(text),
            )
    };
    let labels = div()
        .relative()
        .h(px(14.))
        .text_size(px(11.))
        .child(div().text_color(p.text_soft).child(axis(start)))
        .child(
            div()
                .absolute()
                .top_0()
                .right_0()
                .text_color(p.info)
                .child(format!("Reset {}", axis(pace.resets_at))),
        )
        .when(
            inside(now_x) && empty_x.is_none_or(|e| (e - now_x).abs() > 0.12),
            |s| {
                s.child(label(
                    now_x,
                    "Now".into(),
                    p.text_strong,
                    FontWeight::MEDIUM,
                ))
            },
        )
        .when_some(
            pace.projected_empty.filter(|_| empty_x.is_some_and(inside)),
            |s, empty| {
                s.child(label(
                    empty_x.unwrap_or_default(),
                    axis(empty),
                    p.error,
                    FontWeight::SEMIBOLD,
                ))
            },
        );

    let until = if pace.window < Duration::DAY {
        let local = pace.resets_at.to_offset(offset);
        format!("{:02}:{:02}", local.hour(), local.minute())
    } else {
        weekday_time(pace.resets_at, offset)
    };
    let lead = format!("Using {}.", pace.rate(pace.used_per_day));
    let text = format!(
        "{lead} To last until {until}, stay under {}. Estimated",
        pace.rate(pace.budget_per_day)
    );
    let estimated = text.len() - "Estimated".len()..text.len();
    let advice = StyledText::new(text).with_highlights([
        (
            0..lead.len(),
            HighlightStyle {
                color: Some(p.error),
                font_weight: Some(FontWeight::SEMIBOLD),
                ..Default::default()
            },
        ),
        (
            estimated,
            HighlightStyle {
                color: Some(p.text_soft),
                ..Default::default()
            },
        ),
    ]);

    div()
        .flex()
        .flex_col()
        .gap(px(8.))
        .p(px(10.))
        .rounded(px(10.))
        .border_1()
        .border_color(p.away.opacity(0.3))
        .bg(p.away.opacity(0.07))
        .child(
            div()
                .flex()
                .justify_between()
                .items_baseline()
                .child(
                    div()
                        .text_size(px(13.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_strong)
                        .child(metric.label.clone()),
                )
                .child(
                    div()
                        .text_size(px(13.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(color)
                        .child(metric.value.clone()),
                ),
        )
        .child(plot)
        .child(labels)
        .child(div().h(px(1.)).bg(p.away.opacity(0.3)))
        .child(
            div()
                .flex()
                .gap(px(6.))
                .text_size(px(12.))
                .text_color(p.text_sub)
                .child(div().pt(px(2.)).child(icon(IconName::Gauge, 12., p.error)))
                .child(div().flex_1().min_w_0().child(advice)),
        )
}

/// Compact density: one line per account, a mini bar for each of the two tightest
/// limits, and the value of the limit that runs out first.
fn compact_row(account: &AccountView, name: String, p: &Palette) -> AnyElement {
    let left = |m: &MetricView| m.remaining.unwrap_or(1.);
    let mut tightest: Vec<&MetricView> = account.metrics.iter().collect();
    tightest.sort_by(|a, b| left(a).total_cmp(&left(b)));
    let binding = tightest.first().copied();
    tightest.truncate(2);
    let out = binding.is_some_and(|m| m.remaining == Some(0.));
    div()
        .id(SharedString::from(format!("card-{}", account.id)))
        .flex()
        .items_center()
        .gap(px(10.))
        .mx(px(4.))
        .px(px(10.))
        .py(px(8.))
        .rounded(px(9.))
        .cursor_pointer()
        .hover(|s| s.bg(p.bg_weak))
        .on_click(|_, window, cx| {
            window.remove_window();
            crate::app::open_settings(cx);
        })
        .child(provider_logo(&account.provider_id, 13., None, p))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(px(13.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(if out { p.text_soft } else { p.text_strong })
                .child(name),
        )
        .map(|row| match (&account.issue, binding) {
            (Some(issue), _) => row.child(
                div()
                    .flex_none()
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .text_size(px(11.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.error)
                    .child(icon(IconName::CircleAlert, 12., p.error))
                    .child(issue.title.clone()),
            ),
            (None, Some(binding)) => row
                .child(
                    div()
                        .flex_none()
                        .w(px(56.))
                        .flex()
                        .flex_col()
                        .gap(px(4.))
                        .children(
                            account
                                .metrics
                                .iter()
                                .filter(|m| tightest.iter().any(|t| std::ptr::eq(*t, *m)))
                                .map(|m| {
                                    progress(m.fill, m.tone, px(4.), p)
                                        .when(m.remaining == Some(0.), |s| s.bg(p.error_alpha))
                                }),
                        ),
                )
                .child(
                    div()
                        .flex_none()
                        .w(px(62.))
                        .flex()
                        .flex_col()
                        .items_end()
                        .child(
                            div()
                                .text_size(px(13.))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(value_color(binding.tone, p))
                                .child(binding.value.clone()),
                        )
                        .when_some(binding.reset.clone(), |s, reset| {
                            let reset = if reset.starts_with(|c: char| c.is_ascii_digit()) {
                                format!("in {reset}")
                            } else {
                                reset
                            };
                            s.child(
                                div()
                                    .whitespace_nowrap()
                                    .text_size(px(10.))
                                    .text_color(p.text_soft)
                                    .child(reset),
                            )
                        }),
                ),
            (None, None) => row,
        })
        .into_any_element()
}

const CHROME_HEIGHT: f32 = 6. + 56. + 39. + 97. + 6.;

/// Initial window height, close to the laid-out height so the popup does not jump
/// when `render` fits the window to its content.
pub fn preferred_height_for(overview: Option<&Overview>, density: Density) -> f32 {
    let Some(overview) = overview else {
        return CHROME_HEIGHT + 60.;
    };
    let groups: f32 = overview
        .groups
        .iter()
        .map(|group| {
            36. + group
                .accounts
                .iter()
                .map(
                    |account| match (density, &account.issue, account.metrics.len()) {
                        (Density::Compact, None, n) if n > 0 => 49.,
                        (Density::Compact, _, _) => 35.,
                        (Density::Comfortable, Some(_), _) => 76.,
                        (Density::Detailed, Some(_), _) => 80.,
                        (Density::Comfortable, None, 0) => 40.,
                        (Density::Detailed, None, n) => {
                            let burning = account
                                .metrics
                                .iter()
                                .filter(|m| m.pace.is_some_and(|p| p.behind))
                                .count();
                            46. + n as f32 * 71. + burning as f32 * 110.
                        }
                        (Density::Comfortable, None, n) => {
                            let rows = n.div_ceil(2) as f32;
                            50. + rows * 68. + (rows - 1.) * 8.
                        }
                    },
                )
                .sum::<f32>()
        })
        .sum::<f32>()
        + overview.groups.len().saturating_sub(1) as f32 * 9.
        + 4.;
    CHROME_HEIGHT + groups.min(720.)
}

pub fn open_in(store: Entity<QuotaStore>, window: &mut Window, cx: &mut App) -> Entity<QuotaMenu> {
    cx.new(|cx| QuotaMenu::new(store, window, cx))
}
