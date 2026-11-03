//! About page, from the Wonder artboard "Page - Quotio About And Updates". The
//! desktop preview has no self-updater, so Updates points to the releases page.
use gpui_kit::assets::IconName;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::notification::Notification;
use gpui_kit::{
    AnyElement, BoxShadow, ClipboardItem, Context, FontWeight, InteractiveElement, IntoElement,
    ParentElement, SharedString, StatefulInteractiveElement as _, Styled, div, linear_color_stop,
    linear_gradient, point, px, rgb, rgba,
};

use super::SettingsWindow;
use super::widgets::{row, rows, section, tray_name};
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
            .gap(px(20.))
            .pb(px(24.))
            .border_b_1()
            .border_color(p.stroke_soft)
            .child(
                div()
                    .size(px(72.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(18.))
                    .bg(linear_gradient(
                        145.,
                        linear_color_stop(rgb(0x2a2a2a), 0.),
                        linear_color_stop(rgb(0x0b0b0b), 1.),
                    ))
                    .shadow(vec![BoxShadow {
                        color: rgba(0x0e121b73).into(),
                        offset: point(px(0.), px(8.)),
                        blur_radius: px(20.),
                        spread_radius: px(-6.),
                        inset: false,
                    }])
                    .child(
                        div()
                            .size(px(33.))
                            .rounded_full()
                            .border(px(5.))
                            .border_color(p.primary),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
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
                            .text_size(px(14.))
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
                            .text_size(px(12.))
                            .text_color(p.text_soft)
                            .child(format!(
                                "Quota for every AI coding tool, in your {}.",
                                tray_name()
                            )),
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
                IconName::Github,
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
            .child(section("Project", "Quotio is open source.", links, &p).border_b_0())
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
    // The design's pink sponsor card; dark mode keeps the neutral card.
    let sponsor = glyph == IconName::Heart && !p.dark;
    let (bg, border, tint) = if sponsor {
        (
            rgb(0xfff0f3).into(),
            rgb(0xffd6de).into(),
            rgb(0xe5484d).into(),
        )
    } else {
        (p.bg_white, p.stroke_soft, p.text_strong)
    };
    let hover = if sponsor { bg } else { p.bg_weak };
    div()
        .id(SharedString::from(title))
        .flex_1()
        .flex()
        .flex_col()
        .gap(px(12.))
        .p(px(14.))
        .rounded(px(16.))
        .bg(bg)
        .border_1()
        .border_color(border)
        .cursor_pointer()
        .hover(move |s| s.bg(hover))
        .child(
            div()
                .flex()
                .justify_between()
                .child(icon(glyph, 20., tint))
                .child(icon(IconName::ArrowUpRight, 16., p.text_soft)),
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
