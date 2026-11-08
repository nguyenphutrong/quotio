//! Local cutover choices and source-scoped pin restoration. No credential reads.
use anyhow::{Context as _, Result};
use gpui_kit::{App, Global};
use quotio::accounts::adopt::{Receipt, Source};
use quotio::contract::Snapshot;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Prefs {
    pub choice: Option<Choice>,
    pub pending_pins: Option<Vec<Pin>>,
    pub pin_warning: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Choice {
    pub bundle: String,
    pub include_isolated: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Pin {
    pub provider: String,
    #[serde(rename = "accountKey")]
    pub account: String,
    #[serde(rename = "hostID")]
    pub host: Option<String>,
}

pub struct Migration {
    pub source: Option<(String, Source)>,
    pub error: Option<String>,
}

impl Global for Migration {}

impl Migration {
    pub fn new(live: bool) -> Self {
        Self {
            source: live.then(crate::host::swift_vault).flatten(),
            error: None,
        }
    }
}

/// Save the exact profile before restarting; no source is read before this choice.
pub fn choose(include_isolated: bool, cx: &mut App) {
    let result = (|| -> Result<()> {
        let bundle = cx
            .global::<Migration>()
            .source
            .as_ref()
            .context("No signed Swift profile")?
            .0
            .clone();
        let store = cx.global_mut::<crate::prefs::Store>();
        let previous = store.prefs.migration.choice.replace(Choice {
            bundle,
            include_isolated,
        });
        if let Err(error) = store.save() {
            store.prefs.migration.choice = previous;
            return Err(error);
        }
        Ok(())
    })();
    match result {
        // macOS exits inside GPUI's run loop, before main's manual restart path.
        Ok(()) => cx.restart(),
        Err(error) => {
            cx.global_mut::<Migration>().error =
                Some(format!("Could not save the migration choice: {error:#}"));
            cx.refresh_windows();
        }
    }
}

pub fn import_proxy(cx: &mut App) {
    let result = (|| -> Result<()> {
        if crate::proxy::running(cx) || crate::prefs::get(cx).proxy.auto_start {
            anyhow::bail!("Stop the proxy and disable automatic start before importing");
        }
        let source = &cx
            .global::<Migration>()
            .source
            .as_ref()
            .context("No signed Swift profile")?
            .1;
        let config = source
            .data_dir
            .parent()
            .context("No Swift support directory")?
            .join("config.yaml");
        let port = crate::proxy::import_swift_config(&config, &crate::proxy::config_path())?;
        let store = cx.global_mut::<crate::prefs::Store>();
        store.prefs.proxy.port = port;
        store.save().context("Proxy config was copied, but its port preference could not be saved; review CLIProxyAPI settings")?;
        Ok(())
    })();
    cx.global_mut::<Migration>().error =
        result.err().map(|error| format!("Proxy import: {error:#}"));
    cx.refresh_windows();
}

pub fn restore_pins(snapshot: &Snapshot, cx: &mut App) {
    let Some(pins) = crate::prefs::get(cx).migration.pending_pins.as_ref() else {
        return;
    };
    let migration = cx.global::<Migration>();
    let Some((bundle, source)) = &migration.source else {
        return;
    };
    let Some(choice) = &crate::prefs::get(cx).migration.choice else {
        return;
    };
    if choice.bundle != *bundle {
        return;
    }
    let receipt = if choice.include_isolated {
        match source.receipt() {
            Ok(Some(receipt)) => Some(receipt),
            _ => return,
        }
    } else {
        None
    };
    if let Some(receipt) = &receipt {
        if receipt
            .target_host
            .as_deref()
            .is_some_and(|host| host != snapshot.host.id)
        {
            return;
        }
        // The ready signal can precede adoption. Do not consume pins against its
        // cached pre-adoption snapshot, even though the receipt is already on disk.
        if snapshot.generated_at < receipt.adopted_at
            && receipt.account_mappings.as_ref().is_some_and(|mappings| {
                mappings
                    .values()
                    .any(|id| !snapshot.accounts.iter().any(|account| account.id == *id))
            })
        {
            return;
        }
    }
    let (accounts, warning) = resolve_pins(pins, receipt.as_ref(), snapshot);
    crate::prefs::update(cx, |prefs| {
        prefs.menu_bar.accounts = accounts;
        prefs.migration.pending_pins = None;
        prefs.migration.pin_warning = warning;
    });
}

fn resolve_pins(
    pins: &[Pin],
    receipt: Option<&Receipt>,
    snapshot: &Snapshot,
) -> (Vec<String>, bool) {
    let mut accounts = Vec::new();
    let mut warning = false;
    for pin in pins {
        let source_host = receipt
            .and_then(|receipt| receipt.source_host.as_deref())
            .unwrap_or(&snapshot.host.id);
        if pin.host.as_deref().is_some_and(|host| host != source_host) {
            warning = true;
            continue;
        }
        let id = match receipt {
            Some(receipt) => receipt
                .account_mappings
                .as_ref()
                .and_then(|mappings| mappings.get(&pin.account))
                .map(String::as_str),
            None => Some(pin.account.as_str()),
        };
        let account = id.and_then(|id| {
            snapshot
                .accounts
                .iter()
                .find(|account| account.id == id && account.provider_id == pin.provider)
        });
        match account {
            Some(account) if !accounts.contains(&account.id) => accounts.push(account.id.clone()),
            None => warning = true,
            _ => {}
        }
    }
    (accounts, warning)
}
