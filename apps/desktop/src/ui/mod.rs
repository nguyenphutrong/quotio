pub mod accounts;
pub mod menu;

use gpui_kit::assets::IconName;
use gpui_kit::component::Icon;
use gpui_kit::{
    AnyElement, Div, FontWeight, Hsla, IntoElement, ParentElement, Pixels, Styled, div, img,
    prelude::FluentBuilder as _, px, relative, svg,
};

use crate::model::Tone;
use crate::providers;
use crate::theme::Palette;

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

/// Provider logo in full color, or tinted with one color like the design's chips and
/// headers. Providers without artwork get a monogram.
pub fn provider_logo(provider_id: &str, size: f32, tint: Option<Hsla>, p: &Palette) -> AnyElement {
    match (providers::logo_path(provider_id), tint) {
        (Some(path), Some(tint)) => svg()
            .path(path)
            .size(px(size))
            .flex_none()
            .text_color(tint)
            .into_any_element(),
        (Some(path), None) => img(path).size(px(size)).flex_none().into_any_element(),
        (None, _) => div()
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

pub fn progress(remaining: Option<f32>, tone: Tone, height: Pixels, p: &Palette) -> Div {
    div()
        .w_full()
        .h(height)
        .rounded_full()
        .bg(p.stroke_soft)
        .overflow_hidden()
        .when_some(remaining, |track, remaining| {
            track.child(
                div()
                    .h_full()
                    .w(relative(remaining))
                    .rounded_full()
                    .bg(tone_color(tone, p)),
            )
        })
}
