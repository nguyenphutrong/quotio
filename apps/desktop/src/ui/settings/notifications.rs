//! Notifications page, from the Wonder artboard "Page - Quotio Settings
//! Notifications". The CLIProxyAPI alerts are macOS-only and left out.
use gpui_kit::assets::IconName;
use gpui_kit::{
    AnyElement, Context, FontWeight, IntoElement, ParentElement, Styled, div,
    prelude::FluentBuilder as _, px,
};

use super::SettingsWindow;
use super::widgets::{page_with, row, rows, section, select, toggle};
use crate::prefs::{self, Notifications};
use crate::theme::{Palette, palette};
use crate::ui::icon;

const THRESHOLDS: [u8; 4] = [10, 20, 30, 50];

impl SettingsWindow {
    pub(super) fn notifications_page(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let settings = prefs::get(cx).notifications.clone();
        let on = settings.enabled;

        let master = div()
            .flex()
            .items_center()
            .gap(px(10.))
            .text_size(px(14.))
            .font_weight(FontWeight::MEDIUM)
            .text_color(p.text_strong)
            .child("Notifications on")
            .child(toggle("notifications-on", on, true, &p, |on, _, cx| {
                let on = *on;
                edit(cx, |n| n.enabled = on);
            }));

        let quota_low = alert_row(
            IconName::BatteryLow,
            "Quota running low",
            "When any limit drops below the threshold.",
            div()
                .flex()
                .items_center()
                .gap(px(12.))
                .child(select(
                    "threshold",
                    THRESHOLDS
                        .iter()
                        .map(|t| (*t, format!("Below {t}%")))
                        .collect(),
                    &settings.threshold,
                    on && settings.quota_low,
                    |threshold, _, cx| {
                        let threshold = *threshold;
                        edit(cx, |n| n.threshold = threshold);
                    },
                ))
                .child(toggle(
                    "quota-low",
                    settings.quota_low,
                    on,
                    &p,
                    |on, _, cx| {
                        let on = *on;
                        edit(cx, |n| n.quota_low = on);
                    },
                )),
            on,
            &p,
        );
        let cooling = alert_row(
            IconName::Clock,
            "Account cooling down",
            "When an account hits its limit and waits for a reset.",
            toggle(
                "cooling-down",
                settings.cooling_down,
                on,
                &p,
                |on, _, cx| {
                    let on = *on;
                    edit(cx, |n| n.cooling_down = on);
                },
            ),
            on,
            &p,
        );

        page_with(
            "Notifications",
            "Hear about low quota before you run out, not after.",
            master,
            &p,
        )
        .child(section(
            "Alerts",
            "Choose what Quotio tells you about.",
            rows([quota_low, cooling], &p),
            &p,
        ))
        .child(section(
            "What you’ll see",
            "Notifications name the account and when it resets.",
            example(&p),
            &p,
        ))
        .into_any_element()
    }
}

fn edit(cx: &mut gpui_kit::App, change: impl FnOnce(&mut Notifications)) {
    prefs::update(cx, |prefs| change(&mut prefs.notifications));
    cx.refresh_windows();
}

/// A row with a leading icon tile, dimmed while notifications are off.
fn alert_row(
    glyph: IconName,
    label: &str,
    help: &str,
    control: impl IntoElement,
    enabled: bool,
    p: &Palette,
) -> AnyElement {
    div()
        .flex()
        .items_center()
        .gap(px(12.))
        .when(!enabled, |s| s.opacity(0.5))
        .child(
            div()
                .size(px(32.))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(10.))
                .bg(p.bg_weak)
                .child(icon(glyph, 16., p.text_sub)),
        )
        .child(div().flex_1().min_w_0().child(row(
            label.to_owned(),
            Some(help.to_owned().into()),
            control,
            p,
        )))
        .into_any_element()
}

fn example(p: &Palette) -> impl IntoElement {
    div()
        .flex()
        .justify_center()
        .p(px(20.))
        .rounded(px(16.))
        .bg(p.bg_weak)
        .child(
            div()
                .w(px(360.))
                .flex()
                .gap(px(10.))
                .p(px(12.))
                .rounded(px(14.))
                .bg(p.bg_white)
                .shadow(p.raised())
                .child(
                    div()
                        .size(px(32.))
                        .flex_none()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(8.))
                        .bg(p.text_strong)
                        .text_color(p.on_strong)
                        .font_weight(FontWeight::SEMIBOLD)
                        .child("Q"),
                )
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .flex()
                                .justify_between()
                                .text_size(px(13.))
                                .child(
                                    div()
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(p.text_strong)
                                        .child("Codex weekly quota at 18%"),
                                )
                                .child(div().text_color(p.text_soft).child("now")),
                        )
                        .child(
                            div()
                                .text_size(px(13.))
                                .text_color(p.text_sub)
                                .child("you@example.com · resets Thu 14:20"),
                        ),
                ),
        )
}
