//! Menu Bar page, from the Sheet frame "Page - Quotio Settings Menu Bar". Trays on
//! Windows and Linux show only an icon, so there the page is called Tray and the rows
//! about text next to the icon, stacking, item count and the preview are left out.
use gpui_kit::assets::IconName;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::notification::Notification;
use gpui_kit::{
    AnyElement, Context, Div, FontWeight, Hsla, InteractiveElement, IntoElement, ParentElement,
    StatefulInteractiveElement as _, Styled, Window, div, linear_color_stop, linear_gradient,
    prelude::FluentBuilder as _, px, relative, rgb, rgba,
};
use serde_json::json;

use super::widgets::{page, row, row_with, rows, section, segmented, this_computer, toggle};
use super::{Page, SettingsWindow};
use crate::host::Method;
use crate::prefs::{self, Density, MenuBar, ModelAggregation, QuotaDisplay, TotalUsage, TrayIcon};
use crate::theme::{Palette, palette};
use crate::ui::{ButtonKind, button, dialog_footer, icon, note, tone_color};

const MAC: bool = cfg!(target_os = "macos");

impl SettingsWindow {
    pub(super) fn menu_bar_page(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let prefs = prefs::get(cx).clone();
        let menu_bar = &prefs.menu_bar;

        let color = row(
            "Color",
            (!MAC).then(|| "The ring shows the lowest quota left across your accounts.".into()),
            segmented(
                "tray-color",
                &[
                    (TrayIcon::Colored, "Colored"),
                    (TrayIcon::Monochrome, "Monochrome"),
                ],
                &prefs.tray_icon,
                &p,
                cx.listener(|this, choice: &TrayIcon, _, cx| {
                    let choice = *choice;
                    prefs::update(cx, |prefs| prefs.tray_icon = choice);
                    this.redraw_quota(cx);
                }),
            ),
            &p,
        );

        let tray = if MAC {
            let mut items = vec![row(
                "Show menu bar icon",
                None,
                toggle(
                    "show-icon",
                    menu_bar.show_icon,
                    true,
                    &p,
                    cx.listener(|this, on: &bool, _, cx| {
                        let on = *on;
                        prefs::update(cx, |prefs| {
                            prefs.menu_bar.show_icon = on;
                            // Without either icon there would be no way back into Quotio.
                            if !on {
                                prefs.menu_bar.show_in_dock = true;
                            }
                        });
                        this.redraw_quota(cx);
                    }),
                ),
                &p,
            )];
            if menu_bar.show_icon {
                items.push(row(
                    "Show quota next to the icon",
                    Some("Pinned accounts show their percentage in the menu bar.".into()),
                    toggle(
                        "show-quota",
                        menu_bar.show_quota,
                        true,
                        &p,
                        cx.listener(|this, on: &bool, _, cx| {
                            let on = *on;
                            prefs::update(cx, |prefs| prefs.menu_bar.show_quota = on);
                            this.redraw_quota(cx);
                        }),
                    ),
                    &p,
                ));
            }
            if menu_bar.show_icon && menu_bar.show_quota {
                let stack = row(
                    "Stack paired metrics",
                    Some("Session and weekly share one compact item.".into()),
                    toggle(
                        "stack-paired",
                        menu_bar.stack_paired,
                        true,
                        &p,
                        cx.listener(|this, on: &bool, _, cx| {
                            let on = *on;
                            prefs::update(cx, |prefs| prefs.menu_bar.stack_paired = on);
                            this.redraw_quota(cx);
                        }),
                    ),
                    &p,
                );
                let count = row(
                    "Accounts in menu bar",
                    Some("Up to 10.".into()),
                    self.stepper(menu_bar.max_items.clamp(1, 10), &p, cx),
                    &p,
                );
                items.extend(
                    [stack, count, color]
                        .map(|item| div().pl(px(16.)).child(item).into_any_element()),
                );
            }
            section(
                "Menu bar",
                "If the icon is hidden, Quotio stays in the Dock.",
                rows(items, &p),
                &p,
            )
        } else {
            section(
                "Tray icon",
                "Click the icon to open quota; right-click for more.",
                rows([color], &p),
                &p,
            )
        };

        let recording = self
            .host_settings
            .as_ref()
            .and_then(|s| s["quota_history_enabled"].as_bool());
        let record = row_with(
            "Record quota history",
            Some(recording_status(recording, &p)),
            toggle(
                "record-history",
                recording.unwrap_or(false),
                recording.is_some(),
                &p,
                cx.listener(|this, on: &bool, window, cx| {
                    this.patch_settings(json!({ "quota_history_enabled": on }), window, cx)
                }),
            ),
            &p,
        );

        let clear = row(
            "Clear all history",
            Some("Accounts, sign-ins and current quota are kept.".into()),
            div()
                .id("clear-history")
                .h(px(36.))
                .flex_none()
                .flex()
                .items_center()
                .gap(px(6.))
                .px(px(12.))
                .rounded(px(10.))
                .bg(p.bg_white)
                .border_1()
                .border_color(p.stroke_soft)
                .shadow_sm()
                .cursor_pointer()
                .hover(|s| s.opacity(0.85))
                .text_size(px(14.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(p.error)
                .child(icon(IconName::Trash, 15., p.error))
                .child("Clear…")
                .on_click(
                    cx.listener(|this, _, window, cx| this.confirm_clear_history(window, cx)),
                ),
            &p,
        );

        let display = div()
            .flex()
            .items_center()
            .gap(px(16.))
            .child(
                div()
                    .flex_1()
                    .text_size(px(14.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_strong)
                    .child("Show percentages as"),
            )
            .child(segmented(
                "quota-display",
                &[
                    (QuotaDisplay::Remaining, "Remaining"),
                    (QuotaDisplay::Used, "Used"),
                ],
                &prefs.quota_display,
                &p,
                cx.listener(|this, choice: &QuotaDisplay, _, cx| {
                    let choice = *choice;
                    prefs::update(cx, |prefs| prefs.quota_display = choice);
                    this.redraw_quota(cx);
                }),
            ));

        let total = row(
            "Total usage",
            None,
            segmented(
                "total-usage",
                &[
                    (TotalUsage::SessionOnly, "Session only"),
                    (TotalUsage::Combined, "Session + extra"),
                ],
                &prefs.total_usage,
                &p,
                cx.listener(|this, choice: &TotalUsage, _, cx| {
                    let choice = *choice;
                    prefs::update(cx, |prefs| prefs.total_usage = choice);
                    this.redraw_quota(cx);
                }),
            ),
            &p,
        );
        let per_model = row(
            "Per-model limits",
            None,
            segmented(
                "model-aggregation",
                &[
                    (ModelAggregation::Lowest, "Lowest"),
                    (ModelAggregation::Average, "Average"),
                ],
                &prefs.model_aggregation,
                &p,
                cx.listener(|this, choice: &ModelAggregation, _, cx| {
                    let choice = *choice;
                    prefs::update(cx, |prefs| prefs.model_aggregation = choice);
                    this.redraw_quota(cx);
                }),
            ),
            &p,
        );

        let preview = (MAC && menu_bar.show_icon && menu_bar.show_quota)
            .then(|| self.preview(&prefs, &p, cx));

        page(
            Page::MenuBar.title(),
            if MAC {
                "What sits in the menu bar, and how quota is shown everywhere in Quotio."
            } else {
                "How the tray icon looks, and how quota is shown everywhere in Quotio."
            },
            &p,
        )
        .child(tray)
        .child(section(
            "Quota history",
            format!(
                "Recorded on {} while Quotio runs. Recording doesn’t change how often quota refreshes.",
                this_computer()
            ),
            rows([record, clear], &p),
            &p,
        ))
        .children(preview)
        .child(section(
            "Quota display",
            if MAC {
                "Applies to the menu, the Accounts page and notifications."
            } else {
                "Applies to the tray, its popup and the Accounts page."
            },
            div()
                .flex()
                .flex_col()
                .gap(px(16.))
                .child(display)
                .child(self.density_options(prefs.density, &p, cx)),
            &p,
        ))
        .child(
            section(
                "Usage calculation",
                "How an account’s overall number is worked out when it has several limits.",
                rows([total, per_model], &p),
                &p,
            )
            .border_b_0(),
        )
        .into_any_element()
    }

    /// Percentages and the tray icon follow these preferences; rebuild them.
    pub(super) fn redraw_quota(&mut self, cx: &mut Context<Self>) {
        self.store.update(cx, |store, cx| store.rebuild(cx));
        cx.notify();
    }

    /// −, the number of accounts, + in one 36 px box.
    fn stepper(&self, value: u8, p: &Palette, cx: &mut Context<Self>) -> Div {
        let step = |id: &'static str, glyph: IconName, to: u8, enabled: bool| {
            div()
                .id(id)
                .w(px(36.))
                .h_full()
                .flex()
                .items_center()
                .justify_center()
                .map(|s| {
                    if enabled {
                        s.cursor_pointer()
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.set_max_items(to, window, cx)
                            }))
                    } else {
                        s.opacity(0.4).cursor_not_allowed()
                    }
                })
                .child(icon(glyph, 16., p.text_sub))
        };
        div()
            .h(px(36.))
            .flex()
            .items_center()
            .rounded(px(10.))
            .bg(p.bg_white)
            .border_1()
            .border_color(p.stroke_soft)
            .shadow_sm()
            .child(
                step("max-items-down", IconName::Minus, value - 1, value > 1)
                    .border_r_1()
                    .border_color(p.stroke_soft),
            )
            .child(
                div()
                    .w(px(40.))
                    .text_center()
                    .text_size(px(14.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_strong)
                    .child(value.to_string()),
            )
            .child(
                step("max-items-up", IconName::Plus, value + 1, value < 10)
                    .border_l_1()
                    .border_color(p.stroke_soft),
            )
    }

