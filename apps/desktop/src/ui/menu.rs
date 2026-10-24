//! Tray popup, built from the Wonder artboard "Menu Bar Quota Menu" (360 px wide).
use gpui_kit::assets::IconName;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FocusHandle, FontWeight, Hsla,
    InteractiveElement, IntoElement, KeyDownEvent, ParentElement, Render, SharedString,
    StatefulInteractiveElement, Styled, Subscription, Window, div, prelude::FluentBuilder as _, px,
    relative, size,
};

use super::{icon, progress, provider_logo, shown_name, value_color};
use crate::model::{AccountView, MetricView, Overview, ProviderGroup};
use crate::prefs::Density;
use crate::store::QuotaStore;
use crate::theme::{FONT_FAMILY, Palette, palette};

pub const WIDTH: f32 = 360.;

pub struct QuotaMenu {
    store: Entity<QuotaStore>,
    filter: Option<String>,
    focus: FocusHandle,
    was_active: bool,
    _subscriptions: Vec<Subscription>,
}

impl QuotaMenu {
    pub fn new(store: Entity<QuotaStore>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        // The system may have switched theme while no window was open to hear it.
        crate::theme::system_changed(window.appearance(), cx);
        let subscriptions = vec![
            cx.observe(&store, |_, _, cx| cx.notify()),
            cx.observe_window_appearance(window, |_, window, cx| {
                crate::theme::system_changed(window.appearance(), cx)
            }),
            // Behave like a menu: clicking elsewhere dismisses it. A new window can
            // report "inactive" before the window manager focuses it, so wait for
            // the first activation.
            cx.observe_window_activation(window, |this: &mut Self, window, cx| {
                if window.is_window_active() {
                    this.was_active = true;
                } else if this.was_active {
                    crate::app::note_menu_dismissed(cx);
                    window.remove_window();
                }
            }),
        ];
        Self {
            store,
            filter: None,
            focus,
            was_active: false,
            _subscriptions: subscriptions,
        }
    }

    fn on_key_down(&mut self, event: &KeyDownEvent, window: &mut Window, cx: &mut Context<Self>) {
        let keystroke = &event.keystroke;
        match keystroke.key.as_str() {
            "escape" => window.remove_window(),
            "," if keystroke.modifiers.secondary() => {
                window.remove_window();
                crate::app::open_settings(cx);
            }
            "q" if keystroke.modifiers.secondary() => crate::app::quit(cx),
            _ => {}
        }
    }

