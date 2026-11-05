//! CLIProxyAPI, the optional local proxy: install releases from GitHub, run the
//! active version as a child process and switch versions, as the macOS app does.
//! Versions live in `<data dir>/proxy/v<version>/`; the active one is a preference.
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, anyhow, bail};
use gpui_kit::{App, Global, SystemNotification, Task};
use semver::Version;
use serde::{Deserialize, Serialize};

const RELEASES: &str = "https://api.github.com/repos/router-for-me/CLIProxyAPI/releases";
/// Installed versions kept on disk, the active one included.
const KEEP: usize = 3;
/// The running proxy's process id, so a proxy left behind by a crashed Quotio can be
/// stopped before the next start takes its port.
const PID_FILE: &str = "proxy.pid";
const BINARY: &str = if cfg!(windows) {
    "cli-proxy-api.exe"
} else {
    "cli-proxy-api"
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Prefs {
    pub port: u16,
    /// Start the proxy when Quotio starts.
    pub auto_start: bool,
    /// The installed version that runs, such as `8.0.56`.
    pub version: Option<String>,
}

impl Default for Prefs {
    fn default() -> Self {
        Self {
            port: 8317,
            auto_start: false,
            version: None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Release {
    pub version: Version,
    pub prerelease: bool,
    asset: String,
    url: String,
    sha256: String,
}

pub struct Proxy {
    http: reqwest::Client,
    runtime: tokio::runtime::Handle,
    dir: PathBuf,
    /// Plain management key. The proxy replaces it with a hash in its config, so it
    /// is written there again before every start.
    pub key: String,
    child: Option<Child>,
    started: Instant,
    /// Unexpected exits in a row; reset once the proxy has run for a minute.
    crashes: u32,
    /// The restart after a crash, cancelled when dropped.
    restarting: Option<Task<()>>,
    /// The health check killed the proxy because it stopped answering.
    hung: bool,
    /// What is in progress, such as "Downloading 8.0.56…".
    pub busy: Option<String>,
    pub error: Option<String>,
    pub upgrade: Option<Release>,
    /// Recent releases, once the user asked for them.
    pub releases: Option<Vec<Release>>,
}

impl Global for Proxy {}

pub fn get(cx: &App) -> &Proxy {
    cx.global::<Proxy>()
}

pub fn running(cx: &App) -> bool {
    get(cx).child.is_some()
}

/// How long the proxy has run, while it runs.
pub fn uptime(cx: &App) -> Option<Duration> {
    let proxy = get(cx);
    proxy.child.is_some().then(|| proxy.started.elapsed())
}

/// Waiting to start again after a crash.
pub fn restarting(cx: &App) -> bool {
    get(cx).restarting.is_some()
}

/// The first client key under `access.api-keys`, which AI tools send to the proxy.
pub fn api_key() -> Option<String> {
    let config = std::fs::read_to_string(config_path()).ok()?;
    let mut lines = config
        .lines()
        .skip_while(|line| !line.starts_with("access:"))
        .skip(1)
        .take_while(|line| line.starts_with([' ', '\t']) || line.is_empty())
        .skip_while(|line| line.trim() != "api-keys:")
        .skip(1);
    let key = lines.next()?.trim().strip_prefix('-')?.trim();
    Some(key.trim_matches(['"', '\'']).to_owned()).filter(|key| !key.is_empty())
}

pub fn endpoint(cx: &App) -> String {
    format!("http://127.0.0.1:{}", crate::prefs::get(cx).proxy.port)
}

fn dir() -> PathBuf {
    directories::ProjectDirs::from("app", "Quotio", "Quotio")
        .map_or_else(
            || std::env::temp_dir().join("quotio"),
            |d| d.data_dir().into(),
        )
        .join("proxy")
}

/// The proxy's config, which the host also reads for provider API keys.
pub fn config_path() -> PathBuf {
    dir().join("config.yaml")
}

/// `live` is off for fixtures, which should neither start processes nor reach the network.
pub fn init(runtime: tokio::runtime::Handle, live: bool, cx: &mut App) {
    let dir = dir();
    let key = management_key(&dir).unwrap_or_else(|error| {
        eprintln!("Could not save the proxy management key: {error:#}");
        random_hex()
    });
    let http = reqwest::Client::builder()
        .user_agent(concat!("quotio-desktop/", env!("CARGO_PKG_VERSION")))
        .build()
        .expect("TLS backend is compiled in");
    cx.set_global(Proxy {
        http,
        runtime,
        dir,
        key,
        child: None,
        started: Instant::now(),
        crashes: 0,
        restarting: None,
        hung: false,
        busy: None,
        error: None,
        upgrade: None,
        releases: None,
    });
    // Every way out of the app, logging out included, stops the proxy with it.
    cx.on_app_quit(|cx| {
        stop(cx);
        async {}
    })
    .detach();
    // Notice when the proxy exits on its own, and bring it back.
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            cx.update(exited);
        }
    })
    .detach();
    // A proxy that runs but no longer answers is killed, so the loop above restarts it.
    cx.spawn(async move |cx| {
        let mut failures = 0;
        loop {
            cx.background_executor()
                .timer(Duration::from_secs(30))
                .await;
            let probe = cx.update(|cx| {
                let proxy = get(cx);
                (proxy.child.is_some() && proxy.started.elapsed() > Duration::from_secs(30)).then(
                    || {
                        (
                            proxy.started,
                            proxy
                                .runtime
                                .spawn(answers(proxy.http.clone(), endpoint(cx))),
                        )
                    },
                )
            });
            let Some((started, probe)) = probe else {
                failures = 0;
                continue;
            };
            // Keep the uptime on screen current.
            cx.update(|cx| cx.refresh_windows());
            if probe.await.unwrap_or(false) {
                failures = 0;
                continue;
            }
            failures += 1;
            if failures < 3 {
                continue;
            }
            failures = 0;
            cx.update(|cx| {
                let proxy = cx.global_mut::<Proxy>();
                // Only the same run that failed three checks in a row.
                if proxy.started == started
                    && let Some(child) = proxy.child.as_mut()
                {
                    proxy.hung = true;
                    let _ = child.kill();
                }
            });
        }
    })
    .detach();
    let prefs = crate::prefs::get(cx).proxy.clone();
    if live && prefs.version.is_some() {
        if prefs.auto_start {
            start(cx);
        }
        check(cx);
    }
}

/// After an unexpected exit, restart up to three times, waiting 2, 4 and 8 seconds.
fn exited(cx: &mut App) {
    let proxy = cx.global_mut::<Proxy>();
    let Some(status) = proxy.child.as_mut().and_then(|c| c.try_wait().ok()?) else {
        return;
    };
    proxy.child = None;
    let _ = std::fs::remove_file(proxy.dir.join(PID_FILE));
    let status = if std::mem::take(&mut proxy.hung) {
        "it stopped responding".to_owned()
    } else {
        status.to_string()
    };
    if proxy.started.elapsed() > Duration::from_secs(60) {
        proxy.crashes = 0;
    }
    proxy.crashes += 1;
    if proxy.crashes <= 3 {
        let delay = Duration::from_secs(1 << proxy.crashes);
        proxy.error = Some(format!(
            "CLIProxyAPI stopped ({status}); restarting in {} s…",
            delay.as_secs()
        ));
        let task = cx.spawn(async move |cx| {
            cx.background_executor().timer(delay).await;
            cx.update(launch);
        });
        cx.global_mut::<Proxy>().restarting = Some(task);
    } else {
        let port = crate::prefs::get(cx).proxy.port;
        let message =
            format!("CLIProxyAPI keeps stopping ({status}). Check that port {port} is free.");
        cx.global_mut::<Proxy>().error = Some(message.clone());
        cx.show_system_notification(SystemNotification {
            tag: "proxy-crashed".into(),
            title: "CLIProxyAPI stopped".into(),
            body: message.into(),
            actions: Vec::new(),
        });
    }
    cx.refresh_windows();
}

pub fn start(cx: &mut App) {
    cx.global_mut::<Proxy>().crashes = 0;
    launch(cx);
}

/// Whether the proxy answers HTTP at all; any status counts, a hang does not.
async fn answers(http: reqwest::Client, endpoint: String) -> bool {
    http.get(format!("{endpoint}/v0/management/config"))
        .timeout(Duration::from_secs(3))
        .send()
        .await
        .is_ok()
}

fn launch(cx: &mut App) {
    cx.global_mut::<Proxy>().restarting = None;
    if running(cx) {
        return;
    }
    let result = spawn(get(cx), &crate::prefs::get(cx).proxy);
    let proxy = cx.global_mut::<Proxy>();
    match result {
        Ok(child) => {
            proxy.child = Some(child);
            proxy.started = Instant::now();
            proxy.error = None;
        }
        Err(error) => proxy.error = Some(format!("{error:#}")),
    }
    cx.refresh_windows();
}

pub fn stop(cx: &mut App) {
    let proxy = cx.global_mut::<Proxy>();
    proxy.restarting = None;
    if let Some(mut child) = proxy.child.take() {
        // ponytail: kills at once; send SIGTERM first if the proxy ever needs to flush.
        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_file(proxy.dir.join(PID_FILE));
    }
    cx.refresh_windows();
}

pub fn restart(cx: &mut App) {
    stop(cx);
    start(cx);
}

/// Installed versions, newest first.
pub fn installed(cx: &App) -> Vec<String> {
    let dir = &get(cx).dir;
    let mut versions: Vec<Version> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| entry.path().join(BINARY).is_file())
        .filter_map(|entry| Version::parse(entry.file_name().to_str()?.strip_prefix('v')?).ok())
        .collect();
    versions.sort_by(|a, b| b.cmp(a));
    versions.iter().map(Version::to_string).collect()
}

