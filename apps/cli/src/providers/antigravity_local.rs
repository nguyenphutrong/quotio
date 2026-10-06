use super::{ProviderContext, Secret, antigravity, http, process};
use crate::{domain::*, error::ProviderError};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use time::OffsetDateTime;

const SERVICE: &str = "exa.language_server_pb.LanguageServerService";
struct Candidate {
    pid: u32,
    #[cfg(target_os = "macos")]
    executable: PathBuf,
    csrf: Secret,
}
fn executable_paths() -> Vec<PathBuf> {
    let mut roots = vec![PathBuf::from("/Applications")];
    if let Some(dirs) = directories::BaseDirs::new() {
        roots.push(dirs.home_dir().join("Applications"));
    }
    roots.into_iter().flat_map(|root| [
        root.join("Antigravity.app/Contents/Resources/bin/language_server"),
        root.join("Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm"),
        root.join("Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64"),
    ]).collect()
}
fn candidates(output: &str, uid: u32, executables: &[PathBuf]) -> Vec<Candidate> {
    output
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            let (owner, rest) = line.split_once(char::is_whitespace)?;
            if owner.parse::<u32>().ok()? != uid {
                return None;
            }
            let (pid, command) = rest.trim_start().split_once(char::is_whitespace)?;
            let pid = pid.parse::<u32>().ok().filter(|pid| *pid > 0)?;
            let command = command.trim_start();
            let (_executable, args) = executables.iter().find_map(|path| {
                command
                    .strip_prefix(path.to_str()?)
                    .filter(|rest| rest.starts_with(char::is_whitespace))
                    .map(|rest| (path.clone(), rest))
            })?;
            let args: Vec<_> = args.split_whitespace().collect();
            let mut tokens = args.iter().enumerate().filter_map(|(index, arg)| {
                arg.strip_prefix("--csrf_token=").or_else(|| {
                    if *arg == "--csrf_token" {
                        args.get(index + 1).copied()
                    } else {
                        None
                    }
                })
            });
            let csrf = tokens.next()?;
            if tokens.next().is_some()
                || csrf.is_empty()
                || csrf.len() > 4096
                || http::sensitive(csrf).is_err()
            {
                return None;
            }
            Some(Candidate {
                pid,
                #[cfg(target_os = "macos")]
                executable: _executable,
                csrf: Secret(csrf.into()),
            })
        })
        .take(4)
        .collect()
}
fn ports(output: &str) -> Vec<u16> {
    let mut ports: Vec<_> = output
        .lines()
        .filter_map(|line| {
            let (address, port) = line.strip_prefix('n')?.rsplit_once(':')?;
            if !matches!(address, "127.0.0.1" | "*") {
                return None;
            }
            port.parse::<u16>().ok().filter(|p| *p != 0)
        })
        .collect();
    ports.sort_unstable();
    ports.dedup();
    ports.truncate(4);
    ports
}
#[cfg(target_os = "macos")]
fn process_matches(candidate: &Candidate) -> bool {
    // Verify the OS executable path, not just the process's editable argv.
    let mut buffer = vec![0u8; 4096];
    let length = unsafe {
        libc::proc_pidpath(
            candidate.pid as i32,
            buffer.as_mut_ptr().cast(),
            buffer.len() as u32,
        )
    };
    if length <= 0 {
        return false;
    }
    let end = buffer.iter().position(|b| *b == 0).unwrap_or(buffer.len());
    std::str::from_utf8(&buffer[..end]).is_ok_and(|path| Path::new(path) == candidate.executable)
}
#[cfg(not(target_os = "macos"))]
fn process_matches(_: &Candidate) -> bool {
    false
}

