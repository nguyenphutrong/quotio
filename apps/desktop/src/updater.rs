//! Self-update for the Windows and Linux builds. Releases tagged `desktop-v*` carry
//! one executable per platform and its Ed25519 signature (`<asset>.sig`), made by
//! `.github/workflows/desktop-release.yml`. macOS uses bundled Sparkle instead.
use std::{path::PathBuf, sync::OnceLock, time::Duration};

use anyhow::{Context as _, Result, anyhow};
use gpui_kit::{App, Global, SystemNotification};
use ring::signature::{ED25519, UnparsedPublicKey};
use semver::Version;
use serde::Deserialize;

const RELEASES: &str = "https://api.github.com/repos/nguyenphutrong/quotio/releases?per_page=100";

/// Public half of the `DESKTOP_UPDATE_KEY` release secret.
const PUBLIC_KEY: [u8; 32] = [
    0xf0, 0xb1, 0x6f, 0x94, 0x4f, 0x28, 0x71, 0x50, 0xa3, 0xdd, 0xb8, 0x0f, 0xad, 0xfd, 0x6f, 0xa7,
    0x0a, 0x28, 0xb8, 0x49, 0x75, 0x4e, 0xe3, 0x53, 0xaa, 0xec, 0x95, 0x02, 0xd7, 0x7b, 0x1b, 0x15,
];

/// The release asset this build updates from; `None` where no build is published.
#[cfg(all(windows, target_arch = "x86_64"))]
pub const ASSET: Option<&str> = Some("quotio-desktop-x86_64-pc-windows-msvc.exe");
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
pub const ASSET: Option<&str> = Some("quotio-desktop-x86_64-unknown-linux-gnu");
#[cfg(not(any(
    all(windows, target_arch = "x86_64"),
    all(target_os = "linux", target_arch = "x86_64")
)))]
pub const ASSET: Option<&str> = None;

/// The installed executable to start once the app has quit.
pub static RESTART: OnceLock<PathBuf> = OnceLock::new();

#[derive(Clone, Debug)]
pub struct Release {
    pub version: Version,
    /// The executable's download size in bytes.
    pub size: u64,
    /// The release notes' first few bullet points.
    pub notes: Vec<String>,
    binary: String,
    signature: String,
}

#[derive(Clone, Default)]
pub enum State {
    #[default]
    Idle,
    Checking,
    UpToDate,
    Available(Release),
    Installing,
    Failed(String),
}

struct Updates {
    http: reqwest::Client,
    runtime: tokio::runtime::Handle,
    state: State,
    /// When the last check reached GitHub.
    checked: Option<chrono::DateTime<chrono::Local>>,
    #[cfg(target_os = "macos")]
    sparkle: Option<crate::sparkle::Controller>,
}

impl Global for Updates {}

pub fn state(cx: &App) -> &State {
    &cx.global::<Updates>().state
}

pub fn checked(cx: &App) -> Option<chrono::DateTime<chrono::Local>> {
    cx.global::<Updates>().checked
}

pub fn supported(cx: &App) -> bool {
    ASSET.is_some() || uses_sparkle(cx)
}

pub fn uses_sparkle(_cx: &App) -> bool {
    #[cfg(target_os = "macos")]
    return _cx.global::<Updates>().sparkle.is_some();
    #[cfg(not(target_os = "macos"))]
    false
}

pub fn version() -> String {
    #[cfg(target_os = "macos")]
    if let Some(version) = crate::sparkle::version() {
        return version;
    }
    env!("CARGO_PKG_VERSION").to_owned()
}

pub fn automatic(on: bool, cx: &mut App) {
    crate::prefs::update(cx, |prefs| prefs.manual_updates = !on);
    #[cfg(target_os = "macos")]
    if let Some(sparkle) = &cx.global::<Updates>().sparkle {
        sparkle.automatic(on);
    }
    cx.refresh_windows();
}

/// `check_now` is off for fixtures, which should not reach the network.
pub fn init(runtime: tokio::runtime::Handle, check_now: bool, cx: &mut App) {
    let http = reqwest::Client::builder()
        .user_agent(concat!("quotio-desktop/", env!("CARGO_PKG_VERSION")))
        .build()
        .expect("TLS backend is compiled in");
    #[cfg(target_os = "macos")]
    let sparkle =
        check_now.then(|| crate::sparkle::Controller::load(!crate::prefs::get(cx).manual_updates));
    #[cfg(target_os = "macos")]
    let initial = match &sparkle {
        Some(Err(error)) => State::Failed(format!("{error:#}")),
        _ => State::Idle,
    };
    cx.set_global(Updates {
        http,
        runtime,
        #[cfg(not(target_os = "macos"))]
        state: State::Idle,
        #[cfg(target_os = "macos")]
        state: initial,
        checked: None,
        #[cfg(target_os = "macos")]
        sparkle: sparkle.and_then(Result::ok),
    });
    // Never replace or clean files inside a signed macOS bundle.
    if ASSET.is_some()
        && let Ok(exe) = std::env::current_exe()
    {
        // ponytail: Windows keeps the previous executable locked until it exits, so
        // it may linger until the next update removes it.
        let _ = std::fs::remove_file(exe.with_extension("old"));
    }
    if !check_now || ASSET.is_none() {
        return;
    }
    // At start, then once a day for an app that stays in the tray for weeks.
    cx.spawn(async move |cx| {
        loop {
            cx.update(|cx| {
                let idle = matches!(state(cx), State::Idle | State::UpToDate | State::Failed(_));
                if idle && !crate::prefs::get(cx).manual_updates {
                    check(cx);
                }
            });
            cx.background_executor()
                .timer(Duration::from_secs(24 * 60 * 60))
                .await;
        }
    })
    .detach();
}

