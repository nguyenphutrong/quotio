//! Accounts page, built from the Wonder artboard "Page - Quotio Accounts".
use std::{cell::Cell, rc::Rc};

use futures::future::BoxFuture;
use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::notification::Notification;
use gpui_kit::component::{Sizable as _, WindowExt as _};
use gpui_kit::{
    Anchor, AnyElement, App, AppContext as _, Context, Entity, Focusable as _, FontWeight,
    InteractiveElement, IntoElement, ParentElement, SharedString, StatefulInteractiveElement,
    Styled, Window, div, prelude::FluentBuilder as _, px, rgb,
};
use serde_json::{Value, json};

use super::SettingsWindow;
use super::connect::{ConnectFlow, Connected};
use super::history::QuotaHistory;
use crate::host::{HostError, Method};
use crate::model::{AccountView, Fix, MetricView, Overview, ProviderGroup};
use crate::theme::{Palette, palette};
use crate::ui::{
    ButtonKind, button, button_with_icon, dialog_footer, field, icon, note, progress,
    provider_logo, shown_name, text_field, value_color,
};
use crate::{prefs, providers};

/// Groups and accounts that match the search: a provider name match keeps the
/// whole group, otherwise only accounts whose name matches stay.
pub(super) fn filter(overview: &Overview, query: &str) -> Vec<ProviderGroup> {
    let query = query.trim().to_lowercase();
    overview
        .groups
        .iter()
        .filter_map(|group| {
            if query.is_empty() || group.name.to_lowercase().contains(&query) {
                return Some(group.clone());
            }
            let accounts: Vec<AccountView> = group
                .accounts
                .iter()
                .filter(|a| a.name.to_lowercase().contains(&query))
                .cloned()
                .collect();
            (!accounts.is_empty()).then(|| ProviderGroup {
                accounts,
                ..group.clone()
            })
        })
        .collect()
}

