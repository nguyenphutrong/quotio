use std::borrow::Cow;

use gpui_kit::assets::{Assets as ComponentAssets, icon_assets};
use gpui_kit::{App, AssetSource, Result, SharedString};
use rust_embed::RustEmbed;

#[derive(RustEmbed)]
#[folder = "assets"]
#[include = "providers/*.svg"]
#[include = "nav/*.svg"]
#[include = "fonts/*.otf"]
pub struct AppFiles;

icon_assets!(
    ExtraIcons,
    [
        Clock,
        Gauge,
        Pin,
        Smartphone,
        Power,
        LayoutGrid,
        ChartLine,
        Users,
        Shield,
        AppWindow,
        CirclePlus,
        KeyRound,
        PanelTop,
        Pencil,
        Trash,
        Monitor,
        Wifi,
        ShieldUser,
        ShieldKeyhole,
        Tablet,
        Lock,
        ArrowUpRight,
        Timer,
        PinOff,
        RotateCcwClock
    ]
);

/// Application files first, then selected Lucide icons, then the default component icons.
pub struct AppAssets;

impl AssetSource for AppAssets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        if let Some(file) = AppFiles::get(path) {
            return Ok(Some(file.data));
        }
        if let Some(bytes) = ExtraIcons.load(path)? {
            return Ok(Some(bytes));
        }
        ComponentAssets.load(path)
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        let mut paths: Vec<SharedString> = AppFiles::iter()
            .filter(|p| p.starts_with(path))
            .map(|p| p.to_string().into())
            .collect();
        paths.extend(ExtraIcons.list(path)?);
        paths.extend(ComponentAssets.list(path)?);
        paths.sort();
        paths.dedup();
        Ok(paths)
    }
}

pub fn load_fonts(cx: &mut App) -> Result<()> {
    let fonts = AppFiles::iter()
        .filter(|p| p.starts_with("fonts/"))
        .filter_map(|p| AppFiles::get(&p).map(|f| f.data))
        .collect();
    cx.text_system().add_fonts(fonts)
}