pub fn check(cx: &mut App) {
    #[cfg(target_os = "macos")]
    if let Some(sparkle) = &cx.global::<Updates>().sparkle {
        sparkle.check();
        return;
    }
    let updates = cx.global_mut::<Updates>();
    updates.state = State::Checking;
    let task = updates.runtime.spawn(latest(updates.http.clone()));
    cx.refresh_windows();
    cx.spawn(async move |cx| {
        let result = task.await.map_err(anyhow::Error::from).and_then(|r| r);
        cx.update(|cx| {
            if result.is_ok() {
                cx.global_mut::<Updates>().checked = Some(chrono::Local::now());
            }
            let state = match result {
                Ok(Some(release)) => {
                    cx.show_system_notification(SystemNotification {
                        tag: format!("update:{}", release.version).into(),
                        title: format!("Quotio {} is available", release.version).into(),
                        body: "Install it from Settings › About & Updates.".into(),
                        actions: Vec::new(),
                    });
                    State::Available(release)
                }
                Ok(None) => State::UpToDate,
                Err(error) => State::Failed(format!("{error:#}")),
            };
            cx.global_mut::<Updates>().state = state;
            cx.refresh_windows();
        })
    })
    .detach();
}

/// Download, verify and swap in the release, then quit so `main` starts it.
pub fn install(release: Release, cx: &mut App) {
    let updates = cx.global_mut::<Updates>();
    updates.state = State::Installing;
    let task = updates
        .runtime
        .spawn(download(updates.http.clone(), release));
    cx.refresh_windows();
    cx.spawn(async move |cx| {
        let result = task.await.map_err(anyhow::Error::from).and_then(|r| r);
        cx.update(|cx| match result.and_then(|binary| replace(&binary)) {
            Ok(()) => crate::app::quit(cx),
            Err(error) => {
                cx.global_mut::<Updates>().state = State::Failed(format!("{error:#}"));
                cx.refresh_windows();
            }
        })
    })
    .detach();
}

#[derive(Deserialize)]
struct GitHubRelease {
    tag_name: String,
    draft: bool,
    body: Option<String>,
    assets: Vec<GitHubAsset>,
}

#[derive(Deserialize)]
struct GitHubAsset {
    name: String,
    browser_download_url: String,
    size: u64,
}

async fn latest(http: reqwest::Client) -> Result<Option<Release>> {
    let Some(asset) = ASSET else { return Ok(None) };
    let releases = http
        .get(RELEASES)
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    let current = Version::parse(env!("CARGO_PKG_VERSION"))?;
    Ok(newest(releases, &current, asset))
}

/// The highest `desktop-v*` release above `current` that ships `asset` and its signature.
fn newest(releases: Vec<GitHubRelease>, current: &Version, asset: &str) -> Option<Release> {
    let signature = format!("{asset}.sig");
    releases
        .into_iter()
        .filter(|release| !release.draft)
        .filter_map(|release| {
            let version = Version::parse(release.tag_name.strip_prefix("desktop-v")?).ok()?;
            let url = |name: &str| {
                release
                    .assets
                    .iter()
                    .find(|a| a.name == name)
                    .map(|a| a.browser_download_url.clone())
            };
            let notes = release
                .body
                .iter()
                .flat_map(|body| body.lines())
                .filter_map(|line| line.trim().strip_prefix(['-', '*']))
                .map(|line| line.trim().to_owned())
                .take(3)
                .collect();
            Some(Release {
                size: release.assets.iter().find(|a| a.name == asset)?.size,
                binary: url(asset)?,
                signature: url(&signature)?,
                version,
                notes,
            })
        })
        .filter(|release| release.version > *current)
        .max_by(|a, b| a.version.cmp(&b.version))
}

async fn download(http: reqwest::Client, release: Release) -> Result<Vec<u8>> {
    let get = async |url: &str| -> Result<Vec<u8>> {
        let response = http.get(url).send().await?.error_for_status()?;
        Ok(response.bytes().await?.to_vec())
    };
    let binary = get(&release.binary).await?;
    let signature = get(&release.signature).await?;
    verify(&binary, &signature)?;
    Ok(binary)
}

fn verify(binary: &[u8], signature: &[u8]) -> Result<()> {
    UnparsedPublicKey::new(&ED25519, PUBLIC_KEY)
        .verify(binary, signature)
        .map_err(|_| anyhow!("The download's signature does not match; nothing was installed."))
}

/// Put `binary` where the running executable is, keeping the old one beside it.
fn replace(binary: &[u8]) -> Result<()> {
    let exe = std::env::current_exe()?;
    let new = exe.with_extension("new");
    let old = exe.with_extension("old");
    std::fs::write(&new, binary).with_context(|| {
        format!(
            "Can't write next to {}; download the update from the releases page instead",
            exe.display()
        )
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&new, std::fs::Permissions::from_mode(0o755))?;
    }
    let _ = std::fs::remove_file(&old);
    // Windows can rename a running executable but not overwrite it.
    std::fs::rename(&exe, &old)?;
    if let Err(error) = std::fs::rename(&new, &exe) {
        let _ = std::fs::rename(&old, &exe);
        return Err(error.into());
    }
    let _ = RESTART.set(exe);
    Ok(())
}
