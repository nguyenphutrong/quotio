//! Privacy page, from the Sheet frame "qt-sun". On macOS, logins kept in the
//! Keychain get a section of their own. The YubiKey credential migration is left
//! out: the host can only migrate credentials the old macOS app hands it.
use gpui_kit::assets::IconName;
use gpui_kit::{
    AnyElement, Context, Div, FontWeight, InteractiveElement, IntoElement, ParentElement,
    StatefulInteractiveElement as _, Styled, div, prelude::FluentBuilder as _, px,
};
use quotio::contract::{ConnectionState, Source};

use super::SettingsWindow;
use super::widgets::{page, row, section, this_computer, toggle};
use crate::model::mask;
use crate::prefs;
use crate::providers;
use crate::theme::{Palette, palette};
use crate::ui::{icon, provider_logo};

impl SettingsWindow {
    pub(super) fn privacy_page(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let hide = prefs::get(cx).hide_names;

        let store = self.store.clone();
        let hide_row = row(
            "Hide account names",
            Some("Names are masked everywhere. Click one on the Accounts page to reveal it for a moment.".into()),
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
            .gap(px(12.))
            .px(px(12.))
            .py(px(10.))
            .rounded(px(12.))
            .bg(p.bg_weak)
            .child(provider_logo("claude", 14., providers::tint("claude"), &p))
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

        let macos = cfg!(target_os = "macos");
        let (keychain, others): (Vec<_>, Vec<_>) = self
            .store
            .read(cx)
            .borrowed_sources()
            .into_iter()
            .partition(|(_, source)| {
                macos
                    && (source.keychain_account.is_some()
                        || source
                            .location
                            .as_deref()
                            .is_some_and(|l| l.ends_with("_keychain")))
            });

        let mut sections = vec![section(
            "On screen",
            "Useful when screen sharing or recording.",
            div().flex().flex_col().child(hide_row).child(preview),
            &p,
        )];
        if macos {
            let open = div()
                .id("open-keychain-access")
                .flex()
                .items_center()
                .gap(px(6.))
                .cursor_pointer()
                .text_size(px(14.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(p.text_sub)
                .child("Open Keychain Access")
                .child(icon(IconName::ExternalLink, 14., p.text_sub))
                .on_click(|_, _, _| {
                    let _ = std::process::Command::new("open")
                        .args(["-a", "Keychain Access"])
                        .spawn();
                });
            sections.push(section(
                "Keychain access",
                "Logins you allowed Quotio to read. To revoke, change the item’s Access Control in Keychain Access.",
                div()
                    .flex()
                    .flex_col()
                    .gap(px(12.))
                    .child(logins(&keychain, "Quotio doesn’t read any Keychain items yet.", &p))
                    .child(open),
                &p,
            ));
        }
        if !macos || !others.is_empty() {
            sections.push(section(
                "Logins Quotio can read",
                "Sign-ins that belong to other apps, such as a CLI. To stop reading one, remove its account on the Accounts page.",
                logins(&others, "Quotio doesn’t read any logins from other apps yet.", &p),
                &p,
            ));
        }
        if let Some(last) = sections.pop() {
            sections.push(last.border_b_0());
        }

        page(
            "Privacy",
            &format!(
                "Credentials never leave {}. Here’s what Quotio can read, and how to hide it on screen.",
                this_computer()
            ),
            &p,
        )
        .children(sections)
        .into_any_element()
    }
}

/// A card of login rows separated by hairlines, or `empty` when there are none.
fn logins(sources: &[(String, Source)], empty: &'static str, p: &Palette) -> Div {
    if sources.is_empty() {
        return div()
            .py(px(12.))
            .text_size(px(14.))
            .text_color(p.text_soft)
            .child(empty);
    }
    div()
        .flex()
        .flex_col()
        .rounded(px(16.))
        .border_1()
        .border_color(p.stroke_soft)
        .children(sources.iter().enumerate().map(|(i, (provider, source))| {
            login_row(provider, source, p)
                .when(i > 0, |s| s.border_t_1().border_color(p.stroke_soft))
        }))
}

fn login_row(provider: &str, source: &Source, p: &Palette) -> Div {
    let allowed = source.state != ConnectionState::NeedsAuthorization;
    let detail = source
        .directory
        .as_deref()
        .map(home_relative)
        .or_else(|| source.keychain_account.clone())
        .or_else(|| source.location.clone())
        .unwrap_or_else(|| humanize(&source.kind));
    let (glyph, badge, fg) = if allowed {
        (IconName::CircleCheck, "Allowed", p.primary)
    } else {
        (IconName::CircleAlert, "Needs access", p.error)
    };
    div()
        .flex()
        .items_center()
        .gap(px(12.))
        .px(px(16.))
        .py(px(12.))
        .child(
            div()
                .size(px(32.))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(10.))
                .bg(p.bg_weak)
                .child(provider_logo(provider, 15., providers::tint(provider), p)),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .flex_1()
                .min_w_0()
                .gap(px(2.))
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_strong)
                        .child(providers::display_name(provider)),
                )
                .child(
                    div()
                        .truncate()
                        .font_family(if cfg!(target_os = "macos") {
                            "Menlo"
                        } else if cfg!(windows) {
                            "Consolas"
                        } else {
                            "monospace"
                        })
                        .text_size(px(12.))
                        .text_color(p.text_sub)
                        .child(detail),
                ),
        )
        .child(
            div()
                .flex_none()
                .flex()
                .items_center()
                .gap(px(4.))
                .text_size(px(12.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(fg)
                .child(icon(glyph, 14., fg))
                .child(badge),
        )
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
