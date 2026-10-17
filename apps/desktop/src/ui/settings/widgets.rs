//! Building blocks shared by the settings pages, from the Wonder "Page - Quotio
//! Settings …" artboards: a page header, sections with an intro column, rows,
//! toggles and selects.
use gpui_kit::component::Disableable as _;
use gpui_kit::component::button::Button;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::{
    AnyElement, App, ClickEvent, Div, ElementId, FontWeight, InteractiveElement, IntoElement,
    ParentElement, SharedString, Stateful, StatefulInteractiveElement as _, Styled, Window, div,
    prelude::FluentBuilder as _, px,
};

use crate::theme::Palette;

pub fn page(title: &str, subtitle: &str, p: &Palette) -> Div {
    div().flex().flex_col().gap(px(24.)).child(
        div()
            .flex()
            .flex_col()
            .gap(px(4.))
            .pb(px(20.))
            .border_b_1()
            .border_color(p.stroke_soft)
            .child(
                div()
                    .text_size(px(18.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(p.text_strong)
                    .child(title.to_owned()),
            )
            .child(
                div()
                    .text_size(px(14.))
                    .text_color(p.text_sub)
                    .child(subtitle.to_owned()),
            ),
    )
}

/// A titled block: a 220 px intro column, then rows or other content.
pub fn section(
    title: &str,
    description: impl Into<SharedString>,
    content: impl IntoElement,
    p: &Palette,
) -> Div {
    div()
        .flex()
        .gap(px(32.))
        .pb(px(24.))
        .border_b_1()
        .border_color(p.stroke_soft)
        .child(
            div()
                .w(px(220.))
                .flex_none()
                .flex()
                .flex_col()
                .gap(px(4.))
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(p.text_strong)
                        .child(title.to_owned()),
                )
                .child(
                    div()
                        .text_size(px(12.))
                        .text_color(p.text_sub)
                        .child(description.into()),
                ),
        )
        .child(div().flex().flex_col().flex_1().min_w_0().child(content))
}

/// Rows separated by hairlines.
pub fn rows(items: impl IntoIterator<Item = AnyElement>, p: &Palette) -> Div {
    div()
        .flex()
        .flex_col()
        .children(items.into_iter().enumerate().map(|(i, item)| {
            div()
                .when(i > 0, |s| s.border_t_1().border_color(p.stroke_soft))
                .child(item)
        }))
}

pub fn row(
    label: impl Into<SharedString>,
    help: Option<SharedString>,
    control: impl IntoElement,
    p: &Palette,
) -> AnyElement {
    div()
        .flex()
        .items_center()
        .gap(px(16.))
        .py(px(12.))
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
                        .child(label.into()),
                )
                .when_some(help, |s, help| {
                    s.child(div().text_size(px(12.)).text_color(p.text_sub).child(help))
                }),
        )
        .child(div().flex_none().child(control))
        .into_any_element()
}

/// 36×20 switch. A disabled toggle is dimmed and ignores clicks.
pub fn toggle(
    id: impl Into<ElementId>,
    on: bool,
    enabled: bool,
    p: &Palette,
    on_change: impl Fn(&bool, &mut Window, &mut App) + 'static,
) -> Stateful<Div> {
    div()
        .id(id)
        .w(px(36.))
        .h(px(20.))
        .flex()
        .when(on, |s| s.justify_end())
        .p(px(2.))
        .rounded_full()
        .bg(if on { p.primary } else { p.stroke_soft })
        .map(|s| {
            if enabled {
                s.cursor_pointer()
                    .on_click(move |_, window, cx| on_change(&!on, window, cx))
            } else {
                s.opacity(0.5)
            }
        })
        .child(
            div()
                .size(px(16.))
                .rounded_full()
                .bg(gpui_kit::white())
                .shadow_sm(),
        )
}

/// A select box that opens a menu of `options`.
pub fn select<T: Clone + PartialEq + 'static>(
    id: &str,
    options: Vec<(T, String)>,
    selected: &T,
    enabled: bool,
    on_change: impl Fn(&T, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    let label = options
        .iter()
        .find(|(value, _)| value == selected)
        .map_or_else(String::new, |(_, label)| label.clone());
    let current = selected.clone();
    let on_change = std::rc::Rc::new(on_change);
    Button::new(SharedString::from(id.to_owned()))
        .outline()
        .w(px(180.))
        .label(label)
        .dropdown_caret(true)
        .disabled(!enabled)
        .dropdown_menu(move |menu: PopupMenu, _, _| {
            options
                .iter()
                .fold(menu.min_w(px(180.)), |menu, (value, label)| {
                    let (value, on_change) = (value.clone(), on_change.clone());
                    menu.item(
                        PopupMenuItem::new(label.clone())
                            .checked(value == current)
                            .on_click(move |_: &ClickEvent, window, cx| {
                                on_change(&value, window, cx)
                            }),
                    )
                })
        })
}
