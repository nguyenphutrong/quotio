//! Tray page, from the Wonder artboard "Page - Quotio Settings Menu Bar". Trays on
//! Windows and Linux show only an icon, so the macOS rows about text next to it,
//! stacking and item count are left out, as are the menu density options.
use gpui_kit::assets::IconName;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::notification::Notification;
use gpui_kit::{
    AnyElement, Context, IntoElement, ParentElement, StatefulInteractiveElement as _, Styled,
    Window, div, px,
};
use serde_json::json;

use super::SettingsWindow;
use super::widgets::{page, row, row_with, rows, section, segmented, toggle};
use crate::host::Method;
use crate::prefs::{self, QuotaDisplay, TrayIcon};
use crate::theme::{Palette, palette};
use crate::ui::{ButtonKind, button, button_with_icon, dialog_footer, note};

impl SettingsWindow {
    pub(super) fn menu_bar_page(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let prefs = prefs::get(cx).clone();

        let color = row(
            "Color",
            Some("The ring shows the lowest quota left across your accounts.".into()),
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
            button_with_icon(
                "clear-history",
                IconName::Trash,
                "Clear…",
                ButtonKind::Secondary,
                &p,
            )
            .on_click(cx.listener(|this, _, window, cx| this.confirm_clear_history(window, cx))),
            &p,
        );

        let display = row(
            "Show percentages as",
            None,
            segmented(
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
            ),
            &p,
        );

        let computer = if cfg!(windows) {
            "this PC"
        } else {
            "this computer"
        };
        page(
            "Tray",
            "How the tray icon looks, and how quota is shown everywhere in Quotio.",
            &p,
        )
        .child(section(
            "Tray icon",
            "Click the icon to open quota; right-click for more.",
            rows([color], &p),
            &p,
        ))
        .child(section(
            "Quota history",
            format!(
                "Recorded on {computer} while Quotio runs. Recording doesn’t change how often quota refreshes."
            ),
            rows([record, clear], &p),
            &p,
        ))
        .child(section(
            "Quota display",
            "Applies to the tray, its popup and the Accounts page.",
            rows([display], &p),
            &p,
        ))
        .into_any_element()
    }

    /// Percentages and the tray icon follow these preferences; rebuild them.
    fn redraw_quota(&mut self, cx: &mut Context<Self>) {
        self.store.update(cx, |store, cx| store.rebuild(cx));
        cx.notify();
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
