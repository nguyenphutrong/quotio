//! Settings window: sidebar navigation and one module per page, built from the
//! Wonder "Page - Quotio …" artboards.
mod accounts;

use std::collections::HashSet;

use gpui_kit::assets::IconName;
use gpui_kit::{
    AnyElement, AppContext as _, Context, Decorations, Entity, FontWeight, InteractiveElement,
    IntoElement, ParentElement, Render, StatefulInteractiveElement, Styled, Subscription, Window,
    WindowControlArea, div, prelude::FluentBuilder as _, px, relative,
};

use gpui_kit::component::input::{InputEvent, InputState};

use super::icon;
use crate::store::QuotaStore;
use crate::theme::{FONT_FAMILY, Palette, palette};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Page {
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
    _subscriptions: Vec<Subscription>,
}

impl SettingsWindow {
    pub fn new(store: Entity<QuotaStore>, window: &mut Window, cx: &mut Context<Self>) -> Self {
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
        Self {
            store,
            page: Page::Accounts,
            search,
            busy: HashSet::new(),
            dialog_events: None,
            _subscriptions: subscriptions,
        }
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
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.page = page;
                    cx.notify();
                }))
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

    fn placeholder_page(&self, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        div()
            .flex()
            .flex_col()
            .gap(px(4.))
            .text_size(px(14.))
            .font_weight(FontWeight::MEDIUM)
            .child(div().text_color(p.text_strong).child(self.page.title()))
            .child(
                div()
                    .text_color(p.text_soft)
                    .child("This page is not part of the desktop preview yet."),
            )
            .into_any_element()
    }
}

impl Render for SettingsWindow {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let overview = self.store.read(cx).all.clone();
        let attention = overview.as_ref().map_or(0, |o| o.attention().count());
        let page = match self.page {
            Page::Accounts => self.accounts_page(overview.as_ref(), cx),
            _ => self.placeholder_page(cx),
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