    /// Lowering the limit below the pinned accounts drops the last ones, after asking.
    fn set_max_items(&mut self, max: u8, window: &mut Window, cx: &mut Context<Self>) {
        let menu_bar = prefs::get(cx).menu_bar.clone();
        let pinned: Vec<String> = if menu_bar.user_modified {
            let every = MenuBar {
                max_items: 10,
                ..menu_bar
            };
            self.store
                .read(cx)
                .overview
                .as_ref()
                .map(|overview| {
                    overview
                        .menu_bar_accounts(&every)
                        .into_iter()
                        .map(|(_, account)| account.id.clone())
                        .collect()
                })
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        if pinned.len() <= max as usize {
            prefs::update(cx, |prefs| prefs.menu_bar.max_items = max);
            self.redraw_quota(cx);
            return;
        }
        let this = cx.entity().downgrade();
        let count = pinned.len();
        window.open_dialog(cx, move |dialog, _, cx| {
            let p = palette(cx).clone();
            let (this, pinned) = (this.clone(), pinned.clone());
            dialog
                .w(px(420.))
                .title("Show fewer accounts?")
                .child(
                    note(
                        format!(
                            "{count} accounts are pinned to the menu bar. Lowering the limit to {max} removes the rest from it."
                        ),
                        p.text_sub,
                    )
                    .text_size(px(14.)),
                )
                .footer(
                    dialog_footer()
                        .child(
                            button("cancel", "Cancel", ButtonKind::Secondary, &p)
                                .on_click(|_, window, cx| window.close_dialog(cx)),
                        )
                        .child(
                            button("lower", "Show fewer", ButtonKind::Danger, &p).on_click(
                                move |_, window, cx| {
                                    window.close_dialog(cx);
                                    prefs::update(cx, |prefs| {
                                        prefs.menu_bar.max_items = max;
                                        prefs.menu_bar.accounts =
                                            pinned[..max as usize].to_vec();
                                    });
                                    let _ = this.update(cx, |this, cx| this.redraw_quota(cx));
                                },
                            ),
                        ),
                )
        });
    }

    /// A mock menu bar with the pinned accounts as they show next to the icon.
    fn preview(&self, prefs: &prefs::Prefs, p: &Palette, cx: &Context<Self>) -> Div {
        // Fixed colors: the mock sits on a light wallpaper in either theme.
        let ink: Hsla = rgb(0x171717).into();
        let colored = prefs.tray_icon == TrayIcon::Colored;
        let used = prefs.quota_display == prefs::QuotaDisplay::Used;
        let items: Vec<AnyElement> = self
            .store
            .read(cx)
            .overview
            .as_ref()
            .map(|overview| {
                overview
                    .menu_bar_accounts(&prefs.menu_bar)
                    .into_iter()
                    .map(|(_, account)| {
                        let item = crate::tray::item(account, prefs.menu_bar.stack_paired, used);
                        let color = |tone| if colored { tone_color(tone, p) } else { ink };
                        let stacked = item.lines.len() == 2;
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .text_size(px(13.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(ink)
                            .when(stacked, |s| {
                                s.px(px(6.)).py(px(2.)).rounded(px(5.)).bg(rgba(0x17171714))
                            })
                            .child(div().size(px(6.)).rounded_full().bg(color(item.dot)))
                            .children(item.lines.into_iter().enumerate().flat_map(
                                |(i, (text, tone))| {
                                    let slash =
                                        (i > 0).then(|| div().text_color(p.text_soft).child("/"));
                                    slash
                                        .into_iter()
                                        .chain([div().text_color(color(tone)).child(text)])
                                },
                            ))
                            .into_any_element()
                    })
                    .collect()
            })
            .unwrap_or_default();
        let count = items.len();
        let caption = format!(
            "Preview · {count} pinned account{}, {}. Pin accounts from the Accounts page.",
            if count == 1 { "" } else { "s" },
            if colored { "colored" } else { "monochrome" },
        );
        div()
            .flex()
            .flex_col()
            .gap(px(6.))
            .child(
                div()
                    .h(px(52.))
                    .px(px(16.))
                    .pt(px(8.))
                    .rounded(px(16.))
                    .bg(linear_gradient(
                        120.,
                        linear_color_stop(rgb(0xc9d6ff), 0.),
                        linear_color_stop(rgb(0xf5d9e8), 1.),
                    ))
                    .child(
                        div()
                            .h(px(28.))
                            .flex()
                            .items_center()
                            .gap(px(16.))
                            .px(px(12.))
                            .rounded(px(8.))
                            .bg(rgba(0xffffff99))
                            .text_size(px(13.))
                            .text_color(ink)
                            .child(div().font_weight(FontWeight::SEMIBOLD).child("Quotio"))
                            .child(div().flex_1())
                            .children(items)
                            .child(icon(IconName::Wifi, 15., ink))
                            .child(icon(IconName::BatteryFull, 17., ink))
                            .child("Sat 21:26"),
                    ),
            )
            .child(
                div()
                    .text_size(px(12.))
                    .text_color(p.text_soft)
                    .child(caption),
            )
    }

    /// Compact, Comfortable and Detailed cards with a sketch of each layout.
    fn density_options(&self, chosen: Density, p: &Palette, cx: &mut Context<Self>) -> Div {
        let option = |density: Density, name: &'static str, help: &'static str, sketch: Div| {
            div()
                .id(name)
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(px(8.))
                .p(px(6.))
                .border_2()
                .border_color(if density == chosen {
                    p.primary
                } else {
                    p.stroke_soft
                })
                .rounded(px(14.))
                .cursor_pointer()
                .child(
                    sketch
                        .h(px(84.))
                        .flex()
                        .flex_col()
                        .justify_center()
                        .px(px(10.))
                        .py(px(8.))
                        .rounded(px(10.))
                        .bg(p.bg_weak),
                )
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .px(px(4.))
                        .pb(px(2.))
                        .child(
                            div()
                                .text_size(px(14.))
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(p.text_strong)
                                .child(name),
                        )
                        .child(div().text_size(px(11.)).text_color(p.text_soft).child(help)),
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    prefs::update(cx, |prefs| prefs.density = density);
                    this.redraw_quota(cx);
                }))
        };
        let line = |fill: f32, color: Hsla| {
            div()
                .flex()
                .items_center()
                .gap(px(6.))
                .child(div().flex_1().h(px(6.)).rounded_full().bg(p.stroke_soft))
                .child(
                    div()
                        .w(px(32.))
                        .h(px(4.))
                        .rounded_full()
                        .bg(p.stroke_soft)
                        .child(div().h_full().w(relative(fill)).rounded_full().bg(color)),
                )
        };
        let compact = div()
            .gap(px(8.))
            .child(line(0.9, p.primary))
            .child(line(0.2, p.away))
            .child(line(0.7, p.primary));
        let comfortable = div()
            .gap(px(10.))
            .child(div().w(px(56.)).h(px(6.)).rounded_full().bg(p.stroke_soft))
            .child(mini_track(0.74, 0.34, p.primary, p))
            .child(mini_track(0.18, 0.68, p.away, p));
        // A falling usage line, drawn as steps; the projection past now is faint.
        let burn = div().h(px(32.)).flex().items_end().children(
            [30., 29., 28., 27., 25., 23., 20., 17., 13., 9., 5.]
                .into_iter()
                .enumerate()
                .map(|(i, height)| {
                    div()
                        .flex_1()
                        .h(px(height))
                        .border_t_2()
                        .border_color(p.away)
                        .when(i >= 8, |s| s.opacity(0.4))
                }),
        );
        let detailed = div()
            .gap(px(8.))
            .child(mini_track(0.18, 0.68, p.away, p))
            .child(burn);
        div()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(
                div()
                    .flex()
                    .gap(px(12.))
                    .child(option(
                        Density::Compact,
                        "Compact",
                        "One line per account",
                        compact,
                    ))
                    .child(option(
                        Density::Comfortable,
                        "Comfortable",
                        "Every limit, with pace",
                        comfortable,
                    ))
                    .child(option(
                        Density::Detailed,
                        "Detailed",
                        "Adds trend and advice",
                        detailed,
                    )),
            )
            .child(note(
                "The black tick shows where you’d be if you spread usage evenly until the reset. Fill left of the tick means you’re using it faster than it refills.",
                p.text_sub,
            ).line_height(relative(1.5)))
    }

