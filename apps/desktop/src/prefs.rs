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
    /// Mask account names on screen, for screen sharing.
    pub hide_names: bool,
    pub sharing: crate::sharing::Prefs,
    pub menu_bar: MenuBar,
    #[serde(alias = "density")]
    pub quota_style: QuotaStyle,
    pub total_usage: TotalUsage,
    pub model_aggregation: ModelAggregation,
    pub proxy: crate::proxy::Prefs,
    pub migration: crate::migration::Prefs,
    /// Check for app updates only when asked, not at start and once a day.
    pub manual_updates: bool,
}

/// Menu bar status item, as in the macOS app. Windows and Linux trays show only the icon.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MenuBar {
    pub show_icon: bool,
    /// Pinned accounts' percentages next to the icon.
    pub show_quota: bool,
    /// Providers with a session and weekly limit share one two-line item.
    pub stack_paired: bool,
    /// 1..=10 pinned accounts.
    pub max_items: u8,
    /// Account ids pinned to the menu bar, in order.
    pub accounts: Vec<String>,
    /// Once the user pins or unpins, new accounts are no longer added automatically.
    pub user_modified: bool,
    /// macOS only. The Dock icon can be hidden only while the menu bar icon shows.
    pub show_in_dock: bool,
}

impl Default for MenuBar {
    fn default() -> Self {
        Self {
            show_icon: true,
            show_quota: true,
            stack_paired: true,
            max_items: 3,
            accounts: Vec::new(),
            user_modified: false,
            show_in_dock: true,
        }
    }
}

/// How the popup draws each account's limits.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum QuotaStyle {
    /// One line per account.
    Compact,
    Rings,
    /// A tick gauge and a big countdown for the first limit.
    Gauge,
    /// Segmented bars with the pace tick. The retired densities read as this.
    #[default]
    #[serde(alias = "comfortable", alias = "detailed")]
    Bars,
}

/// Whether an account's overall number counts only the session limit.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TotalUsage {
    #[default]
    SessionOnly,
    Combined,
}

/// How per-model limits fold into one number.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelAggregation {
    #[default]
    Lowest,
    Average,
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
    /// CLIProxyAPI gave up restarting after repeated crashes.
    pub proxy_stopped: bool,
    /// A newer CLIProxyAPI release is out.
    pub proxy_update: bool,
}

