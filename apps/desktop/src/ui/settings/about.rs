//! About page, from the Wonder artboard "Page - Quotio About And Updates". The
//! Windows and Linux builds update themselves; elsewhere Updates points to the
//! releases page.
use gpui_kit::assets::IconName;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::notification::Notification;
use gpui_kit::{
    AnyElement, BoxShadow, ClipboardItem, Context, Div, FontWeight, InteractiveElement,
    IntoElement, ParentElement, SharedString, StatefulInteractiveElement as _, Styled, div,
    linear_color_stop, linear_gradient, point, prelude::FluentBuilder as _, px, rgb, rgba,
};

use super::SettingsWindow;
use super::widgets::{row, rows, section, toggle, tray_name};
use crate::prefs;
use crate::theme::{Palette, palette};
use crate::ui::{ButtonKind, button, button_with_icon, icon};
use crate::updater::{self, State};

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

        let (updates_help, updates) = if updater::ASSET.is_some() {
            self.updates(&p, cx)
        } else {
            let releases = row(
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
            (
                "Desktop builds don’t update themselves yet.".into(),
                rows([releases], &p),
            )
        };

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
            .child(section("Updates", updates_help, updates, &p))
            .child(section("Project", "Quotio is open source.", links, &p).border_b_0())
            .into_any_element()
    }
}

impl SettingsWindow {
    /// The self-updating builds' card for a ready update and the auto-check row.
    fn updates(&self, p: &Palette, cx: &mut Context<Self>) -> (SharedString, Div) {
        let state = updater::state(cx).clone();
        let help: SharedString = match &state {
            State::Checking => "Checking GitHub releases…".into(),
            State::Installing => "Downloading and verifying the update…".into(),
            State::Failed(error) => error.clone().into(),
            _ => match updater::checked(cx) {
                Some(at) if at.date_naive() == chrono::Local::now().date_naive() => {
                    format!("Last checked today at {}.", at.format("%H:%M")).into()
                }
                Some(at) => format!("Last checked {}.", at.format("%b %-d at %H:%M")).into(),
                None => "Quotio installs signed builds from GitHub releases.".into(),
            },
        };
        let busy = matches!(state, State::Checking | State::Installing);
        let auto = !prefs::get(cx).manual_updates;
        let check_now = div()
            .id("check-updates")
            .flex()
            .items_center()
            .gap(px(4.))
            .text_size(px(14.))
            .font_weight(FontWeight::MEDIUM)
            .text_color(p.text_sub)
            .child(icon(IconName::RefreshCw, 14., p.text_sub))
            .child("Check now")
            .map(|s| {
                if busy {
                    s.opacity(0.5)
                } else {
                    s.cursor_pointer()
                        .hover(|s| s.text_color(p.text_strong))
                        .on_click(|_, _, cx| updater::check(cx))
                }
            });
        let auto_row = div()
            .flex()
            .items_center()
            .gap(px(16.))
            .py(px(12.))
            .child(
                div()
                    .flex_1()
                    .text_size(px(14.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_strong)
                    .child("Check for updates automatically"),
            )
            .child(check_now)
            .child(toggle("auto-updates", auto, true, p, |on, _, cx| {
                let on = *on;
                prefs::update(cx, |prefs| prefs.manual_updates = !on);
                cx.refresh_windows();
            }));
        let content = div()
            .flex()
            .flex_col()
            .gap(px(4.))
            .when_some(
                match state {
                    State::Available(release) => Some(release),
                    _ => None,
                },
                |s, release| s.child(ready_card(release, p)),
            )
            .child(auto_row);
        (help, content)
    }
}

/// "Quotio 2.5.0 is ready" with its size, release notes and install button.
fn ready_card(release: updater::Release, p: &Palette) -> impl IntoElement {
    let size = format!("{:.0} MB", release.size as f64 / 1_000_000.);
    div()
        .flex()
        .flex_col()
        .gap(px(12.))
        .p(px(16.))
        .rounded(px(16.))
        .border_1()
        .border_color(p.stroke_soft)
        .bg(if p.dark {
            linear_gradient(
                180.,
                linear_color_stop(p.bg_weak, 0.),
                linear_color_stop(p.bg_white, 0.7),
            )
        } else {
            linear_gradient(
                180.,
                linear_color_stop(rgb(0xf3f6ff), 0.),
                linear_color_stop(rgb(0xffffff), 0.7),
            )
        })
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(12.))
                .child(
                    div()
                        .size(px(32.))
                        .flex_none()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(10.))
                        .bg(p.info)
                        .child(icon(IconName::Sparkles, 16., rgb(0xffffff).into())),
                )
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .flex_1()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(px(14.))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(p.text_strong)
                                .child(format!("Quotio {} is ready", release.version)),
                        )
                        .child(
                            div()
                                .text_size(px(12.))
                                .text_color(p.text_sub)
                                .child(format!("{size} · Quotio relaunches to finish")),
                        ),
                )
                .child({
                    let release = release.clone();
                    button(
                        "install-update",
                        "Install & relaunch",
                        ButtonKind::Primary,
                        p,
                    )
                    .on_click(move |_, _, cx| updater::install(release.clone(), cx))
                }),
        )
        .when(!release.notes.is_empty(), |s| {
            s.child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(6.))
                    .pl(px(44.))
                    .text_size(px(13.))
                    .text_color(p.text_sub)
                    .children(release.notes.iter().map(|note| format!("• {note}"))),
            )
        })
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
