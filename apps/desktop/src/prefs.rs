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
}

pub struct Store {
    pub prefs: Prefs,
}

impl Global for Store {}

impl Store {
    pub fn load() -> Self {
        let prefs = path()
            .ok()
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|bytes| {
                serde_json::from_slice(&bytes)
                    .map_err(|error| eprintln!("Ignoring unreadable preferences: {error}"))
                    .ok()
            })
            .unwrap_or_default();
        Self { prefs }
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
