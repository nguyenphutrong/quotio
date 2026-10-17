//! Read-only sharing with the Quotio iPhone app over `/v2/sharing` and
//! `/v2/clients`. The host keeps listeners only while it runs, so the app saves
//! which connections are on and opens them again at launch, as the macOS app does.
use std::collections::BTreeMap;
use std::sync::Arc;

use anyhow::{Context as _, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::host::{HostClient, Method};

pub const DEFAULT_PORT: u16 = 6768;

/// Device access lasts 30 days, as on macOS.
pub const ACCESS_SECONDS: u64 = 30 * 24 * 60 * 60;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    LocalNetwork,
    Tailscale,
    /// A loopback listener behind the user's own HTTPS reverse proxy.
    Proxy,
}

impl Mode {
    pub const ALL: [Mode; 3] = [Mode::LocalNetwork, Mode::Tailscale, Mode::Proxy];

    pub fn label(self) -> &'static str {
        match self {
            Mode::LocalNetwork => "Local network",
            Mode::Tailscale => "Tailscale",
            Mode::Proxy => "HTTPS proxy",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Prefs {
    pub port: u16,
    pub enabled: Vec<Mode>,
    pub proxy_url: Option<String>,
}

impl Default for Prefs {
    fn default() -> Self {
        Self {
            port: DEFAULT_PORT,
            enabled: Vec::new(),
            proxy_url: None,
        }
    }
}

/// Open or close one connection. Local network and Tailscale listen on this
/// computer's address for that network; the proxy mode listens on loopback.
pub async fn set(host: Arc<dyn HostClient>, mode: Mode, on: bool, prefs: Prefs) -> Result<Value> {
    let path = || "/v2/sharing".to_owned();
    if !on {
        let body = json!({ "enabled": false, "mode": mode });
        return host.call(Method::PUT, path(), Some(body)).await;
    }
    let body = if mode == Mode::Proxy {
        let origin = prefs
            .proxy_url
            .filter(|url| !url.is_empty())
            .context("enter the proxy’s https:// address first")?;
        json!({
            "enabled": true,
            "mode": mode,
            "listen": format!("127.0.0.1:{}", prefs.port),
            "public_url": origin,
        })
    } else {
        let view = host.call(Method::GET, path(), None).await?;
        let address = view["addresses"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|a| a["mode"] == json!(mode))
            .and_then(|a| a["address"].as_str())
            .with_context(|| {
                format!(
                    "this computer has no {} address",
                    mode.label().to_lowercase()
                )
            })?;
        json!({
            "enabled": true,
            "mode": mode,
            "listen": format!("{address}:{}", prefs.port),
            "public_url": null,
        })
    };
    host.call(Method::PUT, path(), Some(body)).await
}

/// Reopen the connections that were on when Quotio last ran.
pub async fn restore(host: Arc<dyn HostClient>, prefs: Prefs) {
    for mode in prefs.enabled.clone() {
        if let Err(error) = set(host.clone(), mode, true, prefs.clone()).await {
            eprintln!("Could not reopen {} sharing: {error:#}", mode.label());
        }
    }
}

/// The open endpoint for `mode` in a `GET /v2/sharing` view.
pub fn endpoint(view: &Value, mode: Mode) -> Option<&Value> {
    view["endpoints"]
        .as_array()?
        .iter()
        .find(|e| e["mode"] == json!(mode) && e["enabled"] == json!(true))
}

/// The QR payload the iPhone app reads: sorted-key JSON, the same as macOS.
/// `created` is the `POST /v2/clients` response.
pub fn pairing_payload(created: &Value, endpoint: &Value) -> Result<String> {
    let text = |value: &Value, what: &str| -> Result<String> {
        value
            .as_str()
            .map(str::to_owned)
            .with_context(|| format!("the host did not return {what}"))
    };
    // The app decodes ISO 8601 dates without fractional seconds.
    let expires = OffsetDateTime::parse(
        &text(&created["client"]["expires_at"], "an expiry")?,
        &Rfc3339,
    )?
    .replace_nanosecond(0)?
    .format(&Rfc3339)?;
    let mut payload = BTreeMap::new();
    payload.insert("pairing_version", json!(2));
    payload.insert(
        "origin",
        json!(text(&endpoint["public_url"], "an address")?),
    );
    payload.insert("host_name", json!(host_name()));
    payload.insert("host_id", json!(text(&created["host_id"], "a host id")?));
    payload.insert(
        "client_id",
        json!(text(&created["client"]["id"], "a client id")?),
    );
    payload.insert("expires_at", json!(expires));
    payload.insert("token", json!(text(&created["token"], "a token")?));
    if let Some(certificate) = endpoint["certificate"].as_str() {
        payload.insert("certificate", json!(certificate));
    }
    Ok(serde_json::to_string(&payload)?)
}

/// The QR code for `payload` as an SVG document.
pub fn qr_svg(payload: &str) -> Result<Vec<u8>> {
    let code = qrcode::QrCode::with_error_correction_level(payload, qrcode::EcLevel::L)?;
    Ok(code
        .render::<qrcode::render::svg::Color>()
        .min_dimensions(240, 240)
        .quiet_zone(true)
        .build()
        .into_bytes())
}

/// The computer's name, shown on the iPhone next to the quota it reads.
fn host_name() -> String {
    let name = if cfg!(windows) {
        std::env::var("COMPUTERNAME").ok()
    } else {
        std::fs::read_to_string("/proc/sys/kernel/hostname").ok()
    };
    name.map(|n| n.trim().to_owned())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| "Quotio".to_owned())
}
