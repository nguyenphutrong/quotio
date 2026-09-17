//! Provider metadata safe to expose through the local API.
use crate::cli::Provider;
use serde::Serialize;

#[derive(Clone, Copy, Serialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum AuthMethod {
    ApiKey,
    #[serde(rename = "oauth")]
    OAuth,
    Native,
    OwnedToken,
}
#[derive(Clone, Serialize, PartialEq, Eq)]
pub struct SettingMetadata {
    pub name: &'static str,
    pub field_path: String,
    pub required: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub values: Option<&'static [&'static str]>,
}
#[derive(Clone, Copy, Serialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Usage,
    AddAccount,
    RenameAccount,
    SelectAccount,
    SetAccountEnabled,
    UpdateApiKey,
    RemoveAccount,
    #[serde(rename = "start_oauth")]
    StartOAuth,
}
#[derive(Clone, Serialize, PartialEq, Eq)]
pub struct SourceCapability {
    pub kind: &'static str,
    pub platforms: Vec<&'static str>,
    pub origin: &'static str,
    pub credential_refresh: bool,
}
#[derive(Clone, Serialize, PartialEq, Eq)]
pub struct ProviderCapability {
    pub provider: Provider,
    pub auth: Vec<AuthMethod>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub oauth_workflow: Option<crate::accounts::oauth::Workflow>,
    pub settings: Vec<SettingMetadata>,
    /// Usage collection works on every supported platform.
    pub usage_platform: &'static str,
    /// Legacy field retained for clients predating Linux account storage.
    pub account_storage_platform: Option<&'static str>,
    pub account_storage_platforms: Vec<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub native_instructions: Option<&'static str>,
    pub operations: Vec<Operation>,
    pub source_references: Vec<SourceCapability>,
    /// Explicit opt-in metadata inspection, never an automatic credential scan.
    pub source_discovery_endpoint: &'static str,
}
const FACTORY_REGIONS: &[&str] = &["global", "eu"];
const ASIA_REGIONS: &[&str] = &["global", "cn"];
pub fn capability(provider: Provider) -> ProviderCapability {
    let mut settings: Vec<SettingMetadata> = provider
        .catalog()
        .map(|definition| {
            definition
                .settings
                .iter()
                .map(|setting| SettingMetadata {
                    name: setting.name,
                    field_path: format!("settings.{}", setting.name),
                    required: setting.required,
                    values: None,
                })
                .collect()
        })
        .unwrap_or_default();
    match provider {
        Provider::Factory => {
            settings.push(SettingMetadata {
                name: "region",
                field_path: "region".into(),
                required: false,
                values: Some(FACTORY_REGIONS),
            });
            settings.push(SettingMetadata {
                name: "organization",
                field_path: "organization".into(),
                required: false,
                values: None,
            });
        }
        Provider::Zai | Provider::MiniMax => settings.push(SettingMetadata {
            name: "region",
            field_path: "region".into(),
            required: false,
            values: Some(ASIA_REGIONS),
        }),
        _ => (),
    }
    let native = match provider {
        Provider::Codex => Some(
            "Use the existing Codex CLI login, or add a separate Quotio-managed OAuth account.",
        ),
        Provider::Amp => Some("Use the existing Amp CLI login, or add a Quotio-managed API key."),
        Provider::Factory => Some(
            "Register an explicit Factory credential file as read-only, or supply separately owned tokens for the default WorkOS client. Native refresh stays with Factory.",
        ),
        Provider::Antigravity => Some(
            "Register the fixed Antigravity Keychain entry or state database as read-only, or supply separately owned tokens and client credentials. Refresh borrowed tokens in Antigravity.",
        ),
        Provider::Catalog(id)
            if provider.catalog().is_some_and(|definition| {
                definition.auth == crate::providers::catalog::AuthKind::OAuth
            }) =>
        {
            match id {
                "claude" => {
                    Some("Sign in with Claude Code or set its supported local access token.")
                }
                "gemini" => {
                    Some("Sign in with Gemini CLI or set its supported local access token.")
                }
                "copilot" => {
                    Some("Sign in with GitHub Copilot CLI or set its supported local access token.")
                }
                "cursor" => Some("Sign in with Cursor to make its local login available."),
                "grok" => Some("Sign in with the supported Grok editor integration."),
                "kiro" => Some(
                    "Register the fixed Kiro native file as read-only, or supply separately owned Social or IdC tokens. Native refresh stays with Kiro.",
                ),
                _ => Some("Sign in with the provider's supported local CLI or application."),
            }
        }
        _ => None,
    };
    let auth = match provider {
        Provider::Codex | Provider::Catalog("claude" | "copilot") => {
            vec![AuthMethod::OAuth, AuthMethod::Native]
        }
        Provider::Amp => vec![AuthMethod::ApiKey, AuthMethod::Native],
        Provider::Factory => vec![
            AuthMethod::ApiKey,
            AuthMethod::OwnedToken,
            AuthMethod::Native,
        ],
        Provider::Catalog("grok" | "kiro") => vec![AuthMethod::Native, AuthMethod::OwnedToken],
        Provider::Antigravity => vec![AuthMethod::Native, AuthMethod::OwnedToken],
        Provider::Catalog(_) if native.is_some() => vec![AuthMethod::Native],
        _ if provider.api_key_name().is_some() => vec![AuthMethod::ApiKey],
        _ => Vec::new(),
    };
    let mut operations = vec![Operation::Usage];
    if provider.supports_accounts() {
        operations.extend([
            Operation::AddAccount,
            Operation::RenameAccount,
            Operation::SelectAccount,
            Operation::SetAccountEnabled,
            Operation::RemoveAccount,
        ]);
        if provider.api_key_name().is_some() {
            operations.push(Operation::UpdateApiKey);
        }
    }
    let oauth_workflow = match provider {
        Provider::Codex => Some(crate::accounts::oauth::Workflow::BrowserCallback),
        Provider::Catalog("claude") => Some(crate::accounts::oauth::Workflow::ManualCode),
        Provider::Catalog("copilot") => Some(crate::accounts::oauth::Workflow::DeviceCode),
        _ => None,
    };
    if oauth_workflow.is_some() {
        operations.push(Operation::StartOAuth);
    }
    let mut source_references =
        if matches!(provider, Provider::Catalog("clinepass") | Provider::Zai) {
            vec![SourceCapability {
                kind: "quotio_custom_provider",
                platforms: vec!["macos"],
                origin: "borrowed_proxy",
                credential_refresh: false,
            }]
        } else if provider == Provider::Catalog("devin-desktop") {
            vec![SourceCapability {
                kind: "devin_desktop_native",
                platforms: vec!["macos", "linux"],
                origin: "borrowed_native",
                credential_refresh: false,
            }]
        } else if provider == Provider::Antigravity {
            vec![SourceCapability {
                kind: "antigravity_native",
                platforms: vec!["macos"],
                origin: "borrowed_native",
                credential_refresh: false,
            }]
        } else if provider == Provider::Catalog("kiro") {
            vec![SourceCapability {
                kind: "kiro_native",
                platforms: vec!["macos", "linux"],
                origin: "borrowed_native",
                credential_refresh: false,
            }]
        } else if provider == Provider::Factory {
            vec![SourceCapability {
                kind: "factory_native",
                platforms: vec!["macos", "linux"],
                origin: "borrowed_native",
                credential_refresh: false,
            }]
        } else if provider == Provider::Catalog("copilot") {
            vec![SourceCapability {
                kind: "copilot_native",
                platforms: vec!["macos", "linux"],
                origin: "borrowed_native",
                credential_refresh: false,
            }]
        } else if provider == Provider::Catalog("claude") {
            vec![SourceCapability {
                kind: "claude_native",
                platforms: vec!["macos", "linux"],
                origin: "borrowed_native",
                credential_refresh: false,
            }]
        } else if provider == Provider::Catalog("grok") {
            vec![SourceCapability {
                kind: "grok_native",
                platforms: vec!["macos", "linux"],
                origin: "borrowed_native",
                credential_refresh: false,
            }]
        } else if provider == Provider::Catalog("cursor") {
            vec![SourceCapability {
                kind: "cursor_native",
                platforms: vec!["macos"],
                origin: "borrowed_native",
                credential_refresh: false,
            }]
        } else if provider == Provider::Codex {
            vec![SourceCapability {
                kind: "codex_native",
                platforms: vec!["macos", "linux"],
                origin: "borrowed_native",
                credential_refresh: false,
            }]
        } else if provider == Provider::Amp {
            vec![SourceCapability {
                kind: "amp_native",
                platforms: vec!["macos", "linux"],
                origin: "borrowed_native",
                credential_refresh: false,
            }]
        } else {
            vec![]
        };
    if matches!(
        provider,
        Provider::Codex
            | Provider::Antigravity
            | Provider::Catalog("claude" | "copilot" | "kiro" | "vertexai")
    ) {
        source_references.push(SourceCapability {
            kind: "cli_proxy_auth_file",
            platforms: vec!["macos", "linux"],
            origin: "borrowed_proxy",
            credential_refresh: false,
        });
    }
    ProviderCapability {
        provider,
        oauth_workflow,
        auth,
        settings,
        usage_platform: "all",
        account_storage_platform: provider.supports_accounts().then_some("macos"),
        account_storage_platforms: if provider.supports_accounts() {
            vec!["macos", "linux"]
        } else {
            vec![]
        },
        source_discovery_endpoint: "/v1/account-sources/discover",
        source_references,
        native_instructions: native,
        operations,
    }
}
pub fn all() -> Vec<ProviderCapability> {
    clap::ValueEnum::value_variants()
        .iter()
        .copied()
        .map(capability)
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn registry_metadata_and_core_settings_are_exposed_without_environment_names() {
        let factory = capability(Provider::Factory);
        assert_eq!(factory.account_storage_platforms, vec!["macos", "linux"]);
        assert_eq!(
            factory.auth,
            vec![
                AuthMethod::ApiKey,
                AuthMethod::OwnedToken,
                AuthMethod::Native
            ]
        );
        assert!(
            factory
                .settings
                .iter()
                .any(|setting| setting.name == "organization")
        );
        assert_eq!(
            capability(Provider::Codex).auth,
            vec![AuthMethod::OAuth, AuthMethod::Native]
        );
        for definition in crate::providers::catalog::definitions() {
            let capability = capability(Provider::Catalog(definition.id));
            assert_eq!(capability.settings.len(), definition.settings.len());
            for setting in capability.settings {
                assert_eq!(setting.field_path, format!("settings.{}", setting.name));
            }
        }
    }
}
