//! Notifications page, from the Wonder artboard "Page - Quotio Settings
//! Notifications". The CLIProxyAPI alerts are macOS-only and left out.
use gpui_kit::assets::IconName;
use gpui_kit::component::Disableable as _;
use gpui_kit::component::button::Button;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::{
    AnyElement, BoxShadow, ClickEvent, Context, FontWeight, Hsla, IntoElement, ParentElement,
    Styled, div, linear_color_stop, linear_gradient, point, prelude::FluentBuilder as _, px,
    relative, rgb, rgba,
};

use super::SettingsWindow;
use super::widgets::{page_with, row, rows, section, toggle};
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
            (IconName::BatteryLow, p.error, p.error_alpha),
            "Quota running low",
            "When any limit drops below the threshold.",
            div()
                .flex()
                .items_center()
                .gap(px(12.))
                .child(threshold_select(
                    settings.threshold,
                    on && settings.quota_low,
                    &p,
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
            (IconName::Timer, p.away, p.away.opacity(0.14)),
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
        .child(
            section(
                "What you’ll see",
                "Notifications name the account and when it resets.",
                example(&p),
                &p,
            )
            .border_b_0(),
        )
        .into_any_element()
    }
}

fn edit(cx: &mut gpui_kit::App, change: impl FnOnce(&mut Notifications)) {
    prefs::update(cx, |prefs| change(&mut prefs.notifications));
    cx.refresh_windows();
}

/// The compact "Below 20%" select that opens the threshold menu.
fn threshold_select(threshold: u8, enabled: bool, p: &Palette) -> impl IntoElement {
    Button::new("threshold")
        .outline()
        .h(px(32.))
        .px(px(10.))
        .rounded(px(9.))
        .border_color(p.stroke_soft)
        .bg(p.bg_white)
        .shadow(Vec::new())
        .disabled(!enabled)
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(6.))
                .text_size(px(14.))
                .child(div().text_color(p.text_soft).child("Below"))
                .child(
                    div()
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_strong)
                        .child(format!("{threshold}%")),
                )
                .child(icon(IconName::ChevronDown, 16., p.text_soft)),
        )
        .dropdown_menu(move |menu: PopupMenu, _, _| {
            THRESHOLDS.iter().fold(menu.min_w(px(140.)), |menu, &t| {
                menu.item(
                    PopupMenuItem::new(format!("Below {t}%"))
                        .checked(t == threshold)
                        .on_click(move |_: &ClickEvent, _, cx| edit(cx, |n| n.threshold = t)),
                )
            })
        })
}

/// A row with a leading tinted icon tile, dimmed while notifications are off.
fn alert_row(
    (glyph, tint, tile): (IconName, Hsla, Hsla),
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
                .bg(tile)
                .child(icon(glyph, 16., tint)),
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
        .flex_1()
        .justify_end()
        .p(px(20.))
        .rounded(px(16.))
        .bg(linear_gradient(
            120.,
            linear_color_stop(rgb(0xc9d6ff), 0.),
            linear_color_stop(rgb(0xf5d9e8), 1.),
        ))
        .child(
            div()
                .w(px(340.))
                .flex()
                .gap(px(12.))
                .p(px(12.))
                .rounded(px(18.))
                .bg(p.bg_white.opacity(0.85))
                .shadow(vec![BoxShadow {
                    color: rgba(0x0e121b40).into(),
                    offset: point(px(0.), px(8.)),
                    blur_radius: px(24.),
                    spread_radius: px(-8.),
                    inset: false,
                }])
                .child(
                    div()
                        .size(px(36.))
                        .flex_none()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(9.))
                        .bg(p.text_strong)
                        .text_color(p.on_strong)
                        .text_size(px(14.))
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
                                .line_height(relative(1.5))
                                .child(
                                    div()
                                        .text_size(px(13.))
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(p.text_strong)
                                        .child("Codex weekly quota at 18%"),
                                )
                                .child(
                                    div()
                                        .text_size(px(11.))
                                        .text_color(p.text_soft)
                                        .child("now"),
                                ),
                        )
                        .child(
                            div()
                                .text_size(px(13.))
                                .line_height(relative(1.4))
                                .text_color(p.text_sub)
                                .child("you@example.com · resets Thu 14:20"),
                        ),
                ),
        )
}
