//! Design tokens from the Wonder `Personal → Quotio` page. Views read colors from
//! here instead of hard-coding them. The dark set maps each token to its AlignUI
//! dark-mode counterpart, the system the Wonder tokens come from.
use gpui_kit::component::{Theme, ThemeMode};
use gpui_kit::{App, BoxShadow, Global, Hsla, WindowAppearance, point, px, rgb, rgba};
use serde::{Deserialize, Serialize};

pub const FONT_FAMILY: &str = "Inter";

/// The user's choice in General → Appearance.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Appearance {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Clone)]
pub struct Palette {
    pub dark: bool,
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
    /// Color of rings and drop shadows: neutral-950 in light, white in dark.
    shadow: u32,
}

impl Palette {
    pub fn light() -> Self {
        Self {
            dark: false,
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
            shadow: 0x171717,
        }
    }

    pub fn dark() -> Self {
        Self {
            dark: true,
            bg_white: rgb(0x171717).into(),
            bg_weak: rgb(0x1c1c1c).into(),
            stroke_soft: rgb(0x292929).into(),
            text_strong: rgb(0xffffff).into(),
            text_sub: rgb(0xa3a3a3).into(),
            text_soft: rgb(0x7b7b7b).into(),
            primary: rgb(0x1fc16b).into(),
            away: rgb(0xf6b51e).into(),
            error: rgb(0xfb3748).into(),
            error_alpha: rgba(0xfb374829).into(),
            on_strong: rgb(0x171717).into(),
            shadow: 0xffffff,
        }
    }

    fn shadow(&self, alpha: u8, y: f32, blur: f32, spread: f32) -> BoxShadow {
        // Dark surfaces get no visible drop shadow; the ring does the separating.
        let alpha = if self.dark && y > 0. { 0 } else { alpha };
        BoxShadow {
            color: rgba(self.shadow << 8 | alpha as u32).into(),
            offset: point(px(0.), px(y)),
            blur_radius: px(blur),
            spread_radius: px(spread),
            inset: false,
        }
    }

    /// `shadow-[0px_1px_2px_rgba(23,23,23,0.06),0px_0px_0px_1px_rgba(23,23,23,0.06)]`
    pub fn raised(&self) -> Vec<BoxShadow> {
        vec![self.shadow(0x0f, 1., 2., 0.), self.shadow(0x0f, 0., 0., 1.)]
    }

    /// Secondary buttons use a slightly stronger ring than raised rows.
    pub fn button(&self) -> Vec<BoxShadow> {
        vec![self.shadow(0x0f, 1., 2., 0.), self.shadow(0x1a, 0., 0., 1.)]
    }

    /// Content panel inside the settings window.
    pub fn panel(&self) -> Vec<BoxShadow> {
        vec![
            self.shadow(0x0a, 3., 3., -1.5),
            self.shadow(0x0a, 1., 1., -0.5),
            self.shadow(0x14, 0., 0., 1.),
        ]
    }
}

impl Global for Palette {}

pub fn palette(cx: &App) -> &Palette {
    cx.global::<Palette>()
}

/// Remembered so `System` can follow the desktop when it switches.
struct Chosen(Appearance);

impl Global for Chosen {}

/// Apply `appearance`, resolving `System` against the desktop's current setting.
/// Component widgets (inputs, menus, dialogs) follow through the component theme.
pub fn apply(appearance: Appearance, system: WindowAppearance, cx: &mut App) {
    cx.set_global(Chosen(appearance));
    let dark = match appearance {
        Appearance::System => matches!(
            system,
            WindowAppearance::Dark | WindowAppearance::VibrantDark
        ),
        Appearance::Light => false,
        Appearance::Dark => true,
    };
    if cx.has_global::<Palette>() && palette(cx).dark == dark {
        return;
    }
    let p = if dark {
        Palette::dark()
    } else {
        Palette::light()
    };
    Theme::change(
        if dark {
            ThemeMode::Dark
        } else {
            ThemeMode::Light
        },
        None,
        cx,
    );
    // Dialogs, menus and text fields come from the component library; give them
    // the same tokens as the hand-built views.
    Theme::update(cx, |theme| {
        theme.font_family = FONT_FAMILY.into();
        theme.radius = px(10.);
        let c = &mut theme.colors;
        c.background = p.bg_white;
        c.foreground = p.text_strong;
        c.border = p.stroke_soft;
        c.input = p.stroke_soft;
        c.ring = p.text_soft;
        c.muted = p.bg_weak;
        c.muted_foreground = p.text_soft;
        c.popover = p.bg_white;
        c.popover_foreground = p.text_strong;
        c.accent = p.bg_weak;
        c.accent_foreground = p.text_strong;
        c.primary = p.text_strong;
        c.primary_hover = p.text_sub;
        c.primary_active = p.text_sub;
        c.primary_foreground = p.on_strong;
        c.danger = p.error;
        c.danger_foreground = gpui_kit::white();
    });
    cx.set_global(p);
    cx.refresh_windows();
}

/// Call when a window reports that the desktop appearance changed.
pub fn system_changed(system: WindowAppearance, cx: &mut App) {
    let chosen = cx.global::<Chosen>().0;
    if chosen == Appearance::System {
        apply(chosen, system, cx);
    }
}