/// Run `version` from now on, restarting the proxy if it runs.
pub fn activate(version: String, cx: &mut App) {
    let was_running = running(cx);
    crate::prefs::update(cx, |prefs| prefs.proxy.version = Some(version));
    if was_running {
        restart(cx);
    }
    cx.refresh_windows();
}

pub fn delete(version: &str, cx: &mut App) {
    let result = if crate::prefs::get(cx).proxy.version.as_deref() == Some(version) {
        Err(anyhow!(
            "Activate another version before deleting {version}."
        ))
    } else {
        std::fs::remove_dir_all(get(cx).dir.join(format!("v{version}"))).map_err(Into::into)
    };
    cx.global_mut::<Proxy>().error = result.err().map(|error| format!("{error:#}"));
    cx.refresh_windows();
}

/// Download, verify and activate `release`, keeping the newest few versions.
pub fn install(release: Release, cx: &mut App) {
    let proxy = cx.global_mut::<Proxy>();
    if proxy.busy.is_some() {
        return;
    }
    proxy.busy = Some(format!("Downloading {}…", release.version));
    proxy.error = None;
    let task = proxy.runtime.spawn(download(
        proxy.http.clone(),
        release.clone(),
        proxy.dir.clone(),
    ));
    cx.refresh_windows();
    cx.spawn(async move |cx| {
        let result = task.await.map_err(anyhow::Error::from).and_then(|r| r);
        cx.update(|cx| {
            let proxy = cx.global_mut::<Proxy>();
            proxy.busy = None;
            match result {
                Ok(()) => {
                    if proxy
                        .upgrade
                        .as_ref()
                        .is_some_and(|u| u.version <= release.version)
                    {
                        proxy.upgrade = None;
                    }
                    let was_running = proxy.child.is_some();
                    activate(release.version.to_string(), cx);
                    prune(cx);
                    // The first install starts the proxy, as "Install and run" says.
                    if !was_running {
                        start(cx);
                    }
                }
                Err(error) => proxy.error = Some(format!("{error:#}")),
            }
            cx.refresh_windows();
        })
    })
    .detach();
}