    fn confirm_clear_history(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let host = self.store.read(cx).host();
        window.open_dialog(cx, move |dialog, _, cx| {
            let p = palette(cx).clone();
            let host = host.clone();
            dialog
                .w(px(420.))
                .title("Clear all quota history?")
                .child(
                    note(
                        "Charts start over from the next refresh. Accounts, sign-ins and current quota are kept.",
                        p.text_sub,
                    )
                    .text_size(px(14.)),
                )
                .footer(
                    dialog_footer()
                        .child(
                            button("cancel", "Cancel", ButtonKind::Secondary, &p)
                                .on_click(|_, window, cx| window.close_dialog(cx)),
                        )
                        .child(
                            button("clear", "Clear history", ButtonKind::Danger, &p).on_click(
                                move |_, window, cx| {
                                    window.close_dialog(cx);
                                    let work = host.call(
                                        Method::DELETE,
                                        "/v2/quota-history".into(),
                                        None,
                                    );
                                    window
                                        .spawn(cx, async move |cx| {
                                            let notification = match work.await {
                                                Ok(_) => Notification::success(
                                                    "Quota history cleared.",
                                                ),
                                                Err(error) => Notification::error(format!(
                                                    "Couldn’t clear quota history: {error:#}."
                                                )),
                                            };
                                            let _ = cx.update(|window, cx| {
                                                window.push_notification(notification, cx)
                                            });
                                        })
                                        .detach();
                                },
                            ),
                        ),
                )
        });
    }
}

/// A 6 px bar filled to `fill`, with the even-pace tick at `tick`.
fn mini_track(fill: f32, tick: f32, color: Hsla, p: &Palette) -> Div {
    div()
        .relative()
        .w_full()
        .h(px(6.))
        .rounded_full()
        .bg(p.stroke_soft)
        .child(
            div()
                .absolute()
                .left_0()
                .top_0()
                .h_full()
                .w(relative(fill))
                .rounded_full()
                .bg(color),
        )
        .child(
            div()
                .absolute()
                .left(relative(tick))
                .top(px(-2.))
                .w(px(2.))
                .h(px(10.))
                .bg(p.text_strong),
        )
}

fn recording_status(recording: Option<bool>, p: &Palette) -> impl IntoElement {
    let (dot, text) = match recording {
        Some(true) => (p.primary, "Recording · kept for 30 days"),
        Some(false) => (p.text_soft, "Not recording"),
        None => (p.text_soft, "Unavailable while Quotio can’t reach its host"),
    };
    div()
        .flex()
        .items_center()
        .gap(px(6.))
        .child(div().size(px(6.)).rounded_full().bg(dot))
        .child(div().text_size(px(12.)).text_color(p.text_sub).child(text))
}
