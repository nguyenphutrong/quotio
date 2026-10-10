use clap::{Parser, ValueEnum};
use quotio::{
    cli::{Cli, Command, Format, Provider},
    config::Config,
    output,
    providers::{EnvironmentCredentials, ProviderContext, SystemClock},
};
use std::{
    io::{self, Write},
    process::ExitCode,
    sync::Arc,
    time::Duration,
};
use tracing_subscriber::{filter::Targets, layer::SubscriberExt, util::SubscriberInitExt};

fn account_timeout(command: &quotio::cli::AccountCommand) -> Option<Duration> {
    if matches!(
        command,
        quotio::cli::AccountCommand::Add {
            provider: Provider::Catalog("claude"),
            token_stdin: false,
            ..
        }
    ) {
        // Manual OAuth bounds input and exchange separately. Once claimed, a
        // durable credential commit must not be dropped at the input deadline.
        None
    } else if matches!(
        command,
        quotio::cli::AccountCommand::Add {
            provider: Provider::Catalog("copilot"),
            ..
        }
    ) {
        // Device expiry is at most one hour, plus startup and persistence time.
        Some(Duration::from_secs(3720))
    } else {
        Some(Duration::from_secs(180))
    }
}

async fn within_account_deadline<T>(
    timeout: Option<Duration>,
    operation: impl std::future::Future<Output = Result<T, quotio::accounts::AccountError>>,
) -> Result<T, quotio::accounts::AccountError> {
    match timeout {
        Some(timeout) => tokio::time::timeout(timeout, operation)
            .await
            .unwrap_or(Err(quotio::accounts::AccountError::Cancelled)),
        None => operation.await,
    }
}

