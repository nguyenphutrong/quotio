//! X11 window-manager hints GPUI does not expose. The popup is a managed window so it
//! can take focus, but GPUI sets no position hint, so window managers place it
//! wherever they like and list it in the taskbar.
use anyhow::Result;
use gpui_kit::{Pixels, Point, Window};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use x11rb::{
    connection::Connection as _,
    protocol::xproto::{ClientMessageEvent, ConfigureWindowAux, ConnectionExt as _, EventMask},
};

/// Move the popup to `origin` and keep it above other windows, out of the taskbar
/// and pager. Does nothing on Wayland, where clients cannot position windows.
pub fn place_popup(window: &Window, origin: Point<Pixels>) -> Result<()> {
    let id = match HasWindowHandle::window_handle(window)?.as_raw() {
        RawWindowHandle::Xcb(handle) => handle.window.get(),
        RawWindowHandle::Xlib(handle) => handle.window as u32,
        _ => return Ok(()),
    };
    let scale = window.scale_factor();
    let (conn, screen) = x11rb::connect(None)?;
    let root = conn.setup().roots[screen].root;
    let atom =
        |name: &str| -> Result<u32> { Ok(conn.intern_atom(false, name.as_bytes())?.reply()?.atom) };
    let state = atom("_NET_WM_STATE")?;
    const ADD: u32 = 1;
    for (first, second) in [
        (
            atom("_NET_WM_STATE_SKIP_TASKBAR")?,
            atom("_NET_WM_STATE_SKIP_PAGER")?,
        ),
        (atom("_NET_WM_STATE_ABOVE")?, 0),
    ] {
        let event = ClientMessageEvent::new(32, id, state, [ADD, first, second, 1, 0]);
        conn.send_event(
            false,
            root,
            EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY,
            event,
        )?;
    }
    let x = (f32::from(origin.x) * scale).round() as i32;
    let y = (f32::from(origin.y) * scale).round() as i32;
    conn.configure_window(id, &ConfigureWindowAux::new().x(x).y(y))?;
    conn.flush()?;
    // Wait until the server has processed the requests before the connection closes.
    conn.get_input_focus()?.reply()?;
    Ok(())
}
