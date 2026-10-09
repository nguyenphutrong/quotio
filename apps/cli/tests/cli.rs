use clap::Parser;
use quotio::{
    cli::{Cli, Command as CliCommand},
    config::Config,
};
use std::{
    path::PathBuf,
    process::{Command, Output},
    sync::atomic::{AtomicUsize, Ordering},
};
static NEXT: AtomicUsize = AtomicUsize::new(0);
struct ConfigFile(PathBuf);
impl ConfigFile {
    fn new(contents: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "quotio-test-{}-{}.toml",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::write(&path, contents).unwrap();
        Self(path)
    }
}
impl Drop for ConfigFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
        let _ = std::fs::remove_dir_all(self.0.with_extension("cache"));
        let _ = std::fs::remove_dir_all(self.0.with_extension("home"));
    }
}
fn run(args: &[&str], config: &ConfigFile) -> Output {
    Command::new(env!("CARGO_BIN_EXE_quotio"))
        .args(args)
        .env_clear()
        .env("HOME", config.0.with_extension("home"))
        .env("QUOTIO_CACHE_DIR", config.0.with_extension("cache"))
        .arg("--no-saved-accounts")
        .arg("--config")
        .arg(&config.0)
        .output()
        .unwrap()
}
#[test]
fn argument_contract() {
    let parsed = Cli::try_parse_from([
        "quotio",
        "usage",
        "--provider",
        "mock",
        "--provider",
        "mock",
        "--format",
        "json",
        "--timeout",
        "1",
        "--no-color",
        "--verbose",
    ])
    .unwrap();
    let Some(CliCommand::Usage(args)) = parsed.command else {
        panic!()
    };
    assert_eq!(args.provider.len(), 2);
    for value in ["0", "3601", "NaN", "-1"] {
        assert!(Cli::try_parse_from(["quotio", "usage", "--timeout", value]).is_err());
    }
    assert!(Cli::try_parse_from(["quotio", "usage", "--provider", "unknown"]).is_err());
    assert!(Cli::try_parse_from(["quotio"]).unwrap().command.is_none());
    assert!(Cli::try_parse_from(["quotio", "interactive"]).is_err());
}
#[test]
fn sharing_requires_explicit_network_addresses_and_valid_ports() {
    for mode in ["local-network", "tailscale"] {
        assert!(Cli::try_parse_from(["quotio", "sharing", "enable", "--mode", mode]).is_err());
        assert!(
            Cli::try_parse_from([
                "quotio",
                "sharing",
                "enable",
                "--mode",
                mode,
                "--address",
                "192.168.1.10"
            ])
            .is_ok()
        );
    }
    assert!(Cli::try_parse_from(["quotio", "sharing", "enable", "--mode", "proxy"]).is_err());
    for port in ["0", "65536", "bad"] {
        assert!(
            Cli::try_parse_from([
                "quotio",
                "sharing",
                "enable",
                "--mode",
                "tailscale",
                "--address",
                "100.64.0.2",
                "--port",
                port
            ])
            .is_err()
        );
    }
}

#[test]
fn provider_json_uses_the_http_contract() {
    let config = ConfigFile::new("enabled_providers = [\"mock\"]");
    let output = Command::new(env!("CARGO_BIN_EXE_quotio"))
        .args(["providers", "--format", "json", "--config"])
        .arg(&config.0)
        .env_clear()
        .output()
        .unwrap();
    assert!(output.status.success());
    let actual: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    let expected = serde_json::to_value(quotio::providers::capabilities::ProviderList::new(&[
        quotio::cli::Provider::Mock,
    ]))
    .unwrap();
    assert_eq!(actual, expected);
}

