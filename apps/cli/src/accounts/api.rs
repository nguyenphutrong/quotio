//! API-neutral account operations. These types deliberately exclude credentials.
use super::{AccountError, Credential, service, vault::Vault};
use crate::{cli::Provider, providers::ProviderContext};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Serialize, PartialEq, Eq)]
pub struct AccountDto {
    pub id: String,
    pub provider: Provider,
    pub label: String,
    pub active: bool,
    pub origin: super::AccountOrigin,
    pub enabled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_kind: Option<&'static str>,
}
impl From<&super::Account> for AccountDto {
    fn from(account: &super::Account) -> Self {
        Self {
            id: account.id.clone(),
            provider: account.provider,
            label: account.label.clone(),
            active: account.active,
            origin: account.origin(),
            enabled: account.enabled(),
            source_kind: match account.credential {
                Credential::GrokNative { .. } => Some("grok_native"),
                Credential::DevinDesktopNative { .. } => Some("devin_desktop_native"),
                Credential::FactoryNative { .. } => Some("factory_native"),
                Credential::KiroNative { .. } => Some("kiro_native"),
                Credential::AntigravityNative { .. } => Some("antigravity_native"),
                Credential::CursorNative { .. } => Some("cursor_native"),
                Credential::AmpNative { .. } => Some("amp_native"),
                Credential::CodexNative { .. } => Some("codex_native"),
                Credential::ClaudeNative { .. } => Some("claude_native"),
                Credential::CopilotNative { .. } => Some("copilot_native"),
                Credential::QuotioCustomProvider { .. } => Some("quotio_custom_provider"),
                _ => None,
            },
        }
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApiKeyInput {
    pub provider: Provider,
    pub label: Option<String>,
    pub api_key: String,
    #[serde(default)]
    pub settings: BTreeMap<String, String>,
    pub region: Option<String>,
    pub organization: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AccountPatch {
    pub enabled: Option<bool>,
    pub label: Option<String>,
    pub active: Option<bool>,
    pub api_key: Option<String>,
    pub settings: Option<BTreeMap<String, String>>,
    pub region: Option<String>,
    pub organization: Option<String>,
}
fn credential(input: ApiKeyInput, context: &ProviderContext) -> Result<Credential, AccountError> {
    let ApiKeyInput {
        provider,
        api_key,
        region,
        organization,
        settings,
        ..
    } = input;
    let token = api_key.trim();
    if token.is_empty() || token.len() > 16_384 || token.chars().any(char::is_control) {
        return Err(AccountError::Input);
    }
    let region_valid = matches!(
        (provider, region.as_deref()),
        (_, None)
            | (Provider::Factory, Some("global" | "eu"))
            | (Provider::Zai | Provider::MiniMax, Some("global" | "cn"))
    );
    if !region_valid || (provider != Provider::Factory && organization.is_some()) {
        return Err(AccountError::Unsupported);
    }
    if let Some(definition) = provider.catalog()
        && definition.auth == crate::providers::catalog::AuthKind::OAuth
    {
        return Err(AccountError::NativeOAuth(definition.key_env));
    }
    if provider.catalog().is_some() {
        Ok(Credential::CatalogKey {
            token: token.into(),
            settings: service::provider_settings(provider, settings, context)?,
        })
    } else if provider.api_key_name().is_some() {
        if !settings.is_empty() {
            return Err(AccountError::Settings);
        };
        Ok(Credential::ApiKey {
            token: token.into(),
            region,
            organization,
        })
    } else {
        Err(AccountError::Unsupported)
    }
}
#[derive(Deserialize)]
#[serde(untagged)]
pub enum AccountCreateInput {
    ApiKey(ApiKeyInput),
    GrokOwned(GrokOwnedInput),
    FactoryOwned(FactoryOwnedInput),
    KiroOwned(KiroOwnedInput),
    AntigravityOwned(AntigravityOwnedInput),
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GrokOwnedKind {
    GrokOwned,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrokOwnedInput {
    pub kind: GrokOwnedKind,
    pub label: String,
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: i64,
}
pub fn prepare_grok_owned(input: GrokOwnedInput) -> Result<PreparedAccount, AccountError> {
    let valid = |s: &str| {
        !s.is_empty()
            && s.len() <= 16_384
            && !s.chars().any(|c| c.is_control() || c.is_whitespace())
    };
    if !valid(&input.access_token) || !valid(&input.refresh_token) || input.expires_at < 0 {
        return Err(AccountError::Input);
    }
    Ok(PreparedAccount {
        provider: Provider::Catalog("grok"),
        label: super::validate_label(&input.label)?,
        identity: crate::cache::fingerprint(&["grok_owned", &input.refresh_token]),
        credential: Credential::GrokOAuth {
            access_token: crate::providers::catalog::oauth_editors::grok_oauth_token(
                crate::providers::Secret(input.access_token),
            )?
            .0,
            refresh_token: input.refresh_token,
            expires_at: input.expires_at,
            refresh_pending: false,
        },
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FactoryOwnedKind {
    FactoryOwned,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FactoryOwnedInput {
    pub kind: FactoryOwnedKind,
    pub label: String,
    pub access_token: String,
    pub refresh_token: String,
    pub organization_id: Option<String>,
}
pub fn prepare_factory_owned(input: FactoryOwnedInput) -> Result<PreparedAccount, AccountError> {
    use crate::providers::factory::{token_expiry, valid_token};
    if !valid_token(&input.access_token)
        || !valid_token(&input.refresh_token)
        || input
            .organization_id
            .as_ref()
            .is_some_and(|id| !valid_token(id) || id.len() > 256)
    {
        return Err(AccountError::Input);
    }
    Ok(PreparedAccount {
        provider: Provider::Factory,
        label: super::validate_label(&input.label)?,
        identity: crate::cache::fingerprint(&["factory_owned", &input.refresh_token]),
        credential: Credential::FactoryOAuth {
            expires_at: token_expiry(&input.access_token),
            access_token: input.access_token,
            refresh_token: input.refresh_token,
            organization_id: input.organization_id,
            refresh_pending: false,
        },
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum KiroOwnedKind {
    KiroOwned,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct KiroOwnedInput {
    pub kind: KiroOwnedKind,
    pub label: String,
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: i64,
    #[serde(rename = "authMethod")]
    pub auth_method: super::KiroAuthMethod,
    pub region: String,
    #[serde(rename = "profileArn")]
    pub profile_arn: Option<String>,
    #[serde(rename = "clientId")]
    pub client_id: Option<String>,
    #[serde(rename = "clientSecret")]
    pub client_secret: Option<String>,
}
pub fn prepare_kiro_owned(input: KiroOwnedInput) -> Result<PreparedAccount, AccountError> {
    let identity = crate::cache::fingerprint(&["kiro_owned", &input.refresh_token]);
    let label = super::validate_label(&input.label)?;
    let credential = crate::providers::catalog::oauth_cloud::kiro_owned_credential(input)?;
    Ok(PreparedAccount {
        provider: Provider::Catalog("kiro"),
        label,
        credential,
        identity,
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AntigravityOwnedKind {
    AntigravityOwned,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AntigravityOwnedInput {
    pub kind: AntigravityOwnedKind,
    pub label: String,
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: i64,
    pub client_id: String,
    pub client_secret: String,
}
pub fn prepare_antigravity_owned(
    input: AntigravityOwnedInput,
) -> Result<PreparedAccount, AccountError> {
    let identity = crate::cache::fingerprint(&["antigravity_owned", &input.refresh_token]);
    let label = super::validate_label(&input.label)?;
    let credential = crate::providers::antigravity_auth::owned_credential(input)?;
    Ok(PreparedAccount {
        provider: Provider::Antigravity,
        label,
        credential,
        identity,
    })
}

impl PreparedAccount {
    pub(super) fn discovered(
        provider: Provider,
        identity: String,
        credential: Credential,
    ) -> Result<Self, AccountError> {
        Ok(Self {
            provider,
            identity,
            credential,
            label: format!("{} native {}", provider.id(), &super::random_string()?[..8]),
        })
    }
}
pub struct PreparedAccount {
    provider: Provider,
    label: String,
    credential: Credential,
    identity: String,
}
pub struct PreparedPatch {
    label: Option<String>,
    active: Option<bool>,
    enabled: Option<bool>,
    replacement: Option<(Provider, String, Credential)>,
}
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum SourceInput {
    Discovered {
        discovery_ref: String,
    },
    KiroNative {},
    AntigravityNative {
        location: super::sources::AntigravityLocation,
    },
    DevinDesktopNative {
        location: super::sources::DevinDesktopLocation,
    },
    FactoryNative {
        location: super::sources::FactoryLocation,
    },
    CopilotNative {
        location: super::sources::CopilotLocation,
        entry_key: String,
    },
    ClaudeNative {
        location: super::sources::ClaudeLocation,
    },
    CodexNative {
        #[serde(default)]
        location: super::sources::CodexLocation,
    },
    GrokNative {
        entry_key: String,
    },
    CursorNative {},
    AmpNative {},
    QuotioCustomProvider {
        source: super::sources::CustomProviderReference,
    },
}
pub async fn prepare_source(input: SourceInput) -> Result<PreparedAccount, AccountError> {
    let (identity, credential, resolved) = match input {
        SourceInput::Discovered { .. } => return Err(AccountError::Input),
        SourceInput::AntigravityNative { location } => {
            let source = super::sources::AntigravityNativeReference::system(location)?;
            let resolved = source.resolve().await?;
            (
                source.identity()?,
                Credential::AntigravityNative { source },
                resolved,
            )
        }
        SourceInput::KiroNative {} => {
            let source = super::sources::KiroNativeReference::system()?;
            let resolved = source.resolve().await?;
            (
                source.identity()?,
                Credential::KiroNative { source },
                resolved,
            )
        }
        SourceInput::DevinDesktopNative { location } => {
            let source = super::sources::DevinDesktopNativeReference::system(location)?;
            let resolved = source.resolve().await?;
            (
                source.identity()?,
                Credential::DevinDesktopNative { source },
                resolved,
            )
        }
        SourceInput::FactoryNative { location } => {
            let source = super::sources::FactoryNativeReference::system(location)?;
            let resolved = source.resolve().await?;
            (
                source.identity()?,
                Credential::FactoryNative { source },
                resolved,
            )
        }
        SourceInput::CopilotNative {
            location,
            entry_key,
        } => {
            let source = super::sources::CopilotNativeReference::system(location, entry_key)?;
            let resolved = source.resolve().await?;
            (
                source.identity()?,
                Credential::CopilotNative { source },
                resolved,
            )
        }
        SourceInput::ClaudeNative { location } => {
            let source = super::sources::ClaudeNativeReference::system(location)?;
            let resolved = source.resolve().await?;
            (
                source.identity()?,
                Credential::ClaudeNative { source },
                resolved,
            )
        }
        SourceInput::CodexNative { location } => {
            let source = super::sources::CodexNativeReference::system(location)?;
            let resolved = source.resolve().await?;
            (
                source.identity()?,
                Credential::CodexNative { source },
                resolved,
            )
        }
        SourceInput::QuotioCustomProvider { source } => {
            let resolved = source.resolve().await?;
            (
                source.identity()?,
                Credential::QuotioCustomProvider { source },
                resolved,
            )
        }
        SourceInput::GrokNative { entry_key } => {
            let source = super::sources::GrokNativeReference::system(entry_key)?;
            let resolved = source.resolve().await?;
            (
                source.identity()?,
                Credential::GrokNative { source },
                resolved,
            )
        }
        SourceInput::CursorNative {} => {
            let source = super::sources::CursorNativeReference::system()?;
            let resolved = source.resolve().await?;
            (
                source.identity()?,
                Credential::CursorNative { source },
                resolved,
            )
        }
        SourceInput::AmpNative {} => {
            let source = super::sources::AmpNativeReference::system()?;
            let resolved = source.resolve().await?;
            (
                source.identity()?,
                Credential::AmpNative { source },
                resolved,
            )
        }
    };
    let provider = resolved.provider;
    let label = if provider == Provider::Catalog("cursor")
        && super::validate_label(&resolved.label).is_err()
    {
        "Local Cursor account".into()
    } else {
        resolved.label
    };
    Ok(PreparedAccount {
        provider,
        label,
        identity,
        credential,
    })
}

pub async fn prepare(
    context: &ProviderContext,
    input: ApiKeyInput,
) -> Result<PreparedAccount, AccountError> {
    let provider = input.provider;
    let requested_label = input.label.clone();
    let credential = credential(input, context)?;
    let usage = tokio::time::timeout(
        std::time::Duration::from_secs(30),
        service::validate(context, provider, &credential),
    )
    .await
    .map_err(|_| AccountError::Cancelled)??;
    let label = service::default_label(requested_label.as_deref(), &credential)?;
    Ok(PreparedAccount {
        provider,
        label,
        credential,
        identity: usage.account.id,
    })
}
pub async fn prepare_update(
    vault: Vault,
    context: &ProviderContext,
    id: &str,
    patch: AccountPatch,
) -> Result<PreparedPatch, AccountError> {
    let AccountPatch {
        enabled,
        label,
        active,
        api_key,
        settings,
        region,
        organization,
    } = patch;
    let replacement = match api_key {
        Some(api_key) => {
            let account = service::get(vault, id.to_owned()).await?;
            let credential = credential(
                ApiKeyInput {
                    provider: account.provider,
                    label: None,
                    api_key,
                    settings: settings.unwrap_or_default(),
                    region,
                    organization,
                },
                context,
            )?;
            let usage = tokio::time::timeout(
                std::time::Duration::from_secs(30),
                service::validate(context, account.provider, &credential),
            )
            .await
            .map_err(|_| AccountError::Cancelled)??;
            Some((account.provider, usage.account.id, credential))
        }
        None if settings.is_some() || region.is_some() || organization.is_some() => {
            return Err(AccountError::Input);
        }
        None => None,
    };
    Ok(PreparedPatch {
        label,
        active,
        enabled,
        replacement,
    })
}
pub async fn save(vault: Vault, prepared: PreparedAccount) -> Result<AccountDto, AccountError> {
    let account = service::add_persisted(
        vault,
        prepared.provider,
        prepared.label,
        prepared.credential,
        prepared.identity,
    )
    .await?;
    Ok(AccountDto::from(&account))
}
pub async fn save_once(
    vault: Vault,
    prepared: PreparedAccount,
    intent: service::MutationIntent,
) -> Result<String, AccountError> {
    service::commit_once(vault, intent, move |document| {
        document.add(
            prepared.provider,
            &prepared.label,
            prepared.identity,
            prepared.credential,
        )
    })
    .await
}
pub async fn update_once(
    vault: Vault,
    id: String,
    patch: PreparedPatch,
    intent: service::MutationIntent,
) -> Result<String, AccountError> {
    service::commit_once(vault, intent, move |document| {
        document.patch(&id, patch.label.as_deref(), patch.active, patch.enabled)?;
        if let Some((provider, identity, credential)) = patch.replacement {
            document.replace_api_key(&id, provider, identity, credential)?;
        }
        Ok(id)
    })
    .await
}
pub async fn remove_once(
    vault: Vault,
    id: String,
    intent: service::MutationIntent,
) -> Result<String, AccountError> {
    service::commit_once(vault, intent, move |document| {
        document.remove(&id)?;
        Ok(id)
    })
    .await
}

pub async fn create(
    vault: Vault,
    context: &ProviderContext,
    input: ApiKeyInput,
) -> Result<AccountDto, AccountError> {
    save(vault, prepare(context, input).await?).await
}
pub async fn list(vault: Vault) -> Result<Vec<AccountDto>, AccountError> {
    Ok(service::list(vault)
        .await?
        .iter()
        .map(AccountDto::from)
        .collect())
}
pub async fn get(vault: Vault, id: String) -> Result<AccountDto, AccountError> {
    let account = service::get(vault, id).await?;
    Ok(AccountDto::from(&account))
}
pub async fn update(
    vault: Vault,
    id: String,
    patch: AccountPatch,
) -> Result<AccountDto, AccountError> {
    if patch.api_key.is_some()
        || patch.settings.is_some()
        || patch.region.is_some()
        || patch.organization.is_some()
    {
        return Err(AccountError::Unsupported);
    }
    let account = service::patch(vault, id, patch.label, patch.active, patch.enabled).await?;
    Ok(AccountDto::from(&account))
}
pub async fn remove(vault: Vault, id: String) -> Result<(), AccountError> {
    service::remove(vault, id).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_key_input_rejects_unknown_fields_and_never_accepts_identity() {
        let input: ApiKeyInput = serde_json::from_str(
            r#"{"provider":"amp","api_key":"secret","settings":{},"region":null,"organization":null}"#,
        )
        .unwrap();
        assert_eq!(input.provider, Provider::Amp);
        assert!(
            serde_json::from_str::<ApiKeyInput>(
                r#"{"provider":"amp","api_key":"secret","identity":"caller-controlled"}"#,
            )
            .is_err()
        );
    }

    #[tokio::test]
    async fn save_returns_committed_dto_without_post_write_read() {
        use crate::accounts::vault::Backend;
        use std::sync::{Arc, Mutex};
        struct ReadFailsAfterWrite(Mutex<bool>);
        impl Backend for ReadFailsAfterWrite {
            fn read(&self) -> Result<Option<Vec<u8>>, AccountError> {
                if *self.0.lock().unwrap() {
                    Err(AccountError::Storage)
                } else {
                    Ok(None)
                }
            }
            fn write(&self, _: &[u8]) -> Result<(), AccountError> {
                *self.0.lock().unwrap() = true;
                Ok(())
            }
        }
        let path = std::env::temp_dir().join(format!(
            "quotio-api-save-{}.lock",
            crate::accounts::random_string().unwrap()
        ));
        let vault = Vault::new(Arc::new(ReadFailsAfterWrite(Mutex::new(false))), path);
        let account = save(
            vault,
            PreparedAccount {
                provider: Provider::Amp,
                label: "saved".into(),
                credential: Credential::ApiKey {
                    token: "secret".into(),
                    region: None,
                    organization: None,
                },
                identity: "verified".into(),
            },
        )
        .await
        .unwrap();
        assert_eq!(account.provider, Provider::Amp);
        assert_eq!(account.label, "saved");
        assert!(account.active);
    }

    #[test]
    fn antigravity_source_contract_is_fixed_and_read_only() {
        for location in ["gemini_keychain", "state_db"] {
            let body = serde_json::json!({"kind":"antigravity_native", "location":location});
            assert!(serde_json::from_value::<SourceInput>(body.clone()).is_ok());
            for field in ["path", "service", "account", "endpoint", "refresh", "owned"] {
                let mut invalid = body.clone();
                invalid[field] = "fixture".into();
                assert!(serde_json::from_value::<SourceInput>(invalid).is_err());
            }
        }
        assert!(
            serde_json::from_value::<SourceInput>(
                serde_json::json!({"kind":"antigravity_native", "location":"antigravity_keychain"})
            )
            .is_err()
        );
    }
    #[test]
    fn kiro_source_registration_isolated() {
        let dir = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "accounts::api::tests::kiro_source_registration_child",
                "--nocapture",
            ])
            .env("HOME", &dir)
            .env("QUOTIO_KIRO_SOURCE_FIXTURE", &dir)
            .output()
            .unwrap();
        std::fs::remove_dir_all(dir).unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    #[tokio::test]
    async fn kiro_source_registration_child() {
        let Some(dir) = std::env::var_os("QUOTIO_KIRO_SOURCE_FIXTURE") else {
            return;
        };
        let dir = std::path::PathBuf::from(dir);
        let source = super::super::sources::KiroNativeReference::system().unwrap();
        assert_eq!(source.path, dir.join(".aws/sso/cache/kiro-auth-token.json"));
        std::fs::create_dir_all(source.path.parent().unwrap()).unwrap();
        let bytes = br#"{"accessToken":"fixture-access","refreshToken":"owner-only","clientId":"fixture-client","profileArn":"arn:aws:codewhisperer:eu-west-1:123456789012:profile/test"}"#;
        std::fs::write(&source.path, bytes).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&source.path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let vault = Vault::new(
            std::sync::Arc::new(super::super::vault::tests::Memory::default()),
            dir.join("lock"),
        );
        let prepared = prepare_source(
            serde_json::from_value(serde_json::json!({"kind":"kiro_native"})).unwrap(),
        )
        .await
        .unwrap();
        let account = save(vault.clone(), prepared).await.unwrap();
        assert_eq!(account.source_kind, Some("kiro_native"));
        let serialized = serde_json::to_string(&account).unwrap();
        assert!(!serialized.contains("fixture-access"));
        assert!(!serialized.contains(source.path.to_str().unwrap()));
        let stored = serde_json::to_string(&vault.begin().unwrap().document).unwrap();
        assert!(!stored.contains("owner-only"));
        assert!(!stored.contains("fixture-access"));
        assert_eq!(std::fs::read(&source.path).unwrap(), bytes);
        for field in ["path", "source", "refresh_token", "endpoint", "owned"] {
            let mut bad = serde_json::json!({"kind":"kiro_native"});
            bad[field] = "untrusted".into();
            assert!(serde_json::from_value::<SourceInput>(bad).is_err());
        }
    }

    #[test]
    fn devin_desktop_source_registration_isolated() {
        let dir = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "accounts::api::tests::devin_desktop_source_registration_child",
                "--nocapture",
            ])
            .env("HOME", &dir)
            .env("QUOTIO_DEVIN_SOURCE_FIXTURE", &dir)
            .output()
            .unwrap();
        std::fs::remove_dir_all(dir).unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[tokio::test]
    async fn devin_desktop_source_registration_child() {
        let Some(dir) = std::env::var_os("QUOTIO_DEVIN_SOURCE_FIXTURE") else {
            return;
        };
        use crate::accounts::{
            sources::{DevinDesktopLocation, DevinDesktopNativeReference},
            vault::tests::Memory,
        };
        let dir = std::path::PathBuf::from(dir);
        let vault = Vault::new(
            std::sync::Arc::new(Memory::default()),
            dir.join("vault.lock"),
        );
        for location in [
            DevinDesktopLocation::CredentialsToml,
            DevinDesktopLocation::StateDatabase,
        ] {
            let source = DevinDesktopNativeReference::system(location).unwrap();
            assert!(source.path.starts_with(&dir));
            std::fs::create_dir_all(source.path.parent().unwrap()).unwrap();
            match location {
                DevinDesktopLocation::CredentialsToml => {
                    std::fs::write(&source.path, "windsurf_api_key='fixture-registration-key'")
                        .unwrap()
                }
                DevinDesktopLocation::StateDatabase => {
                    let output = std::process::Command::new("/usr/bin/sqlite3").args(["-init", "/dev/null"])
                        .arg(&source.path).arg("CREATE TABLE ItemTable(key TEXT, value TEXT); INSERT INTO ItemTable VALUES('windsurfAuthStatus','{\"apiKey\":\"fixture-registration-key\"}');").output().unwrap();
                    assert!(output.status.success());
                }
            }
            let before = std::fs::read(&source.path).unwrap();
            let prepared = prepare_source(SourceInput::DevinDesktopNative { location })
                .await
                .unwrap();
            assert_eq!(prepared.identity, source.identity().unwrap());
            let account = save(vault.clone(), prepared).await.unwrap();
            assert_eq!(account.provider, Provider::Catalog("devin-desktop"));
            assert_eq!(account.source_kind, Some("devin_desktop_native"));
            let serialized = serde_json::to_string(&account).unwrap();
            assert!(!serialized.contains("fixture-registration-key"));
            assert!(!serialized.contains(source.path.to_str().unwrap()));
            assert_eq!(std::fs::read(&source.path).unwrap(), before);
        }
        assert_eq!(list(vault).await.unwrap().len(), 2);
        for location in ["credentials_toml", "state_database"] {
            let base = serde_json::json!({"kind":"devin_desktop_native", "location":location});
            assert!(serde_json::from_value::<SourceInput>(base.clone()).is_ok());
            for field in ["path", "source", "api_key", "api_server_url", "provider"] {
                let mut bad = base.clone();
                bad[field] = serde_json::json!("untrusted");
                assert!(serde_json::from_value::<SourceInput>(bad).is_err());
            }
        }
        for value in [
            serde_json::json!({"kind":"devin_desktop_native"}),
            serde_json::json!({"kind":"devin_desktop_native", "location":"other"}),
        ] {
            assert!(serde_json::from_value::<SourceInput>(value).is_err());
        }
    }

    #[tokio::test]
    async fn save_write_failure_preserves_existing_storage() {
        use crate::accounts::vault::Backend;
        use std::sync::{Arc, Mutex};
        struct WriteFails(Mutex<Option<Vec<u8>>>);
        impl Backend for WriteFails {
            fn read(&self) -> Result<Option<Vec<u8>>, AccountError> {
                Ok(self.0.lock().unwrap().clone())
            }
            fn write(&self, _: &[u8]) -> Result<(), AccountError> {
                Err(AccountError::Storage)
            }
        }
        let backend = Arc::new(WriteFails(Mutex::new(Some(
            serde_json::to_vec(&crate::accounts::Document::empty()).unwrap(),
        ))));
        let path = std::env::temp_dir().join(format!(
            "quotio-api-write-{}.lock",
            crate::accounts::random_string().unwrap()
        ));
        let vault = Vault::new(backend.clone(), path);
        let result = save(
            vault,
            PreparedAccount {
                provider: Provider::Amp,
                label: "saved".into(),
                credential: Credential::ApiKey {
                    token: "secret".into(),
                    region: None,
                    organization: None,
                },
                identity: "verified".into(),
            },
        )
        .await;
        assert!(matches!(result, Err(AccountError::Storage)));
        assert_eq!(
            *backend.0.lock().unwrap(),
            Some(serde_json::to_vec(&crate::accounts::Document::empty()).unwrap())
        );
    }

    #[tokio::test]
    async fn patch_is_one_transaction_when_label_conflicts() {
        use crate::accounts::vault::tests::Memory;
        use std::sync::Arc;
        let path = std::env::temp_dir().join(format!(
            "quotio-api-{}.lock",
            crate::accounts::random_string().unwrap()
        ));
        let vault = Vault::new(Arc::new(Memory::default()), path);
        let key = |token: &str| Credential::ApiKey {
            token: token.into(),
            region: None,
            organization: None,
        };
        let first = service::add(
            vault.clone(),
            Provider::Amp,
            "first".into(),
            key("one"),
            "one".into(),
        )
        .await
        .unwrap();
        let second = service::add(
            vault.clone(),
            Provider::Amp,
            "second".into(),
            key("two"),
            "two".into(),
        )
        .await
        .unwrap();
        assert!(matches!(
            update(
                vault.clone(),
                second.clone(),
                AccountPatch {
                    enabled: None,
                    label: Some("first".into()),
                    active: Some(true),
                    api_key: None,
                    settings: None,
                    region: None,
                    organization: None,
                }
            )
            .await,
            Err(AccountError::Duplicate)
        ));
        let accounts = list(vault).await.unwrap();
        assert!(
            accounts
                .iter()
                .any(|account| account.id == first && account.active)
        );
        assert!(
            accounts
                .iter()
                .any(|account| account.id == second && !account.active)
        );
    }

    #[test]
    fn patch_rejects_unknown_fields() {
        assert!(
            serde_json::from_str::<AccountPatch>(r#"{"active":true,"credential":"secret"}"#)
                .is_err()
        );
    }

    #[tokio::test]
    async fn api_key_replacement_preserves_account_id() {
        use crate::accounts::vault::tests::Memory;
        use std::sync::Arc;

        let vault = Vault::new(
            Arc::new(Memory::default()),
            std::env::temp_dir().join(format!(
                "quotio-api-key-replacement-{}.lock",
                crate::accounts::random_string().unwrap()
            )),
        );
        let id = service::add(
            vault.clone(),
            Provider::Amp,
            "Amp".into(),
            Credential::ApiKey {
                token: "old".into(),
                region: None,
                organization: None,
            },
            "old-identity".into(),
        )
        .await
        .unwrap();
        let prepared = PreparedPatch {
            label: Some("Updated Amp".into()),
            active: None,
            enabled: None,
            replacement: Some((
                Provider::Amp,
                "new-identity".into(),
                Credential::ApiKey {
                    token: "new".into(),
                    region: None,
                    organization: None,
                },
            )),
        };
        let intent = service::MutationIntent::new("replace-key", "request".into()).unwrap();

        let updated = update_once(vault.clone(), id.clone(), prepared, intent)
            .await
            .unwrap();
        let account = service::get(vault, id.clone()).await.unwrap();

        assert_eq!(updated, id);
        assert_eq!(account.id, id);
        assert_eq!(account.label, "Updated Amp");
        assert_eq!(account.identity, "new-identity");
        assert!(matches!(account.credential, Credential::ApiKey { token, .. } if token == "new"));
    }
}
