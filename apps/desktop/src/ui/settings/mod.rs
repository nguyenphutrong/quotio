//! Settings window: sidebar navigation and one module per page, built from the
//! Wonder "Page - Quotio …" artboards.
mod about;
mod accounts;
mod cli_proxy;
mod connect;
mod general;
mod iphone;
mod menu_bar;
mod notifications;
mod privacy;
mod widgets;

use std::collections::HashSet;

use gpui_kit::assets::IconName;
use gpui_kit::{
    AppContext as _, Context, Decorations, Entity, FontWeight, InteractiveElement, IntoElement,
    ParentElement, Render, StatefulInteractiveElement, Styled, Subscription, Window,
    WindowControlArea, div, prelude::FluentBuilder as _, px, relative,
};

use gpui_kit::component::input::{InputEvent, InputState};

use gpui_kit::component::WindowExt as _;
use gpui_kit::component::notification::Notification;
use serde_json::Value;

use super::icon;
use crate::host::{HostError, Method};
use crate::store::QuotaStore;
use crate::theme::{FONT_FAMILY, Palette, palette};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Page {
    Accounts,
    IphoneSharing,
    CliProxyApi,
    General,
    MenuBar,
    Notifications,
    Privacy,
    About,
}

impl Page {
    fn title(self) -> &'static str {
        match self {
            Page::Accounts => "Accounts",
            Page::IphoneSharing => "iPhone Sharing",
            Page::CliProxyApi => "CLIProxyAPI",
            Page::General => "General",
            Page::MenuBar => {
                if cfg!(target_os = "macos") {
                    "Menu Bar"
                } else {
                    "Tray"
                }
            }
            Page::Notifications => "Notifications",
            Page::Privacy => "Privacy",
            Page::About => "About & Updates",
        }
    }

    fn icon(self) -> IconName {
        match self {
            Page::Accounts => IconName::Users,
            Page::IphoneSharing => IconName::Smartphone,
            Page::CliProxyApi => IconName::Globe,
            Page::General => IconName::Settings,
            Page::MenuBar => IconName::PanelTop,
            Page::Notifications => IconName::Bell,
            Page::Privacy => IconName::Shield,
            Page::About => IconName::Info,
        }
    }
}

pub struct SettingsWindow {
    store: Entity<QuotaStore>,
    page: Page,
    search: Entity<InputState>,
    /// Accounts with a change in flight; their rows are dimmed.
    busy: HashSet<String>,
    /// Events of the open dialog's field, replaced with each dialog.
    dialog_events: Option<Subscription>,
    /// Connectable providers, once the host has listed them.
    catalog: Option<Vec<crate::catalog::Provider>>,
    /// `GET /v2/settings`, updated as soon as the user changes something.
    host_settings: Option<Value>,
    /// `GET /v2/discovery`: when Quotio last looked for logins and what it found.
    discovery: Option<Value>,
    launch_at_login: bool,
    scanning: bool,
    /// Account whose hidden name is shown for a moment.
    revealed: Option<String>,
    /// `GET /v2/sharing` and the paired devices from `GET /v2/clients`.
    sharing: Option<Value>,
    devices: Option<Vec<Value>>,
    /// The connection being turned on or off.
    sharing_busy: Option<crate::sharing::Mode>,
    sharing_advanced: bool,
    share_port: Entity<InputState>,
    share_proxy: Entity<InputState>,
    _subscriptions: Vec<Subscription>,
}

