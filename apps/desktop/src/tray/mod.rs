pub mod icon;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(windows)]
mod windows;

#[derive(Clone, Copy, Debug)]
pub enum TrayEvent {
    /// Primary click, with the screen position the platform reported, if any.
    Activate(Option<(i32, i32)>),
    OpenSettings,
    Refresh,
    Quit,
}

#[cfg(target_os = "linux")]
pub use linux::Tray;
#[cfg(windows)]
pub use windows::Tray;

/// macOS keeps its native Swift menu bar; the GPUI app there has no tray of its own.
#[cfg(not(any(target_os = "linux", windows)))]
pub struct Tray;

#[cfg(not(any(target_os = "linux", windows)))]
impl Tray {
    pub fn start(
        _events: futures::channel::mpsc::UnboundedSender<TrayEvent>,
        _runtime: &tokio::runtime::Handle,
    ) -> anyhow::Result<Self> {
        anyhow::bail!("no tray on this platform")
    }

    pub fn update(&self, _gauge: Vec<u8>, _tooltip: String) {}
}
