use super::{AccountError, Credential, service, vault::Vault};
use crate::{
    cli::{AccountCommand, Format, Provider},
    providers::ProviderContext,
};
use clap::ValueEnum;

pub async fn run(
    command: AccountCommand,
    context: &ProviderContext,
) -> Result<String, AccountError> {
    if !cfg!(any(target_os = "macos", target_os = "linux")) {
        return Err(AccountError::Unsupported);
    }
    run_with_vault(command, context, Vault::system()?).await
}

/// Registers the provider's native login through the same inspection and Keychain
/// authorization the HTTP API uses. Several logins require an explicit location, because
/// inspection cannot tell which one the provider's own tool still refreshes.
async fn authorize_native(
    vault: Vault,
    provider: Provider,
    location: Option<String>,
) -> Result<String, AccountError> {
    use super::api::SourceInput;
    let mut registry = super::discovery::Registry::default();
    let candidates = registry.native_candidates(provider, location)?;
    let candidate = match candidates.as_slice() {
        [] => return Err(AccountError::NotFound),
        [candidate] => candidate,
        _ => {
            let choices = candidates.iter().map(|c| {
                let access = if c["status"] == "available" {
                    "readable"
                } else {
                    "needs Keychain access"
                };
                format!(
                    "{} ({access})",
                    c["source"]["location"].as_str().unwrap_or("default")
                )
            });
            return Err(AccountError::AmbiguousSource(
                choices.collect::<Vec<_>>().join(", "),
            ));
        }
    };
    let mut input: SourceInput =
        serde_json::from_value(candidate["source"].clone()).map_err(|_| AccountError::Input)?;
    if candidate["status"] == "permission_required" {
        input = super::authorization::authorize(input).await?;
    }
    let prepared = match input {
        SourceInput::Discovered { discovery_ref } => {
            registry.get(&discovery_ref)?.resolve().await?
        }
        input => super::api::prepare_source(input).await?,
    };
    let id = super::api::register_source(vault, prepared).await?;
    let provider = provider.id();
    Ok(format!(
        "Local {provider} login registered: {id}. Run quotio usage --provider {provider}.\n"
    ))
}

