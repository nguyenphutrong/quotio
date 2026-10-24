//! About page, from the Wonder artboard "Page - Quotio About And Updates". The
//! desktop preview has no self-updater, so Updates points to the releases page.
use gpui_kit::assets::IconName;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::notification::Notification;
use gpui_kit::{
    AnyElement, ClipboardItem, Context, FontWeight, InteractiveElement, IntoElement, ParentElement,
    SharedString, StatefulInteractiveElement as _, Styled, div, px,
};

use super::SettingsWindow;
use super::widgets::{row, rows, section};
use crate::theme::{Palette, palette};
use crate::ui::{ButtonKind, button_with_icon, icon};

const REPOSITORY: &str = "https://github.com/nguyenphutrong/quotio";
const RELEASES: &str = "https://github.com/nguyenphutrong/quotio/releases";
const PROXY: &str = "https://github.com/router-for-me/CLIProxyAPI";
const SPONSORS: &str = "https://www.quotio.dev/sponsors";

impl SettingsWindow {
    pub(super) fn about_page(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let version = env!("CARGO_PKG_VERSION");
        let hero = div()
            .flex()
            .items_center()
            .gap(px(16.))
            .pb(px(24.))
            .border_b_1()
            .border_color(p.stroke_soft)
            .child(
                div()
                    .size(px(64.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(16.))
                    .bg(p.text_strong)
                    .text_size(px(28.))
                    .font_weight(FontWeight::BOLD)
                    .text_color(p.on_strong)
                    .child("Q"),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .child(
                        div()
                            .text_size(px(20.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(p.text_strong)
                            .child("Quotio"),
                    )
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .text_size(px(13.))
                            .text_color(p.text_sub)
                            .child(format!("Version {version} · desktop preview"))
                            .child(
                                div()
                                    .id("copy-version")
                                    .cursor_pointer()
                                    .child(icon(IconName::Copy, 13., p.text_soft))
                                    .on_click(move |_, window, cx| {
                                        cx.write_to_clipboard(ClipboardItem::new_string(
                                            version.to_owned(),
                                        ));
                                        window.push_notification(
                                            Notification::info("Version copied."),
                                            cx,
                                        );
                                    }),
                            ),
                    )
                    .child(
                        div()
                            .text_size(px(13.))
                            .text_color(p.text_soft)
                            .child("Quota for every AI coding tool, in your tray."),
                    ),
            );

        let updates = row(
            "Latest release",
            Some("See what’s new and download the newest build.".into()),
            button_with_icon(
                "releases",
                IconName::ExternalLink,
                "Open releases",
                ButtonKind::Secondary,
                &p,
            )
            .on_click(|_, _, cx| cx.open_url(RELEASES)),
            &p,
        );

        let links = div()
            .flex()
            .gap(px(12.))
            .child(link_card(
                "Quotio",
                "Source and issues",
                IconName::Github,
                REPOSITORY,
                &p,
            ))
            .child(link_card(
                "CLIProxyAPI",
                "The local proxy",
                IconName::Globe,
                PROXY,
                &p,
            ))
            .child(link_card(
                "Support Quotio",
                "Sponsor development",
                IconName::Heart,
                SPONSORS,
                &p,
            ));

        div()
            .flex()
            .flex_col()
            .gap(px(24.))
            .child(hero)
            .child(section(
                "Updates",
                "Desktop builds don’t update themselves yet.",
                rows([updates], &p),
                &p,
            ))
            .child(section("Project", "Quotio is open source.", links, &p))
            .into_any_element()
    }
}

fn link_card(
    title: &'static str,
    help: &'static str,
    glyph: IconName,
    url: &'static str,
    p: &Palette,
) -> impl IntoElement {
    div()
        .id(SharedString::from(title))
        .flex_1()
        .flex()
        .flex_col()
        .gap(px(10.))
        .p(px(14.))
        .rounded(px(14.))
        .border_1()
        .border_color(p.stroke_soft)
        .cursor_pointer()
        .hover(|s| s.bg(p.bg_weak))
        .child(
            div()
                .flex()
                .justify_between()
                .child(icon(glyph, 18., p.text_strong))
                .child(icon(IconName::ExternalLink, 14., p.text_soft)),
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
                        .child(title),
                )
                .child(div().text_size(px(12.)).text_color(p.text_sub).child(help)),
        )
        .on_click(move |_, _, cx| cx.open_url(url))
}
