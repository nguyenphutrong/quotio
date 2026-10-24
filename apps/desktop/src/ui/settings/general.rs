//! General page, built from the Wonder artboard "Page - Quotio Settings General".
//! Show in Dock is left out until macOS has a menu bar item to fall back on, and
//! Language until the app is localized. "Show guide" opens the add-account dialog.
use gpui_kit::assets::IconName;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::notification::Notification;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement, IntoElement, ParentElement,
    StatefulInteractiveElement as _, Styled, Window, div, prelude::FluentBuilder as _, px, rgb,
};
use serde_json::{Value, json};
use time::OffsetDateTime;

use super::SettingsWindow;
use super::connect::scan_summary;
use super::widgets::{page, row, rows, section, select, this_computer, toggle, tray_name};
use crate::host::Method;
use crate::model::ago_phrase;
use crate::theme::{Appearance, Palette, palette};
use crate::ui::{ButtonKind, button_with_icon, icon};
use crate::{autostart, prefs, theme};

/// Seconds between scheduled refreshes; zero refreshes only on request.
const INTERVALS: [(u64, &str); 6] = [
    (0, "Manual"),
    (60, "Every minute"),
    (120, "Every 2 minutes"),
    (300, "Every 5 minutes"),
    (600, "Every 10 minutes"),
    (900, "Every 15 minutes"),
];

impl SettingsWindow {
    pub(super) fn general_page(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let settings = self.host_settings.clone();
        let fixed = |name: &str| {
            settings.as_ref().is_none_or(|s| {
                s["overridden"]
                    .as_array()
                    .is_some_and(|o| o.iter().any(|v| v == name))
            })
        };

        let launch = row(
            "Launch at login",
            Some(
                format!(
                    "Start Quotio quietly in the {} when you {}.",
                    tray_name(),
                    if cfg!(target_os = "macos") {
                        "log in"
                    } else {
                        "sign in"
                    }
                )
                .into(),
            ),
            toggle(
                "launch-at-login",
                self.launch_at_login,
                cfg!(any(target_os = "linux", target_os = "macos", windows)),
                &p,
                cx.listener(|this, on: &bool, window, cx| {
                    if let Err(error) = autostart::set(*on) {
                        window.push_notification(
                            Notification::error(format!(
                                "Couldn’t change launch at login: {error:#}."
                            )),
                            cx,
                        );
                    }
                    this.launch_at_login = autostart::enabled();
                    cx.notify();
                }),
            ),
            &p,
        );

        let interval = settings
            .as_ref()
            .and_then(|s| s["refresh_interval"].as_u64())
            .unwrap_or(60);
        let mut options: Vec<(u64, String)> = INTERVALS
            .iter()
            .map(|(seconds, label)| (*seconds, (*label).to_owned()))
            .collect();
        // A value set in the config file by hand still shows as itself.
        if !options.iter().any(|(seconds, _)| *seconds == interval) {
            options.push((interval, format!("Every {interval} seconds")));
        }
        let refresh_fixed = fixed("refresh_interval");
        let auto_refresh = row(
            "Auto-refresh",
            Some(if refresh_fixed && settings.is_some() {
                "Set by a command-line option.".into()
            } else {
                "Choose Manual to refresh only when you ask.".into()
            }),
            select(
                "refresh-interval",
                options,
                &interval,
                !refresh_fixed,
                cx.listener(|this, seconds: &u64, window, cx| {
                    this.patch_settings(json!({ "refresh_interval": seconds }), window, cx)
                }),
            ),
            &p,
        );

        let discover = settings
            .as_ref()
            .and_then(|s| s["automatically_discover_logins"].as_bool())
            .unwrap_or(true);
        let detect = row(
            "Detect logins on launch",
            Some("Finds Claude, Codex, Gemini and other CLI logins automatically.".into()),
            toggle(
                "detect-logins",
                discover,
                settings.is_some(),
                &p,
                cx.listener(|this, on: &bool, window, cx| {
                    this.patch_settings(json!({ "automatically_discover_logins": on }), window, cx)
                }),
            ),
            &p,
        );

        let scan = row(
            "Scan now",
            Some(self.last_scan().into()),
            button_with_icon(
                "scan-all",
                IconName::Search,
                if self.scanning {
                    "Scanning…"
                } else {
                    "Scan all providers"
                },
                ButtonKind::Secondary,
                &p,
            )
            .when(self.scanning, |s| s.opacity(0.5))
            .on_click(cx.listener(|this, _, window, cx| this.scan_all(window, cx))),
            &p,
        );

        page(
            "General",
            "Startup, appearance and how often quota refreshes.",
            &p,
        )
        .child(section(
            "Startup",
            format!(
                "How Quotio starts and where it lives on {}.",
                this_computer()
            ),
            rows([launch], &p),
            &p,
        ))
        .child(section(
            "Appearance",
            format!("System follows {}’s appearance.", this_computer()),
            self.theme_options(&p, cx),
            &p,
        ))
        .child(section(
            "Refresh & logins",
            format!(
                "How often quota updates, and whether Quotio looks for logins already on {}.",
                this_computer()
            ),
            rows([auto_refresh, detect, scan], &p),
            &p,
        ))
        .child(welcome_guide(&p, cx))
        .into_any_element()
    }

