//! Settings window, built from the Wonder artboard "Page - Quotio Accounts".
use gpui_kit::assets::IconName;
use gpui_kit::{
    AnyElement, Context, Decorations, Entity, FontWeight, InteractiveElement, IntoElement,
    ParentElement, Render, SharedString, StatefulInteractiveElement, Styled, Subscription, Window,
    WindowControlArea, div, prelude::FluentBuilder as _, px, relative,
};

use super::{icon, progress, provider_logo, value_color};
use crate::model::{AccountView, MetricView, Overview, ProviderGroup};
use crate::store::QuotaStore;
use crate::theme::{self, FONT_FAMILY, Palette, palette};

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
    _subscriptions: Vec<Subscription>,
}

impl SettingsWindow {
    pub fn new(store: Entity<QuotaStore>, cx: &mut Context<Self>) -> Self {
        let subscriptions = vec![cx.observe(&store, |_, _, cx| cx.notify())];
        Self {
            store,
            page: Page::Accounts,
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
                            .shadow(theme::raised())
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

    fn accounts_page(&self, overview: Option<&Overview>, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let store = self.store.read(cx);
        let subtitle: SharedString = match (overview, &store.error) {
            (_, Some(error)) => format!("Host unavailable: {error}").into(),
            (Some(overview), None) => overview.status_line().into(),
            (None, None) => "Loading…".into(),
        };
        let refreshing = store.refreshing;
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
                    .gap(px(8.))
                    .px(px(10.))
                    .rounded(px(10.))
                    .bg(p.bg_weak)
                    .text_size(px(14.))
                    .text_color(p.text_soft)
                    .child(icon(IconName::Search, 16., p.text_soft))
                    .child("Search accounts"),
            )
            .child(
                div()
                    .id("refresh")
                    .h(px(32.))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .px(px(10.))
                    .rounded(px(10.))
                    .bg(p.bg_white)
                    .shadow(theme::button())
                    .cursor_pointer()
                    .when(refreshing, |s| s.opacity(0.5))
                    .text_size(px(14.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_sub)
                    .child(icon(IconName::RefreshCw, 16., p.text_sub))
                    .child("Refresh")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.store.update(cx, |store, cx| store.refresh(None, cx));
                    })),
            )
            .child(
                div()
                    .h(px(32.))
                    .flex()
                    .items_center()
                    .gap(px(6.))
                    .px(px(10.))
                    .rounded(px(10.))
                    .bg(p.text_strong)
                    .text_size(px(14.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.on_strong)
                    .child(icon(IconName::Plus, 16., p.on_strong))
                    .child("Add account"),
            );
        let attention: Vec<AnyElement> = overview
            .into_iter()
            .flat_map(|o| o.attention())
            .map(|(_, account, issue)| {
                div()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .px(px(12.))
                    .py(px(10.))
                    .rounded(px(12.))
                    .bg(p.bg_white)
                    .shadow(theme::raised())
                    .child(
                        div()
                            .size(px(32.))
                            .flex_none()
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(8.))
                            .bg(p.error_alpha)
                            .child(icon(IconName::CircleAlert, 16., p.error)),
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
                                    .child(format!("{} · {}", issue.title, account.name)),
                            )
                            .child(
                                div()
                                    .text_size(px(12.))
                                    .text_color(p.text_sub)
                                    .child(issue.detail.clone()),
                            ),
                    )
                    .child(
                        div()
                            .h(px(32.))
                            .flex_none()
                            .flex()
                            .items_center()
                            .px(px(12.))
                            .rounded(px(10.))
                            .bg(p.text_strong)
                            .text_size(px(14.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(p.on_strong)
                            .child(issue.action.clone()),
                    )
                    .into_any_element()
            })
            .collect();
        let attention_count = attention.len();
        div()
            .flex()
            .flex_col()
            .gap(px(24.))
            .child(header)
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
                                .child(icon(IconName::TriangleAlert, 16., p.away))
                                .child(match attention_count {
                                    1 => "1 thing needs your attention".to_owned(),
                                    n => format!("{n} things need your attention"),
                                }),
                        )
                        .children(attention),
                )
            })
            .child(
                div().flex().flex_col().gap(px(20.)).children(
                    overview
                        .into_iter()
                        .flat_map(|o| &o.groups)
                        .map(|group| provider_group(group, &p)),
                ),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(12.))
                    .px(px(16.))
                    .py(px(12.))
                    .rounded(px(16.))
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
                                    .child("Cursor, Copilot, Kiro, Warp and 39 more"),
                            ),
                    )
                    .child(icon(IconName::ChevronRight, 18., p.text_soft)),
            )
            .into_any_element()
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
        let overview = self.store.read(cx).overview.clone();
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
                    .shadow(theme::panel())
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

fn provider_group(group: &ProviderGroup, p: &Palette) -> AnyElement {
    let count = group.accounts.len();
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
                .child(provider_logo(&group.provider_id, 18., None, p))
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
                        .map(|(i, account)| account_row(account, i + 1 < count, p)),
                ),
        )
        .into_any_element()
}

fn account_row(account: &AccountView, divider: bool, p: &Palette) -> AnyElement {
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
                        .min_w_0()
                        .truncate()
                        .text_size(px(14.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_strong)
                        .child(account.name.clone()),
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
        Some(issue) => div()
            .flex_1()
            .flex()
            .items_center()
            .gap(px(8.))
            .px(px(12.))
            .py(px(8.))
            .rounded(px(10.))
            .bg(p.error_alpha)
            .text_size(px(12.))
            .child(icon(IconName::CircleAlert, 16., p.error))
            .child(
                div()
                    .flex_1()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_strong)
                    .child(format!("{}. {}", issue.title, issue.detail)),
            )
            .child(
                div()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(p.error)
                    .child(issue.action.clone()),
            ),
        None => div()
            .flex_1()
            .grid()
            .grid_cols(2)
            .gap(px(24.))
            .children(account.metrics.iter().map(|m| metric_column(m, p))),
    };
    let action = |glyph: IconName, filled: bool| {
        div()
            .size(px(28.))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(8.))
            .when(filled, |s| s.bg(p.bg_weak))
            .child(icon(glyph, 16., p.text_sub))
    };
    div()
        .flex()
        .items_center()
        .gap(px(24.))
        .px(px(16.))
        .py(px(14.))
        .when(divider, |s| s.border_b_1().border_color(p.stroke_soft))
        .child(identity)
        .child(body)
        .child(
            div()
                .flex_none()
                .flex()
                .items_center()
                .gap(px(4.))
                .child(action(IconName::ChartLine, true))
                .child(action(IconName::Ellipsis, false)),
        )
        .into_any_element()
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
        .child(progress(metric.remaining, metric.tone, px(6.), p))
        .when_some(metric.reset_sentence(), |s, reset| {
            s.child(
                div()
                    .text_size(px(12.))
                    .text_color(p.text_soft)
                    .child(reset),
            )
        })
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