impl SettingsWindow {
    pub fn new(store: Entity<QuotaStore>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let catalog = connect::load_catalog(store.read(cx).host());
        cx.spawn(async move |this, cx| {
            if let Ok(catalog) = catalog.await {
                let _ = this.update(cx, |this, cx| {
                    this.catalog = Some(catalog);
                    cx.notify();
                });
            }
        })
        .detach();
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search accounts"));
        let subscriptions = vec![
            cx.observe(&store, |_, _, cx| cx.notify()),
            cx.subscribe(&search, |_, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            }),
            cx.observe_window_appearance(window, |_, window, cx| {
                crate::theme::system_changed(window.appearance(), cx)
            }),
        ];
        let saved = crate::prefs::get(cx).sharing.clone();
        // The proxy connection lives under Advanced; keep it in view while it is on.
        let sharing_advanced = saved.enabled.contains(&crate::sharing::Mode::Proxy);
        let share_port =
            cx.new(|cx| InputState::new(window, cx).default_value(saved.port.to_string()));
        let share_proxy = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("https://quotio.example.com")
                .default_value(saved.proxy_url.unwrap_or_default())
        });
        let mut this = Self {
            store,
            page: Page::Accounts,
            search,
            busy: HashSet::new(),
            dialog_events: None,
            catalog: None,
            host_settings: None,
            discovery: None,
            launch_at_login: crate::autostart::enabled(),
            scanning: false,
            revealed: None,
            sharing: None,
            devices: None,
            sharing_busy: None,
            sharing_advanced,
            share_port,
            share_proxy,
            _subscriptions: subscriptions,
        };
        this.load_host_settings(cx);
        this
    }

    pub fn show(&mut self, page: Page, cx: &mut Context<Self>) {
        if self.page != page {
            self.page = page;
            // Pick up changes made in the config file or another client.
            self.load_host_settings(cx);
            if page == Page::IphoneSharing {
                self.load_sharing(cx);
            }
        }
        cx.notify();
    }

    fn load_host_settings(&mut self, cx: &mut Context<Self>) {
        let host = self.store.read(cx).host();
        cx.spawn(async move |this, cx| {
            let settings = host.call(Method::GET, "/v2/settings".into(), None).await;
            let discovery = host.call(Method::GET, "/v2/discovery".into(), None).await;
            let _ = this.update(cx, |this, cx| {
                this.host_settings = settings.ok();
                this.discovery = discovery.ok();
                cx.notify();
            });
        })
        .detach();
    }

    /// Change host-wide settings. The page shows the new values at once; if the
    /// host refuses, it shows the error and the stored values again.
    fn patch_settings(&mut self, change: Value, window: &mut Window, cx: &mut Context<Self>) {
        let Some(current) = self.host_settings.as_mut() else {
            return;
        };
        for (key, value) in change.as_object().into_iter().flatten() {
            current[key] = value.clone();
        }
        cx.notify();
        let host = self.store.read(cx).host();
        cx.spawn_in(window, async move |this, cx| {
            // Another client may have saved in between; a conflict re-reads once.
            let mut attempts = 0;
            let result = loop {
                attempts += 1;
                let attempt = async {
                    let settings = host.call(Method::GET, "/v2/settings".into(), None).await?;
                    let mut body = change.clone();
                    body["revision"] = settings["revision"].clone();
                    host.call(Method::PATCH, "/v2/settings".into(), Some(body))
                        .await
                }
                .await;
                match attempt {
                    Err(error)
                        if attempts < 2 && HostError::code(&error) == Some("revision_conflict") => {
                    }
                    result => break result,
                }
            };
            let _ = this.update_in(cx, |this, window, cx| match result {
                Ok(settings) => {
                    this.host_settings = Some(settings);
                    cx.notify();
                }
                Err(error) => {
                    window.push_notification(
                        Notification::error(format!("Couldn’t save the setting: {error:#}.")),
                        cx,
                    );
                    this.load_host_settings(cx);
                }
            });
        })
        .detach();
    }

    fn sidebar(&self, attention: usize, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let nav = |page: Page, badge: Option<usize>, cx: &mut Context<Self>| {
            let active = self.page == page;
            div()
                .id(page.title())
                .flex()
                .items_center()
                .gap(px(8.))
                .p(px(8.))
                .rounded(px(10.))
                .cursor_pointer()
                .text_size(px(14.))
                .font_weight(FontWeight::MEDIUM)
                .map(|s| {
                    if active {
                        s.bg(p.bg_white)
                            .shadow(p.raised())
                            .text_color(p.text_strong)
                    } else {
                        s.text_color(p.text_sub).hover(|s| s.bg(p.stroke_soft))
                    }
                })
                .child(icon(
                    page.icon(),
                    20.,
                    if active { p.primary } else { p.text_sub },
                ))
                .child(div().flex_1().child(page.title()))
                .when_some(badge.filter(|n| *n > 0), |s, n| {
                    s.child(
                        div()
                            .min_w(px(18.))
                            .flex()
                            .justify_center()
                            .px(px(6.))
                            .py(px(2.))
                            .rounded(px(5.))
                            .bg(p.error_alpha)
                            .text_size(px(11.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(p.error)
                            .child(n.to_string()),
                    )
                })
                .on_click(cx.listener(move |this, _, _, cx| this.show(page, cx)))
        };
        div()
            .w(px(240.))
            .flex_none()
            .flex()
            .flex_col()
            .gap(px(16.))
            .p(px(14.))
            // Window chrome row: native traffic lights sit here on macOS.
            .child(
                div()
                    .h(px(28.))
                    .window_control_area(WindowControlArea::Drag),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    .child(nav(Page::Accounts, Some(attention), cx))
                    .child(nav(Page::IphoneSharing, None, cx))
                    .child(nav(Page::CliProxyApi, None, cx)),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(4.))
                    .child(
                        div()
                            .h(px(24.))
                            .px(px(8.))
                            .flex()
                            .items_center()
                            .text_size(px(12.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(p.text_soft)
                            .child("Application"),
                    )
                    .child(nav(Page::General, None, cx))
                    .child(nav(Page::MenuBar, None, cx))
                    .child(nav(Page::Notifications, None, cx))
                    .child(nav(Page::Privacy, None, cx)),
            )
            .child(div().flex_1())
            .child(nav(Page::About, None, cx))
    }
}

impl Render for SettingsWindow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let overview = self.store.read(cx).all.clone();
        let attention = overview.as_ref().map_or(0, |o| o.attention().count());
        let page = match self.page {
            Page::Accounts => self.accounts_page(overview.as_ref(), cx),
            Page::General => self.general_page(cx),
            Page::IphoneSharing => self.iphone_page(cx),
            Page::About => self.about_page(cx),
            Page::CliProxyApi => self.cli_proxy_page(cx),
            Page::MenuBar => self.menu_bar_page(cx),
            Page::Notifications => self.notifications_page(cx),
            Page::Privacy => self.privacy_page(cx),
        };
        // macOS draws traffic lights; X11 without a compositor falls back to the
        // window manager's title bar. Otherwise the app draws its own controls.
        let own_controls = cfg!(windows)
            || (cfg!(target_os = "linux")
                && matches!(window.window_decorations(), Decorations::Client { .. }));
        div()
            .size_full()
            .flex()
            .gap(px(6.))
            .p(px(6.))
            .font_family(FONT_FAMILY)
            .line_height(relative(1.38))
            .bg(p.bg_weak)
            .child(self.sidebar(attention, cx))
            .child(
                div()
                    .relative()
                    .flex_1()
                    .min_w_0()
                    .rounded(px(24.))
                    .bg(p.bg_white)
                    .shadow(p.panel())
                    .overflow_hidden()
                    .child(
                        div()
                            .id("content")
                            .size_full()
                            .overflow_y_scroll()
                            .pt(px(if own_controls { 48. } else { 22. }))
                            .pb(px(28.))
                            .px(px(28.))
                            .child(page),
                    )
                    .when(own_controls, |s| s.child(window_controls(window, &p))),
            )
    }
}

/// Minimize, maximize and close for Windows and Linux client-side decorations.
fn window_controls(window: &Window, p: &Palette) -> impl IntoElement {
    let control = |id: &'static str, glyph: IconName, area: WindowControlArea| {
        div()
            .id(id)
            .size(px(28.))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(8.))
            .hover(|s| s.bg(p.bg_weak))
            .window_control_area(area)
            .child(icon(glyph, 14., p.text_sub))
    };
    let maximize = if window.is_maximized() {
        IconName::WindowRestore
    } else {
        IconName::WindowMaximize
    };
    div()
        .absolute()
        .top(px(10.))
        .right(px(10.))
        .flex()
        .gap(px(2.))
        .child(
            control("minimize", IconName::WindowMinimize, WindowControlArea::Min)
                .on_click(|_, window, _| window.minimize_window()),
        )
        .child(
            control("maximize", maximize, WindowControlArea::Max)
                .on_click(|_, window, _| window.zoom_window()),
        )
        .child(
            control("close", IconName::WindowClose, WindowControlArea::Close)
                .on_click(|_, window, _| window.remove_window()),
        )
}