fn client() -> Result<reqwest::Client, ProviderError> {
    // This client is private to this module; URLs are constructed from numeric
    // loopback ports only. Google requests always use the normal validated client.
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .danger_accept_invalid_certs(true)
        .timeout(std::time::Duration::from_secs(2))
        .build()
        .map_err(|_| ProviderError::Internal)
}
async fn rpc(
    client: &reqwest::Client,
    scheme: &str,
    port: u16,
    csrf: &Secret,
    method: &str,
    now: OffsetDateTime,
) -> Result<Value, ProviderError> {
    let url = format!("{scheme}://127.0.0.1:{port}/{SERVICE}/{method}");
    http::json(client.post(url)
        .header("x-codeium-csrf-token", http::sensitive(&csrf.0)?)
        .header("Connect-Protocol-Version", "1")
        .json(&json!({"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}})), now).await
}
fn identity(value: &Value) -> Result<(String, Option<String>), ProviderError> {
    let status = value.get("userStatus").ok_or(ProviderError::InvalidData)?;
    let email = status
        .get("email")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|email| {
            email.contains('@') && email.len() <= 320 && !email.chars().any(char::is_control)
        })
        .ok_or(ProviderError::Authentication)?;
    let plan = status
        .pointer("/userTier/name")
        .or_else(|| status.pointer("/planStatus/planInfo/planName"))
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .map(str::to_owned);
    Ok((email.into(), plan))
}
fn windows(value: &Value, now: OffsetDateTime) -> Result<Vec<QuotaWindow>, ProviderError> {
    let groups = value
        .get("groups")
        .or_else(|| value.pointer("/response/groups"))
        .and_then(Value::as_array)
        .ok_or(ProviderError::InvalidData)?;
    let mut windows = Vec::new();
    for group in groups {
        let buckets = group
            .get("buckets")
            .and_then(Value::as_array)
            .ok_or(ProviderError::InvalidData)?;
        for bucket in buckets {
            if bucket.get("disabled").and_then(Value::as_bool) == Some(true) {
                continue;
            }
            let id = bucket
                .get("bucketId")
                .and_then(Value::as_str)
                .filter(|s| !s.trim().is_empty())
                .ok_or(ProviderError::InvalidData)?;
            let label = match id {
                "gemini-session" => "Session",
                "gemini-weekly" => "Weekly",
                "3p-session" => "Claude Session",
                "3p-weekly" => "Claude Weekly",
                other => other,
            };
            windows.push(antigravity::window(
                label.into(),
                antigravity::fraction(bucket.get("remainingFraction"))?,
                bucket.get("resetTime"),
                "antigravity_local_service",
                now,
            )?);
        }
    }
    if windows.is_empty() {
        return Err(ProviderError::QuotaUnavailable);
    }
    Ok(windows)
}
async fn probe(
    client: &reqwest::Client,
    scheme: &str,
    port: u16,
    csrf: &Secret,
    context: &ProviderContext,
    expected: Option<(&str, &str)>,
) -> Result<ProviderUsage, ProviderError> {
    let (email, plan) = identity(
        &rpc(
            client,
            scheme,
            port,
            csrf,
            "GetUserStatus",
            context.clock.now(),
        )
        .await?,
    )?;
    if expected.is_some_and(|(_, expected_email)| !email.eq_ignore_ascii_case(expected_email)) {
        return Err(ProviderError::Authentication);
    }
    let quota = rpc(
        client,
        scheme,
        port,
        csrf,
        "RetrieveUserQuotaSummary",
        context.clock.now(),
    )
    .await?;
    let windows = windows(&quota, context.clock.now())?;
    let (after, _) = identity(
        &rpc(
            client,
            scheme,
            port,
            csrf,
            "GetUserStatus",
            context.clock.now(),
        )
        .await?,
    )?;
    if !after.eq_ignore_ascii_case(&email) {
        return Err(ProviderError::Authentication);
    }
    Ok(ProviderUsage {
        fresh_observation: false,
        history_identity: None,
        reset_credits: None,
        antigravity_subscription: None,
        codex_profile: None,
        codex_reset_credits: None,
        diagnostics: vec![],
        account_ref: None,
        provider: ProviderId("antigravity".into()),
        account: AccountIdentity {
            verified: None,
            subscription_status: None,
            id: expected
                .map(|(id, _)| id.to_owned())
                .unwrap_or_else(|| email.clone()),
            label: email,
            plan,
        },
        windows,
    })
}

pub(super) async fn fetch(
    context: &ProviderContext,
    expected: Option<(&str, &str)>,
) -> Result<ProviderUsage, ProviderError> {
    #[cfg(not(target_os = "macos"))]
    let uid = u32::MAX;
    #[cfg(target_os = "macos")]
    let uid = unsafe { libc::getuid() };
    if !cfg!(target_os = "macos") {
        return Err(ProviderError::Unavailable);
    }
    let bytes = process::output(
        Path::new("/bin/ps"),
        &["-U", &uid.to_string(), "-o", "uid=,pid=,args="],
    )
    .await?;
    let output = std::str::from_utf8(&bytes).map_err(|_| ProviderError::InvalidData)?;
    let candidates = candidates(output, uid, &executable_paths());
    if expected.is_none() && candidates.len() > 1 {
        return Err(ProviderError::Authentication);
    }
    let client = client()?;
    let mut last = ProviderError::Unavailable;
    for candidate in candidates {
        if !process_matches(&candidate) {
            continue;
        }
        let bytes = process::output(
            Path::new("/usr/sbin/lsof"),
            &[
                "-nP",
                "-i4TCP",
                "-sTCP:LISTEN",
                "-a",
                "-p",
                &candidate.pid.to_string(),
                "-Fpn",
            ],
        )
        .await;
        let Ok(bytes) = bytes else {
            continue;
        };
        let output = std::str::from_utf8(&bytes).map_err(|_| ProviderError::InvalidData)?;
        for port in ports(output) {
            for scheme in ["https", "http"] {
                if !process_matches(&candidate) {
                    break;
                }
                match probe(&client, scheme, port, &candidate.csrf, context, expected).await {
                    Ok(usage) if process_matches(&candidate) => return Ok(usage),
                    Ok(_) => return Err(ProviderError::Unavailable),
                    Err(ProviderError::Authentication) => {
                        last = ProviderError::Authentication;
                        break;
                    }
                    Err(error) => last = error,
                }
            }
        }
    }
    Err(last)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn discovery_requires_own_user_exact_executable_and_one_csrf_flag() {
        let paths = vec![PathBuf::from(
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
        )];
        let executable = paths[0].display();
        let text = format!(
            "501 10 {executable} --csrf_token=synthetic\n502 11 {executable} --csrf_token=other\n501 12 /bin/echo {executable} --csrf_token=spoof\n501 13 {executable}.fake --csrf_token=spoof\n501 14 {executable} --csrf_token=a --csrf_token=b\n501 15 {executable} --csrf_token\n"
        );
        let found = candidates(&text, 501, &paths);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].pid, 10);
        assert_eq!(found[0].csrf.0, "synthetic");
        assert_eq!(
            ports(
                "p10\nn127.0.0.1:5000\nn*:5001\nn[::1]:5002\nn192.0.2.1:5003\nn127.0.0.1:0\nn127.0.0.1:65536\nn127.0.0.1:5000"
            ),
            vec![5000, 5001]
        );
    }
    fn status(email: &str) -> Value {
        json!({"userStatus":{"email":email,"userTier":{"name":"Test plan"}}})
    }
    fn summary() -> Value {
        json!({"groups":[{"buckets":[{"bucketId":"gemini-weekly","remainingFraction":1,"resetTime":"2026-09-12T10:00:00Z"},{"bucketId":"3p-weekly","remainingFraction":0.5}]}]})
    }
    #[test]
    fn summary_omits_absent_windows_and_preserves_unknown() {
        let windows = windows(&summary(), OffsetDateTime::UNIX_EPOCH).unwrap();
        assert_eq!(
            windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(),
            vec!["Weekly", "Claude Weekly"]
        );
        assert_eq!(windows[0].quota, Quota::from_used(Some(0.0)));
        assert_eq!(windows[1].quota, Quota::from_used(Some(50.0)));
        assert_eq!(windows[0].provenance.source, "antigravity_local_service");
        let unknown = super::windows(
            &json!({"groups":[{"buckets":[{"bucketId":"gemini-session"}]}]}),
            OffsetDateTime::UNIX_EPOCH,
        )
        .unwrap();
        assert_eq!(unknown[0].quota, Quota::Unknown);
        assert!(super::windows(&json!({"groups":[{"buckets":[{"bucketId":"gemini-session","remainingFraction":1.1}]}]}), OffsetDateTime::UNIX_EPOCH).is_err());
    }
    #[tokio::test]
    async fn local_rpc_checks_identity_and_sends_only_csrf() {
        let (base, task) = http::fixture::server(vec![
            status("local@example.invalid"),
            summary(),
            status("local@example.invalid"),
        ])
        .await;
        let port = reqwest::Url::parse(&base).unwrap().port().unwrap();
        let usage = probe(
            &client().unwrap(),
            "http",
            port,
            &Secret("synthetic-csrf".into()),
            &http::fixture::context(),
            Some(("verified-id", "local@example.invalid")),
        )
        .await
        .unwrap();
        assert_eq!(usage.account.id, "verified-id");
        assert_eq!(usage.account.plan.as_deref(), Some("Test plan"));
        assert_eq!(usage.windows.len(), 2);
        let requests = task.await.unwrap();
        assert_eq!(requests.len(), 3);
        assert!(requests[1].starts_with(&format!("POST /{SERVICE}/RetrieveUserQuotaSummary ")));
        for request in requests {
            let request = request.to_ascii_lowercase();
            assert!(request.contains("x-codeium-csrf-token: synthetic-csrf"));
            assert!(!request.contains("authorization:"));
        }
    }
    #[tokio::test]
    async fn mismatched_or_changed_account_never_returns_quota() {
        for changed in [false, true] {
            let responses = if changed {
                vec![
                    status("expected@example.invalid"),
                    summary(),
                    status("other@example.invalid"),
                ]
            } else {
                vec![status("other@example.invalid")]
            };
            let count = responses.len();
            let (base, task) = http::fixture::server(responses).await;
            let result = probe(
                &client().unwrap(),
                "http",
                reqwest::Url::parse(&base).unwrap().port().unwrap(),
                &Secret("synthetic-csrf".into()),
                &http::fixture::context(),
                Some(("verified-id", "expected@example.invalid")),
            )
            .await;
            assert_eq!(result.unwrap_err(), ProviderError::Authentication);
            assert_eq!(task.await.unwrap().len(), count);
        }
    }
    #[tokio::test]
    async fn redirects_cannot_forward_csrf() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let source = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let destination = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = source.local_addr().unwrap().port();
        let destination_port = destination.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut socket, _) = source.accept().await.unwrap();
            let mut bytes = [0; 8192];
            assert!(socket.read(&mut bytes).await.unwrap() > 0);
            socket.write_all(format!("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{destination_port}/capture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
        });
        let result = rpc(
            &client().unwrap(),
            "http",
            port,
            &Secret("synthetic-csrf".into()),
            "GetUserStatus",
            OffsetDateTime::UNIX_EPOCH,
        )
        .await;
        assert_eq!(result.unwrap_err(), ProviderError::Unavailable);
        server.await.unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(30), destination.accept())
                .await
                .is_err()
        );
    }
}