/// Look for a release newer than the active version.
pub fn check(cx: &mut App) {
    fetch(cx, "Checking for updates…", "/latest", |releases, cx| {
        let active = crate::prefs::get(cx).proxy.version.clone();
        let active = active.and_then(|v| Version::parse(&v).ok());
        let latest = releases.into_iter().next();
        cx.global_mut::<Proxy>().upgrade =
            latest.filter(|latest| active.is_none_or(|active| latest.version > active));
    });
}

/// Install and start the newest release, for the first install.
pub fn install_latest(cx: &mut App) {
    fetch(
        cx,
        "Finding the latest release…",
        "/latest",
        |releases, cx| match releases.into_iter().next() {
            Some(release) => install(release, cx),
            None => {
                cx.global_mut::<Proxy>().error =
                    Some("The latest release has no build for this platform.".into())
            }
        },
    );
}

pub fn load_releases(cx: &mut App) {
    fetch(cx, "Loading releases…", "?per_page=10", |releases, cx| {
        cx.global_mut::<Proxy>().releases = Some(releases);
    });
}

fn fetch(
    cx: &mut App,
    busy: &str,
    query: &'static str,
    done: impl FnOnce(Vec<Release>, &mut App) + 'static,
) {
    let proxy = cx.global_mut::<Proxy>();
    if proxy.busy.is_some() {
        return;
    }
    proxy.busy = Some(busy.to_owned());
    proxy.error = None;
    let http = proxy.http.clone();
    let task = proxy.runtime.spawn(async move {
        let response = http
            .get(format!("{RELEASES}{query}"))
            .send()
            .await?
            .error_for_status()?;
        // `/latest` answers with one release, the list with many.
        let json: serde_json::Value = response.json().await?;
        let list = match json {
            serde_json::Value::Array(list) => list,
            one => vec![one],
        };
        Ok::<_, anyhow::Error>(
            list.into_iter()
                .filter_map(|r| serde_json::from_value(r).ok())
                .filter_map(compatible)
                .collect::<Vec<_>>(),
        )
    });
    cx.refresh_windows();
    cx.spawn(async move |cx| {
        let result = task.await.map_err(anyhow::Error::from).and_then(|r| r);
        cx.update(|cx| {
            cx.global_mut::<Proxy>().busy = None;
            match result {
                Ok(releases) => done(releases, cx),
                Err(error) => {
                    cx.global_mut::<Proxy>().error =
                        Some(format!("Couldn’t reach GitHub: {error:#}"))
                }
            }
            cx.refresh_windows();
        })
    })
    .detach();
}

