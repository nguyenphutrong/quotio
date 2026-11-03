//! Start Quotio when the user signs in: a per-user LaunchAgent on macOS, an XDG
//! autostart entry on Linux, the per-user `Run` key on Windows.
use anyhow::Result;

#[cfg(target_os = "linux")]
fn entry() -> Result<std::path::PathBuf> {
    let dirs = directories::BaseDirs::new().ok_or_else(|| anyhow::anyhow!("no home directory"))?;
    Ok(dirs
        .config_dir()
        .join("autostart/app.quotio.Quotio.desktop"))
}

#[cfg(target_os = "linux")]
pub fn enabled() -> bool {
    entry().is_ok_and(|path| path.exists())
}

#[cfg(target_os = "linux")]
pub fn set(on: bool) -> Result<()> {
    let path = entry()?;
    if !on {
        return match std::fs::remove_file(&path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        };
    }
    // Desktop entries quote arguments and escape `"`, `` ` ``, `$` and `\`.
    let exe = std::env::current_exe()?.display().to_string();
    let exe: String = exe
        .chars()
        .flat_map(|c| match c {
            '"' | '`' | '$' | '\\' => vec!['\\', c],
            c => vec![c],
        })
        .collect();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(
        &path,
        format!(
            "[Desktop Entry]\nType=Application\nName=Quotio\nComment=AI coding quota in your tray\nExec=\"{exe}\"\nTerminal=false\nX-GNOME-Autostart-enabled=true\n"
        ),
    )?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn entry() -> Result<std::path::PathBuf> {
    let dirs = directories::BaseDirs::new().ok_or_else(|| anyhow::anyhow!("no home directory"))?;
    Ok(dirs
        .home_dir()
        .join("Library/LaunchAgents/app.quotio.Quotio.plist"))
}

#[cfg(target_os = "macos")]
pub fn enabled() -> bool {
    entry().is_ok_and(|path| path.exists())
}

#[cfg(target_os = "macos")]
pub fn set(on: bool) -> Result<()> {
    let path = entry()?;
    if !on {
        return match std::fs::remove_file(&path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error.into()),
            _ => Ok(()),
        };
    }
    let exe = std::env::current_exe()?.display().to_string();
    let exe = exe
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(
        &path,
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>Label</key>\n\t<string>app.quotio.Quotio</string>\n\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>{exe}</string>\n\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n</dict>\n</plist>\n"
        ),
    )?;
    Ok(())
}

#[cfg(windows)]
const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";

#[cfg(windows)]
fn reg(args: &[&str]) -> std::io::Result<std::process::Output> {
    use std::os::windows::process::CommandExt as _;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    std::process::Command::new("reg")
        .args(args)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
}

#[cfg(windows)]
pub fn enabled() -> bool {
    reg(&["query", RUN_KEY, "/v", "Quotio"]).is_ok_and(|out| out.status.success())
}

#[cfg(windows)]
pub fn set(on: bool) -> Result<()> {
    let output = if on {
        let exe = format!("\"{}\"", std::env::current_exe()?.display());
        reg(&[
            "add", RUN_KEY, "/v", "Quotio", "/t", "REG_SZ", "/d", &exe, "/f",
        ])?
    } else if enabled() {
        reg(&["delete", RUN_KEY, "/v", "Quotio", "/f"])?
    } else {
        return Ok(());
    };
    anyhow::ensure!(
        output.status.success(),
        "reg.exe exited with {}",
        output.status
    );
    Ok(())
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
pub fn enabled() -> bool {
    false
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
pub fn set(_: bool) -> Result<()> {
    anyhow::bail!("not supported on this platform")
}
