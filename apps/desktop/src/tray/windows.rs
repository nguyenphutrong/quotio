//! Notification-area icon on Windows, status item on macOS. tray-icon drives
//! Shell_NotifyIcon or NSStatusItem from the thread that created it, which is GPUI's
//! main thread and its event loop.
use anyhow::Result;
use futures::channel::mpsc::UnboundedSender;
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};

#[cfg(target_os = "macos")]
use super::macos::logical;
use super::{TrayEvent, icon};

pub struct Tray {
    pub(super) icon: TrayIcon,
}

fn bitmap(pixels: Vec<u8>) -> Result<Icon> {
    Ok(Icon::from_rgba(pixels, icon::SIZE, icon::SIZE)?)
}

impl Tray {
    pub fn start(
        events: UnboundedSender<TrayEvent>,
        _runtime: &tokio::runtime::Handle,
    ) -> Result<Self> {
        let menu = Menu::new();
        let open = MenuItem::with_id("open", "Open Quotio…", true, None);
        let refresh = MenuItem::with_id("refresh", "Refresh", true, None);
        let quit = MenuItem::with_id("quit", "Quit Quotio", true, None);
        menu.append(&refresh)?;
        menu.append(&open)?;
        menu.append(&PredefinedMenuItem::separator())?;
        menu.append(&quit)?;

        let clicks = events.clone();
        TrayIconEvent::set_event_handler(Some(move |event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                rect,
                ..
            } = event
            {
                // Anchor at the centre of the icon's edge that faces the screen: the
                // top of a taskbar icon, the bottom of a menu bar item.
                let x = rect.position.x + rect.size.width as f64 / 2.;
                let y = if cfg!(windows) {
                    rect.position.y
                } else {
                    rect.position.y + rect.size.height as f64
                };
                let (x, y) = logical(x, y);
                let _ = clicks.unbounded_send(TrayEvent::Activate(Some((x as i32, y as i32))));
            }
        }));
        MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
            let event = match event.id.as_ref() {
                "open" => TrayEvent::OpenSettings,
                "refresh" => TrayEvent::Refresh,
                "quit" => TrayEvent::Quit,
                _ => return,
            };
            let _ = events.unbounded_send(event);
        }));

        let icon = TrayIconBuilder::new()
            .with_id("quotio")
            .with_tooltip("Quotio")
            .with_icon(bitmap(icon::gauge(None, icon::Style::default()))?)
            .with_menu(Box::new(menu))
            .with_menu_on_left_click(false)
            .build()?;
        Ok(Self { icon })
    }

    /// `gauge` is RGBA pixels from `icon::gauge`.
    pub fn update(&self, gauge: Vec<u8>, tooltip: String) {
        if let Ok(icon) = bitmap(gauge) {
            let _ = self.icon.set_icon(Some(icon));
        }
        let _ = self.icon.set_tooltip(Some(tooltip));
    }
}

/// tray-icon reports physical pixels; GPUI places windows in logical pixels,
/// each display divided by its own scale.
#[cfg(windows)]
fn logical(x: f64, y: f64) -> (f64, f64) {
    use windows_sys::Win32::Foundation::POINT;
    use windows_sys::Win32::Graphics::Gdi::{MONITOR_DEFAULTTONEAREST, MonitorFromPoint};
    use windows_sys::Win32::UI::HiDpi::{GetDpiForMonitor, MDT_EFFECTIVE_DPI};
    let point = POINT {
        x: x as i32,
        y: y as i32,
    };
    let (mut dpi, mut _dpi_y) = (96u32, 96u32);
    // SAFETY: plain Win32 calls with valid out-pointers.
    let ok = unsafe {
        let monitor = MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
        GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi, &mut _dpi_y) == 0
    };
    let scale = if ok { dpi as f64 / 96. } else { 1. };
    (x / scale, y / scale)
}