    fn theme_options(&self, p: &Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let chosen = prefs::get(cx).appearance;
        let option = |appearance: Appearance, glyph: IconName, name: &'static str| {
            let selected = appearance == chosen;
            let preview = div().h(px(72.)).rounded(px(10.)).overflow_hidden().flex();
            // Fixed colors: each preview shows its theme whatever the current one is.
            let preview = match appearance {
                Appearance::System => preview
                    .child(div().flex_1().bg(rgb(0xf7f7f7)))
                    .child(div().flex_1().bg(rgb(0x171717))),
                Appearance::Light => preview.bg(rgb(0xf7f7f7)),
                Appearance::Dark => preview.bg(rgb(0x171717)),
            };
            let label = if selected { p.text_strong } else { p.text_sub };
            div()
                .id(name)
                .flex_1()
                .flex()
                .flex_col()
                .gap(px(8.))
                .p(px(6.))
                .border_2()
                .border_color(if selected { p.primary } else { p.stroke_soft })
                .rounded(px(14.))
                .cursor_pointer()
                .child(preview.border_1().border_color(p.stroke_soft))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .px(px(4.))
                        .pb(px(2.))
                        .text_size(px(14.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(label)
                        .child(icon(glyph, 15., label))
                        .child(name),
                )
                .on_click(cx.listener(move |_, _, window, cx| {
                    prefs::update(cx, |prefs| prefs.appearance = appearance);
                    theme::apply(appearance, window.appearance(), cx);
                }))
        };
        div()
            .flex()
            .gap(px(12.))
            .child(option(Appearance::System, IconName::Monitor, "System"))
            .child(option(Appearance::Light, IconName::Sun, "Light"))
            .child(option(Appearance::Dark, IconName::Moon, "Dark"))
    }

    /// "Last scan found 4 logins · 10 min ago", from `GET /v2/discovery`.
    fn last_scan(&self) -> String {
        let Some(report) = &self.discovery else {
            return "Look for logins from provider apps and CLIs.".into();
        };
        let last = report["scans"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|scan| scan["at"].as_str())
            .filter_map(|at| {
                OffsetDateTime::parse(at, &time::format_description::well_known::Rfc3339).ok()
            })
            .max();
        let Some(last) = last else {
            return "Quotio has not looked for logins yet.".into();
        };
        let found = report["known_sources"].as_array().map_or(0, Vec::len);
        let logins = if found == 1 { "login" } else { "logins" };
        format!(
            "Last scan found {found} {logins} · {}",
            ago_phrase(OffsetDateTime::now_utc() - last)
        )
    }

    /// Look for logins of every tracked provider, including ones removed before.
    fn scan_all(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.scanning {
            return;
        }
        self.scanning = true;
        cx.notify();
        let work = self.store.read(cx).host().mutate(
            Method::POST,
            "/v2/discovery".into(),
            Some(json!({ "providers": [], "restore_removed": true })),
        );
        cx.spawn_in(window, async move |this, cx| {
            let result: anyhow::Result<Value> = work.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.scanning = false;
                this.store.update(cx, |store, cx| store.reload(cx));
                this.load_host_settings(cx);
                let notification = match result {
                    Ok(report) => Notification::success(scan_summary(&report)),
                    Err(error) => {
                        Notification::error(format!("Couldn’t scan for logins: {error:#}."))
                    }
                };
                window.push_notification(notification, cx);
                cx.notify();
            });
        })
        .detach();
    }
}

fn welcome_guide(p: &Palette, cx: &mut Context<SettingsWindow>) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap(px(12.))
        .px(px(16.))
        .py(px(12.))
        .rounded(px(16.))
        .bg(p.bg_weak)
        .child(
            div()
                .size(px(32.))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(10.))
                .bg(p.bg_white)
                .shadow_sm()
                .child(icon(IconName::BookOpen, 16., p.text_sub)),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(px(2.))
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_strong)
                        .child("Welcome guide"),
                )
                .child(
                    div()
                        .text_size(px(12.))
                        .text_color(p.text_sub)
                        .child("Walk through connecting providers and granting access again."),
                ),
        )
        .child(
            div()
                .id("show-guide")
                .flex_none()
                .text_size(px(14.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(p.text_strong)
                .underline()
                .cursor_pointer()
                .child("Show guide")
                .on_click(cx.listener(|this, _, window, cx| this.connect(None, window, cx))),
        )
}