async fn run_with_vault(
    command: AccountCommand,
    context: &ProviderContext,
    vault: Vault,
) -> Result<String, AccountError> {
    match command {
        AccountCommand::Authorize { provider, location } => match provider {
            Provider::Antigravity if location.is_none() => {
                crate::providers::antigravity_auth::authorize().await?;
                Ok(
                    "Antigravity credentials are readable. Run quotio usage --provider antigravity.\n"
                        .into(),
                )
            }
            Provider::Catalog("claude" | "copilot") | Provider::Factory => {
                authorize_native(vault, provider, location).await
            }
            _ => Err(AccountError::Unsupported),
        },
        AccountCommand::List { format } => {
            let accounts = super::api::resolved_list(vault).await?;
            match format {
                Format::Json => serde_json::to_string_pretty(&accounts)
                    .map(|value| format!("{value}\n"))
                    .map_err(|_| AccountError::Corrupt),
                Format::Text => Ok(accounts
                    .accounts
                    .iter()
                    .map(|account| {
                        format!(
                            "{} {}  {}\n",
                            account.id, account.provider_id, account.display_name
                        )
                    })
                    .collect()),
            }
        }
        AccountCommand::Use { id } => {
            service::select_resolved(vault, id).await?;
            Ok("Active account updated.\n".into())
        }
        AccountCommand::Remove { id } => {
            service::remove_resolved(vault, id).await?;
            Ok("Account removed from Quotio.\n".into())
        }
        AccountCommand::Add {
            provider,
            label,
            token_stdin,
            no_browser,
            region,
            organization,
            host,
            settings,
        } => {
            if let Some(label) = &label {
                super::validate_label(label)?;
            }
            // Only Copilot device sign-in can target another GitHub host.
            let host = match host {
                Some(_) if provider != Provider::Catalog("copilot") || token_stdin => {
                    return Err(AccountError::Unsupported);
                }
                Some(raw) => Some(
                    super::github_host::GitHubHost::parse(&raw)
                        .map_err(|_| AccountError::Settings)?,
                )
                .filter(|host| !host.is_github_com()),
                None => None,
            };
            let region_valid = matches!(
                (provider, region.as_deref()),
                (_, None)
                    | (Provider::Factory, Some("global" | "eu"))
                    | (Provider::Zai | Provider::MiniMax, Some("global" | "cn"))
            );
            if !region_valid || (provider != Provider::Factory && organization.is_some()) {
                return Err(AccountError::Unsupported);
            }
            if matches!(provider, Provider::Catalog("claude" | "copilot")) && !token_stdin {
                if region.is_some() || organization.is_some() || !settings.is_empty() {
                    return Err(AccountError::Unsupported);
                }
                let manager = super::oauth::OAuthSessionManager::new(
                    context.clone(),
                    vault,
                    std::sync::Arc::new(tokio::sync::Mutex::new(())),
                    std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0)),
                );
                let session = manager
                    .begin_at(provider, label, super::oauth::OAuthMode::Relay, host)
                    .await?;
                eprintln!("Open this URL to sign in:\n{}", session.url);
                // These workflows display user actions without launching a browser.
                let session = if let Some(code) = &session.user_code {
                    eprintln!("Enter this code: {code}");
                    loop {
                        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                        let current = manager.get(&session.id).await?;
                        match current.status {
                            super::oauth::SessionStatus::Waiting
                            | super::oauth::SessionStatus::Processing => (),
                            super::oauth::SessionStatus::Completed => break current,
                            super::oauth::SessionStatus::Expired
                            | super::oauth::SessionStatus::Cancelled => {
                                return Err(AccountError::Cancelled);
                            }
                            super::oauth::SessionStatus::Failed => return Err(AccountError::OAuth),
                        }
                    }
                } else {
                    let code = tokio::time::timeout(
                        std::time::Duration::from_secs(180),
                        super::input::read_oauth_code(),
                    )
                    .await
                    .map_err(|_| AccountError::Cancelled)??;
                    manager.manual_code(&session.id, &code).await?
                };
                return Ok(format!(
                    "Account saved: {}\n",
                    session.account_id.ok_or(AccountError::OAuth)?
                ));
            }
            if let Some(definition) = provider.catalog()
                && definition.auth == crate::providers::catalog::AuthKind::OAuth
            {
                return Err(AccountError::NativeOAuth(definition.key_env));
            }
            let metadata = parse_settings(provider, &settings, context)?;
            let credential = match provider {
                Provider::Codex if !token_stdin => {
                    super::oauth::login(context, !no_browser).await?
                }
                provider if provider.api_key_name().is_some() && !no_browser => {
                    let name = provider.to_possible_value().expect("provider");
                    let name = match provider {
                        Provider::Amp => "Amp",
                        Provider::Factory => "Factory",
                        Provider::MiniMax => "MiniMax Token Plan",
                        _ => name.get_name(),
                    };
                    let token = super::input::read_api_key(name, token_stdin).await?;
                    let token = token.trim();
                    if token.is_empty()
                        || token.len() > 16384
                        || token.chars().any(char::is_control)
                    {
                        return Err(AccountError::Input);
                    }
                    if provider.catalog().is_some() {
                        Credential::CatalogKey {
                            token: token.into(),
                            settings: metadata,
                        }
                    } else {
                        Credential::ApiKey {
                            token: token.into(),
                            region,
                            organization,
                        }
                    }
                }
                _ => return Err(AccountError::Unsupported),
            };
            let usage = service::validate(context, provider, &credential).await?;
            let origin = if label.is_some() {
                super::LabelOrigin::User
            } else {
                super::LabelOrigin::Generated
            };
            let label = service::default_label(label.as_deref(), &credential)?;
            let id = service::add_persisted(
                vault,
                provider,
                label,
                credential,
                usage.account.id,
                Some(origin),
            )
            .await?
            .id;
            Ok(format!("Account validated and saved: {id}\n"))
        }
    }
}

