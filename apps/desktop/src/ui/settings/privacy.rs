//! Privacy page, from the Wonder artboard "Page - Quotio Settings Privacy". The
//! Keychain and YubiKey migration sections are macOS-only; this page lists the
//! logins Quotio reads from other apps instead.
use gpui_kit::assets::IconName;
use gpui_kit::{
    AnyElement, Context, FontWeight, IntoElement, ParentElement, Styled, div,
    prelude::FluentBuilder as _, px,
};
use quotio::contract::{ConnectionState, Source};

use super::SettingsWindow;
use super::widgets::{page, row, rows, section, toggle};
use crate::model::mask;
use crate::prefs;
use crate::providers;
use crate::theme::{Palette, palette};
use crate::ui::{icon, provider_logo};

impl SettingsWindow {
    pub(super) fn privacy_page(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let hide = prefs::get(cx).hide_names;
        let computer = if cfg!(windows) {
            "this PC"
        } else {
            "this computer"
        };

        let store = self.store.clone();
        let hide_row = row(
            "Hide account names",
            Some("Names and emails are masked everywhere. Click one on the Accounts page to show it for a moment.".into()),
            toggle("hide-names", hide, true, &p, move |on, _, cx| {
                let on = *on;
                prefs::update(cx, |prefs| prefs.hide_names = on);
                // The tray tooltip follows the store, not the windows.
                store.update(cx, |_, cx| cx.notify());
                cx.refresh_windows();
            }),
            &p,
        );
        let sample = "you@example.com";
        let preview = div()
            .flex()
            .items_center()
            .gap(px(10.))
            .mb(px(12.))
            .px(px(12.))
            .py(px(10.))
            .rounded(px(12.))
            .bg(p.bg_weak)
            .child(icon(IconName::CircleUser, 16., p.text_sub))
            .child(
                div()
                    .text_size(px(14.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_strong)
                    .child(if hide {
                        mask(sample)
                    } else {
                        sample.to_owned()
                    }),
            )
            .child(div().flex_1())
            .child(
                div()
                    .text_size(px(14.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(p.text_strong)
                    .child("74%"),
            );

        let sources = self.store.read(cx).borrowed_sources();
        let logins = if sources.is_empty() {
            div()
                .py(px(12.))
                .text_size(px(14.))
                .text_color(p.text_soft)
                .child("Quotio doesn’t read any logins from other apps yet.")
                .into_any_element()
        } else {
            rows(
                sources
                    .iter()
                    .map(|(provider, source)| login_row(provider, source, &p)),
                &p,
            )
            .into_any_element()
        };

        page(
            "Privacy",
            &format!(
                "Credentials never leave {computer}. Here’s what Quotio can read, and how to hide it on screen."
            ),
            &p,
        )
        .child(section(
            "On screen",
            "Useful when screen sharing or recording.",
            rows([hide_row, preview.into_any_element()], &p),
            &p,
        ))
        .child(section(
            "Logins Quotio can read",
            "Sign-ins that belong to other apps, such as a CLI. To stop reading one, remove its account on the Accounts page.",
            logins,
            &p,
        ))
        .into_any_element()
    }
}

fn login_row(provider: &str, source: &Source, p: &Palette) -> AnyElement {
    let allowed = source.state != ConnectionState::NeedsAuthorization;
    let detail = source
        .directory
        .as_deref()
        .map(home_relative)
        .or_else(|| source.keychain_account.clone())
        .or_else(|| source.location.clone())
        .unwrap_or_else(|| humanize(&source.kind));
    let (badge, fg, bg) = if allowed {
        ("Allowed", p.primary, p.bg_weak)
    } else {
        ("Needs access", p.error, p.error_alpha)
    };
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
                .bg(p.bg_weak)
                .child(provider_logo(provider, 16., None, p)),
        )
        .child(
            div().flex_1().min_w_0().child(row(
                providers::display_name(provider),
                Some(detail.into()),
                div()
                    .px(px(8.))
                    .py(px(2.))
                    .rounded(px(6.))
                    .bg(bg)
                    .text_size(px(12.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(fg)
                    .when(allowed, |s| s.border_1().border_color(p.stroke_soft))
                    .child(badge),
                p,
            )),
        )
        .into_any_element()
}

/// `/home/me/.codex-work` → `~/.codex-work`.
fn home_relative(path: &str) -> String {
    let home = directories::BaseDirs::new().map(|d| d.home_dir().display().to_string());
    match home.as_deref().and_then(|home| path.strip_prefix(home)) {
        Some(rest) if rest.is_empty() || rest.starts_with(['/', '\\']) => format!("~{rest}"),
        _ => path.to_owned(),
    }
}

/// `codex_native` → `Codex native`.
fn humanize(kind: &str) -> String {
    let words = kind.replace('_', " ");
    let mut chars = words.chars();
    chars
        .next()
        .map(|c| c.to_uppercase().chain(chars).collect())
        .unwrap_or_default()
}
