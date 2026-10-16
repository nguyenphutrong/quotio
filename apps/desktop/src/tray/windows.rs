//! Notification-area icon. tray-icon drives Shell_NotifyIcon from the thread that
//! created it, which is GPUI's main thread and its Win32 message loop.
use anyhow::Result;
use futures::channel::mpsc::UnboundedSender;
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};

use super::{TrayEvent, icon};

pub struct Tray {
    icon: TrayIcon,
}

fn bitmap(remaining: Option<f32>) -> Result<Icon> {
    Ok(Icon::from_rgba(
        icon::gauge(remaining),
        icon::SIZE,
        icon::SIZE,
    )?)
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
                // Anchor at the top centre of the icon; the popup opens above the taskbar.
                let x = rect.position.x + rect.size.width as f64 / 2.;
                let _ = clicks.unbounded_send(TrayEvent::Activate(Some((
                    x as i32,
                    rect.position.y as i32,
                ))));
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
            .with_icon(bitmap(None)?)
            .with_menu(Box::new(menu))
            .with_menu_on_left_click(false)
            .build()?;
        Ok(Self { icon })
    }

    pub fn update(&self, remaining: Option<f32>, tooltip: String) {
        if let Ok(icon) = bitmap(remaining) {
            let _ = self.icon.set_icon(Some(icon));
        }
        let _ = self.icon.set_tooltip(Some(tooltip));
    }
}