/// Delete all but the active and the newest versions, `KEEP` in all.
fn prune(cx: &mut App) {
    let active = crate::prefs::get(cx).proxy.version.clone();
    let others = installed(cx)
        .into_iter()
        .filter(|v| Some(v) != active.as_ref());
    for version in others.skip(KEEP - 1) {
        let _ = std::fs::remove_dir_all(get(cx).dir.join(format!("v{version}")));
    }
}

#[derive(Deserialize)]
struct GitHubRelease {
    tag_name: String,
    draft: bool,
    prerelease: bool,
    assets: Vec<GitHubAsset>,
}

#[derive(Deserialize)]
struct GitHubAsset {
    name: String,
    browser_download_url: String,
    digest: Option<String>,
}

/// The release's archive for this platform, if it has one with a checksum.
fn compatible(release: GitHubRelease) -> Option<Release> {
    if release.draft {
        return None;
    }
    let os = if cfg!(target_os = "macos") {
        "darwin"
    } else if cfg!(windows) {
        "windows"
    } else {
        "linux"
    };
    let arch = if cfg!(target_arch = "aarch64") {
        "aarch64"
    } else {
        "amd64"
    };
    let ext = if cfg!(windows) { "zip" } else { "tar.gz" };
    // The exact suffix skips variants such as `_linux_amd64_no-plugin.tar.gz`.
    let suffix = format!("_{os}_{arch}.{ext}");
    let asset = release
        .assets
        .into_iter()
        .find(|a| a.name.ends_with(&suffix))?;
    Some(Release {
        version: Version::parse(release.tag_name.trim_start_matches('v')).ok()?,
        prerelease: release.prerelease,
        sha256: asset.digest?.strip_prefix("sha256:")?.to_lowercase(),
        url: asset.browser_download_url,
        asset: asset.name,
    })
}

async fn download(http: reqwest::Client, release: Release, dir: PathBuf) -> Result<()> {
    let archive = http
        .get(&release.url)
        .send()
        .await?
        .error_for_status()?
        .bytes()
        .await?;
    let digest = ring::digest::digest(&ring::digest::SHA256, &archive);
    let hex: String = digest.as_ref().iter().map(|b| format!("{b:02x}")).collect();
    if hex != release.sha256 {
        bail!("The download’s checksum does not match; nothing was installed.");
    }
    tokio::task::spawn_blocking(move || unpack(&archive, &release, &dir)).await?
}

/// Extract only the executable, so archive paths never reach the disk.
fn unpack(archive: &[u8], release: &Release, dir: &Path) -> Result<()> {
    let temp = dir.join(format!(".download-{}", release.version));
    let _ = std::fs::remove_dir_all(&temp);
    std::fs::create_dir_all(&temp)?;
    let result = (|| {
        let file = temp.join(&release.asset);
        std::fs::write(&file, archive)?;
        // bsdtar ships with macOS and Windows 10+ and reads zip; GNU tar reads tar.gz.
        #[cfg(windows)]
        let tar = PathBuf::from(std::env::var_os("SystemRoot").unwrap_or("C:\\Windows".into()))
            .join("System32\\tar.exe");
        #[cfg(not(windows))]
        let tar = PathBuf::from("tar");
        let status = Command::new(tar)
            .arg("-xf")
            .arg(&file)
            .arg("-C")
            .arg(&temp)
            .arg(BINARY)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .context("Couldn’t run tar")?;
        let binary = temp.join(BINARY);
        if !status.success() || !std::fs::symlink_metadata(&binary)?.is_file() {
            bail!("{} has no {BINARY}", release.asset);
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755))?;
        }
        let target = dir.join(format!("v{}", release.version));
        std::fs::create_dir_all(&target)?;
        std::fs::rename(&binary, target.join(BINARY))?;
        Ok(())
    })();
    let _ = std::fs::remove_dir_all(&temp);
    result
}

