//! Preferences that belong to this app rather than the host, such as the theme.
//! Host-wide settings (refresh interval, history, sharing) live in `/v2/settings`.
use std::path::PathBuf;

use anyhow::{Context as _, Result};
use gpui_kit::{App, Global};
use serde::{Deserialize, Serialize};

use crate::theme::Appearance;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Prefs {
    pub appearance: Appearance,
    pub quota_display: QuotaDisplay,
    pub tray_icon: TrayIcon,
    pub notifications: Notifications,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Notifications {
    pub enabled: bool,
    pub quota_low: bool,
    /// Percent left at or below which quota counts as low.
    pub threshold: u8,
    /// A limit is used up and the account waits for its reset.
    pub cooling_down: bool,
}

impl Default for Notifications {
    fn default() -> Self {
        Self {
            enabled: true,
            quota_low: true,
            threshold: 20,
            cooling_down: true,
        }
    }
}

/// Whether percentages count what is left or what is used.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum QuotaDisplay {
    #[default]
    Remaining,
    Used,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TrayIcon {
    /// The gauge turns green, amber or red with the lowest quota.
    #[default]
    Colored,
    Monochrome,
}

/// Where preferences are saved. `None` keeps changes in memory only: fixture mode
/// reads the user's file but never writes it.
pub struct Store {
    path: Option<PathBuf>,
    pub prefs: Prefs,
}

impl Global for Store {}

impl Store {
    pub fn load(persist: bool) -> Self {
        let path = path()
            .map_err(|error| eprintln!("Preferences will not be saved: {error:#}"))
            .ok();
        let prefs = path
            .as_ref()
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|bytes| {
                serde_json::from_slice(&bytes)
                    .map_err(|error| eprintln!("Ignoring unreadable preferences: {error}"))
                    .ok()
            })
            .unwrap_or_default();
        Self {
            path: path.filter(|_| persist),
            prefs,
        }
    }

    fn save(&self) -> Result<()> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let temp = path.with_extension("json.tmp");
        std::fs::write(&temp, serde_json::to_vec_pretty(&self.prefs)?)?;
        std::fs::rename(&temp, path)?;
        Ok(())
    }
}

fn path() -> Result<PathBuf> {
    let dirs =
        directories::ProjectDirs::from("app", "Quotio", "Quotio").context("no home directory")?;
    Ok(dirs.config_dir().join("desktop.json"))
}

pub fn get(cx: &App) -> &Prefs {
    &cx.global::<Store>().prefs
}

/// Change preferences and write them to disk.
pub fn update(cx: &mut App, edit: impl FnOnce(&mut Prefs)) {
    let store = cx.global_mut::<Store>();
    edit(&mut store.prefs);
    if let Err(error) = store.save() {
        eprintln!("Could not save preferences: {error:#}");
    }
}
