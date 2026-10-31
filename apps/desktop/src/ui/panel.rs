//! The account panel beside the tray popup, from the design's "Detailed Menu With
//! Account Submenu": each limit over its window, and a way into the full history.
use std::collections::HashMap;

use gpui_kit::assets::IconName;
use gpui_kit::{
    App, Context, Entity, FontWeight, Hsla, InteractiveElement, IntoElement, ParentElement, Render,
    StatefulInteractiveElement, Styled, Subscription, Window, div, prelude::FluentBuilder as _, px,
    relative, size,
};
use time::Duration;

use super::menu::{History, burn_card, fetch_history, metric_row};
use super::{icon, provider_logo, shown_name};
use crate::model::AccountView;
use crate::store::QuotaStore;
use crate::theme::{FONT_FAMILY, palette};

const PLOT_HEIGHT: f32 = 64.;

pub struct AccountPanel {
    store: Entity<QuotaStore>,
    account: String,
    history: History,
    was_active: bool,
    _subscriptions: Vec<Subscription>,
}

impl AccountPanel {
    pub fn new(
        store: Entity<QuotaStore>,
        account: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let subscriptions = vec![
            cx.observe(&store, |_, _, cx| cx.notify()),
            // Clicking the panel takes focus from the popup; both close once neither has it.
            cx.observe_window_activation(window, |this: &mut Self, window, cx| {
                if window.is_window_active() {
                    this.was_active = true;
                } else if this.was_active {
                    crate::app::popup_deactivated(cx);
                }
            }),
        ];
        let mut history = HashMap::new();
        let host = store.read(cx).host();
        if let Some(account) = find(&store, &account, cx) {
            for metric in &account.metrics {
                let Some(pace) = metric.pace else { continue };
                let key = (account.id.clone(), metric.id.clone());
                history.insert(key.clone(), Vec::new());
                let request = fetch_history(&host, &key.0, &key.1, pace.window);
                cx.spawn(async move |this, cx| {
                    let Some(points) = request.await else { return };
                    let _ = this.update(cx, |this, cx| {
                        this.history.insert(key, points);
                        cx.notify();
                    });
                })
                .detach();
            }
        }
        Self {
            store,
            account,
            history,
            was_active: false,
            _subscriptions: subscriptions,
        }
    }
}

fn find(store: &Entity<QuotaStore>, id: &str, cx: &App) -> Option<AccountView> {
    let overview = store.read(cx).overview.as_ref()?;
    overview
        .groups
        .iter()
        .flat_map(|g| &g.accounts)
        .find(|a| a.id == id)
        .cloned()
}

/// `5 hours`, `daily`, `weekly` or `30 days`, after the limit's name.
fn window_name(window: Duration) -> String {
    if window == Duration::DAY {
        "daily".into()
    } else if window == Duration::days(7) {
        "weekly".into()
    } else if window < Duration::DAY {
        format!("{} hours", window.whole_hours())
    } else {
        format!("{} days", window.whole_days())
    }
}

/// Opening height; the panel then fits itself to what it lays out.
pub fn preferred_height(store: &Entity<QuotaStore>, id: &str, cx: &App) -> f32 {
    let cards: f32 = find(store, id, cx).map_or(0., |account| {
        account
            .metrics
            .iter()
            .map(|m| if m.pace.is_some() { 182. } else { 82. } + 8.)
            .sum()
    });
    12. + 44. + cards + 34. + 9. + 40.
}

impl Render for AccountPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let Some(account) = find(&self.store, &self.account, cx) else {
            return div();
        };
        let (now, offset) = {
            let store = self.store.read(cx);
            (store.now(), store.offset())
        };
        let cards = account.metrics.iter().map(|m| match m.pace {
            Some(pace) => {
                let key = (account.id.clone(), m.id.clone());
                let recorded = self.history.get(&key).map_or(&[][..], Vec::as_slice);
                // `Weekly · weekly` says it twice.
                let window = window_name(pace.window);
                let title = if m.label.eq_ignore_ascii_case(&window) {
                    m.label.clone()
                } else {
                    format!("{} · {window}", m.label)
                };
                burn_card(m, title, pace, recorded, now, offset, PLOT_HEIGHT, &p).into_any_element()
            }
            None => div()
                .p(px(10.))
                .rounded(px(10.))
                .bg(p.bg_weak)
                .child(metric_row(m, &p))
                .into_any_element(),
        });
        let swatch = |label: &'static str, color: Hsla| {
            div()
                .flex()
                .items_center()
                .gap(px(5.))
                .child(div().w(px(10.)).h(px(2.)).rounded(px(1.)).bg(color))
                .child(label)
        };
        let charts = account.metrics.iter().any(|m| m.pace.is_some());
        let target = account.clone();
        div()
            // Fit the window to the panel's natural height once it is laid out.
            .on_children_prepainted(|bounds, window, _| {
                let Some(panel) = bounds.first() else { return };
                let viewport = window.viewport_size();
                if (viewport.height - panel.size.height).abs() > px(1.) {
                    window.resize(size(viewport.width, panel.size.height));
                }
            })
            .size_full()
            .font_family(FONT_FAMILY)
            .line_height(relative(1.45))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(8.))
                    .bg(p.bg_white)
                    .border_1()
                    .border_color(p.stroke_soft)
                    .rounded(px(14.))
                    .p(px(6.))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(8.))
                            .px(px(6.))
                            .pt(px(6.))
                            .child(provider_logo(&account.provider_id, 15., None, &p))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(px(13.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(p.text_strong)
                                    .child(shown_name(&account.name, cx)),
                            )
                            .when_some(account.updated.clone(), |s, updated| {
                                s.child(
                                    div()
                                        .flex_none()
                                        .text_size(px(11.))
                                        .text_color(p.text_soft)
                                        .child(format!("Updated {updated}")),
                                )
                            }),
                    )
                    .children(cards)
                    .when(charts, |s| {
                        s.child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(12.))
                                .px(px(6.))
                                .text_size(px(11.))
                                .text_color(p.text_soft)
                                .child(swatch("Recorded", p.primary))
                                .child(swatch("Even pace", p.text_soft))
                                .child(swatch("Projection", p.primary))
                                .child(div().flex_1())
                                .child("Estimated"),
                        )
                    })
                    .child(div().mx(px(6.)).h(px(1.)).bg(p.stroke_soft))
                    .child(
                        div()
                            .id("open-history")
                            .flex()
                            .items_center()
                            .gap(px(8.))
                            .px(px(6.))
                            .py(px(6.))
                            .rounded(px(8.))
                            .cursor_pointer()
                            .hover(|s| s.bg(p.bg_weak))
                            .text_size(px(13.))
                            .text_color(p.text_strong)
                            .child(icon(IconName::RotateCcwClock, 15., p.text_sub))
                            .child("Open quota history…")
                            .on_click(move |_, window, cx| {
                                // This window is mid-update, so the shell can't close it for us.
                                window.remove_window();
                                crate::app::close_popup(cx);
                                crate::app::open_history(target.clone(), cx);
                            }),
                    ),
            )
    }
}
