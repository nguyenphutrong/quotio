//! StatusNotifierItem over D-Bus (KDE, GNOME with the AppIndicator extension, XFCE,
//! Cinnamon, wlroots bars). Uses ksni rather than libappindicator, which needs a GTK
//! main loop that GPUI does not run.
use std::time::Duration;

use anyhow::{Context as _, Result};
use futures::channel::mpsc::UnboundedSender;
use ksni::{MenuItem, TrayMethods as _, menu::StandardItem};

use super::{TrayEvent, icon};

struct Item {
    events: UnboundedSender<TrayEvent>,
    pixmap: Vec<u8>,
    tooltip: String,
}

impl Item {
    fn send(&self, event: TrayEvent) {
        let _ = self.events.unbounded_send(event);
    }
}

impl ksni::Tray for Item {
    fn id(&self) -> String {
        "app.quotio.Quotio".into()
    }

    fn title(&self) -> String {
        "Quotio".into()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        vec![ksni::Icon {
            width: icon::SIZE as i32,
            height: icon::SIZE as i32,
            data: self.pixmap.clone(),
        }]
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip {
            title: "Quotio".into(),
            description: self.tooltip.clone(),
            ..Default::default()
        }
    }

    fn activate(&mut self, x: i32, y: i32) {
        // Some hosts report (0, 0) when they do not know the click position.
        let position = (x != 0 || y != 0).then_some((x, y));
        self.send(TrayEvent::Activate(position));
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let item = |label: &str, event: TrayEvent| {
            StandardItem {
                label: label.into(),
                activate: Box::new(move |tray: &mut Self| tray.send(event)),
                ..Default::default()
            }
            .into()
        };
        vec![
            item("Show Quota", TrayEvent::Activate(None)),
            item("Refresh", TrayEvent::Refresh),
            item("Open Quotio…", TrayEvent::OpenSettings),
            MenuItem::Separator,
            item("Quit Quotio", TrayEvent::Quit),
        ]
    }
}

/// ARGB32 in network byte order, as the SNI specification requires.
fn argb(rgba: &[u8]) -> Vec<u8> {
    rgba.chunks_exact(4)
        .flat_map(|p| [p[3], p[0], p[1], p[2]])
        .collect()
}

pub struct Tray {
    handle: ksni::Handle<Item>,
    runtime: tokio::runtime::Handle,
}

impl Tray {
    pub fn start(
        events: UnboundedSender<TrayEvent>,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Self> {
        let item = Item {
            events,
            pixmap: argb(&icon::gauge(None, icon::Style::default())),
            tooltip: String::new(),
        };
        let handle = runtime
            .block_on(async { tokio::time::timeout(Duration::from_secs(5), item.spawn()).await })
            .context("tray registration timed out")?
            .context("no StatusNotifierItem host")?;
        Ok(Self {
            handle,
            runtime: runtime.clone(),
        })
    }

    /// `gauge` is RGBA pixels from `icon::gauge`.
    pub fn update(&self, gauge: Vec<u8>, tooltip: String) {
        let handle = self.handle.clone();
        let pixmap = argb(&gauge);
        self.runtime.spawn(async move {
            handle
                .update(|item| {
                    item.pixmap = pixmap;
                    item.tooltip = tooltip;
                })
                .await;
        });
    }
}