fn parse_settings(
    provider: Provider,
    args: &[String],
    context: &ProviderContext,
) -> Result<std::collections::BTreeMap<String, String>, AccountError> {
    let mut values = std::collections::BTreeMap::new();
    for arg in args {
        let (name, value) = arg.split_once('=').ok_or(AccountError::Settings)?;
        if values.insert(name.to_owned(), value.to_owned()).is_some() {
            return Err(AccountError::Settings);
        }
    }
    service::provider_settings(provider, values, context)
}
#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn v2_cli_json_is_the_shared_resolved_account_contract() {
        let dir = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        let vault = super::Vault::new(
            std::sync::Arc::new(crate::accounts::vault::tests::Memory::default()),
            dir.join("lock"),
        );
        let mut tx = vault.begin().unwrap();
        tx.document
            .add(
                crate::cli::Provider::Amp,
                "Fixture name",
                "fixture".into(),
                crate::accounts::Credential::ApiKey {
                    token: "not-in-the-response".into(),
                    region: None,
                    organization: None,
                },
            )
            .unwrap();
        tx.commit().unwrap();
        let context = crate::providers::http::fixture::context();
        let output = super::run_with_vault(
            crate::cli::AccountCommand::List {
                format: crate::cli::Format::Json,
            },
            &context,
            vault.clone(),
        )
        .await
        .unwrap();
        let expected = crate::accounts::api::resolved_list(vault.clone())
            .await
            .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&output).unwrap(),
            serde_json::to_value(expected).unwrap()
        );
        assert!(!output.contains("not-in-the-response"));
        assert!(
            clap::Parser::try_parse_from(["quotio", "accounts", "list", "--schema-version", "2"])
                .map(|_: crate::cli::Cli| ())
                .is_err()
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    use super::*;
    fn key(token: &str) -> Credential {
        Credential::ApiKey {
            token: token.into(),
            region: None,
            organization: None,
        }
    }
    #[test]
    fn defaults_to_email_or_masked_key_and_respects_override() {
        let oauth = Credential::CodexOAuth {
            access_token: "secret-access".into(),
            refresh_token: "secret-refresh".into(),
            id_token: "secret-id".into(),
            account_id: "account".into(),
            email: "demo@example.com".into(),
            expires_at: 0,
        };
        assert_eq!(
            service::default_label(None, &oauth).unwrap(),
            "demo@example.com"
        );
        assert_eq!(
            service::default_label(None, &key("synthetic-key-ABCD")).unwrap(),
            "API key ****ABCD"
        );
        assert_eq!(
            service::default_label(Some(" Work "), &oauth).unwrap(),
            "Work"
        );
        assert_eq!(
            service::default_label(Some(" Work "), &key("synthetic-key-ABCD")).unwrap(),
            "Work"
        );
        assert!(service::default_label(Some(" "), &oauth).is_err());
    }
    #[tokio::test]
    async fn host_is_copilot_device_only_and_validated_before_sign_in() {
        let dir = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        let vault = super::Vault::new(
            std::sync::Arc::new(crate::accounts::vault::tests::Memory::default()),
            dir.join("lock"),
        );
        let context = crate::providers::http::fixture::context();
        for (provider, host, token_stdin, expected) in [
            (
                Provider::Catalog("claude"),
                "github.com",
                false,
                "unsupported",
            ),
            (Provider::Amp, "octocorp.ghe.com", false, "unsupported"),
            (
                Provider::Catalog("copilot"),
                "octocorp.ghe.com",
                true,
                "unsupported",
            ),
            (
                Provider::Catalog("copilot"),
                "https://octocorp.ghe.com",
                false,
                "settings",
            ),
            (
                Provider::Catalog("copilot"),
                "github.example.com",
                false,
                "settings",
            ),
        ] {
            let error = super::run_with_vault(
                crate::cli::AccountCommand::Add {
                    provider,
                    label: None,
                    token_stdin,
                    no_browser: true,
                    region: None,
                    organization: None,
                    host: Some(host.into()),
                    settings: Vec::new(),
                },
                &context,
                vault.clone(),
            )
            .await
            .unwrap_err();
            match expected {
                "unsupported" => assert!(matches!(error, AccountError::Unsupported)),
                _ => assert!(matches!(error, AccountError::Settings)),
            }
        }
        assert!(
            clap::Parser::try_parse_from([
                "quotio",
                "accounts",
                "add",
                "--provider",
                "copilot",
                "--host",
                "octocorp.ghe.com",
            ])
            .map(|_: crate::cli::Cli| ())
            .is_ok()
        );
        let _ = std::fs::remove_dir_all(dir);
    }
    #[test]
    fn short_and_non_ascii_keys_are_fully_masked() {
        for token in ["abcd", "12345678", "ééééééééé", "secret\nvalue"] {
            assert_eq!(
                service::default_label(None, &key(token)).unwrap(),
                "API key ****"
            );
        }
    }
}

#[cfg(test)]
mod catalog_setting_tests {
    use super::*;
    #[test]
    fn settings_are_allowlisted_and_required_before_key_input() {
        let context = crate::providers::http::fixture::context();
        for definition in crate::providers::catalog::definitions() {
            let provider = Provider::Catalog(definition.id);
            assert!(matches!(
                parse_settings(provider, &["unknown=never-echo-this".into()], &context),
                Err(AccountError::Settings)
            ));
            let args: Vec<_> = definition
                .settings
                .iter()
                .map(|s| format!("{}=example-value", s.name))
                .collect();
            let parsed = parse_settings(provider, &args, &context).unwrap();
            assert_eq!(parsed.len(), definition.settings.len());
            if definition.settings.iter().any(|s| s.required) {
                assert!(matches!(
                    parse_settings(provider, &[], &context),
                    Err(AccountError::Settings)
                ));
            }
            if let Some(setting) = definition.settings.first() {
                assert!(
                    parse_settings(
                        provider,
                        &[
                            format!("{}=first", setting.name),
                            format!("{}=second", setting.name)
                        ],
                        &context
                    )
                    .is_err()
                );
            }
        }
    }
}
