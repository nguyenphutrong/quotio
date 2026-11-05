//! CLIProxyAPI page, from the Wonder "Page - Quotio CLIProxyAPI" artboard: a server
//! card, configuration rows and the version card, plus the install, error and
//! version-list states the artboard leaves out.
use std::time::Duration;

use gpui_kit::assets::IconName;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::notification::Notification;
use gpui_kit::{
    AnyElement, ClipboardItem, Context, Div, FontWeight, Hsla, InteractiveElement, IntoElement,
    ParentElement, SharedString, StatefulInteractiveElement as _, Styled, div,
    prelude::FluentBuilder as _, px,
};

use super::SettingsWindow;
use super::widgets::{page, row, rows, section, toggle};
use crate::proxy;
use crate::theme::{MONO_FONT, Palette, palette};
use crate::ui::{ButtonKind, button, button_with_icon, icon, note, text_field};

impl SettingsWindow {
    pub(super) fn cli_proxy_page(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let state = proxy::get(cx);
        let (busy, error) = (state.busy.clone(), state.error.clone());
        let page = page(
            "CLIProxyAPI",
            "An optional local proxy for your AI tools. Quota monitoring works without it.",
            &p,
        )
        .children(busy.map(|busy| banner(IconName::LoaderCircle, &busy, p.text_sub, &p)))
        .children(error.map(|error| banner(IconName::CircleAlert, &error, p.error, &p)));
        if proxy::installed(cx).is_empty() {
            let install = button("install-proxy", "Install and run", ButtonKind::Primary, &p)
                .on_click(|_, _, cx| proxy::install_latest(cx));
            return page
                .child(
                    section(
                        "Not installed",
                        "Quotio downloads the latest release from GitHub and checks it before running it.",
                        rows(
                            [row(
                                "CLIProxyAPI",
                                Some("Routes your AI tools through the accounts you sign in to.".into()),
                                install,
                                &p,
                            )],
                            &p,
                        ),
                        &p,
                    )
                    .border_b_0(),
                )
                .into_any_element();
        }
        page.child(self.proxy_server(&p, cx))
            .child(self.proxy_configuration(&p, cx))
            .child(self.proxy_versions(&p, cx))
            .into_any_element()
    }

    /// Status, start/stop, and the endpoint row with the client key and dashboard.
    fn proxy_server(&self, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        let uptime = proxy::uptime(cx);
        let version = crate::prefs::get(cx)
            .proxy
            .version
            .clone()
            .unwrap_or_default();
        let (title, help) = match uptime {
            Some(uptime) => ("Running", format!("{} · v{version}", up(uptime))),
            None if proxy::restarting(cx) => ("Restarting…", format!("v{version}")),
            None => ("Stopped", format!("v{version}")),
        };
        let running = uptime.is_some();
        let badge = div()
            .size(px(40.))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(12.))
            .bg(if running {
                p.primary.opacity(0.1)
            } else {
                p.bg_weak
            })
            .child(
                div()
                    .size(px(10.))
                    .rounded_full()
                    .bg(if running { p.primary } else { p.text_soft })
                    .when(running, |s| {
                        s.shadow(vec![gpui_kit::BoxShadow {
                            color: p.primary.opacity(0.18),
                            offset: gpui_kit::point(px(0.), px(0.)),
                            blur_radius: px(0.),
                            spread_radius: px(4.),
                            inset: false,
                        }])
                    }),
            );
        let controls = if running {
            div()
                .flex()
                .gap(px(8.))
                .child(
                    button_with_icon(
                        "proxy-restart",
                        IconName::RotateCw,
                        "Restart",
                        ButtonKind::Secondary,
                        p,
                    )
                    .h(px(36.))
                    .on_click(|_, _, cx| proxy::restart(cx)),
                )
                .child(
                    button("proxy-stop", "Stop", ButtonKind::Secondary, p)
                        .h(px(36.))
                        .text_color(p.error)
                        .child(div().size(px(10.)).rounded(px(2.)).bg(p.error))
                        .flex_row_reverse()
                        .on_click(|_, _, cx| proxy::stop(cx)),
                )
        } else {
            div().child(
                button_with_icon(
                    "proxy-start",
                    IconName::Play,
                    "Start",
                    ButtonKind::Primary,
                    p,
                )
                .h(px(36.))
                .on_click(|_, _, cx| proxy::start(cx)),
            )
        };
        let status = div()
            .flex()
            .items_center()
            .gap(px(16.))
            .px(px(20.))
            .py(px(16.))
            .child(badge)
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(px(16.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(p.text_strong)
                            .child(title),
                    )
                    .child(div().text_size(px(12.)).text_color(p.text_sub).child(help)),
            )
            .child(controls);