impl SettingsWindow {
    pub(super) fn accounts_page(
        &self,
        overview: Option<&Overview>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = palette(cx).clone();
        let store = self.store.read(cx);
        let subtitle: SharedString = match (overview, &store.error) {
            (_, Some(error)) => format!("Host unavailable: {error}").into(),
            (Some(overview), None) => overview.status_line().into(),
            (None, None) => "Loading…".into(),
        };
        let refreshing = store.refreshing;
        let store_vault_locked = store.vault_locked;
        let query = self.search.read(cx).value().to_string();
        let header = div()
            .flex()
            .items_start()
            .gap(px(16.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .gap(px(4.))
                    .text_size(px(14.))
                    .font_weight(FontWeight::MEDIUM)
                    .child(div().text_color(p.text_strong).child("Accounts"))
                    .child(div().text_color(p.text_soft).child(subtitle)),
            )
            .child(
                div()
                    .w(px(200.))
                    .h(px(32.))
                    .flex()
                    .items_center()
                    .gap(px(2.))
                    .pl(px(10.))
                    .rounded(px(10.))
                    .bg(p.bg_weak)
                    .child(icon(IconName::Search, 16., p.text_soft))
                    .child(
                        Input::new(&self.search)
                            .appearance(false)
                            .cleanable(true)
                            .text_size(px(14.)),
                    ),
            )
            .child(
                button_with_icon(
                    "refresh",
                    IconName::RefreshCw,
                    "Refresh",
                    ButtonKind::Secondary,
                    &p,
                )
                .when(refreshing, |s| s.opacity(0.5))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.store.update(cx, |store, cx| store.refresh(None, cx));
                })),
            )
            .child(
                button_with_icon(
                    "add-account",
                    IconName::Plus,
                    "Add account",
                    ButtonKind::Primary,
                    &p,
                )
                .on_click(cx.listener(|this, _, window, cx| this.connect(None, window, cx))),
            );
        let attention: Vec<AnyElement> = overview
            .into_iter()
            .flat_map(|o| o.attention())
            .map(|(_, account, issue)| {
                let fix_id = SharedString::from(format!("fix-{}", account.id));
                let target = account.clone();
                let access = matches!(issue.fix, Fix::Authorize(_) | Fix::UnlockVault);
                div()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .px(px(12.))
                    .py(px(10.))
                    .rounded(px(12.))
                    .bg(p.bg_white)
                    .shadow(p.raised())
                    .child(
                        div()
                            .size(px(32.))
                            .flex_none()
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(8.))
                            .map(|s| {
                                if access {
                                    s.bg(p.bg_weak).child(icon(IconName::Lock, 16., p.text_sub))
                                } else {
                                    s.bg(p.error_alpha).child(alert_dot(p.error))
                                }
                            }),
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
                                    .font_weight(FontWeight::MEDIUM)
                                    .text_color(p.text_strong)
                                    .child(format!(
                                        "{} · {}",
                                        issue.title,
                                        shown_name(&account.name, cx)
                                    )),
                            )
                            .child(
                                div()
                                    .text_size(px(12.))
                                    .text_color(p.text_sub)
                                    .child(issue.detail.clone()),
                            ),
                    )
                    .child(
                        button(
                            fix_id,
                            issue.action.clone(),
                            if issue.fix == Fix::Retry {
                                ButtonKind::Secondary
                            } else {
                                ButtonKind::Primary
                            },
                            &p,
                        )
                        .when(self.busy.contains(&account.id), |s| s.opacity(0.5))
                        .on_click(
                            cx.listener(move |this, _, window, cx| this.fix(&target, window, cx)),
                        ),
                    )
                    .into_any_element()
            })
            .collect();
        let attention_count = attention.len();
        let vault_locked = store_vault_locked;
        let groups = overview.map(|o| filter(o, &query)).unwrap_or_default();
        let no_match = !query.trim().is_empty() && groups.is_empty();
        div()
            .flex()
            .flex_col()
            .gap(px(24.))
            .child(header)
            .when(vault_locked, |s| s.child(self.vault_banner(&p, cx)))
            .when(attention_count > 0, |s| {
                s.child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(4.))
                        .p(px(4.))
                        .rounded(px(16.))
                        .bg(p.bg_weak)
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(8.))
                                .pt(px(8.))
                                .pb(px(4.))
                                .px(px(12.))
                                .text_size(px(12.))
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(p.text_sub)
                                .child(alert_dot(p.away))
                                .child(match attention_count {
                                    1 => "1 thing needs your attention".to_owned(),
                                    n => format!("{n} things need your attention"),
                                }),
                        )
                        .children(attention),
                )
            })
            .when(no_match, |s| {
                s.child(
                    div()
                        .py(px(24.))
                        .flex()
                        .justify_center()
                        .text_size(px(14.))
                        .text_color(p.text_soft)
                        .child(format!(
                            "No provider or account matches “{}”.",
                            query.trim()
                        )),
                )
            })
            .child(
                div().flex().flex_col().gap(px(20.)).children(
                    groups
                        .iter()
                        .map(|group| self.provider_group(group, &p, cx)),
                ),
            )
            .child(
                div()
                    .id("connect-another")
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .px(px(16.))
                    .py(px(12.))
                    .rounded(px(16.))
                    .cursor_pointer()
                    .hover(|s| s.bg(p.bg_weak))
                    .on_click(cx.listener(|this, _, window, cx| this.connect(None, window, cx)))
                    .border_1()
                    .border_dashed()
                    .border_color(p.stroke_soft)
                    .child(icon(IconName::CirclePlus, 18., p.text_soft))
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
                                    .text_color(p.text_sub)
                                    .child("Connect another provider"),
                            )
                            .child(
                                div()
                                    .text_size(px(12.))
                                    .text_color(p.text_soft)
                                    .child(self.unconnected(overview)),
                            ),
                    )
                    .child(icon(IconName::ChevronRight, 18., p.text_soft)),
            )
            .into_any_element()
    }

    /// Open the add-account dialog, at `provider` when given.
    pub(super) fn connect(
        &mut self,
        provider: Option<&str>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let catalog = self.catalog.clone();
        let store = self.store.clone();
        let flow = cx.new(|cx| ConnectFlow::new(store, catalog, provider, window, cx));
        self.dialog_events = Some(cx.subscribe_in(
            &flow,
            window,
            |_, _, _: &Connected, window, cx| window.close_dialog(cx),
        ));
        let first = Cell::new(true);
        window.open_dialog(cx, move |dialog, window, cx| {
            if first.replace(false) {
                flow.update(cx, |flow, cx| flow.focus_search(window, cx));
            }
            let cancel = flow.clone();
            dialog
                .w(px(520.))
                .child(flow.clone())
                .on_close(move |_, _, cx| cancel.update(cx, |flow, cx| flow.cancel_session(cx)))
        });
    }

    /// The host stores accounts in an encrypted vault; until it opens, nothing loads.
    fn vault_banner(&self, p: &Palette, cx: &mut Context<Self>) -> impl IntoElement {
        let help = if cfg!(target_os = "linux") {
            "Quotio keeps sign-ins in your keyring. Unlock it, or set QUOTIO_VAULT_KEY_FILE."
        } else {
            "Quotio keeps sign-ins in Windows Credential Manager."
        };
        div()
            .flex()
            .items_center()
            .gap(px(12.))
            .px(px(12.))
            .py(px(10.))
            .rounded(px(12.))
            .bg(p.bg_white)
            .shadow(p.raised())
            .child(
                div()
                    .size(px(32.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(8.))
                    .bg(p.bg_weak)
                    .child(icon(IconName::KeyRound, 16., p.text_sub)),
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
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(p.text_strong)
                            .child("Allow Quotio to open its account store"),
                    )
                    .child(div().text_size(px(12.)).text_color(p.text_sub).child(help)),
            )
            .child(
                button("unlock-vault", "Grant access", ButtonKind::Primary, p).on_click(
                    cx.listener(|this, _, window, cx| {
                        let host = this.store.read(cx).host();
                        let work = this.mutate(
                            Method::POST,
                            "/v2/account-vault/authorize".into(),
                            Some(json!({})),
                            cx,
                        );
                        cx.spawn_in(window, async move |this, cx| {
                            // Granting can succeed while the keyring itself stays locked.
                            let result = match work.await {
                                Ok(_) => host.snapshot().await.map(|_| ()).map_err(|error| {
                                    match HostError::code(&error) {
                                        Some("credential_storage_unavailable") => anyhow::anyhow!(
                                            "the keyring is still locked or missing"
                                        ),
                                        _ => error,
                                    }
                                }),
                                Err(error) => Err(error),
                            };
                            let _ = this.update_in(cx, |this, window, cx| {
                                this.store.update(cx, |store, cx| store.reload(cx));
                                if let Err(error) = result {
                                    window.push_notification(
                                        Notification::error(format!(
                                            "Couldn’t open the account store: {error:#}."
                                        )),
                                        cx,
                                    );
                                }
                            });
                        })
                        .detach();
                    }),
                ),
            )
    }

    /// "Amp, Claude, Codex, Copilot and 36 more": providers without an account yet,
    /// the ones with a browser sign-in or CLI login first.
    fn unconnected(&self, overview: Option<&Overview>) -> String {
        let Some(catalog) = &self.catalog else {
            return "Browser sign-in, API keys and CLI logins".into();
        };
        let mut missing: Vec<&crate::catalog::Provider> = catalog
            .iter()
            .filter(|p| overview.is_none_or(|o| o.groups.iter().all(|g| g.provider_id != p.id)))
            .collect();
        missing.sort_by_key(|p| !(p.browser_sign_in() || p.scan() || p.local_login().is_some()));
        let names: Vec<&str> = missing.iter().map(|p| p.display_name.as_str()).collect();
        match names.len() {
            0 => "Add more accounts for any provider".into(),
            1..=4 => names.join(", "),
            n => format!("{} and {} more", names[..4].join(", "), n - 4),
        }
    }

    fn provider_group(
        &self,
        group: &ProviderGroup,
        p: &Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let count = group.accounts.len();
        let provider = group.provider_id.clone();
        div()
            .flex()
            .flex_col()
            .gap(px(8.))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .px(px(4.))
                    .child(provider_logo(
                        &group.provider_id,
                        18.,
                        providers::tint(&group.provider_id),
                        p,
                    ))
                    .child(
                        div()
                            .text_size(px(14.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(p.text_strong)
                            .child(group.name.clone()),
                    )
                    .child(
                        div()
                            .text_size(px(12.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(p.text_soft)
                            .child(count.to_string()),
                    )
                    .child(div().flex_1())
                    .child(
                        div()
                            .id(SharedString::from(format!("refresh-{provider}")))
                            .cursor_pointer()
                            .child(icon(IconName::RefreshCw, 16., p.text_soft))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let provider = provider.clone();
                                this.store
                                    .update(cx, |store, cx| store.refresh(Some(provider), cx));
                            })),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .rounded(px(16.))
                    .border_1()
                    .border_color(p.stroke_soft)
                    .overflow_hidden()
                    .children(
                        group
                            .accounts
                            .iter()
                            .enumerate()
                            .map(|(i, account)| self.account_row(account, i + 1 < count, p, cx)),
                    ),
            )
            .into_any_element()
    }

    fn account_row(
        &self,
        account: &AccountView,
        divider: bool,
        p: &Palette,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // Hidden names show for a moment when clicked.
        let masked = prefs::get(cx).hide_names && self.revealed.as_ref() != Some(&account.id);
        let name = if masked {
            crate::model::mask(&account.name)
        } else {
            account.name.clone()
        };
        let identity = div()
            .w(px(220.))
            .flex_none()
            .flex()
            .flex_col()
            .gap(px(2.))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .child(
                        div()
                            .id(SharedString::from(format!("name-{}", account.id)))
                            .min_w_0()
                            .truncate()
                            .text_size(px(14.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(if account.enabled {
                                p.text_strong
                            } else {
                                p.text_soft
                            })
                            .child(name)
                            .when(masked, |s| {
                                let id = account.id.clone();
                                s.cursor_pointer().on_click(
                                    cx.listener(move |this, _, _, cx| this.reveal(id.clone(), cx)),
                                )
                            }),
                    )
                    .when(account.pinned, |s| {
                        s.child(icon(IconName::Pin, 14., p.text_soft))
                    }),
            )
            .when_some(account.plan.clone(), |s, plan| {
                s.child(
                    div()
                        .text_size(px(12.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_sub)
                        .child(plan),
                )
            });
        let body = match &account.issue {
            _ if !account.enabled => div()
                .flex_1()
                .flex()
                .items_center()
                .gap(px(8.))
                .px(px(12.))
                .py(px(8.))
                .rounded(px(10.))
                .bg(p.bg_weak)
                .text_size(px(12.))
                .child(icon(IconName::Pause, 16., p.text_soft))
                .child(
                    div()
                        .flex_1()
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_sub)
                        .child("Paused. Quota is not being refreshed."),
                )
                .when(account.allowed.set_enabled, |s| {
                    let target = account.clone();
                    s.child(
                        div()
                            .id(SharedString::from(format!("resume-{}", account.id)))
                            .cursor_pointer()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(p.text_strong)
                            .child("Resume")
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.set_enabled(&target, true, window, cx)
                            })),
                    )
                }),
            Some(issue) => {
                let target = account.clone();
                // `min_w_0` lets a long message wrap instead of pushing the
                // row's buttons out.
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .items_center()
                    .gap(px(8.))
                    .px(px(12.))
                    .py(px(8.))
                    .rounded(px(10.))
                    .bg(p.error_alpha)
                    .text_size(px(12.))
                    .child(alert_dot(p.error))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(p.text_strong)
                            .child(format!("{}. {}", issue.title, issue.detail)),
                    )
                    .child(
                        div()
                            .id(SharedString::from(format!("row-fix-{}", account.id)))
                            .flex_none()
                            .cursor_pointer()
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(p.error)
                            .child(issue.action.clone())
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.fix(&target, window, cx)
                            })),
                    )
            }
            None if account.metrics.is_empty() => div()
                .flex_1()
                .text_size(px(12.))
                .text_color(p.text_soft)
                .child("Waiting for the first refresh."),
            None => div()
                .flex_1()
                .grid()
                .grid_cols(2)
                .gap(px(24.))
                .children(account.metrics.iter().map(|m| metric_column(m, p))),
        };
        let busy = self.busy.contains(&account.id);
        div()
            .flex()
            .items_center()
            .gap(px(24.))
            .px(px(16.))
            .py(px(14.))
            .when(divider, |s| s.border_b_1().border_color(p.stroke_soft))
            .when(busy, |s| s.opacity(0.6))
            .child(identity)
            .child(body)
            .child(
                div()
                    .flex_none()
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .child({
                        let target = account.clone();
                        div()
                            .id(SharedString::from(format!("history-{}", account.id)))
                            .size(px(28.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(8.))
                            .bg(p.bg_weak)
                            .cursor_pointer()
                            .child(icon(IconName::ChartLine, 16., p.text_sub))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.open_history(&target, window, cx)
                            }))
                    })
                    .child(self.account_menu(account, cx)),
            )
            .into_any_element()
    }

    fn open_history(&mut self, account: &AccountView, window: &mut Window, cx: &mut Context<Self>) {
        let (host, offset) = {
            let store = self.store.read(cx);
            (store.host(), store.offset())
        };
        let view = cx.new(|cx| QuotaHistory::new(host, offset, account, cx));
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(720.)).child(view.clone())
        });
    }

    /// The row's "…" menu with everything the host allows for this account.
    fn account_menu(&self, account: &AccountView, cx: &mut Context<Self>) -> impl IntoElement {
        let this = cx.entity().downgrade();
        let in_menu_bar = self.menu_bar_ids(cx).contains(&account.id);
        let account = account.clone();
        Button::new(SharedString::from(format!("menu-{}", account.id)))
            .ghost()
            .xsmall()
            .icon(IconName::EllipsisVertical)
            .dropdown_menu_with_anchor(Anchor::TopRight, move |menu, _, _| {
                let menu = menu.min_w(px(180.));
                let item = |label: &'static str, glyph: IconName, action: Action| {
                    let this = this.clone();
                    let account = account.clone();
                    PopupMenuItem::new(label)
                        .icon(glyph)
                        .on_click(move |_, window, cx| {
                            let _ = this.update(cx, |this, cx| {
                                this.account_action(&account, action, window, cx)
                            });
                        })
                };
                let a = &account.allowed;
                menu.item(
                    item("Refresh", IconName::RefreshCw, Action::Refresh)
                        .disabled(!account.enabled),
                )
                .when(a.rename, |m| {
                    m.item(item("Rename…", IconName::Pencil, Action::Rename))
                })
                .when(account.key_source.is_some(), |m| {
                    m.item(item(
                        "Replace API key…",
                        IconName::KeyRound,
                        Action::ReplaceKey,
                    ))
                })
                .when(a.set_enabled && account.enabled, |m| {
                    m.item(item("Pause", IconName::Pause, Action::Pause))
                })
                .when(a.set_enabled && !account.enabled, |m| {
                    m.item(item("Resume", IconName::Play, Action::Resume))
                })
                .when(cfg!(target_os = "macos"), |m| {
                    m.item(if in_menu_bar {
                        item(
                            "Remove from menu bar",
                            IconName::PinOff,
                            Action::HideFromMenuBar,
                        )
                    } else {
                        item("Show in menu bar", IconName::Pin, Action::ShowInMenuBar)
                    })
                })
                .when(a.remove, |m| {
                    m.separator()
                        .item(item("Remove…", IconName::Trash, Action::Remove))
                })
            })
    }

    /// Show a hidden account name for a few seconds.
    fn reveal(&mut self, id: String, cx: &mut Context<Self>) {
        self.revealed = Some(id.clone());
        cx.notify();
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(std::time::Duration::from_secs(3))
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.revealed.as_ref() == Some(&id) {
                    this.revealed = None;
                    cx.notify();
                }
            });
        })
        .detach();
    }

    fn account_action(
        &mut self,
        account: &AccountView,
        action: Action,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action {
            Action::Refresh => self.refresh_account(account, window, cx),
            Action::Rename => self.rename(account, window, cx),
            Action::ReplaceKey => self.replace_key(account, window, cx),
            Action::Pause => self.set_enabled(account, false, window, cx),
            Action::Resume => self.set_enabled(account, true, window, cx),
            Action::Remove => self.confirm_remove(account, window, cx),
            Action::ShowInMenuBar => self.pin_to_menu_bar(account, true, window, cx),
            Action::HideFromMenuBar => self.pin_to_menu_bar(account, false, window, cx),
        }
    }

    /// Accounts pinned to the menu bar that still exist; until the user pins or unpins
    /// one, the accounts shown there automatically.
    fn menu_bar_ids(&self, cx: &App) -> Vec<String> {
        let menu_bar = &prefs::get(cx).menu_bar;
        let store = self.store.read(cx);
        if menu_bar.user_modified {
            let exists = |id: &String| {
                store.all.as_ref().is_some_and(|all| {
                    all.groups
                        .iter()
                        .flat_map(|group| &group.accounts)
                        .any(|account| &account.id == id)
                })
            };
            menu_bar
                .accounts
                .iter()
                .filter(|id| exists(id))
                .cloned()
                .collect()
        } else {
            store.overview.as_ref().map_or_else(Vec::new, |overview| {
                overview
                    .menu_bar_accounts(menu_bar)
                    .into_iter()
                    .map(|(_, account)| account.id.clone())
                    .collect()
            })
        }
    }

    /// Pinning also turns the menu bar icon and its quota on, as in the macOS app.
    fn pin_to_menu_bar(
        &mut self,
        account: &AccountView,
        pin: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let mut ids = self.menu_bar_ids(cx);
        ids.retain(|id| id != &account.id);
        if pin {
            let max = prefs::get(cx).menu_bar.max_items.clamp(1, 10);
            if ids.len() >= max as usize {
                window.push_notification(
                    Notification::warning(format!(
                        "You can show up to {max} accounts in the menu bar. Raise the limit on the Menu Bar page."
                    ))
                    .title("Menu bar is full"),
                    cx,
                );
                return;
            }
            ids.push(account.id.clone());
        }
        prefs::update(cx, |prefs| {
            prefs.menu_bar.accounts = ids;
            prefs.menu_bar.user_modified = true;
            if pin {
                prefs.menu_bar.show_icon = true;
                prefs.menu_bar.show_quota = true;
            }
        });
        self.redraw_quota(cx);
    }

    /// Run a host change for `account`, dim its row meanwhile, then re-read the
    /// snapshot. Failures appear as a notification naming what was attempted.
    fn run(
        &mut self,
        account: &AccountView,
        what: &'static str,
        work: BoxFuture<'static, anyhow::Result<Value>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let id = account.id.clone();
        self.busy.insert(id.clone());
        cx.notify();
        cx.spawn_in(window, async move |this, cx| {
            let result = work.await;
            let _ = this.update_in(cx, |this, window, cx| {
                this.busy.remove(&id);
                this.store.update(cx, |store, cx| store.reload(cx));
                if let Err(error) = result {
                    window.push_notification(
                        Notification::error(format!("Couldn’t {what}: {error:#}.")),
                        cx,
                    );
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn mutate(
        &self,
        method: Method,
        path: String,
        body: Option<Value>,
        cx: &Context<Self>,
    ) -> BoxFuture<'static, anyhow::Result<Value>> {
        self.store.read(cx).host().mutate(method, path, body)
    }

    fn refresh_account(
        &mut self,
        account: &AccountView,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let body = json!({
            "providers": [account.provider_id],
            "account_id": account.id,
            "force": true,
        });
        let work = self.mutate(Method::POST, "/v2/refresh".into(), Some(body), cx);
        // The refresh itself succeeds even when the provider rejects the login.
        let work = Box::pin(async move {
            let result = work.await?;
            if result["failures"].as_u64().unwrap_or(0) > 0 {
                anyhow::bail!("the provider did not return quota");
            }
            Ok(result)
        });
        self.run(account, "refresh the account", work, window, cx);
    }

    fn set_enabled(
        &mut self,
        account: &AccountView,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let work = self.mutate(
            Method::PATCH,
            format!("/v2/accounts/{}", account.id),
            Some(json!({ "enabled": enabled })),
            cx,
        );
        let what = if enabled {
            "resume the account"
        } else {
            "pause the account"
        };
        self.run(account, what, work, window, cx);
    }

    /// The button on a row that needs attention.
    fn fix(&mut self, account: &AccountView, window: &mut Window, cx: &mut Context<Self>) {
        let Some(issue) = &account.issue else { return };
        match &issue.fix {
            Fix::Retry => self.refresh_account(account, window, cx),
            Fix::Authorize(source) => {
                let source = source.clone();
                let work = self.authorize_source(&source, cx);
                self.run(account, "grant access", work, window, cx);
            }
            Fix::UnlockVault => {
                let host = self.store.read(cx).host();
                let refresh = json!({
                    "providers": [account.provider_id],
                    "account_id": account.id,
                    "force": true,
                });
                // Access can be granted while the keyring itself stays locked; a
                // refresh shows whether the sign-in opens now.
                let work = Box::pin(async move {
                    host.mutate(
                        Method::POST,
                        "/v2/account-vault/authorize".into(),
                        Some(json!({})),
                    )
                    .await?;
                    let result = host
                        .mutate(Method::POST, "/v2/refresh".into(), Some(refresh))
                        .await?;
                    if result["failures"].as_u64().unwrap_or(0) > 0 {
                        let hint = if cfg!(windows) {
                            "check Windows Credential Manager"
                        } else {
                            "unlock your keyring"
                        };
                        anyhow::bail!("the saved sign-in is still locked; {hint}");
                    }
                    Ok(result)
                });
                self.run(account, "grant access", work, window, cx);
            }
            Fix::SignIn => self.connect(Some(&account.provider_id), window, cx),
            Fix::ReplaceKey => self.replace_key(account, window, cx),
        }
    }

    /// Let the host read a login it found, then look for it again.
    fn authorize_source(
        &self,
        source_id: &str,
        cx: &Context<Self>,
    ) -> BoxFuture<'static, anyhow::Result<Value>> {
        let snapshot_source = self.store.read(cx).source(source_id);
        let host = self.store.read(cx).host();
        Box::pin(async move {
            let source = snapshot_source.ok_or_else(|| anyhow::anyhow!("the login is gone"))?;
            let body = json!({
                "kind": source.kind,
                "location": source.location,
                "entry_key": source.keychain_account,
                "config_dir": source.directory,
            });
            host.mutate(Method::POST, "/v2/sources/authorize".into(), Some(body))
                .await
        })
    }

    fn rename(&mut self, account: &AccountView, window: &mut Window, cx: &mut Context<Self>) {
        let input = cx.new(|cx| InputState::new(window, cx).default_value(account.name.clone()));
        let this = cx.entity().downgrade();
        // `None` goes back to the name the provider reports.
        let submit = {
            let account = account.clone();
            Rc::new(
                move |label: Option<String>, window: &mut Window, cx: &mut App| {
                    window.close_dialog(cx);
                    let _ = this.update(cx, |this, cx| {
                        let work = this.mutate(
                            Method::PATCH,
                            format!("/v2/accounts/{}", account.id),
                            Some(json!({ "user_label": label })),
                            cx,
                        );
                        this.run(&account, "rename the account", work, window, cx);
                    });
                },
            )
        };
        let save: Rc<dyn Fn(&mut Window, &mut App)> = {
            let (submit, input) = (submit.clone(), input.clone());
            Rc::new(move |window, cx| {
                let label = input.read(cx).value().trim().to_owned();
                if !label.is_empty() {
                    submit(Some(label), window, cx);
                }
            })
        };
        self.submit_on_enter(&input, save.clone(), window, cx);
        let has_label = account.user_label.is_some();
        let first = Cell::new(true);
        window.open_dialog(cx, move |dialog, window, cx| {
            if first.replace(false) {
                input.read(cx).focus_handle(cx).focus(window, cx);
            }
            let p = palette(cx).clone();
            let (submit, save) = (submit.clone(), save.clone());
            dialog
                .w(px(420.))
                .title("Rename account")
                .child(field("Name", text_field(&input, &p), &p))
                .footer(
                    dialog_footer()
                        .when(has_label, |s| {
                            s.child(
                                button(
                                    "use-provider-name",
                                    "Use provider name",
                                    ButtonKind::Secondary,
                                    &p,
                                )
                                .on_click(move |_, window, cx| submit(None, window, cx)),
                            )
                            .child(div().flex_1())
                        })
                        .child(
                            button("cancel", "Cancel", ButtonKind::Secondary, &p)
                                .on_click(|_, window, cx| window.close_dialog(cx)),
                        )
                        .child(
                            button("save", "Save", ButtonKind::Primary, &p)
                                .on_click(move |_, window, cx| save(window, cx)),
                        ),
                )
        });
    }

    fn replace_key(&mut self, account: &AccountView, window: &mut Window, cx: &mut Context<Self>) {
        let Some(source) = account.key_source.clone() else {
            return;
        };
        let input = cx.new(|cx| {
            InputState::new(window, cx)
                .masked(true)
                .placeholder("Paste the new key")
        });
        let save: Rc<dyn Fn(&mut Window, &mut App)> = {
            let (this, input, account) = (cx.entity().downgrade(), input.clone(), account.clone());
            Rc::new(move |window, cx| {
                let key = input.read(cx).value().trim().to_owned();
                if key.is_empty() {
                    return;
                }
                window.close_dialog(cx);
                let _ = this.update(cx, |this, cx| {
                    let work = this.mutate(
                        Method::PATCH,
                        format!("/v2/sources/{source}"),
                        Some(json!({ "api_key": key })),
                        cx,
                    );
                    this.run(&account, "replace the key", work, window, cx);
                });
            })
        };
        self.submit_on_enter(&input, save.clone(), window, cx);
        let title = format!(
            "Replace {} API key",
            providers::display_name(&account.provider_id)
        );
        let label = format!("New key for {}", shown_name(&account.name, cx));
        let first = Cell::new(true);
        window.open_dialog(cx, move |dialog, window, cx| {
            if first.replace(false) {
                input.read(cx).focus_handle(cx).focus(window, cx);
            }
            let p = palette(cx).clone();
            let save = save.clone();
            dialog
                .w(px(420.))
                .title(title.clone())
                .child(field(label.clone(), text_field(&input, &p), &p))
                .footer(
                    dialog_footer()
                        .child(
                            button("cancel", "Cancel", ButtonKind::Secondary, &p)
                                .on_click(|_, window, cx| window.close_dialog(cx)),
                        )
                        .child(
                            button("save", "Replace key", ButtonKind::Primary, &p)
                                .on_click(move |_, window, cx| save(window, cx)),
                        ),
                )
        });
    }

    /// Pressing Enter in a dialog's field does what its main button does.
    fn submit_on_enter(
        &mut self,
        input: &Entity<InputState>,
        submit: Rc<dyn Fn(&mut Window, &mut App)>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.dialog_events = Some(cx.subscribe_in(
            input,
            window,
            move |_, _, event: &InputEvent, window, cx| {
                // The handlers update this view, which is mid-update here.
                if matches!(event, InputEvent::PressEnter { .. }) {
                    let submit = submit.clone();
                    window.defer(cx, move |window, cx| submit(window, cx));
                }
            },
        ));
    }

    fn confirm_remove(
        &mut self,
        account: &AccountView,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let this = cx.entity().downgrade();
        let account = account.clone();
        window.open_dialog(cx, move |dialog, _, cx| {
            let p = palette(cx).clone();
            let (this, account) = (this.clone(), account.clone());
            dialog
                .w(px(420.))
                .title("Remove this account from Quotio?")
                .child(note(
                    format!(
                        "{} and its quota history will be removed. Sign-ins kept by {} itself are not touched.",
                        shown_name(&account.name, cx),
                        providers::display_name(&account.provider_id)
                    ),
                    p.text_sub,
                ).text_size(px(14.)))
                .footer(
                    dialog_footer()
                        .child(
                            button("cancel", "Cancel", ButtonKind::Secondary, &p)
                                .on_click(|_, window, cx| window.close_dialog(cx)),
                        )
                        .child(
                            button("remove", "Remove", ButtonKind::Danger, &p).on_click(
                                move |_, window, cx| {
                                    window.close_dialog(cx);
                                    let _ = this.update(cx, |this, cx| {
                                        let work = this.mutate(
                                            Method::DELETE,
                                            format!("/v2/accounts/{}", account.id),
                                            None,
                                            cx,
                                        );
                                        this.run(&account, "remove the account", work, window, cx);
                                    });
                                },
                            ),
                        ),
                )
        });
    }
}

#[derive(Clone, Copy)]
enum Action {
    Refresh,
    Rename,
    ReplaceKey,
    Pause,
    Resume,
    Remove,
    ShowInMenuBar,
    HideFromMenuBar,
}

fn metric_column(metric: &MetricView, p: &Palette) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap(px(6.))
        .min_w_0()
        .child(
            div()
                .flex()
                .items_baseline()
                .gap(px(8.))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_size(px(12.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_sub)
                        .child(metric.label.clone()),
                )
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(value_color(metric.tone, p))
                        .child(metric.value.clone()),
                ),
        )
        .child(progress(metric.fill, metric.tone, px(6.), p))
        .when_some(metric.reset_sentence(), |s, reset| {
            s.child(
                div()
                    .text_size(px(12.))
                    .text_color(p.text_soft)
                    .child(reset),
            )
        })
}

/// Filled circle with "!", which Lucide doesn't draw.
fn alert_dot(color: gpui_kit::Hsla) -> impl IntoElement {
    div()
        .size(px(16.))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .rounded_full()
        .bg(color)
        .text_size(px(11.))
        .font_weight(FontWeight::BOLD)
        .text_color(rgb(0xffffff))
        .child("!")
}