#[test]
fn json_contract_and_deduplication() {
    let config = ConfigFile::new("enabled_providers = []");
    let result = run(
        &[
            "usage",
            "--provider",
            "mock",
            "--provider",
            "mock",
            "--format",
            "json",
            "--verbose",
        ],
        &config,
    );
    assert_eq!(result.status.code(), Some(0));
    let value: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value.as_object().unwrap().len(), 6);
    assert_eq!(value["schema_version"], 2);
    let document: serde_json::Value =
        serde_json::from_str(include_str!("../docs/openapi.json")).unwrap();
    jsonschema::draft202012::new(&serde_json::json!({"$ref":"#/components/schemas/V2Snapshot", "components":document["components"]})).unwrap().validate(&value).unwrap();
    time::OffsetDateTime::parse(
        value["generated_at"].as_str().unwrap(),
        &time::format_description::well_known::Rfc3339,
    )
    .unwrap();
    assert_eq!(value["accounts"].as_array().unwrap().len(), 1);
    assert_eq!(value["accounts"][0]["provider_id"], "mock");
    assert_eq!(value["accounts"][0]["display_name"], "Demo account");
    assert_eq!(value["usage"][0]["account_id"], value["accounts"][0]["id"]);
    let windows = &value["usage"][0]["metrics"];
    assert_eq!(windows.as_array().unwrap().len(), 3);
    assert_eq!(
        windows[0]["quota"],
        serde_json::json!({"state":"available", "used_percent":25.0, "remaining_percent":75.0})
    );
    assert_eq!(windows[1]["quota"]["state"], "exhausted");
    assert_eq!(windows[2]["quota"], serde_json::json!({"state":"unknown"}));
    assert!(windows[2]["resets_at"].is_null());
    assert_eq!(windows[0]["provenance"]["source"], "mock_fixture");
    let timestamp = |value: &serde_json::Value| {
        time::OffsetDateTime::parse(
            value.as_str().unwrap(),
            &time::format_description::well_known::Rfc3339,
        )
        .unwrap()
    };
    let fetched_at = timestamp(&windows[0]["fetched_at"]);
    assert!(fetched_at <= timestamp(&value["generated_at"]));
    assert_eq!(
        timestamp(&windows[0]["resets_at"]),
        fetched_at + time::Duration::days(7)
    );
    assert_eq!(value["usage"][0]["freshness"], "fresh");
    assert!(value["usage"][0]["issue"].is_null());
    assert!(String::from_utf8_lossy(&result.stderr).contains("collecting provider usage"));
}
#[test]
fn text_output_and_explicit_selection() {
    let config = ConfigFile::new("enabled_providers = [\"mock\"]");
    let result = run(&["usage", "--provider", "mock", "--no-color"], &config);
    assert_eq!(result.status.code(), Some(0));
    assert!(result.stderr.is_empty());
    let text = String::from_utf8(result.stdout).unwrap();
    assert!(!text.contains('\x1b'));
}
#[test]
fn empty_and_invalid_config_exit_codes_and_redaction() {
    let empty = ConfigFile::new("enabled_providers = []");
    let result = run(&["usage", "--format", "json"], &empty);
    assert_eq!(result.status.code(), Some(3));
    assert!(serde_json::from_slice::<serde_json::Value>(&result.stdout).is_ok());
    for input in [
        "token = 'secret-sentinel'",
        "enabled_providers = ['secret-sentinel']",
        "enabled_providers = secret-sentinel",
    ] {
        let config = ConfigFile::new(input);
        let result = run(&["usage"], &config);
        assert_eq!(result.status.code(), Some(2));
        assert!(result.stdout.is_empty());
        assert!(!String::from_utf8_lossy(&result.stderr).contains("secret-sentinel"));
    }
    let result = run(&["usage", "--provider", "secret-sentinel"], &empty);
    assert_eq!(result.status.code(), Some(2));
    assert!(!String::from_utf8_lossy(&result.stderr).contains("secret-sentinel"));
}
#[test]
fn missing_config_and_help() {
    assert!(
        Config::load(Some(std::path::Path::new(
            "/nonexistent/quotio/config.toml"
        )))
        .is_err()
    );
    for args in [vec!["--help"], vec!["usage", "--help"], vec!["providers"]] {
        let result = Command::new(env!("CARGO_BIN_EXE_quotio"))
            .args(args)
            .output()
            .unwrap();
        assert_eq!(result.status.code(), Some(0));
        assert!(!result.stdout.is_empty());
        assert!(result.stderr.is_empty());
    }
}

#[test]
fn real_provider_selection_and_mixed_missing_auth() {
    use quotio::cli::Provider;
    let configured =
        Config::parse("enabled_providers = ['codex','amp','antigravity','droid','factory']")
            .unwrap()
            .providers()
            .unwrap();
    assert_eq!(
        configured,
        vec![
            Provider::Codex,
            Provider::Amp,
            Provider::Antigravity,
            Provider::Factory
        ]
    );
    let config = ConfigFile::new("enabled_providers = []");
    let output = Command::new(env!("CARGO_BIN_EXE_quotio"))
        .args([
            "usage",
            "--provider",
            "mock",
            "--provider",
            "factory",
            "--no-saved-accounts",
            "--format",
            "json",
            "--verbose",
            "--config",
        ])
        .arg(&config.0)
        .env_remove("FACTORY_API_KEY")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    let accounts = value["accounts"].as_array().unwrap();
    assert!(
        accounts
            .iter()
            .any(|account| account["provider_id"] == "mock")
    );
    assert!(
        !accounts
            .iter()
            .any(|account| account["provider_id"] == "factory")
    );
    assert_eq!(
        value["provider_issues"]["factory"]["code"],
        "authentication"
    );
}

