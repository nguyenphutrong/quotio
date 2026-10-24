pub mod menu;
pub mod settings;

use gpui_kit::assets::IconName;
use gpui_kit::component::Icon;
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::{
    AnyElement, App, Div, ElementId, Entity, FontWeight, Hsla, InteractiveElement, IntoElement,
    ParentElement, Pixels, SharedString, Stateful, Styled, div, prelude::FluentBuilder as _, px,
    relative, svg,
};

use crate::model::Tone;
use crate::providers;
use crate::theme::Palette;

/// An account name as the user wants it on screen: masked under Privacy → Hide
/// account names.
pub fn shown_name(name: &str, cx: &App) -> String {
    if crate::prefs::get(cx).hide_names {
        crate::model::mask(name)
    } else {
        name.to_owned()
    }
}

pub fn tone_color(tone: Tone, p: &Palette) -> Hsla {
    match tone {
        Tone::Good => p.primary,
        Tone::Warning => p.away,
        Tone::Critical => p.error,
        Tone::Neutral => p.text_soft,
    }
}

/// Percent text stays neutral until the quota is critical, as in the design.
pub fn value_color(tone: Tone, p: &Palette) -> Hsla {
    match tone {
        Tone::Critical => p.error,
        _ => p.text_strong,
    }
}

pub fn icon(name: IconName, size: f32, color: Hsla) -> Icon {
    Icon::new(name).size(px(size)).text_color(color)
}

/// Provider logo in the strong text color, or tinted like the design's chips and
/// headers. The artwork is single-color (`currentColor`), so it must follow the theme.
/// Providers without artwork get a monogram.
pub fn provider_logo(provider_id: &str, size: f32, tint: Option<Hsla>, p: &Palette) -> AnyElement {
    match providers::logo_path(provider_id) {
        Some(path) => svg()
            .path(path)
            .size(px(size))
            .flex_none()
            .text_color(tint.unwrap_or(p.text_strong))
            .into_any_element(),
        None => div()
            .size(px(size))
            .flex_none()
            .rounded_full()
            .bg(p.stroke_soft)
            .flex()
            .items_center()
            .justify_center()
            .text_size(px(size * 0.6))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(p.text_sub)
            .child(
                providers::display_name(provider_id)
                    .chars()
                    .next()
                    .unwrap_or('?')
                    .to_string(),
            )
            .into_any_element(),
    }
}

/// A bar filled to `fill`, a share in `0.0..=1.0`.
pub fn progress(fill: Option<f32>, tone: Tone, height: Pixels, p: &Palette) -> Div {
    div()
        .w_full()
        .h(height)
        .rounded_full()
        .bg(p.stroke_soft)
        .overflow_hidden()
        .when_some(fill, |track, fill| {
            track.child(
                div()
                    .h_full()
                    .w(relative(fill))
                    .rounded_full()
                    .bg(tone_color(tone, p)),
            )
        })
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ButtonKind {
    /// Filled with the strong text color, like "Add account".
    Primary,
    /// White with a ring, like "Refresh".
    Secondary,
    /// Filled red, for removing things.
    Danger,
}

/// A 32 px button from the Wonder pages.
pub fn button(
    id: impl Into<ElementId>,
    label: impl Into<SharedString>,
    kind: ButtonKind,
    p: &Palette,
) -> Stateful<Div> {
    button_base(id, kind, p).child(label.into())
}

/// A button with a 16 px icon before its label, like "Refresh" and "Add account".
pub fn button_with_icon(
    id: impl Into<ElementId>,
    glyph: IconName,
    label: impl Into<SharedString>,
    kind: ButtonKind,
    p: &Palette,
) -> Stateful<Div> {
    let color = match kind {
        ButtonKind::Primary => p.on_strong,
        ButtonKind::Secondary => p.text_strong,
        ButtonKind::Danger => gpui_kit::white(),
    };
    button_base(id, kind, p)
        .px(px(10.))
        .child(icon(glyph, 16., color))
        .child(label.into())
}

fn button_base(id: impl Into<ElementId>, kind: ButtonKind, p: &Palette) -> Stateful<Div> {
    let (bg, fg) = match kind {
        ButtonKind::Primary => (p.text_strong, p.on_strong),
        ButtonKind::Secondary => (p.bg_white, p.text_strong),
        ButtonKind::Danger => (p.error, gpui_kit::white()),
    };
    div()
        .id(id)
        .h(px(32.))
        .flex_none()
        .flex()
        .items_center()
        .justify_center()
        .gap(px(6.))
        .px(px(12.))
        .rounded(px(10.))
        .bg(bg)
        .when(kind == ButtonKind::Secondary, |s| s.shadow(p.button()))
        .cursor_pointer()
        .hover(|s| s.opacity(0.85))
        .text_size(px(14.))
        .font_weight(FontWeight::MEDIUM)
        .text_color(fg)
}

/// A 36 px text field with the design's border and radius.
pub fn text_field(state: &Entity<InputState>, p: &Palette) -> Input {
    Input::new(state)
        .h(px(36.))
        .rounded(px(10.))
        .border_color(p.stroke_soft)
        .bg(p.bg_white)
        .text_size(px(14.))
}

/// Label above a field in dialogs.
pub fn field(label: impl Into<SharedString>, control: impl IntoElement, p: &Palette) -> Div {
    div()
        .flex()
        .flex_col()
        .gap(px(6.))
        .child(
            div()
                .text_size(px(12.))
                .font_weight(FontWeight::MEDIUM)
                .text_color(p.text_sub)
                .child(label.into()),
        )
        .child(control)
}

/// Right-aligned dialog buttons.
pub fn dialog_footer() -> Div {
    div().flex().justify_end().gap(px(8.)).pt(px(8.))
}

/// Explanatory or error text under a form.
pub fn note(text: impl Into<SharedString>, color: Hsla) -> Div {
    div()
        .text_size(px(12.))
        .text_color(color)
        .child(text.into())
}