    fn header(&self, overview: Option<&Overview>, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let store = self.store.read(cx);
        let status: SharedString = match (overview, &store.error) {
            (_, Some(error)) => format!("Host unavailable: {error}").into(),
            (Some(overview), None) => overview.status_line().into(),
            (None, None) => "Loading…".into(),
        };
        let refreshing = store.refreshing;
        div()
            .flex()
            .justify_between()
            .items_center()
            .pt(px(8.))
            .pb(px(10.))
            .px(px(10.))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(2.))
                    .min_w_0()
                    .child(
                        div()
                            .text_size(px(14.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(p.text_strong)
                            .child("Quotio"),
                    )
                    .child(
                        div()
                            .text_size(px(12.))
                            .text_color(p.text_soft)
                            .truncate()
                            .child(status),
                    ),
            )
            .child(
                div()
                    .id("refresh-all")
                    .size(px(28.))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(8.))
                    .border_1()
                    .border_color(p.stroke_soft)
                    .cursor_pointer()
                    .hover(|s| s.bg(p.bg_weak))
                    .when(refreshing, |s| s.opacity(0.5))
                    .child(icon(IconName::RefreshCw, 15., p.text_sub))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.store.update(cx, |store, cx| store.refresh(None, cx));
                    })),
            )
    }

    fn chips(&self, overview: &Overview, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let chip = |id: SharedString,
                    label: SharedString,
                    leading: &dyn Fn(Hsla) -> AnyElement,
                    value: Option<String>,
                    active: bool,
                    cx: &mut Context<Self>| {
            let color = if active { p.on_strong } else { p.text_sub };
            div()
                .id(id)
                .flex()
                .items_center()
                .h(px(28.))
                .px(px(10.))
                .gap(px(6.))
                .rounded_full()
                .text_size(px(12.))
                .font_weight(FontWeight::MEDIUM)
                .cursor_pointer()
                .text_color(color)
                .map(|s| {
                    if active {
                        s.bg(p.text_strong)
                    } else {
                        s.bg(p.bg_weak).hover(|s| s.bg(p.stroke_soft))
                    }
                })
                .child(leading(color))
                .child(label)
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.filter = value.clone();
                    cx.notify();
                }))
        };
        div()
            .flex()
            .flex_wrap()
            .gap(px(6.))
            .px(px(10.))
            .pb(px(10.))
            .border_b_1()
            .border_color(p.stroke_soft)
            .child(chip(
                "chip-all".into(),
                "All".into(),
                &|color| icon(IconName::LayoutGrid, 13., color).into_any_element(),
                None,
                self.filter.is_none(),
                cx,
            ))
            .children(overview.groups.iter().map(|group| {
                chip(
                    format!("chip-{}", group.provider_id).into(),
                    group.name.clone().into(),
                    &|color| provider_logo(&group.provider_id, 12., Some(color), &p),
                    Some(group.provider_id.clone()),
                    self.filter.as_deref() == Some(&group.provider_id),
                    cx,
                )
            }))
    }

    fn group(&self, index: usize, group: &ProviderGroup, cx: &mut Context<Self>) -> AnyElement {
        let p = palette(cx).clone();
        let provider = group.provider_id.clone();
        let density = crate::prefs::get(cx).density;
        div()
            .flex()
            .flex_col()
            .pt(px(8.))
            .when(index > 0, |s| s.border_t_1().border_color(p.stroke_soft))
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .px(px(10.))
                    .py(px(6.))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .text_size(px(12.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(p.text_soft)
                            .child(provider_logo(
                                &group.provider_id,
                                12.,
                                Some(p.text_soft),
                                &p,
                            ))
                            .child(group.name.clone()),
                    )
                    .child(
                        div()
                            .id(SharedString::from(format!("refresh-{provider}")))
                            .cursor_pointer()
                            .child(icon(IconName::RefreshCw, 13., p.text_soft))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let provider = provider.clone();
                                this.store
                                    .update(cx, |store, cx| store.refresh(Some(provider), cx));
                            })),
                    ),
            )
            .children(group.accounts.iter().map(|account| {
                let name = shown_name(&account.name, cx);
                match density {
                    Density::Compact => compact_row(account, name, &p),
                    Density::Comfortable => account_card(account, name, false, &p),
                    Density::Detailed => account_card(account, name, true, &p),
                }
            }))
            .into_any_element()
    }

    fn footer(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let shortcut = |key: &str| {
            if cfg!(target_os = "macos") {
                format!("⌘{}", key.to_uppercase())
            } else {
                format!("Ctrl+{}", key.to_uppercase())
            }
        };
        let item =
            |id: &'static str, glyph: IconName, label: &'static str, keys: Option<String>| {
                div()
                    .id(id)
                    .flex()
                    .items_center()
                    .gap(px(10.))
                    .px(px(10.))
                    .py(px(6.))
                    .rounded(px(8.))
                    .text_size(px(13.))
                    .text_color(p.text_strong)
                    .cursor_pointer()
                    .hover(|s| s.bg(p.bg_weak))
                    .child(icon(glyph, 15., p.text_sub))
                    .child(div().flex_1().child(label))
                    .when_some(keys, |s, keys| {
                        s.child(div().text_size(px(12.)).text_color(p.text_soft).child(keys))
                    })
            };
        div()
            .flex()
            .flex_col()
            .pt(px(6.))
            .border_t_1()
            .border_color(p.stroke_soft)
            .child(
                item("pair-iphone", IconName::Smartphone, "Pair iPhone…", None).on_click(
                    |_, window, cx| {
                        window.remove_window();
                        crate::app::open_settings_at(crate::ui::settings::Page::IphoneSharing, cx);
                    },
                ),
            )
            .child(
                item(
                    "open-quotio",
                    IconName::Settings,
                    "Open Quotio…",
                    Some(shortcut(",")),
                )
                .on_click(|_, window, cx| {
                    window.remove_window();
                    crate::app::open_settings(cx);
                }),
            )
            .child(
                item("quit", IconName::Power, "Quit Quotio", Some(shortcut("q")))
                    .on_click(|_, _, cx| crate::app::quit(cx)),
            )
    }
}

