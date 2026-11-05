//! CLIProxyAPI page: install, run and update the local proxy, as the macOS app's
//! CLIProxyAPI settings and version manager do.
use gpui_kit::assets::IconName;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::notification::Notification;
use gpui_kit::{
    AnyElement, ClipboardItem, Context, FontWeight, IntoElement, ParentElement,
    StatefulInteractiveElement as _, Styled, div, px,
};

use super::SettingsWindow;
use super::widgets::{page, row, row_with, rows, section, toggle};
use crate::proxy;
use crate::theme::{Palette, palette};
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
        .children(busy.map(|busy| status(IconName::LoaderCircle, &busy, p.text_sub, &p)))
        .children(error.map(|error| status(IconName::CircleAlert, &error, p.error, &p)));
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

    fn proxy_server(&self, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        let running = proxy::running(cx);
        let endpoint = proxy::endpoint(cx);
        let state = div()
            .text_size(px(12.))
            .text_color(if running { p.primary } else { p.text_sub })
            .child(if running { "Running" } else { "Stopped" });
        let toggle_run = if running {
            button_with_icon(
                "proxy-stop",
                IconName::Power,
                "Stop",
                ButtonKind::Secondary,
                p,
            )
            .on_click(|_, _, cx| proxy::stop(cx))
        } else {
            button_with_icon(
                "proxy-start",
                IconName::Play,
                "Start",
                ButtonKind::Primary,
                p,
            )
            .on_click(|_, _, cx| proxy::start(cx))
        };
        let controls = div()
            .flex()
            .gap(px(8.))
            .child(toggle_run)
            .children(running.then(|| {
                button_with_icon(
                    "proxy-restart",
                    IconName::RefreshCw,
                    "Restart",
                    ButtonKind::Secondary,
                    p,
                )
                .on_click(|_, _, cx| proxy::restart(cx))
            }));
        let copy_endpoint = endpoint.clone();
        let management = format!("{endpoint}/management.html");
        section(
            "Server",
            "Point your AI tools at this address.",
            rows(
                [
                    row_with("Status", Some(state), controls, p),
                    row(
                        "Endpoint",
                        Some(endpoint.into()),
                        copy_button("copy-endpoint", copy_endpoint, "Endpoint copied.", p),
                        p,
                    ),
                    row(
                        "Management dashboard",
                        Some("Sign in with the management key.".into()),
                        div()
                            .flex()
                            .gap(px(8.))
                            .child(
                                button_with_icon(
                                    "open-management",
                                    IconName::ExternalLink,
                                    "Open",
                                    ButtonKind::Secondary,
                                    p,
                                )
                                .on_click(move |_, _, cx| cx.open_url(&management)),
                            )
                            .child(copy_button(
                                "copy-key",
                                proxy::get(cx).key.clone(),
                                "Management key copied.",
                                p,
                            )),
                        p,
                    ),
                ],
                p,
            ),
            p,
        )
        .into_any_element()
    }

    fn proxy_configuration(&self, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        let auto_start = crate::prefs::get(cx).proxy.auto_start;
        let port = div()
            .flex()
            .gap(px(8.))
            .child(text_field(&self.proxy_port, p).w(px(100.)))
            .child(
                button("save-proxy-port", "Save", ButtonKind::Secondary, p).on_click(cx.listener(
                    |this, _, window, cx| {
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
                    },
                )),
            );
        section(
            "Configuration",
            "Changing the port restarts a running proxy.",
            rows(
                [
                    row("Port", None, port, p),
                    row(
                        "Start with Quotio",
                        Some("Run the proxy whenever Quotio opens.".into()),
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

    fn proxy_versions(&self, p: &Palette, cx: &mut Context<Self>) -> AnyElement {
        let state = proxy::get(cx);
        let active = crate::prefs::get(cx).proxy.version.clone();
        let installed = proxy::installed(cx);
        let update = match state.upgrade.clone() {
            Some(release) => button(
                "proxy-update",
                format!("Update to {}", release.version),
                ButtonKind::Primary,
                p,
            )
            .on_click(move |_, _, cx| proxy::install(release.clone(), cx)),
            None => button("proxy-check", "Check for updates", ButtonKind::Secondary, p)
                .on_click(|_, _, cx| proxy::check(cx)),
        };
        let mut items = vec![row(
            "Version",
            Some(active.clone().unwrap_or_else(|| "—".into()).into()),
            update,
            p,
        )];
        items.extend(
            installed
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
                }),
        );
        match &state.releases {
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
        section(
            "Versions",
            "Quotio keeps the three newest installed versions.",
            rows(items, p),
            p,
        )
        .border_b_0()
        .into_any_element()
    }
}

fn status(glyph: IconName, text: &str, color: gpui_kit::Hsla, p: &Palette) -> AnyElement {
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

fn copy_button(
    id: &'static str,
    value: String,
    done: &'static str,
    p: &Palette,
) -> impl IntoElement {
    button_with_icon(id, IconName::Copy, "Copy", ButtonKind::Secondary, p).on_click(
        move |_, window, cx| {
            cx.write_to_clipboard(ClipboardItem::new_string(value.clone()));
            window.push_notification(Notification::info(done), cx);
        },
    )
}
