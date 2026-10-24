//! CLIProxyAPI page. The macOS app downloads, runs and updates the proxy; the
//! desktop preview does not manage it yet, so this page says so and links to it.
use gpui_kit::assets::IconName;
use gpui_kit::{
    AnyElement, Context, FontWeight, IntoElement, ParentElement, StatefulInteractiveElement as _,
    Styled, div, px,
};

use super::SettingsWindow;
use super::widgets::{page, row, rows, section};
use crate::theme::palette;
use crate::ui::{ButtonKind, button_with_icon, icon};

impl SettingsWindow {
    pub(super) fn cli_proxy_page(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let system = if cfg!(target_os = "macos") {
            "macOS"
        } else if cfg!(windows) {
            "Windows"
        } else {
            "Linux"
        };
        let status = div()
            .flex()
            .items_center()
            .gap(px(12.))
            .p(px(16.))
            .rounded(px(16.))
            .bg(p.bg_weak)
            .child(
                div()
                    .size(px(36.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(10.))
                    .bg(p.bg_white)
                    .shadow(p.raised())
                    .child(icon(IconName::Info, 18., p.text_sub)),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(px(14.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(p.text_strong)
                            .child(format!("Quotio doesn’t run the proxy on {system} yet")),
                    )
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(p.text_sub)
                            .child(
                                "The Quotio macOS app can start, stop and update CLIProxyAPI for you. Here, run it yourself if your tools need it.",
                            ),
                    ),
            );
        let project = row(
            "CLIProxyAPI on GitHub",
            Some("Downloads, setup and the management dashboard.".into()),
            button_with_icon(
                "open-proxy",
                IconName::ExternalLink,
                "Open",
                ButtonKind::Secondary,
                &p,
            )
            .on_click(|_, _, cx| cx.open_url("https://github.com/router-for-me/CLIProxyAPI")),
            &p,
        );
        page(
            "CLIProxyAPI",
            "An optional local proxy for your AI tools. Quota monitoring works without it.",
            &p,
        )
        .child(status)
        .child(
            section(
                "Run it yourself",
                "Quota for accounts you add in Quotio keeps working either way.",
                rows([project], &p),
                &p,
            )
            .border_b_0(),
        )
        .into_any_element()
    }
}
