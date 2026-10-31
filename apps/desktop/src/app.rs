//! Window lifecycle: the tray popup and the settings window.
use std::time::{Duration, Instant};

use gpui_kit::{
    AnyWindowHandle, App, AppContext as _, Bounds, Entity, Global, Pixels, Point, TitlebarOptions,
    WeakEntity, WindowBackgroundAppearance, WindowBounds, WindowDecorations, WindowKind,
    WindowOptions, point, px, size,
};

use crate::store::QuotaStore;
use crate::ui::{
    menu,
    settings::{Page, SettingsWindow},
};

const APP_ID: &str = "app.quotio.Quotio";
const MENU_GAP: f32 = 8.;

struct Shell {
    store: Entity<QuotaStore>,
    menu: Option<AnyWindowHandle>,
    settings: Option<AnyWindowHandle>,
    settings_view: Option<WeakEntity<SettingsWindow>>,
    menu_dismissed_at: Option<Instant>,
}

impl Global for Shell {}

pub fn init(store: Entity<QuotaStore>, cx: &mut App) {
    cx.set_global(Shell {
        store,
        menu: None,
        settings: None,
        settings_view: None,
        menu_dismissed_at: None,
    });
}

/// Called when the popup loses focus. A tray click that arrives right after the
/// popup closed itself is the same click, so it must not reopen the popup.
pub fn note_menu_dismissed(cx: &mut App) {
    let shell = cx.global_mut::<Shell>();
    shell.menu = None;
    shell.menu_dismissed_at = Some(Instant::now());
}

pub fn toggle_menu(anchor: Option<Point<Pixels>>, cx: &mut App) {
    let shell = cx.global_mut::<Shell>();
    if let Some(handle) = shell.menu.take()
        && handle
            .update(cx, |_, window, _| window.remove_window())
            .is_ok()
    {
        return;
    }
    let shell = cx.global::<Shell>();
    if shell
        .menu_dismissed_at
        .is_some_and(|at| at.elapsed() < Duration::from_millis(400))
    {
        return;
    }
    let store = shell.store.clone();
    let height = menu::preferred_height_for(
        store.read(cx).overview.as_ref(),
        crate::prefs::get(cx).density,
    );
    let bounds = menu_bounds(anchor, height, cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        // Named for window managers that draw their own frame (X11 without a compositor).
        titlebar: cfg!(target_os = "linux").then(|| TitlebarOptions {
            title: Some("Quotio".into()),
            ..Default::default()
        }),
        focus: true,
        show: true,
        // On X11 a GPUI pop-up is override-redirect: it never receives focus, so
        // Escape and click-away could not dismiss it. Let the window manager own it.
        kind: if cfg!(target_os = "linux") {
            WindowKind::Normal
        } else {
            WindowKind::PopUp
        },
        is_movable: false,
        is_resizable: false,
        is_minimizable: false,
        window_background: WindowBackgroundAppearance::Transparent,
        window_decorations: Some(WindowDecorations::Client),
        app_id: Some(APP_ID.into()),
        ..Default::default()
    };
    match gpui_kit::open_window(options, cx, |window, cx| menu::open_in(store, window, cx)) {
        Ok((handle, _)) => {
            #[cfg(target_os = "linux")]
            if let Ok(Err(error)) = handle.update(cx, |_, window, _| {
                crate::x11::place_popup(window, bounds.origin)
            }) {
                eprintln!("Could not place the quota menu: {error:#}");
            }
            cx.global_mut::<Shell>().menu = Some(handle);
            cx.activate(true);
        }
        Err(error) => eprintln!("Could not open the quota menu: {error:#}"),
    }
}

/// Place the popup next to the tray icon, inside the display that contains it.
/// Without a position, use the corner where the platform keeps its tray.
fn menu_bounds(anchor: Option<Point<Pixels>>, height: f32, cx: &App) -> Bounds<Pixels> {
    let width = px(menu::WIDTH);
    let height = px(height);
    let display = anchor
        .and_then(|anchor| {
            cx.displays()
                .into_iter()
                .find(|d| d.bounds().contains(&anchor))
        })
        .or_else(|| cx.primary_display());
    let Some(display) = display else {
        return Bounds::new(point(px(0.), px(0.)), size(width, height));
    };
    let area = display.bounds();
    let gap = px(MENU_GAP);
    // A tall list on a short display scrolls instead; `clamp` panics if it can't fit.
    let height = height.min(area.size.height - gap * 2.);
    let anchor = anchor.unwrap_or_else(|| {
        if cfg!(windows) {
            point(area.right() - width / 2. - gap, area.bottom() - px(48.))
        } else {
            point(area.right() - width / 2. - gap, area.top() + px(28.))
        }
    });
    let x = (anchor.x - width / 2.).clamp(area.left() + gap, area.right() - width - gap);
    // A tray in the lower half of the screen means a bottom panel: open upwards.
    let y = if anchor.y > area.center().y {
        anchor.y - height - gap
    } else {
        anchor.y + gap
    }
    .clamp(area.top() + gap, area.bottom() - height - gap);
    Bounds::new(point(x, y), size(width, height))
}

pub fn open_settings(cx: &mut App) {
    let (settings, store) = {
        let shell = cx.global::<Shell>();
        (shell.settings, shell.store.clone())
    };
    if let Some(handle) = settings
        && handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    {
        cx.activate(true);
        return;
    }
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
            None,
            size(px(1158.), px(760.)),
            cx,
        ))),
        titlebar: Some(TitlebarOptions {
            title: Some("Quotio".into()),
            appears_transparent: true,
            traffic_light_position: Some(point(px(22.), px(22.))),
        }),
        window_min_size: Some(size(px(900.), px(560.))),
        window_decorations: Some(WindowDecorations::Client),
        app_id: Some(APP_ID.into()),
        ..Default::default()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        cx.new(|cx| SettingsWindow::new(store, window, cx))
    }) {
        Ok((handle, view)) => {
            let shell = cx.global_mut::<Shell>();
            shell.settings = Some(handle);
            shell.settings_view = Some(view.downgrade());
            cx.activate(true);
        }
        Err(error) => eprintln!("Could not open Quotio: {error:#}"),
    }
}

/// Open the settings window at `page`, such as iPhone Sharing from the popup.
pub fn open_settings_at(page: Page, cx: &mut App) {
    open_settings(cx);
    if let Some(view) = cx.global::<Shell>().settings_view.clone() {
        let _ = view.update(cx, |view, cx| view.show(page, cx));
    }
}

/// Open an account's quota history over the Accounts page, as the popup card's chevron does.
pub fn open_history(account: crate::model::AccountView, cx: &mut App) {
    open_settings_at(Page::Accounts, cx);
    let shell = cx.global::<Shell>();
    if let (Some(handle), Some(view)) = (shell.settings, shell.settings_view.clone()) {
        let _ = handle.update(cx, |_, window, cx| {
            view.update(cx, |view, cx| view.open_history(&account, window, cx))
        });
    }
}

pub fn refresh(cx: &mut App) {
    let store = cx.global::<Shell>().store.clone();
    store.update(cx, |store, cx| store.refresh(None, cx));
}

pub fn quit(cx: &mut App) {
    cx.quit();
}