impl Render for QuotaMenu {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let p = palette(cx).clone();
        let overview = self.store.read(cx).overview.clone();
        let groups: Vec<AnyElement> = match &overview {
            Some(overview) => overview
                .groups
                .iter()
                .filter(|g| self.filter.as_ref().is_none_or(|f| *f == g.provider_id))
                .enumerate()
                .map(|(index, group)| self.group(index, group, cx))
                .collect(),
            None => Vec::new(),
        };
        let empty = overview.as_ref().is_some_and(|o| o.groups.is_empty());
        // Long account lists scroll inside the popup instead of leaving the screen.
        let max_groups = window.display(cx).map_or(px(560.), |d| {
            d.bounds().size.height * 0.85 - px(CHROME_HEIGHT)
        });
        div()
            // Fit the window to the panel's natural height once it is laid out.
            .on_children_prepainted(|bounds, window, _| {
                let Some(panel) = bounds.first() else { return };
                let viewport = window.viewport_size();
                if (viewport.height - panel.size.height).abs() > px(1.) {
                    window.resize(size(viewport.width, panel.size.height));
                }
            })
            .id("quota-menu")
            .track_focus(&self.focus)
            .on_key_down(cx.listener(Self::on_key_down))
            .size_full()
            .font_family(FONT_FAMILY)
            .line_height(relative(1.45))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .bg(p.bg_white)
                    .border_1()
                    .border_color(p.stroke_soft)
                    .rounded(px(14.))
                    .p(px(6.))
                    .overflow_hidden()
                    .child(self.header(overview.as_ref(), cx))
                    .when_some(overview.as_ref(), |s, overview| {
                        s.child(self.chips(overview, cx))
                    })
                    .child(
                        div()
                            .id("groups")
                            .max_h(max_groups)
                            .overflow_y_scroll()
                            .flex()
                            .flex_col()
                            .gap(px(8.))
                            .pb(px(4.))
                            .children(groups)
                            .when(empty, |s| {
                                s.child(
                                    div()
                                        .p(px(16.))
                                        .text_size(px(13.))
                                        .text_color(p.text_sub)
                                        .child("No accounts yet. Open Quotio to add one."),
                                )
                            }),
                    )
                    .child(self.footer(cx)),
            )
    }
}

/// Comfortable shows the limits as tiles; Detailed gives each limit a full-width row.
fn account_card(account: &AccountView, name: String, detailed: bool, p: &Palette) -> AnyElement {
    let group = SharedString::from(format!("card-{}", account.id));
    let mut card = div()
        .id(group.clone())
        .group(group.clone())
        .flex()
        .flex_col()
        .mx(px(4.))
        .p(px(if detailed { 12. } else { 10. }))
        .rounded(px(12.))
        .gap(px(match (detailed, account.issue.is_some()) {
            (_, true) => 8.,
            (true, false) => 12.,
            (false, false) => 10.,
        }))
        .cursor_pointer()
        .hover(|s| s.bg(p.bg_weak))
        .on_click(|_, window, cx| {
            window.remove_window();
            crate::app::open_settings(cx);
        })
        .child(card_header(account, name, &group, p));
    if let Some(issue) = &account.issue {
        card = card.child(
            div()
                .flex()
                .items_center()
                .gap(px(6.))
                .px(px(8.))
                .py(px(6.))
                .rounded(px(8.))
                .bg(p.error_alpha)
                .text_size(px(12.))
                .text_color(p.error)
                .child(icon(IconName::CircleAlert, 13., p.error))
                .child(div().flex_1().child(issue.title.clone()))
                .child(
                    div()
                        .font_weight(FontWeight::MEDIUM)
                        .child(issue.action.clone()),
                ),
        );
    } else if detailed {
        card = card.children(account.metrics.iter().map(|m| metric_row(m, p)));
    } else if !account.metrics.is_empty() {
        let single = account.metrics.len() == 1;
        card = card.child(
            div()
                .grid()
                .grid_cols(if single { 1 } else { 2 })
                .gap(px(8.))
                .children(account.metrics.iter().map(|m| metric_tile(m, &group, p))),
        );
    }
    card.into_any_element()
}