impl Default for Notifications {
    fn default() -> Self {
        Self {
            enabled: true,
            quota_low: true,
            threshold: 20,
            cooling_down: true,
            proxy_stopped: true,
            proxy_update: false,
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
        #[cfg(target_os = "macos")]
        if persist
            && path.as_ref().is_some_and(|path| {
                std::fs::symlink_metadata(path)
                    .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
            })
            && let Some(prefs) = swift_preferences()
        {
            let store = Self { path, prefs };
            if let Err(error) = store.save() {
                eprintln!("Could not save migrated Swift preferences: {error:#}");
            }
            return store;
        }
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

    pub(crate) fn save(&self) -> Result<()> {
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

/// Read only this bundle's Swift preferences; never change its UserDefaults.
#[cfg(target_os = "macos")]
fn swift_preferences() -> Option<Prefs> {
    use objc2_foundation::{NSBundle, NSData, NSDictionary, NSNumber, NSString, NSUserDefaults};

    let bundle = NSBundle::mainBundle().bundleIdentifier()?;
    let domain = NSUserDefaults::standardUserDefaults().persistentDomainForName(&bundle)?;
    if ![
        "appearanceMode",
        "hideSensitiveInfo",
        "quotaDisplayMode",
        "menuBarColorMode",
        "quotaDisplayStyle",
        "totalUsageMode",
        "modelAggregationMode",
        "showMenuBarIcon",
        "menuBarShowQuota",
        "menuBarMaxItems",
        "menuBarStackClaudeQuotaWindows",
        "showInDock",
        "notificationsEnabled",
        "quotaAlertThreshold",
        "notifyOnQuotaLow",
        "notifyOnCooling",
        "notifyOnProxyCrash",
        "notifyOnUpgradeAvailable",
        "autoCheckUpdates",
        "menuBarProviderSelectionV2",
        "menuBarSelectedQuotaItems",
        "hasUserModifiedMenuBar",
    ]
    .iter()
    .any(|key| domain.objectForKey(&NSString::from_str(key)).is_some())
    {
        return None;
    }
    let string = |key: &str| {
        domain
            .objectForKey(&NSString::from_str(key))?
            .downcast::<NSString>()
            .ok()
            .map(|value| value.to_string())
    };
    let number = |key: &str| {
        domain
            .objectForKey(&NSString::from_str(key))?
            .downcast::<NSNumber>()
            .ok()
    };
    let mut prefs = Prefs {
        notifications: Notifications {
            proxy_update: true,
            ..Notifications::default()
        },
        ..Prefs::default()
    };
    for (key, target) in [
        ("hideSensitiveInfo", &mut prefs.hide_names),
        ("showMenuBarIcon", &mut prefs.menu_bar.show_icon),
        ("menuBarShowQuota", &mut prefs.menu_bar.show_quota),
        (
            "menuBarStackClaudeQuotaWindows",
            &mut prefs.menu_bar.stack_paired,
        ),
        ("showInDock", &mut prefs.menu_bar.show_in_dock),
        ("notificationsEnabled", &mut prefs.notifications.enabled),
        ("hasUserModifiedMenuBar", &mut prefs.menu_bar.user_modified),
        ("notifyOnQuotaLow", &mut prefs.notifications.quota_low),
        ("notifyOnCooling", &mut prefs.notifications.cooling_down),
        ("notifyOnProxyCrash", &mut prefs.notifications.proxy_stopped),
        (
            "notifyOnUpgradeAvailable",
            &mut prefs.notifications.proxy_update,
        ),
    ] {
        if let Some(value) = number(key) {
            *target = value.boolValue();
        }
    }
    if let Some(value) = number("autoCheckUpdates") {
        prefs.manual_updates = !value.boolValue();
    }
    if let Some(value) = number("menuBarMaxItems") {
        prefs.menu_bar.max_items = value.integerValue().clamp(1, 10) as u8;
    }
    if let Some(value) = number("quotaAlertThreshold") {
        let value = value.doubleValue();
        if value.is_finite() && value > 0.0 {
            prefs.notifications.threshold = value.min(100.0) as u8;
        }
    }
    prefs.appearance = match string("appearanceMode").as_deref() {
        Some("dark") => Appearance::Dark,
        Some("light") => Appearance::Light,
        _ => Appearance::System,
    };
    prefs.quota_display = match string("quotaDisplayMode").as_deref() {
        Some("used") => QuotaDisplay::Used,
        _ => QuotaDisplay::Remaining,
    };
    prefs.tray_icon = match string("menuBarColorMode").as_deref() {
        Some("colored") => TrayIcon::Colored,
        _ => TrayIcon::Monochrome,
    };
    prefs.quota_style = match string("quotaDisplayStyle").as_deref() {
        Some("compact" | "lowestBar") => QuotaStyle::Compact,
        _ => QuotaStyle::Bars,
    };
    prefs.total_usage = match string("totalUsageMode").as_deref() {
        Some("combined") => TotalUsage::Combined,
        _ => TotalUsage::SessionOnly,
    };
    prefs.model_aggregation = match string("modelAggregationMode").as_deref() {
        Some("average") => ModelAggregation::Average,
        _ => ModelAggregation::Lowest,
    };
    let v2 = domain.objectForKey(&NSString::from_str("menuBarProviderSelectionV2"));
    let legacy = v2.is_none();
    let data = match v2 {
        Some(value) => value
            .downcast::<NSDictionary>()
            .ok()
            .and_then(|selection| selection.objectForKey(&NSString::from_str("items"))),
        None => domain.objectForKey(&NSString::from_str("menuBarSelectedQuotaItems")),
    };
    if let Some(data) = data.and_then(|value| value.downcast::<NSData>().ok()) {
        match serde_json::from_slice::<Vec<crate::migration::Pin>>(&data.to_vec()) {
            Ok(mut pins) => {
                if legacy {
                    pins.retain(|pin| pin.provider != "gemini-cli");
                    for pin in &mut pins {
                        pin.provider = match pin.provider.as_str() {
                            "github-copilot" => "copilot",
                            "factory-droid" => "factory",
                            "vertex" => "vertexai",
                            "devin" => "devin-desktop",
                            "glm" => "zai",
                            provider => provider,
                        }
                        .to_owned();
                    }
                }
                prefs.migration.pending_pins = Some(pins);
            }
            Err(_) => prefs.migration.pin_warning = true,
        }
    }
    Some(prefs)
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
