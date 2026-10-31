pub mod icon;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
/// tray-icon drives both the Windows notification area and the macOS menu bar.
#[cfg(any(windows, target_os = "macos"))]
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
#[cfg(any(windows, target_os = "macos"))]
pub use windows::Tray;

use crate::model::{AccountView, Tone, tone};

/// One account next to the menu bar icon: a dot, then one line or a stacked pair.
pub struct Item {
    pub dot: Tone,
    pub lines: Vec<(String, Tone)>,
}

/// What an account shows next to the icon. The Menu Bar settings preview uses it too.
pub fn item(account: &AccountView, stack_paired: bool, used: bool) -> Item {
    if account.issue.is_some() {
        return Item {
            dot: Tone::Neutral,
            lines: vec![("⚠︎".into(), Tone::Warning)],
        };
    }
    let percents: Vec<_> = account
        .metrics
        .iter()
        .filter(|m| m.remaining.is_some())
        .collect();
    // A session and a weekly limit share one two-line item.
    if stack_paired && let [top, bottom] = percents[..] {
        let lowest = if top.remaining <= bottom.remaining {
            top
        } else {
            bottom
        };
        return Item {
            dot: lowest.tone,
            lines: vec![
                (top.value.clone(), top.tone),
                (bottom.value.clone(), bottom.tone),
            ],
        };
    }
    match account.total {
        Some(total) => {
            let tone = tone(total as f64 * 100.);
            Item {
                dot: tone,
                lines: vec![(percent(total, used), tone)],
            }
        }
        None => Item {
            dot: Tone::Neutral,
            lines: vec![("—".into(), Tone::Neutral)],
        },
    }
}

/// `74%`, as remaining or as used per Quota display.
pub fn percent(remaining: f32, used: bool) -> String {
    let shown = if used { 1. - remaining } else { remaining };
    format!("{:.0}%", shown.clamp(0., 1.) * 100.)
}

/// Other platforms have no tray.
#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
pub struct Tray;

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
impl Tray {
    pub fn start(
        _events: futures::channel::mpsc::UnboundedSender<TrayEvent>,
        _runtime: &tokio::runtime::Handle,
    ) -> anyhow::Result<Self> {
        anyhow::bail!("no tray on this platform")
    }

    pub fn update(&self, _gauge: Vec<u8>, _tooltip: String) {}
}