#[test]
fn account_commands_are_explicit_and_help_exposes_no_secret_argument() {
    for args in [
        vec![
            "quotio",
            "accounts",
            "add",
            "--provider",
            "codex",
            "--label",
            "Personal",
        ],
        vec![
            "quotio",
            "accounts",
            "add",
            "--provider",
            "amp",
            "--label",
            "Work",
            "--token-stdin",
        ],
        vec!["quotio", "accounts", "add", "--provider", "codex"],
        vec![
            "quotio",
            "accounts",
            "add",
            "--provider",
            "amp",
            "--token-stdin",
        ],
        vec![
            "quotio",
            "accounts",
            "add",
            "--provider",
            "factory",
            "--token-stdin",
        ],
        vec!["quotio", "accounts", "list", "--format", "json"],
        vec!["quotio", "accounts", "use", "id"],
        vec!["quotio", "accounts", "remove", "id"],
    ] {
        assert!(Cli::try_parse_from(args).is_ok());
    }
    assert!(
        Cli::try_parse_from([
            "quotio",
            "accounts",
            "add",
            "--provider",
            "amp",
            "--label",
            "Work",
            "--token",
            "secret"
        ])
        .is_err()
    );
    let output = Command::new(env!("CARGO_BIN_EXE_quotio"))
        .args(["accounts", "add", "--help"])
        .output()
        .unwrap();
    assert!(output.status.success());
    assert!(output.stderr.is_empty());
}

#[test]
fn account_selector_requires_one_provider_and_allows_read_only_sources_without_vault() {
    assert!(
        Cli::try_parse_from([
            "quotio",
            "usage",
            "--provider",
            "codex",
            "--account",
            "local"
        ])
        .is_ok()
    );
    assert!(Cli::try_parse_from(["quotio", "usage", "--account", "id"]).is_err());
    assert!(
        Cli::try_parse_from([
            "quotio",
            "usage",
            "--provider",
            "codex",
            "--account",
            "id",
            "--no-saved-accounts",
            "--cli-proxy-auth-dir",
            "/absolute/proxy-auth"
        ])
        .is_ok()
    );
    let config = ConfigFile::new("enabled_providers = []");
    let output = Command::new(env!("CARGO_BIN_EXE_quotio"))
        .args([
            "usage",
            "--provider",
            "codex",
            "--provider",
            "amp",
            "--account",
            "id",
            "--config",
        ])
        .arg(&config.0)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
}

#[test]
fn authorize_help_is_available_without_accessing_keychain() {
    let result = std::process::Command::new(env!("CARGO_BIN_EXE_quotio"))
        .args(["accounts", "authorize", "--help"])
        .output()
        .unwrap();
    assert!(result.status.success());
    assert!(
        String::from_utf8(result.stdout)
            .unwrap()
            .contains("--provider")
    );
}