fn spawn(proxy: &Proxy, prefs: &Prefs) -> Result<Child> {
    let version = prefs
        .version
        .as_deref()
        .context("Install CLIProxyAPI first.")?;
    let binary = proxy.dir.join(format!("v{version}")).join(BINARY);
    let config = write_config(&proxy.dir, prefs.port, &proxy.key)?;
    let pid_file = proxy.dir.join(PID_FILE);
    stop_leftover(&pid_file);
    let child = quiet(&binary)
        .arg("-config")
        .arg(&config)
        .current_dir(&proxy.dir)
        .spawn()
        .with_context(|| format!("Couldn’t start {}", binary.display()))?;
    std::fs::write(&pid_file, child.id().to_string())?;
    Ok(child)
}

/// Stop the proxy a crashed or killed Quotio left running, if that process id still
/// belongs to one of Quotio's proxy executables.
fn stop_leftover(pid_file: &Path) {
    let Some(pid) = std::fs::read_to_string(pid_file)
        .ok()
        .and_then(|pid| pid.trim().parse::<u32>().ok())
    else {
        return;
    };
    let _ = std::fs::remove_file(pid_file);
    let pid = pid.to_string();
    let filter = format!("PID eq {pid}");
    // Windows lists only the image name; elsewhere the command line shows the path.
    let (list, ours, kill) = if cfg!(windows) {
        (
            vec!["tasklist", "/FI", &filter, "/FO", "CSV", "/NH"],
            format!("\"{BINARY}\""),
            vec!["taskkill", "/F", "/PID", &pid],
        )
    } else {
        let dir = pid_file.parent().unwrap_or(pid_file).display().to_string();
        (
            vec!["ps", "-p", &pid, "-o", "command="],
            dir,
            vec!["kill", "-9", &pid],
        )
    };
    let Ok(output) = quiet(list[0])
        .args(&list[1..])
        .stdout(Stdio::piped())
        .output()
    else {
        return;
    };
    if !String::from_utf8_lossy(&output.stdout).contains(&ours) {
        return;
    }
    let _ = quiet(kill[0]).args(&kill[1..]).status();
    // Give the system a moment to release the port.
    std::thread::sleep(Duration::from_millis(300));
}

/// A command with no console window and no standard streams.
fn quiet(program: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut command = Command::new(program);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}

/// Create the v8 config on first use; later, set only the port and management key
/// so the user's own edits stay.
fn write_config(dir: &Path, port: u16, key: &str) -> Result<PathBuf> {
    let path = config_path();
    let content = match std::fs::read_to_string(&path) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => format!(
            "config-version: 8\n\
             server:\n  host: \"127.0.0.1\"\n  port: {port}\n\
             management:\n  allow-remote: false\n  secret-key: \"\"\n\
             access:\n  api-keys:\n    - \"quotio-local-{}\"\n\
             oauth:\n  auth-dir: \"~/.cli-proxy-api\"\n",
            random_hex()
        ),
        Err(error) => return Err(error.into()),
    };
    std::fs::create_dir_all(dir)?;
    std::fs::write(&path, set_config(&content, port, key))?;
    Ok(path)
}

/// Replace `server.port` and `management.secret-key`, leaving every other line as is.
fn set_config(content: &str, port: u16, key: &str) -> String {
    let mut section = "";
    let mut out: Vec<String> = content
        .lines()
        .map(|line| {
            if !line.starts_with([' ', '\t', '#']) && !line.is_empty() {
                section = line.split(':').next().unwrap_or_default();
            }
            match (section, line.trim_start()) {
                ("server", rest) if rest.starts_with("port:") => format!("  port: {port}"),
                ("management", rest) if rest.starts_with("secret-key:") => {
                    format!("  secret-key: \"{key}\"")
                }
                _ => line.to_owned(),
            }
        })
        .collect();
    out.push(String::new());
    out.join("\n")
}

/// Load the management key, or create one readable only by this user.
fn management_key(dir: &Path) -> Result<String> {
    let path = dir.join("management.key");
    if let Ok(key) = std::fs::read_to_string(&path) {
        return Ok(key.trim().to_owned());
    }
    std::fs::create_dir_all(dir)?;
    let key = random_hex();
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    std::io::Write::write_all(&mut options.open(&path)?, key.as_bytes())?;
    Ok(key)
}

fn random_hex() -> String {
    let mut bytes = [0u8; 16];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes)
        .expect("the system random source works");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
