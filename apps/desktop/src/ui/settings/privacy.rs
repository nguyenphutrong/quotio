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
use crate::ui::{ButtonKind, button, icon, provider_logo};

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
        if let Some(migration) = migration_section(&p, cx) {
            sections.insert(0, migration);
        }
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

fn migration_section(p: &Palette, cx: &gpui_kit::App) -> Option<Div> {
    let migration = cx.global::<crate::migration::Migration>();
    let (bundle, source) = migration.source.as_ref()?;
    let prefs = prefs::get(cx);
    let choice = prefs
        .migration
        .choice
        .as_ref()
        .filter(|choice| choice.bundle == *bundle);
    let text = |text: String| div().text_size(px(13.)).text_color(p.text_sub).child(text);
    let mut content = div().flex().flex_col().gap(px(12.))
        .child(text(format!("Swift profile: {bundle}. Source: {}. Destination: the standalone CLI’s shared vault.", home_relative(&source.data_dir.display().to_string()))))
        .child(text("Quit Swift Quotio first. Existing destination labels and enabled states win; newer source credentials may replace older ones. Source credentials and history are retained; only a completion receipt is added. If both stores have paired devices, the destination identity and grants win: source devices may need pairing again.".into()))
        .child(text("Legacy Monitor/PIV accounts are not read by GPUI. Migrate them through the retained signed Swift app first, or sign in again. No proxy, sharing listener or login item is enabled by this choice.".into()));
    match choice {
        None => {
            content = content.child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap(px(8.))
                    .child(
                        button(
                            "migration-shared",
                            "Use shared vault only",
                            ButtonKind::Secondary,
                            p,
                        )
                        .on_click(|_, _, cx| crate::migration::choose(false, cx)),
                    )
                    .child(
                        button(
                            "migration-swift",
                            "Merge Swift vault & restart",
                            ButtonKind::Primary,
                            p,
                        )
                        .on_click(|_, _, cx| crate::migration::choose(true, cx)),
                    ),
            );
        }
        Some(choice) if !choice.include_isolated => {
            content = content.child(text(
                "Selected: shared vault only. The isolated Swift vault has not been imported."
                    .into(),
            ));
            content = content.child(
                button(
                    "migration-swift",
                    "Merge Swift vault & restart",
                    ButtonKind::Secondary,
                    p,
                )
                .on_click(|_, _, cx| crate::migration::choose(true, cx)),
            );
        }
        Some(_) => match source.receipt() {
            Ok(Some(receipt)) => {
                content = content.child(text(format!("Import completed {}. Last attempt: {} accounts added, {} refreshed, {} history rows. Source host: {}. Destination host: {}.", receipt.adopted_at, receipt.accounts_added, receipt.accounts_refreshed, receipt.history_rows, receipt.source_host.as_deref().unwrap_or("not recorded"), receipt.target_host.as_deref().unwrap_or("not recorded"))));
                if receipt.kept_target_pairing || receipt.schema_version == 1 {
                    content = content.child(text("Check paired devices. The destination pairing was retained, or this old receipt cannot report pairing. Pair source devices again if access fails.".into()));
                }
            }
            status => {
                let message = if status.is_err() {
                    "The completion receipt could not be read."
                } else {
                    "The import has not completed. Allow Keychain access (Always Allow for background reads)."
                };
                content = content.child(text(format!("{message} Some accounts may already be copied; retries do not duplicate them.")))
                    .child(button("migration-retry", "Retry on restart", ButtonKind::Secondary, p)
                        .on_click(|_, _, cx| crate::migration::choose(true, cx)));
            }
        },
    }
    if prefs.migration.pending_pins.is_some() {
        content = content.child(text("Menu-bar pins are waiting for your source choice and its accounts. Selecting pins on Accounts overrides this import.".into()));
    }
    if prefs.migration.pin_warning {
        content = content.child(text("Some pins could not be matched safely (remote hosts, old receipts or missing accounts). Review pins on Accounts; they were not guessed from colliding IDs.".into()));
    }
    content = content.child(text("Proxy import copies only the port, auth-directory reference and client API keys into a new local-only v8 config. Management credentials, binaries, routing and provider overrides are not copied. Auth files stay in their source directory; review custom settings before starting the proxy.".into()));
    if std::fs::symlink_metadata(crate::proxy::config_path()).is_ok() {
        content = content.child(text(
            "A GPUI proxy configuration already exists and will not be overwritten.".into(),
        ));
    } else {
        content = content.child(
            button(
                "migration-proxy",
                "Import Swift proxy settings",
                ButtonKind::Secondary,
                p,
            )
            .on_click(|_, _, cx| crate::migration::import_proxy(cx)),
        );
    }
    if let Some(error) = &migration.error {
        content = content.child(
            div()
                .text_size(px(13.))
                .text_color(p.error)
                .child(error.clone()),
        );
    }
    Some(section(
        "Move from Swift",
        "Choose which vault to use before reading the isolated Swift store. The choice is scoped to this exact bundle/profile.",
        content,
        p,
    ))
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
                        .font_family(crate::theme::MONO_FONT)
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