fn main() -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(_) => {
            eprintln!("Could not initialize runtime.");
            return ExitCode::from(3);
        }
    };
    let result = runtime.block_on(run());
    // Native Keychain calls cannot be cancelled by dropping a Rust future.
    // Do not wait for a blocked native call after the command deadline has expired.
    runtime.shutdown_background();
    result
}
async fn run() -> ExitCode {
    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(error)
            if matches!(
                error.kind(),
                clap::error::ErrorKind::DisplayHelp | clap::error::ErrorKind::DisplayVersion
            ) =>
        {
            return if error.print().is_ok() {
                ExitCode::SUCCESS
            } else {
                ExitCode::from(3)
            };
        }
        Err(_) => {
            // Clap's default diagnostics echo input, which may accidentally be a secret.
            eprintln!("Invalid arguments. Run quotio --help or quotio <command> --help.");
            return ExitCode::from(2);
        }
    };
    let Some(command) = cli.command else {
        return match quotio::interactive::run().await {
            Ok(code) => ExitCode::from(code),
            Err((error, code)) => {
                eprintln!("{error}");
                ExitCode::from(code)
            }
        };
    };
    let (text, code) = match command {
        Command::MigrationInspect {
            piv_envelope,
            piv_fingerprint,
            stage_dir,
            metadata,
            account_id,
            provider,
            source,
            credential_reference,
            service,
        } => {
            let result = (|| {
                if let Some(metadata) = metadata {
                    #[cfg(unix)]
                    {
                        use quotio::accounts::staging::{
                            Mapping, StagingError, assess_mapping, stage_mapping,
                        };
                        let mapping = Mapping {
                            account_id: account_id.as_deref().ok_or(StagingError::Mapping)?,
                            provider: provider.as_deref().ok_or(StagingError::Mapping)?,
                            source: source.as_deref().ok_or(StagingError::Mapping)?,
                            credential_reference: Some(
                                credential_reference
                                    .as_deref()
                                    .ok_or(StagingError::Mapping)?,
                            ),
                            service: service.as_deref().ok_or(StagingError::Mapping)?,
                        };
                        let assessment =
                            assess_mapping(&metadata, &piv_envelope, &piv_fingerprint, &mapping)?;
                        let receipt_id = stage_dir
                            .as_deref()
                            .map(|dir| stage_mapping(&assessment, dir))
                            .transpose()?;
                        return Ok(serde_json::json!({
                            "plan": assessment.plan(),
                            "receipt_id": receipt_id,
                            "credentials_staged": false,
                            "encrypted_artifacts_staged": stage_dir.is_some(),
                            "accounts_imported": 0
                        }));
                    }
                    #[cfg(not(unix))]
                    {
                        let _ = (
                            metadata,
                            account_id,
                            provider,
                            source,
                            credential_reference,
                            service,
                        );
                        return Err(quotio::accounts::staging::StagingError::Unsupported);
                    }
                }
                let plan = quotio::accounts::staging::assess(&piv_envelope, &piv_fingerprint)?;
                let receipt_id = stage_dir
                    .as_deref()
                    .map(|dir| quotio::accounts::staging::stage(&plan, dir))
                    .transpose()?;
                Ok::<_, quotio::accounts::staging::StagingError>(serde_json::json!({
                    "plan": plan,
                    "receipt_id": receipt_id,
                    "credentials_staged": false,
                    "accounts_imported": 0
                }))
            })();
            match result {
                // Assessment completed, but migration is always blocked in this release.
                Ok(report) => (format!("{report}\n"), 2),
                Err(error) => {
                    eprintln!("{error}");
                    return ExitCode::from(2);
                }
            }
        }
        Command::Serve(args) => {
            tracing_subscriber::registry()
                .with(
                    tracing_subscriber::fmt::layer()
                        .with_ansi(false)
                        .with_writer(io::stderr),
                )
                .with(Targets::new().with_target("quotio", tracing::Level::INFO))
                .init();
            return match quotio::server::run(args).await {
                Ok(()) => ExitCode::SUCCESS,
                Err(error) => {
                    eprintln!("{error}");
                    ExitCode::from(error.exit_code())
                }
            };
        }
        Command::Providers {
            format: Format::Json,
            config,
        } => match Config::load(config.as_deref()).and_then(|config| config.providers()) {
            Ok(enabled) => match serde_json::to_string_pretty(
                &quotio::providers::capabilities::ProviderList::new(&enabled),
            ) {
                Ok(value) => (format!("{value}\n"), 0),
                Err(_) => return ExitCode::from(3),
            },
            Err(error) => {
                eprintln!("{error}");
                return ExitCode::from(2);
            }
        },
        Command::Providers {
            format: Format::Text,
            ..
        } => (
            Provider::value_variants()
                .iter()
                .map(|provider| {
                    let mut line = format!("{}  {}\n", provider.id(), provider.description());
                    if let Some(definition) = provider.catalog() {
                        line.push_str(&format!("  Credential: {}\n", definition.key_env));
                        for setting in definition.settings {
                            line.push_str(&format!(
                                "  --setting {}=VALUE  [{}; env {}]\n",
                                setting.name,
                                if setting.required {
                                    "required"
                                } else {
                                    "optional"
                                },
                                setting.env
                            ));
                        }
                    }
                    line
                })
                .collect(),
            0,
        ),
        Command::Sharing(args) => match quotio::devices::run_sharing(args).await {
            Ok(value) => (value.to_string(), 0),
            Err(code) => {
                eprintln!("Sharing request failed: {code}");
                return ExitCode::from(3);
            }
        },
        Command::Devices(args) => match quotio::devices::run(args).await {
            Ok(value) => (value.to_string(), 0),
            Err(code) => {
                eprintln!("Device request failed: {code}");
                return ExitCode::from(3);
            }
        },
        Command::Accounts(args) => {
            let http = match reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .build()
            {
                Ok(h) => h,
                Err(_) => {
                    eprintln!("Could not initialize HTTP client.");
                    return ExitCode::from(3);
                }
            };
            let context = ProviderContext {
                http,
                clock: Arc::new(SystemClock),
                credentials: Arc::new(EnvironmentCredentials),
            };
            let timeout = account_timeout(&args.command);
            let result = tokio::select! {
                // Register Ctrl-C before an account command can disable terminal echo.
                biased;
                _=tokio::signal::ctrl_c()=>Err(quotio::accounts::AccountError::Cancelled),
                result=within_account_deadline(timeout,quotio::accounts::command::run(args.command,&context))=>result,
            };
            match result {
                Ok(text) => (text, 0),
                Err(error) => {
                    eprintln!("{error}");
                    return ExitCode::from(2);
                }
            }
        }
        Command::Usage(args) => {
            let level = if args.verbose {
                tracing::Level::DEBUG
            } else {
                tracing::Level::WARN
            };
            tracing_subscriber::registry()
                .with(
                    tracing_subscriber::fmt::layer()
                        .with_ansi(false)
                        .with_writer(io::stderr),
                )
                .with(Targets::new().with_target("quotio", level))
                .init();
            let collected = match quotio::usage::collect(quotio::usage::Request {
                force: args.force,
                providers: args.provider,
                timeout: args.timeout,
                config: args.config,
                cli_proxy_auth_dir: args.cli_proxy_auth_dir,
                cli_proxy_config: args.cli_proxy_config,
                no_saved_accounts: args.no_saved_accounts,
                account: args.account,
            })
            .await
            {
                Ok(collected) => collected,
                Err(error) => {
                    eprintln!("{}", error.message);
                    return ExitCode::from(error.exit_code);
                }
            };
            if !collected.diagnostics.is_empty() {
                eprint!("{}", collected.diagnostics);
            }
            let text = match args.format {
                Format::Text => {
                    let options = output::text::Options::terminal(args.no_color, args.verbose);
                    let text = output::text::render_snapshot(&collected.snapshot, options);
                    // The SDK probes any tty, which costs other terminals a DA1 round trip
                    // and shows its query to terminals that don't parse APC.
                    if std::env::var_os("TERM_PROGRAM").is_some_and(|name| name == "tern") {
                        let view = output::tern::render_snapshot(&collected.snapshot, options);
                        let print = tern_sdk::PrintOptions::new().fallback(text);
                        if tern_sdk::print(view, print).is_err() {
                            eprintln!("Could not write output.");
                            return ExitCode::from(3);
                        }
                        return ExitCode::from(collected.exit_code);
                    }
                    text
                }
                Format::Json => match output::json::render(&collected.snapshot) {
                    Ok(json) => format!("{json}\n"),
                    Err(_) => {
                        eprintln!("Could not encode usage report.");
                        return ExitCode::from(3);
                    }
                },
            };
            (text, collected.exit_code)
        }
    };
    if io::stdout().lock().write_all(text.as_bytes()).is_err() {
        eprintln!("Could not write output.");
        return ExitCode::from(3);
    }
    ExitCode::from(code)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn copilot_terminal_deadline_does_not_truncate_device_expiry() {
        for (provider, expected) in [
            ("copilot", Some(3720)),
            ("codex", Some(180)),
            ("claude", None),
        ] {
            let cli =
                Cli::try_parse_from(["quotio", "accounts", "add", "--provider", provider]).unwrap();
            let Some(Command::Accounts(args)) = cli.command else {
                panic!("account command");
            };
            assert_eq!(
                account_timeout(&args.command),
                expected.map(Duration::from_secs)
            );
        }
    }

    #[tokio::test(start_paused = true)]
    async fn late_claude_input_keeps_exchange_and_commit_alive() {
        let cli =
            Cli::try_parse_from(["quotio", "accounts", "add", "--provider", "claude"]).unwrap();
        let Some(Command::Accounts(args)) = cli.command else {
            panic!("account command")
        };
        let start = tokio::time::Instant::now();
        let result = within_account_deadline(account_timeout(&args.command), async {
            tokio::time::timeout(Duration::from_secs(180), async {
                tokio::time::sleep(Duration::from_secs(179)).await;
            })
            .await
            .unwrap();
            tokio::time::timeout(Duration::from_secs(30), async {
                tokio::time::sleep(Duration::from_secs(20)).await;
            })
            .await
            .unwrap();
            tokio::time::sleep(Duration::from_secs(5)).await;
            Ok("persisted")
        })
        .await;
        assert_eq!(result.unwrap(), "persisted");
        assert_eq!(start.elapsed(), Duration::from_secs(204));
    }
}