#[cfg(target_os = "macos")]
#[test]
fn api_key_prompt_hides_input_and_restores_terminal_on_error_or_ctrl_c() {
    use std::{
        io::{Read, Write},
        os::fd::{AsRawFd, FromRawFd},
        process::Stdio,
        time::{Duration, Instant},
    };
    struct Terminal {
        child: std::process::Child,
        master: std::fs::File,
        slave: std::fs::File,
    }
    impl Drop for Terminal {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
    fn attributes(file: &std::fs::File) -> libc::termios {
        let mut value = std::mem::MaybeUninit::uninit();
        assert_eq!(
            unsafe { libc::tcgetattr(file.as_raw_fd(), value.as_mut_ptr()) },
            0
        );
        unsafe { value.assume_init() }
    }
    for (provider, cancel) in [("amp", false), ("amp", true), ("factory", false)] {
        let mut fds = [-1; 2];
        assert_eq!(
            unsafe {
                libc::openpty(
                    &mut fds[0],
                    &mut fds[1],
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            },
            0
        );
        let master = unsafe { std::fs::File::from_raw_fd(fds[0]) };
        let slave = unsafe { std::fs::File::from_raw_fd(fds[1]) };
        for fd in fds {
            assert_eq!(
                unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) },
                0
            );
        }
        assert_eq!(
            unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) },
            0
        );
        let before = attributes(&slave);
        let flags = unsafe { libc::fcntl(slave.as_raw_fd(), libc::F_GETFL) };
        let child = Command::new(env!("CARGO_BIN_EXE_quotio"))
            .args(["accounts", "add", "--provider", provider])
            .stdin(Stdio::from(slave.try_clone().unwrap()))
            .stdout(Stdio::from(slave.try_clone().unwrap()))
            .stderr(Stdio::from(slave.try_clone().unwrap()))
            .spawn()
            .unwrap();
        let mut terminal = Terminal {
            child,
            master,
            slave,
        };
        let mut output = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let mut buffer = [0; 1024];
            match terminal.master.read(&mut buffer) {
                Ok(n) => output.extend_from_slice(&buffer[..n]),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => (),
                result => panic!("PTY read failed: {result:?}"),
            }
            if String::from_utf8_lossy(&output).contains("API key (hidden):") {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "prompt missing: {}",
                String::from_utf8_lossy(&output)
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        let during_flags = unsafe { libc::fcntl(terminal.slave.as_raw_fd(), libc::F_GETFL) };
        let during = attributes(&terminal.slave);
        assert_eq!(during.c_lflag & (libc::ECHO | libc::ECHONL), 0);
        assert_eq!(
            during.c_cc[libc::VQUIT],
            libc::_POSIX_VDISABLE as libc::cc_t
        );
        assert_eq!(
            during.c_cc[libc::VSUSP],
            libc::_POSIX_VDISABLE as libc::cc_t
        );
        if cancel {
            terminal.master.write_all(b"synthetic-hidden").unwrap();
            assert_eq!(
                unsafe { libc::kill(terminal.child.id() as i32, libc::SIGINT) },
                0
            );
        } else {
            // Internal tab makes this synthetic key invalid before network/Keychain.
            terminal
                .master
                .write_all(b"synthetic-hidden\tkey\n")
                .unwrap();
        }
        let exit = loop {
            if let Some(status) = terminal.child.try_wait().unwrap() {
                break status;
            }
            assert!(Instant::now() < deadline, "command did not finish");
            std::thread::sleep(Duration::from_millis(10));
        };
        loop {
            let mut buffer = [0; 1024];
            match terminal.master.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => output.extend_from_slice(&buffer[..n]),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                result => panic!("PTY read failed: {result:?}"),
            }
        }
        assert_eq!(exit.code(), Some(2));
        let after = attributes(&terminal.slave);
        assert_eq!(after.c_lflag, before.c_lflag);
        assert_eq!(after.c_cc, before.c_cc);
        assert_eq!(
            unsafe { libc::fcntl(terminal.slave.as_raw_fd(), libc::F_GETFL) },
            // Process startup can add unrelated flags before the prompt begins.
            (during_flags & !libc::O_NONBLOCK) | (flags & libc::O_NONBLOCK)
        );
        let text = String::from_utf8_lossy(&output);
        assert!(!text.contains("synthetic-hidden"));
        assert!(
            text.contains(if cancel {
                "cancelled"
            } else {
                "credential input"
            }),
            "{text}"
        );
    }
}

