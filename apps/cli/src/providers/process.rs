use crate::error::ProviderError;
use std::{
    path::{Path, PathBuf},
    process::Stdio,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, BufReader},
    process::{Child, Command},
};
pub(crate) const MAX_BYTES: usize = 1024 * 1024;

pub(crate) fn spawn(program: &Path, args: &[&str]) -> Result<Child, ProviderError> {
    Command::new(resolve_program(program).ok_or(ProviderError::CliNotFound)?)
        .args(args)
        .env("NO_COLOR", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|_| ProviderError::Unavailable)
}
// Desktop launches often have a minimal PATH. Keep provider executable discovery in the host.
pub(crate) fn resolve_program(program: &Path) -> Option<PathBuf> {
    if program.components().count() != 1 || program.is_absolute() {
        return Some(program.to_owned());
    }
    let mut directories: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|path| {
            std::env::split_paths(&path)
                .filter(|directory| !directory.as_os_str().is_empty())
                .collect()
        })
        .unwrap_or_default();
    #[cfg(unix)]
    {
        directories.extend(["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"].map(PathBuf::from));
        if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
            directories.extend(
                [
                    ".local/bin",
                    ".codex/packages/standalone/current/bin",
                    ".amp/bin",
                    ".cargo/bin",
                    ".bun/bin",
                    ".deno/bin",
                    ".npm-global/bin",
                    ".opencode/bin",
                    ".warp/bin",
                    ".volta/bin",
                    ".asdf/shims",
                    ".local/share/mise/shims",
                ]
                .map(|path| home.join(path)),
            );
            let data_home = std::env::var_os("XDG_DATA_HOME")
                .filter(|p| !p.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join(".local/share"));
            for (base, suffix) in [
                (home.join(".nvm/versions/node"), "bin"),
                (data_home.join("fnm/node-versions"), "installation/bin"),
                (home.join(".fnm/node-versions"), "installation/bin"),
            ] {
                if let Ok(entries) = std::fs::read_dir(base) {
                    let mut versions: Vec<_> = entries
                        .filter_map(Result::ok)
                        .map(|entry| entry.path())
                        .collect();
                    versions.sort_unstable_by(|a, b| b.cmp(a));
                    directories.extend(versions.into_iter().map(|path| path.join(suffix)));
                }
            }
        }
    }
    find_program(program, &directories)
}
fn find_program(program: &Path, directories: &[PathBuf]) -> Option<PathBuf> {
    directories
        .iter()
        .map(|directory| directory.join(program))
        .find(|path| {
            let Ok(metadata) = path.metadata() else {
                return false;
            };
            if !metadata.is_file() {
                return false;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                metadata.permissions().mode() & 0o111 != 0
            }
            #[cfg(not(unix))]
            {
                true
            }
        })
}
pub(crate) async fn line<R: tokio::io::AsyncBufRead + Unpin>(
    reader: &mut R,
) -> Result<Vec<u8>, ProviderError> {
    let mut buffer = Vec::new();
    reader
        .take((MAX_BYTES + 1) as u64)
        .read_until(b'\n', &mut buffer)
        .await
        .map_err(|_| ProviderError::InvalidData)?;
    if buffer.is_empty() || buffer.len() > MAX_BYTES {
        return Err(ProviderError::InvalidData);
    }
    Ok(buffer)
}
pub(crate) async fn output(program: &Path, args: &[&str]) -> Result<Vec<u8>, ProviderError> {
    let (status, bytes) = output_status(program, args).await?;
    if !status.success() {
        return Err(ProviderError::Unavailable);
    }
    Ok(bytes)
}
pub(crate) async fn output_status(
    program: &Path,
    args: &[&str],
) -> Result<(std::process::ExitStatus, Vec<u8>), ProviderError> {
    let mut child = spawn(program, args)?;
    drop(child.stdin.take());
    let stdout = child.stdout.take().ok_or(ProviderError::Internal)?;
    let mut bytes = Vec::new();
    BufReader::new(stdout)
        .take((MAX_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .await
        .map_err(|_| ProviderError::InvalidData)?;
    if bytes.len() > MAX_BYTES {
        return Err(ProviderError::InvalidData);
    }
    let status = child.wait().await.map_err(|_| ProviderError::Unavailable)?;
    Ok((status, bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    #[tokio::test]
    async fn output_status_preserves_exit_codes_without_changing_output_errors() {
        let args = ["-c", "printf fixture; exit 44"];
        let (status, bytes) = output_status(Path::new("/bin/sh"), &args).await.unwrap();
        assert_eq!(status.code(), Some(44));
        assert_eq!(bytes, b"fixture");
        assert_eq!(
            output(Path::new("/bin/sh"), &args).await.unwrap_err(),
            ProviderError::Unavailable
        );
    }
    #[cfg(unix)]
    #[test]
    fn executable_lookup_preserves_order_and_rejects_nonexecutables() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!(
            "quotio-process-{}",
            crate::accounts::random_string().unwrap()
        ));
        let first = root.join("first");
        let second = root.join("second");
        std::fs::create_dir_all(&first).unwrap();
        std::fs::create_dir_all(&second).unwrap();
        for directory in [&first, &second] {
            std::fs::write(directory.join("tool"), b"#!/bin/sh\nexit 0\n").unwrap();
            std::fs::set_permissions(
                directory.join("tool"),
                std::fs::Permissions::from_mode(0o700),
            )
            .unwrap();
        }
        let directories = [first.clone(), second.clone()];
        assert_eq!(
            find_program(Path::new("tool"), &directories),
            Some(first.join("tool"))
        );
        std::fs::set_permissions(first.join("tool"), std::fs::Permissions::from_mode(0o600))
            .unwrap();
        assert_eq!(
            find_program(Path::new("tool"), &directories),
            Some(second.join("tool"))
        );
        assert_eq!(
            resolve_program(&first.join("tool")),
            Some(first.join("tool"))
        );
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn protocol_lines_are_bounded() {
        let mut input = BufReader::new(&b"{\"id\":1}\n"[..]);
        assert_eq!(line(&mut input).await.unwrap(), b"{\"id\":1}\n");
        assert_eq!(
            line(&mut input).await.unwrap_err(),
            ProviderError::InvalidData
        );
        let oversized = vec![b'a'; MAX_BYTES + 1];
        let mut input = BufReader::new(oversized.as_slice());
        assert_eq!(
            line(&mut input).await.unwrap_err(),
            ProviderError::InvalidData
        );
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn cancelling_a_subprocess_kills_it() {
        let mut child = spawn(Path::new("/bin/sh"), &["-c", "printf ready; read value"]).unwrap();
        let pid = child.id().unwrap();
        let stdin = child.stdin.take().unwrap();
        let mut output = child.stdout.take().unwrap();
        let mut ready = [0; 5];
        output.read_exact(&mut ready).await.unwrap();
        assert_eq!(&ready, b"ready");
        drop(child);
        let gone = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                let status = Command::new("/bin/kill")
                    .args(["-0", &pid.to_string()])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .await
                    .unwrap();
                if !status.success() {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await;
        assert!(gone.is_ok());
        drop(stdin);
    }
}
