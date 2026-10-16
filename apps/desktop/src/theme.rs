//! Design tokens from the Wonder `Personal → Quotio` page. Views read colors from
//! here instead of hard-coding them so a dark palette can be added as another set.
use gpui_kit::{App, BoxShadow, Global, Hsla, point, px, rgb, rgba};

pub const FONT_FAMILY: &str = "Inter";

#[derive(Clone)]
pub struct Palette {
    pub bg_white: Hsla,
    pub bg_weak: Hsla,
    pub stroke_soft: Hsla,
    pub text_strong: Hsla,
    pub text_sub: Hsla,
    pub text_soft: Hsla,
    pub primary: Hsla,
    pub away: Hsla,
    pub error: Hsla,
    pub error_alpha: Hsla,
    pub on_strong: Hsla,
}

impl Palette {
    pub fn light() -> Self {
        Self {
            bg_white: rgb(0xffffff).into(),
            bg_weak: rgb(0xf7f7f7).into(),
            stroke_soft: rgb(0xebebeb).into(),
            text_strong: rgb(0x171717).into(),
            text_sub: rgb(0x5c5c5c).into(),
            text_soft: rgb(0xa3a3a3).into(),
            primary: rgb(0x1daf61).into(),
            away: rgb(0xf6b51e).into(),
            error: rgb(0xfb3748).into(),
            error_alpha: rgba(0xfb37481a).into(),
            on_strong: rgb(0xffffff).into(),
        }
    }
}

impl Global for Palette {}

pub fn palette(cx: &App) -> &Palette {
    cx.global::<Palette>()
}

fn shadow(color: u32, y: f32, blur: f32, spread: f32) -> BoxShadow {
    BoxShadow {
        color: rgba(color).into(),
        offset: point(px(0.), px(y)),
        blur_radius: px(blur),
        spread_radius: px(spread),
        inset: false,
    }
}

/// `shadow-[0px_1px_2px_rgba(23,23,23,0.06),0px_0px_0px_1px_rgba(23,23,23,0.06)]`
pub fn raised() -> Vec<BoxShadow> {
    vec![
        shadow(0x1717170f, 1., 2., 0.),
        shadow(0x1717170f, 0., 0., 1.),
    ]
}

/// Secondary buttons use a slightly stronger ring than raised rows.
pub fn button() -> Vec<BoxShadow> {
    vec![
        shadow(0x1717170f, 1., 2., 0.),
        shadow(0x1717171a, 0., 0., 1.),
    ]
}

/// Content panel inside the settings window.
pub fn panel() -> Vec<BoxShadow> {
    vec![
        shadow(0x1717170a, 3., 3., -1.5),
        shadow(0x1717170a, 1., 1., -0.5),
        shadow(0x17171714, 0., 0., 1.),
    ]
}