        let endpoint = format!("{}/v1", proxy::endpoint(cx));
        let copy_endpoint = endpoint.clone();
        let dashboard = format!("{}/management.html", proxy::endpoint(cx));
        let management_key = proxy::get(cx).key.clone();
        let api_key = proxy::api_key();
        let endpoint_row = div()
            .flex()
            .items_center()
            .gap(px(12.))
            .px(px(20.))
            .py(px(14.))
            .border_t_1()
            .border_color(p.stroke_soft)
            .bg(p.bg_weak)
            .child(
                div()
                    .text_size(px(12.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_soft)
                    .child("ENDPOINT"),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .font_family(MONO_FONT)
                    .text_size(px(14.))
                    .text_color(p.text_strong)
                    .child(endpoint),
            )
            .child(
                div()
                    .id("copy-endpoint")
                    .size(px(32.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(9.))
                    .bg(p.bg_white)
                    .border_1()
                    .border_color(p.stroke_soft)
                    .cursor_pointer()
                    .hover(|s| s.opacity(0.85))
                    .child(icon(IconName::Copy, 14., p.text_sub))
                    .on_click(move |_, window, cx| {
                        copy(copy_endpoint.clone(), "Endpoint copied.", window, cx)
                    }),
            )
            .children(api_key.map(|key| {
                button_with_icon(
                    "copy-api-key",
                    IconName::KeyRound,
                    "Copy API key",
                    ButtonKind::Secondary,
                    p,
                )
                .on_click(move |_, window, cx| copy(key.clone(), "API key copied.", window, cx))
            }))
            .child(
                button("open-dashboard", "Open dashboard", ButtonKind::Primary, p)
                    .child(icon(IconName::ExternalLink, 14., p.on_strong))
                    .on_click(move |_, window, cx| {
                        // The dashboard asks for the management key; have it ready to paste.
                        copy(
                            management_key.clone(),
                            "Management key copied. Paste it to sign in.",
                            window,
                            cx,
                        );
                        cx.open_url(&dashboard);
                    }),
            );
        div()
            .flex()
            .flex_col()
            .rounded(px(16.))
            .border_1()
            .border_color(p.stroke_soft)
            .overflow_hidden()
            .child(status)
            .child(endpoint_row)
            .into_any_element()
    }

    fn proxy_configuration(&self, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        let saved = crate::prefs::get(cx).proxy.port;
        let auto_start = crate::prefs::get(cx).proxy.auto_start;
        let typed = self.proxy_port.read(cx).value().trim().to_owned();
        let save = if typed == saved.to_string() {
            div()
                .h(px(36.))
                .flex()
                .items_center()
                .px(px(12.))
                .rounded(px(10.))
                .bg(p.bg_weak)
                .text_size(px(14.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(p.text_soft.opacity(0.5))
                .child("Save")
                .into_any_element()
        } else {
            button("save-proxy-port", "Save", ButtonKind::Secondary, p)
                .h(px(36.))
                .on_click(cx.listener(|this, _, window, cx| {
                    match this.proxy_port.read(cx).value().trim().parse::<u16>() {
                        Ok(port) if port > 0 => {
                            crate::prefs::update(cx, |prefs| prefs.proxy.port = port);
                            if proxy::running(cx) {
                                proxy::restart(cx);
                            }
                            window.push_notification(
                                Notification::info(format!("CLIProxyAPI uses port {port}.")),
                                cx,
                            );
                        }
                        _ => window.push_notification(
                            Notification::error("Enter a port between 1 and 65535."),
                            cx,
                        ),
                    }
                    cx.notify();
                }))
                .into_any_element()
        };
        let port = div()
            .flex()
            .gap(px(8.))
            .child(
                text_field(&self.proxy_port, p)
                    .w(px(96.))
                    .font_family(MONO_FONT),
            )
            .child(save);
        section(
            "Configuration",
            "Changing the port restarts the proxy.",
            rows(
                [
                    row("Port", None, port, p),
                    row(
                        "Start with Quotio",
                        Some("Launch the proxy automatically when Quotio opens.".into()),
                        toggle("proxy-auto-start", auto_start, true, p, |on, _, cx| {
                            crate::prefs::update(cx, |prefs| prefs.proxy.auto_start = *on)
                        }),
                        p,
                    ),
                ],
                p,
            ),
            p,
        )
        .into_any_element()
    }

    /// The update card, then "Manage versions…", which lists installed and other
    /// releases in place; the artboard shows only the link.
    fn proxy_versions(&self, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        let state = proxy::get(cx);
        let active = crate::prefs::get(cx).proxy.version.clone();
        let current = format!("You’re on v{}.", active.clone().unwrap_or_default());
        let card = match state.upgrade.clone() {
            Some(release) => version_card(
                IconName::CircleArrowUp,
                p.primary,
                p.primary.opacity(0.1),
                format!("v{} is available", release.version),
                current,
                button("proxy-update", "Update", ButtonKind::Primary, p)
                    .on_click(move |_, _, cx| proxy::install(release.clone(), cx)),
                p,
            ),
            None => version_card(
                IconName::CircleCheck,
                p.text_sub,
                p.bg_weak,
                "CLIProxyAPI is up to date",
                current,
                button("proxy-check", "Check for updates", ButtonKind::Secondary, p)
                    .on_click(|_, _, cx| proxy::check(cx)),
                p,
            ),
        };
        let manage = div()
            .id("manage-versions")
            .flex()
            .items_center()
            .gap(px(6.))
            .cursor_pointer()
            .text_size(px(14.))
            .font_weight(FontWeight::MEDIUM)
            .text_color(p.text_sub)
            .child(icon(IconName::Layers, 15., p.text_sub))
            .child(if self.proxy_versions_open {
                "Hide versions"
            } else {
                "Manage versions…"
            })
            .on_click(cx.listener(|this, _, _, cx| {
                this.proxy_versions_open = !this.proxy_versions_open;
                cx.notify();
            }));
        let content = div()
            .flex()
            .flex_col()
            .gap(px(12.))
            .child(card)
            .child(div().flex().child(manage))
            .when(self.proxy_versions_open, |s| {
                s.child(rows(version_list(active, p, cx), p))
            });
        section(
            "Version",
            "Quotio keeps the three most recent versions so you can roll back.",
            content,
            p,
        )
        .border_b_0()
        .into_any_element()
    }
}

/// Installed versions besides the active one, then releases not yet installed.
fn version_list(
    active: Option<String>,
    p: &Palette,
    cx: &mut Context<SettingsWindow>,
) -> Vec<AnyElement> {
    let installed = proxy::installed(cx);
    let mut items: Vec<AnyElement> = installed
        .iter()
        .filter(|v| Some(*v) != active.as_ref())
        .map(|version| {
            let (activate, delete) = (version.clone(), version.clone());
            row(
                format!("v{version}"),
                Some("Installed".into()),
                div()
                    .flex()
                    .gap(px(8.))
                    .child(
                        button(
                            format!("activate-{version}"),
                            "Use",
                            ButtonKind::Secondary,
                            p,
                        )
                        .on_click(move |_, _, cx| proxy::activate(activate.clone(), cx)),
                    )
                    .child(
                        button_with_icon(
                            format!("delete-{version}"),
                            IconName::Trash,
                            "Delete",
                            ButtonKind::Danger,
                            p,
                        )
                        .on_click(move |_, _, cx| proxy::delete(&delete, cx)),
                    ),
                p,
            )
        })
        .collect();
    match &proxy::get(cx).releases {
        None => items.push(row(
            "Other versions",
            Some("Install an earlier or pre-release version.".into()),
            button("proxy-releases", "Show releases", ButtonKind::Secondary, p)
                .on_click(|_, _, cx| proxy::load_releases(cx)),
            p,
        )),
        Some(releases) => items.extend(
            releases
                .iter()
                .filter(|r| !installed.contains(&r.version.to_string()))
                .map(|release| {
                    let install = release.clone();
                    row(
                        format!("v{}", release.version),
                        Some(
                            if release.prerelease {
                                "Pre-release"
                            } else {
                                "Release"
                            }
                            .into(),
                        ),
                        button(
                            format!("install-{}", release.version),
                            "Install",
                            ButtonKind::Secondary,
                            p,
                        )
                        .on_click(move |_, _, cx| proxy::install(install.clone(), cx)),
                        p,
                    )
                }),
        ),
    }
    items
}

fn version_card(
    glyph: IconName,
    color: Hsla,
    bg: Hsla,
    title: impl Into<SharedString>,
    help: String,
    action: impl IntoElement,
    p: &Palette,
) -> Div {
    div()
        .flex()
        .items_center()
        .gap(px(12.))
        .px(px(16.))
        .py(px(12.))
        .rounded(px(16.))
        .bg(bg)
        .child(icon(glyph, 20., color))
        .child(
            div()
                .flex()
                .flex_col()
                .flex_1()
                .gap(px(2.))
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_strong)
                        .child(Into::<SharedString>::into(title)),
                )
                .child(div().text_size(px(12.)).text_color(p.text_sub).child(help)),
        )
        .child(action)
}

/// `Up 3 h 12 m`, as in the design's status line.
fn up(uptime: Duration) -> String {
    let minutes = uptime.as_secs() / 60;
    match (minutes / 60, minutes % 60) {
        (0, 0) => "Just started".into(),
        (0, m) => format!("Up {m} m"),
        (h, m) => format!("Up {h} h {m} m"),
    }
}

fn banner(glyph: IconName, text: &str, color: Hsla, p: &Palette) -> AnyElement {
    div()
        .flex()
        .items_center()
        .gap(px(8.))
        .p(px(12.))
        .rounded(px(12.))
        .bg(p.bg_weak)
        .child(icon(glyph, 16., color))
        .child(note(text.to_owned(), color).font_weight(FontWeight::MEDIUM))
        .into_any_element()
}

fn copy(value: String, done: &'static str, window: &mut gpui_kit::Window, cx: &mut gpui_kit::App) {
    cx.write_to_clipboard(ClipboardItem::new_string(value));
    window.push_notification(Notification::info(done), cx);
}