#[cfg(target_os = "macos")]
#[test]
fn api_key_pipe_requires_flag_and_preserves_validation() {
    use std::{io::Write, process::Stdio};
    for token_stdin in [false, true] {
        let mut command = Command::new(env!("CARGO_BIN_EXE_quotio"));
        command.args(["accounts", "add", "--provider", "amp"]);
        if token_stdin {
            command.arg("--token-stdin");
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let _ = child
            .stdin
            .take()
            .unwrap()
            .write_all(b"synthetic-hidden\tkey\n");
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        let message = String::from_utf8(output.stderr).unwrap();
        assert!(!message.contains("synthetic-hidden"));
        assert!(message.contains(if token_stdin {
            "credential input"
        } else {
            "--token-stdin"
        }));
    }
}

#[cfg(target_os = "macos")]
#[test]
fn new_key_providers_reach_key_validation_without_network() {
    use std::{io::Write, process::Stdio};
    for provider in ["synthetic", "openrouter", "zai", "minimax"] {
        let mut command = Command::new(env!("CARGO_BIN_EXE_quotio"));
        command.args(["accounts", "add", "--provider", provider, "--token-stdin"]);
        if matches!(provider, "zai" | "minimax") {
            command.args(["--region", "cn"]);
        }
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"invalid\tkey\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(2));
        assert!(
            String::from_utf8(output.stderr)
                .unwrap()
                .contains("credential input")
        );
        assert!(output.stdout.is_empty());
    }
}

#[test]
fn force_and_cache_ttl_contract() {
    for args in [
        vec!["quotio", "usage", "--force"],
        vec!["quotio", "usage", "--provider", "codex", "--force"],
    ] {
        let Some(CliCommand::Usage(args)) = Cli::try_parse_from(args).unwrap().command else {
            panic!()
        };
        assert!(args.force);
    }
    assert_eq!(Config::default().cache_ttl_seconds, 300);
    assert!(Config::default().disabled_providers.is_empty());
    assert_eq!(
        Config::parse("disabled_providers = ['amp', 'amp', 'factory-droid']")
            .unwrap()
            .disabled_providers()
            .unwrap(),
        vec![quotio::cli::Provider::Amp, quotio::cli::Provider::Factory]
    );
    assert_eq!(
        Config::parse("enabled_providers = []")
            .unwrap()
            .cache_ttl_seconds,
        300
    );
    assert_eq!(
        Config::parse("cache_ttl_seconds = 30")
            .unwrap()
            .cache_ttl_seconds,
        30
    );
    assert_eq!(
        Config::parse("cache_ttl_seconds = 0")
            .unwrap()
            .cache_ttl_seconds,
        0
    );
    for invalid in [
        "cache_ttl_seconds = -1",
        "cache_ttl_seconds = 'secret-sentinel'",
    ] {
        assert!(Config::parse(invalid).is_err());
    }
}

#[cfg(unix)]
#[test]
fn root_command_starts_interactive_cli() {
    use std::{
        io::Read,
        os::fd::{AsRawFd, FromRawFd},
        process::Stdio,
        time::{Duration, Instant},
    };

    let config = ConfigFile::new("");
    // CLI discovery also searches fixed install directories such as /opt/homebrew/bin,
    // so disable the CLI-detected providers in the isolated HOME's default config.
    // The vault refuses symlinked paths such as macOS's /var/folders temp directory.
    let home = config.0.with_extension("home");
    std::fs::create_dir_all(&home).unwrap();
    let home = std::fs::canonicalize(home).unwrap();
    for directory in ["Library/Application Support/quotio", ".config/quotio"] {
        std::fs::create_dir_all(home.join(directory)).unwrap();
        std::fs::write(
            home.join(directory).join("config.toml"),
            r#"disabled_providers = ["codex", "amp"]"#,
        )
        .unwrap();
    }
    let mut fds = [-1; 2];
    assert_eq!(
        unsafe {
            libc::openpty(
                &mut fds[0],
                &mut fds[1],
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        },
        0
    );
    let mut master = unsafe { std::fs::File::from_raw_fd(fds[0]) };
    let slave = unsafe { std::fs::File::from_raw_fd(fds[1]) };
    assert_eq!(
        unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) },
        0
    );
    let mut child = Command::new(env!("CARGO_BIN_EXE_quotio"))
        .env_clear()
        .env("HOME", &home)
        .env("QUOTIO_CACHE_DIR", config.0.with_extension("cache"))
        .stdin(Stdio::from(slave.try_clone().unwrap()))
        .stdout(Stdio::from(slave.try_clone().unwrap()))
        .stderr(Stdio::from(slave.try_clone().unwrap()))
        .spawn()
        .unwrap();
    let mut output = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        let mut buffer = [0; 4096];
        match master.read(&mut buffer) {
            Ok(count) => output.extend_from_slice(&buffer[..count]),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(error) if error.raw_os_error() == Some(libc::EIO) => {}
            result => panic!("PTY read failed: {result:?}"),
        }
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        assert!(
            Instant::now() < deadline,
            "interactive CLI did not finish: {}",
            String::from_utf8_lossy(&output)
        );
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(status.code(), Some(3));
    let output = String::from_utf8_lossy(&output);
    assert!(output.contains("Quotio"));
    assert!(output.contains("Checking providers"));
    assert!(output.contains("No providers detected"));
}
