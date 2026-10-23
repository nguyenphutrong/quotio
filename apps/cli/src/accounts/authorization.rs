use super::{
    AccountError,
    api::SourceInput,
    sources::{AntigravityLocation, ClaudeLocation, CopilotLocation, FactoryLocation},
};

pub(crate) fn target(input: &SourceInput) -> Result<(String, Option<&str>), AccountError> {
    match input {
        SourceInput::CopilotNative {
            location: Some(CopilotLocation::GhKeychain),
            entry_key,
            config_dir: None,
            ..
        } if entry_key.is_empty() || entry_key == "github.com" => {
            Ok(("gh:github.com".into(), None))
        }
        SourceInput::CopilotNative {
            location: Some(CopilotLocation::GhKeychain),
            entry_key,
            config_dir: None,
            ..
        } if crate::providers::catalog::oauth_primary::valid_copilot_keychain_account(
            entry_key,
        ) =>
        {
            Ok(("gh:github.com".into(), Some(entry_key)))
        }
        SourceInput::ClaudeNative {
            location: Some(ClaudeLocation::CodeKeychain),
            config_dir,
            ..
        }
        | SourceInput::ClaudeNative {
            location: None,
            config_dir: config_dir @ Some(_),
            ..
        } => Ok((
            super::sources::claude_keychain_service(config_dir.as_ref().map(|dir| dir.as_str())),
            None,
        )),
        SourceInput::AntigravityNative {
            location: AntigravityLocation::GeminiKeychain,
        } => Ok(("gemini".into(), Some("antigravity"))),
        SourceInput::FactoryNative {
            location:
                FactoryLocation::V2LoginKeychain | FactoryLocation::V2Keyring | FactoryLocation::Legacy,
            entry_key: Some(account),
        } if crate::providers::factory::valid_keychain_account(account) => {
            Ok(("Factory CLI".into(), Some(account)))
        }
        _ => Err(AccountError::Input),
    }
}

pub(crate) fn validate(input: &SourceInput) -> Result<(), AccountError> {
    input.check()?;
    if matches!(
        input,
        SourceInput::FactoryNative {
            location: FactoryLocation::V2LoginKeychain
                | FactoryLocation::V2Keyring
                | FactoryLocation::Legacy,
            entry_key: None,
        } | SourceInput::CopilotNative {
            config_dir: Some(_),
            ..
        }
    ) {
        return Ok(());
    }
    target(input).map(|_| ())
}

pub(crate) async fn authorize(mut input: SourceInput) -> Result<SourceInput, AccountError> {
    if matches!(
        input,
        SourceInput::AntigravityNative {
            location: AntigravityLocation::GeminiKeychain,
        }
    ) {
        crate::providers::antigravity_auth::authorize().await?;
        return Ok(input);
    }
    if let SourceInput::CopilotNative {
        config_dir: Some(dir),
        ..
    } = &input
    {
        // gh keeps the token in the fixed service under the user named in this hosts.yml.
        let account = crate::providers::catalog::oauth_primary::copilot_gh_hosts_account(
            dir.join("hosts.yml"),
        )
        .await?;
        crate::providers::catalog::common::authorize_security_tool_keychain(
            "gh:github.com",
            Some(&account),
        )
        .await?;
        return Ok(input);
    }
    if let SourceInput::CopilotNative {
        location: Some(CopilotLocation::GhKeychain),
        entry_key,
        ..
    } = &mut input
        && (entry_key.is_empty() || entry_key == "github.com")
    {
        *entry_key = crate::providers::catalog::oauth_primary::copilot_keychain_account().await?;
    }
    if let SourceInput::FactoryNative {
        location,
        entry_key,
    } = &mut input
    {
        let mut source =
            super::sources::FactoryNativeReference::system(*location, entry_key.clone())?;
        source.freeze_keychain_account().await?;
        *entry_key = source.entry_key;
    }
    let (service, account) = target(&input)?;
    use crate::providers::catalog::common;
    if common::saved_by_security_tool(&service, account) {
        common::authorize_security_tool_keychain(&service, account).await?;
        return Ok(input);
    }
    let account = account.map(str::to_owned);
    tokio::task::spawn_blocking(move || {
        use crate::providers::catalog::common;
        common::authorize_keychain(&service, account.as_deref())
    })
    .await
    .map_err(|_| AccountError::Storage)??;
    Ok(input)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn factory_authorization_targets_the_same_frozen_account_as_loading() {
        for account in ["auth-encryption-key", "auth-encryption-key-security-cli"] {
            let input = SourceInput::FactoryNative {
                location: FactoryLocation::V2Keyring,
                entry_key: Some(account.into()),
            };
            assert_eq!(
                target(&input).unwrap(),
                ("Factory CLI".to_owned(), Some(account))
            );
        }
        for entry_key in [None, Some("unrelated-account".into())] {
            assert!(
                target(&SourceInput::FactoryNative {
                    location: FactoryLocation::V2Keyring,
                    entry_key
                })
                .is_err()
            );
        }
        assert!(
            validate(&SourceInput::FactoryNative {
                location: FactoryLocation::V2Keyring,
                entry_key: None
            })
            .is_ok()
        );
    }

    #[test]
    fn authorization_only_accepts_supported_keychain_sources() {
        for (kind, location) in [
            ("claude_native", "code_keychain"),
            ("copilot_native", "gh_keychain"),
            ("factory_native", "v2_keyring"),
            ("antigravity_native", "gemini_keychain"),
        ] {
            let mut value = serde_json::json!({"kind":kind,"location":location});
            if kind == "copilot_native" {
                value["entry_key"] = "fixture".into();
            } else if kind == "factory_native" {
                value["entry_key"] = "auth-encryption-key".into();
            }
            let source: SourceInput = serde_json::from_value(value).unwrap();
            assert!(target(&source).is_ok());
        }
        for source in [
            SourceInput::ClaudeNative {
                location: Some(ClaudeLocation::CodeFile),
                config_dir: None,
                label: None,
            },
            SourceInput::FactoryNative {
                location: FactoryLocation::V2File,
                entry_key: None,
            },
            SourceInput::AmpNative {},
        ] {
            assert!(target(&source).is_err());
        }
        assert!(serde_json::from_value::<SourceInput>(serde_json::json!({"kind":"claude_native","location":"code_keychain","service":"arbitrary"})).is_err());
    }
}