fn card_header(
    account: &AccountView,
    name: String,
    group: &SharedString,
    p: &Palette,
) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap(px(8.))
        .child(
            div()
                .min_w_0()
                .truncate()
                .text_size(px(13.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(p.text_strong)
                .child(name),
        )
        .when(account.pinned, |s| {
            s.child(icon(IconName::Pin, 11., p.text_soft))
        })
        .when_some(account.plan.clone(), |s, plan| {
            s.child(
                div()
                    .flex_none()
                    .px(px(6.))
                    .py(px(2.))
                    .rounded(px(6.))
                    .border_1()
                    .border_color(p.stroke_soft)
                    .bg(p.bg_weak)
                    .group_hover(group.clone(), |s| s.bg(p.bg_white))
                    .text_size(px(11.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.text_sub)
                    .child(plan),
            )
        })
        .child(div().flex_1())
        .when_some(account.updated.clone(), |s, updated| {
            s.child(
                div()
                    .flex_none()
                    .text_size(px(11.))
                    .text_color(p.text_soft)
                    .child(updated),
            )
        })
        .child(
            div()
                .invisible()
                .group_hover(group.clone(), |s| s.visible())
                .child(icon(IconName::ChevronRight, 14., p.text_soft)),
        )
}

fn metric_tile(metric: &MetricView, group: &SharedString, p: &Palette) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap(px(6.))
        .p(px(8.))
        .rounded(px(10.))
        .bg(p.bg_weak)
        .group_hover(group.clone(), |s| s.bg(p.bg_white))
        .min_w_0()
        .child(
            div()
                .flex()
                .justify_between()
                .items_baseline()
                .gap(px(6.))
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(px(11.))
                        .text_color(p.text_sub)
                        .child(metric.label.clone()),
                )
                .child(
                    div()
                        .flex_none()
                        .text_size(px(13.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(value_color(metric.tone, p))
                        .child(metric.value.clone()),
                ),
        )
        .child(progress(metric.fill, metric.tone, px(4.), p))
        .when_some(metric.reset.clone(), |s, reset| {
            s.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .text_size(px(11.))
                    .text_color(p.text_soft)
                    .child(icon(IconName::Clock, 11., p.text_soft))
                    .child(reset),
            )
        })
}

/// Detailed density: one limit across the card, with its reset in words.
fn metric_row(metric: &MetricView, p: &Palette) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap(px(6.))
        .child(
            div()
                .flex()
                .justify_between()
                .items_baseline()
                .gap(px(8.))
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(px(12.))
                        .text_color(p.text_sub)
                        .child(metric.label.clone()),
                )
                .child(
                    div()
                        .flex_none()
                        .text_size(px(13.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(value_color(metric.tone, p))
                        .child(metric.value.clone()),
                ),
        )
        .child(progress(metric.fill, metric.tone, px(6.), p))
        .when_some(metric.reset_sentence(), |s, reset| {
            s.child(
                div()
                    .text_size(px(11.))
                    .text_color(p.text_soft)
                    .child(reset),
            )
        })
}

/// Compact density: one line per account, a mini bar for each of the two tightest
/// limits, and the value of the limit that runs out first.
fn compact_row(account: &AccountView, name: String, p: &Palette) -> AnyElement {
    let left = |m: &MetricView| m.remaining.unwrap_or(1.);
    let mut tightest: Vec<&MetricView> = account.metrics.iter().collect();
    tightest.sort_by(|a, b| left(a).total_cmp(&left(b)));
    let binding = tightest.first().copied();
    tightest.truncate(2);
    let out = binding.is_some_and(|m| m.remaining == Some(0.));
    div()
        .id(SharedString::from(format!("card-{}", account.id)))
        .flex()
        .items_center()
        .gap(px(10.))
        .mx(px(4.))
        .px(px(10.))
        .py(px(8.))
        .rounded(px(9.))
        .cursor_pointer()
        .hover(|s| s.bg(p.bg_weak))
        .on_click(|_, window, cx| {
            window.remove_window();
            crate::app::open_settings(cx);
        })
        .child(provider_logo(&account.provider_id, 13., None, p))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(px(13.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(if out { p.text_soft } else { p.text_strong })
                .child(name),
        )
        .map(|row| match (&account.issue, binding) {
            (Some(issue), _) => row.child(
                div()
                    .flex_none()
                    .flex()
                    .items_center()
                    .gap(px(4.))
                    .text_size(px(11.))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(p.error)
                    .child(icon(IconName::CircleAlert, 12., p.error))
                    .child(issue.title.clone()),
            ),
            (None, Some(binding)) => row
                .child(
                    div()
                        .flex_none()
                        .w(px(56.))
                        .flex()
                        .flex_col()
                        .gap(px(4.))
                        .children(
                            account
                                .metrics
                                .iter()
                                .filter(|m| tightest.iter().any(|t| std::ptr::eq(*t, *m)))
                                .map(|m| {
                                    progress(m.fill, m.tone, px(4.), p)
                                        .when(m.remaining == Some(0.), |s| s.bg(p.error_alpha))
                                }),
                        ),
                )
                .child(
                    div()
                        .flex_none()
                        .w(px(62.))
                        .flex()
                        .flex_col()
                        .items_end()
                        .child(
                            div()
                                .text_size(px(13.))
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(value_color(binding.tone, p))
                                .child(binding.value.clone()),
                        )
                        .when_some(binding.reset.clone(), |s, reset| {
                            let reset = if reset.starts_with(|c: char| c.is_ascii_digit()) {
                                format!("in {reset}")
                            } else {
                                reset
                            };
                            s.child(
                                div()
                                    .whitespace_nowrap()
                                    .text_size(px(10.))
                                    .text_color(p.text_soft)
                                    .child(reset),
                            )
                        }),
                ),
            (None, None) => row,
        })
        .into_any_element()
}

const CHROME_HEIGHT: f32 = 6. + 56. + 39. + 97. + 6.;

/// Initial window height, close to the laid-out height so the popup does not jump
/// when `render` fits the window to its content.
pub fn preferred_height_for(overview: Option<&Overview>, density: Density) -> f32 {
    let Some(overview) = overview else {
        return CHROME_HEIGHT + 60.;
    };
    let groups: f32 = overview
        .groups
        .iter()
        .map(|group| {
            36. + group
                .accounts
                .iter()
                .map(
                    |account| match (density, &account.issue, account.metrics.len()) {
                        (Density::Compact, None, n) if n > 0 => 49.,
                        (Density::Compact, _, _) => 35.,
                        (Density::Comfortable, Some(_), _) => 76.,
                        (Density::Detailed, Some(_), _) => 80.,
                        (Density::Comfortable, None, 0) => 40.,
                        (Density::Detailed, None, n) => 46. + n as f32 * 65.,
                        (Density::Comfortable, None, n) => {
                            let rows = n.div_ceil(2) as f32;
                            50. + rows * 62. + (rows - 1.) * 8.
                        }
                    },
                )
                .sum::<f32>()
        })
        .sum::<f32>()
        + overview.groups.len().saturating_sub(1) as f32 * 9.
        + 4.;
    CHROME_HEIGHT + groups.min(720.)
}

pub fn open_in(store: Entity<QuotaStore>, window: &mut Window, cx: &mut App) -> Entity<QuotaMenu> {
    cx.new(|cx| QuotaMenu::new(store, window, cx))
}
