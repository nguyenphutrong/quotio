//! API-neutral account operations. These types deliberately exclude credentials.
pub mod migration;

use super::{AccountError, Credential, LabelOrigin, service, vault::Vault};
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_location: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source_id: Option<String>,
}
impl From<&super::Account> for AccountDto {
    fn from(account: &super::Account) -> Self {
        Self {
            id: account.id.clone(),
            provider: account.provider,
            label: account.display_name().to_owned(),
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
            source_location: (match &account.credential {
                Credential::ClaudeNative { source } => Some(serde_json::json!(source.location)),
                Credential::FactoryNative { source } => Some(serde_json::json!(source.location)),
                Credential::AntigravityNative { source } => {
                    Some(serde_json::json!(source.location))
                }
                Credential::CopilotNative { source } => Some(serde_json::json!(source.location)),
                Credential::DevinDesktopNative { source } => {
                    Some(serde_json::json!(source.location))
                }
                _ => None,
            })
            .and_then(|value| value.as_str().map(str::to_owned)),
            source_id: matches!(account.credential, Credential::QuotioCustomProvider { .. })
                .then(|| account.identity.clone()),
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
    #[serde(default, deserialize_with = "present_nullable")]
    pub settings: Option<Option<BTreeMap<String, String>>>,
    #[serde(default, deserialize_with = "present_nullable")]
    pub region: Option<Option<String>>,
    #[serde(default, deserialize_with = "present_nullable")]
    pub organization: Option<Option<String>>,
}
fn present_value<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}

// A missing PATCH field preserves the value; explicit null resets it.
fn present_nullable<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}
impl AccountPatch {
    fn replacement_input(&self, account: &super::Account) -> Result<ApiKeyInput, AccountError> {
        let (settings, region, organization) = match &account.credential {
            Credential::ApiKey {
                region,
                organization,
                ..
            } => (BTreeMap::new(), region.clone(), organization.clone()),
            Credential::CatalogKey { settings, .. } => (settings.clone(), None, None),
            _ => return Err(AccountError::Unsupported),
        };
        Ok(ApiKeyInput {
            provider: account.provider,
            label: None,
            api_key: self.api_key.clone().ok_or(AccountError::Input)?,
            settings: self
                .settings
                .clone()
                .map(Option::unwrap_or_default)
                .unwrap_or(settings),
            region: self.region.clone().unwrap_or(region),
            organization: self.organization.clone().unwrap_or(organization),
        })
    }
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
        name_origin: Some(LabelOrigin::User),
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
        name_origin: Some(LabelOrigin::User),
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
        name_origin: Some(LabelOrigin::User),
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
        name_origin: Some(LabelOrigin::User),
        provider: Provider::Antigravity,
        label,
        credential,
        identity,
    })
}

impl PreparedAccount {
    fn insert(self, document: &mut super::Document) -> Result<String, AccountError> {
        match self.name_origin {
            Some(origin) => document.add_named(
                self.provider,
                &self.label,
                origin,
                self.identity,
                self.credential,
            ),
            None => document.add(self.provider, &self.label, self.identity, self.credential),
        }
    }

    pub(super) fn discovered(
        provider: Provider,
        identity: String,
        credential: Credential,
    ) -> Result<Self, AccountError> {
        Ok(Self {
            name_origin: Some(LabelOrigin::Generated),
            provider,
            identity,
            credential,
            label: format!("{} native {}", provider.id(), &super::random_string()?[..8]),
        })
    }
}
pub struct PreparedAccount {
    name_origin: Option<LabelOrigin>,
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
    expected_credential: Option<Credential>,
}
impl PreparedPatch {
    fn apply(self, document: &mut super::Document, id: &str) -> Result<(), AccountError> {
        if let Some(expected) = self.expected_credential {
            let current = document
                .accounts
                .iter()
                .find(|account| account.id == id)
                .ok_or(AccountError::NotFound)?;
            if current.credential != expected {
                return Err(AccountError::Busy);
            }
        }
        document.patch(id, self.label.as_deref(), self.active, self.enabled)?;
        if let Some((provider, identity, credential)) = self.replacement {
            document.replace_api_key(id, provider, identity, credential)?;
        }
        Ok(())
    }
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
        #[serde(default)]
        entry_key: Option<String>,
    },
    CopilotNative {
        location: super::sources::CopilotLocation,
        #[serde(default)]
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
        SourceInput::FactoryNative {
            location,
            entry_key,
        } => {
            let mut source = super::sources::FactoryNativeReference::system(location, entry_key)?;
            source.freeze_keychain_account().await?;
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
            let entry_key = if (entry_key.is_empty() || entry_key == "github.com")
                && location == super::sources::CopilotLocation::GhKeychain
            {
                crate::providers::catalog::oauth_primary::copilot_keychain_account().await?
            } else {
                entry_key
            };
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
        name_origin: Some(LabelOrigin::Generated),
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
        name_origin: Some(if requested_label.is_some() {
            LabelOrigin::User
        } else {
            LabelOrigin::Generated
        }),
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
    let mut expected_credential = None;
    let replacement = match &patch.api_key {
        Some(_) => {
            let account = service::get(vault, id.to_owned()).await?;
            let credential = credential(patch.replacement_input(&account)?, context)?;
            expected_credential = Some(account.credential);
            let usage = tokio::time::timeout(
                std::time::Duration::from_secs(30),
                service::validate(context, account.provider, &credential),
            )
            .await
            .map_err(|_| AccountError::Cancelled)??;
            Some((account.provider, usage.account.id, credential))
        }
        None if patch.settings.is_some()
            || patch.region.is_some()
            || patch.organization.is_some() =>
        {
            return Err(AccountError::Input);
        }
        None => None,
    };
    Ok(PreparedPatch {
        label: patch.label,
        active: patch.active,
        enabled: patch.enabled,
        replacement,
        expected_credential,
    })
}

pub async fn save(vault: Vault, prepared: PreparedAccount) -> Result<AccountDto, AccountError> {
    let account = service::add_persisted(
        vault,
        prepared.provider,
        prepared.label,
        prepared.credential,
        prepared.identity,
        prepared.name_origin,
    )
    .await?;
    Ok(AccountDto::from(&account))
}
pub async fn save_once(
    vault: Vault,
    prepared: PreparedAccount,
    intent: service::MutationIntent,
) -> Result<String, AccountError> {
    service::commit_once(vault, intent, move |document| prepared.insert(document)).await
}
pub async fn resolved_save_once(
    vault: Vault,
    prepared: PreparedAccount,
    intent: service::MutationIntent,
) -> Result<String, AccountError> {
    service::commit_once(vault, intent, move |document| {
        document.enable_resolved_accounts()?;
        prepared.insert(document)
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
        patch.apply(document, &id)?;
        Ok(id)
    })
    .await
}

pub(crate) async fn register_source_once(
    vault: Vault,
    prepared: PreparedAccount,
    intent: service::MutationIntent,
) -> Result<String, AccountError> {
    service::commit_once(vault, intent, move |document| {
        register_into(document, prepared)
    })
    .await
}

/// Registers an explicitly requested source, restoring it if the user removed it before.
pub(crate) async fn register_source(
    vault: Vault,
    prepared: PreparedAccount,
) -> Result<String, AccountError> {
    let mut tx = service::begin(vault).await?;
    let id = register_into(&mut tx.document, prepared)?;
    service::commit(tx).await?;
    Ok(id)
}

fn register_into(
    document: &mut super::Document,
    prepared: PreparedAccount,
) -> Result<String, AccountError> {
    if let Some(existing) = document.accounts.iter().find(|account| {
        account.provider == prepared.provider && account.identity == prepared.identity
    }) {
        if let Some(registry) = &mut document.resolved {
            registry.restore(existing);
        }
        return Ok(existing.id.clone());
    }
    let id = prepared.insert(document)?;
    if let Some(registry) = &mut document.resolved {
        registry.restore(
            document
                .accounts
                .iter()
                .find(|account| account.id == id)
                .expect("inserted"),
        );
    }
    Ok(id)
}

/// Automatic discovery is idempotent by source identity and does not grow the retry ledger.
pub(crate) async fn register_native(
    vault: Vault,
    prepared: PreparedAccount,
) -> Result<bool, AccountError> {
    tokio::task::spawn_blocking(move || {
        let mut tx = vault.begin()?;
        if tx
            .document
            .resolved
            .as_ref()
            .is_some_and(|registry| registry.is_suppressed(prepared.provider, &prepared.identity))
        {
            return Ok(false);
        }
        if tx.document.accounts.iter().any(|account| {
            account.provider == prepared.provider && account.identity == prepared.identity
        }) {
            return Ok(false);
        }
        prepared.insert(&mut tx.document)?;
        tx.commit()?;
        Ok(true)
    })
    .await
    .map_err(|_| AccountError::Storage)?
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
async fn resolved_view(
    vault: Vault,
    id: Option<String>,
) -> Result<crate::contract::AccountList, AccountError> {
    let mut tx = service::begin(vault.clone()).await?;
    if tx.document.resolved.is_none() {
        tokio::task::spawn_blocking(move || {
            tx.document.enable_resolved_accounts()?;
            tx.commit()
        })
        .await
        .map_err(|_| AccountError::Storage)??;
        tx = service::begin(vault).await?;
    }
    tokio::task::spawn_blocking(move || {
        let registry = tx.document.resolved.as_ref().expect("initialized");
        let canonical = id
            .as_deref()
            .map(|id| {
                registry
                    .resolve_id(id)
                    .map(str::to_owned)
                    .ok_or(AccountError::NotFound)
            })
            .transpose()?;
        let mut result = registry.account_list(&tx.document.accounts)?;
        if let Some(id) = canonical {
            result.accounts.retain(|account| account.id == id);
        }
        Ok(result)
    })
    .await
    .map_err(|_| AccountError::Storage)?
}

pub async fn resolved_list(vault: Vault) -> Result<crate::contract::AccountList, AccountError> {
    resolved_view(vault, None).await
}

pub async fn resolved_snapshot(
    vault: Vault,
    mut report: crate::domain::UsageReport,
    now: time::OffsetDateTime,
    ttl: time::Duration,
) -> Result<crate::contract::Snapshot, AccountError> {
    tokio::task::spawn_blocking(move || {
        let mut tx = vault.begin()?;
        tx.document.enable_resolved_accounts()?;
        report.providers.retain(|usage| {
            let record = usage.account_ref.as_ref().and_then(|reference| {
                tx.document
                    .accounts
                    .iter()
                    .find(|record| record.id == reference.id)
            });
            record.is_none_or(|record| {
                !matches!(
                    record.credential,
                    Credential::ApiKey { .. } | Credential::CatalogKey { .. }
                ) || record.identity == usage.account.id
            })
        });
        let registry = tx.document.resolved.as_mut().expect("initialized");
        let mut snapshot = crate::contract::snapshot::project(
            registry.account_list(&tx.document.accounts)?,
            &report,
            now,
            ttl,
        )
        .map_err(|_| AccountError::Snapshot)?;
        let digest = crate::contract::snapshot::digest(&snapshot)?;
        if registry.snapshot_digest.as_ref() != Some(&digest) {
            registry.snapshot_digest = Some(digest);
            snapshot.revision = registry
                .revision
                .checked_add(1)
                .ok_or(AccountError::Corrupt)?;
            tx.commit()?;
        }
        Ok(snapshot)
    })
    .await
    .map_err(|_| AccountError::Storage)?
}

pub async fn resolved_get(
    vault: Vault,
    id: String,
) -> Result<crate::contract::Account, AccountError> {
    resolved_view(vault, Some(id))
        .await?
        .accounts
        .into_iter()
        .next()
        .ok_or(AccountError::NotFound)
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResolvedAccountPatch {
    #[serde(default, deserialize_with = "present_nullable")]
    pub user_label: Option<Option<String>>,
    #[serde(default, deserialize_with = "present_value")]
    pub enabled: Option<bool>,
    #[serde(default, deserialize_with = "present_value")]
    pub active: Option<bool>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourcePatch {
    #[serde(default, deserialize_with = "present_value")]
    pub enabled: Option<bool>,
    #[serde(default, deserialize_with = "present_value")]
    pub api_key: Option<String>,
    #[serde(default, deserialize_with = "present_nullable")]
    pub settings: Option<Option<BTreeMap<String, String>>>,
    #[serde(default, deserialize_with = "present_nullable")]
    pub region: Option<Option<String>>,
    #[serde(default, deserialize_with = "present_nullable")]
    pub organization: Option<Option<String>>,
}
impl SourcePatch {
    pub fn into_account_patch(self) -> Result<AccountPatch, AccountError> {
        if self.enabled.is_none() && self.api_key.is_none() {
            return Err(AccountError::Input);
        }
        if self.api_key.is_none()
            && (self.settings.is_some() || self.region.is_some() || self.organization.is_some())
        {
            return Err(AccountError::Input);
        }
        Ok(AccountPatch {
            enabled: self.enabled,
            api_key: self.api_key,
            settings: self.settings,
            region: self.region,
            organization: self.organization,
            label: None,
            active: None,
        })
    }
}

pub async fn resolved_update_once(
    vault: Vault,
    id: String,
    patch: ResolvedAccountPatch,
    intent: service::MutationIntent,
) -> Result<String, AccountError> {
    if patch.user_label.is_none() && patch.enabled.is_none() && patch.active.is_none() {
        return Err(AccountError::Input);
    }
    if patch.active == Some(false) {
        return Err(AccountError::Unsupported);
    }
    service::commit_once(vault, intent, move |document| {
        document.enable_resolved_accounts()?;
        let registry = document.resolved.as_mut().expect("initialized");
        let canonical = registry
            .resolve_id(&id)
            .ok_or(AccountError::NotFound)?
            .to_owned();
        let sources = registry.source_ids(&canonical)?;
        if let Some(label) = patch.user_label {
            registry.set_label(&canonical, label.as_deref())?;
            if label.is_none() {
                for account in &mut document.accounts {
                    if sources.contains(&account.id) {
                        account
                            .naming
                            .get_or_insert(super::AccountNaming {
                                origin: LabelOrigin::Generated,
                                observed_name: None,
                            })
                            .origin = LabelOrigin::Generated;
                    }
                }
            }
        }
        if let Some(enabled) = patch.enabled {
            for source in sources {
                document.patch(&source, None, None, Some(enabled))?;
            }
        }
        if patch.active == Some(true) {
            let source = document
                .resolved
                .as_ref()
                .expect("initialized")
                .preferred_source(&document.accounts, &canonical)?;
            document.select(&source)?;
        }
        Ok(canonical)
    })
    .await
}

pub async fn resolved_remove_once(
    vault: Vault,
    id: String,
    intent: service::MutationIntent,
) -> Result<String, AccountError> {
    service::commit_once(vault, intent, move |document| {
        document.enable_resolved_accounts()?;
        let registry = document.resolved.as_ref().expect("initialized");
        let canonical = registry
            .resolve_id(&id)
            .ok_or(AccountError::NotFound)?
            .to_owned();
        let sources = registry.source_ids(&canonical)?;
        for source in sources {
            document.remove(&source)?;
        }
        Ok(canonical)
    })
    .await
}

pub async fn source_update_once(
    vault: Vault,
    id: String,
    patch: Option<PreparedPatch>,
    intent: service::MutationIntent,
) -> Result<String, AccountError> {
    service::commit_once(vault, intent, move |document| {
        document.enable_resolved_accounts()?;
        let canonical = document
            .resolved
            .as_ref()
            .expect("initialized")
            .account_id_for_source(&id)
            .ok_or(AccountError::NotFound)?
            .to_owned();
        if let Some(patch) = patch {
            patch.apply(document, &id)?;
            // Credential replacement can move this source to a new logical account.
            return Ok(document
                .resolved
                .as_ref()
                .expect("initialized")
                .account_id_for_source(&id)
                .ok_or(AccountError::NotFound)?
                .to_owned());
        } else {
            document.remove(&id)?;
        }
        Ok(canonical)
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn resolved_reads_wait_for_a_busy_vault() {
        let dir = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let vault = Vault::new(
            std::sync::Arc::new(super::super::vault::tests::Memory::default()),
            dir.join("lock"),
        );
        let held = vault.begin().unwrap();
        let mut read = Box::pin(resolved_list(vault.clone()));
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(75), &mut read)
                .await
                .is_err()
        );
        drop(held);
        assert!(
            tokio::time::timeout(std::time::Duration::from_secs(2), read)
                .await
                .unwrap()
                .unwrap()
                .accounts
                .is_empty()
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn reauthorizing_a_source_preserves_its_account_and_disabled_state() {
        let dir = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let vault = Vault::new(
            std::sync::Arc::new(super::super::vault::tests::Memory::default()),
            dir.join("lock"),
        );
        let prepared = || PreparedAccount {
            name_origin: Some(LabelOrigin::User),
            provider: Provider::Catalog("claude"),
            label: "Claude native account".into(),
            identity: "source-identity".into(),
            credential: Credential::ClaudeNative {
                source: super::super::sources::ClaudeNativeReference {
                    location: super::super::sources::ClaudeLocation::CodeKeychain,
                    path: None,
                },
            },
        };
        let first = register_source_once(
            vault.clone(),
            prepared(),
            service::MutationIntent::new("first", "first".into()).unwrap(),
        )
        .await
        .unwrap();
        let mut tx = vault.begin().unwrap();
        tx.document.patch(&first, None, None, Some(false)).unwrap();
        tx.commit().unwrap();
        let second = register_source_once(
            vault.clone(),
            prepared(),
            service::MutationIntent::new("second", "second".into()).unwrap(),
        )
        .await
        .unwrap();
        assert_eq!(first, second);
        let tx = vault.begin().unwrap();
        assert_eq!(tx.document.accounts.len(), 1);
        assert!(!tx.document.accounts[0].enabled());
        drop(tx);
        std::fs::remove_dir_all(dir).unwrap();
    }

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
                name_origin: Some(LabelOrigin::User),
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
                name_origin: Some(LabelOrigin::User),
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

    #[test]
    fn api_key_rotation_preserves_omitted_settings_and_honors_explicit_changes() {
        for (provider, credential, settings, region, organization) in [
            (
                Provider::Zai,
                Credential::ApiKey {
                    token: "old".into(),
                    region: Some("cn".into()),
                    organization: None,
                },
                BTreeMap::new(),
                Some("cn".into()),
                None,
            ),
            (
                Provider::Factory,
                Credential::ApiKey {
                    token: "old".into(),
                    region: Some("eu".into()),
                    organization: Some("org".into()),
                },
                BTreeMap::new(),
                Some("eu".into()),
                Some("org".into()),
            ),
            (
                Provider::Catalog("litellm"),
                Credential::CatalogKey {
                    token: "old".into(),
                    settings: BTreeMap::from([("base_url".into(), "https://example.test".into())]),
                },
                BTreeMap::from([("base_url".into(), "https://example.test".into())]),
                None,
                None,
            ),
        ] {
            let account = super::super::Account {
                naming: None,
                id: "id".into(),
                provider,
                label: "Work".into(),
                identity: "identity".into(),
                active: true,
                enabled: true,
                credential,
            };
            let patch: AccountPatch = serde_json::from_str(r#"{"api_key":"new"}"#).unwrap();
            let input = patch.replacement_input(&account).unwrap();
            assert_eq!(input.api_key, "new");
            assert_eq!(input.settings, settings);
            assert_eq!(input.region, region);
            assert_eq!(input.organization, organization);

            let patch: AccountPatch = serde_json::from_str(
                r#"{"api_key":"new","settings":null,"region":null,"organization":null}"#,
            )
            .unwrap();
            let cleared = patch.replacement_input(&account).unwrap();
            assert!(cleared.settings.is_empty());
            assert_eq!(cleared.region, None);
            assert_eq!(cleared.organization, None);

            let patch: AccountPatch = serde_json::from_str(r#"{"api_key":"new","settings":{"base_url":"https://new.example.test"},"region":"global","organization":"new-org"}"#).unwrap();
            let replaced = patch.replacement_input(&account).unwrap();
            assert_eq!(
                replaced.settings.get("base_url").map(String::as_str),
                Some("https://new.example.test")
            );
            assert_eq!(replaced.region.as_deref(), Some("global"));
            assert_eq!(replaced.organization.as_deref(), Some("new-org"));
        }
    }

    #[tokio::test]
    async fn source_replacement_is_scoped_fenced_and_returns_the_new_logical_id() {
        use crate::accounts::vault::tests::Memory;
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let vault = Vault::new(std::sync::Arc::new(Memory::default()), dir.join("lock"));
        let key = |token: &str| Credential::ApiKey {
            token: token.into(),
            region: None,
            organization: None,
        };
        let (first, second) = {
            let mut tx = vault.begin().unwrap();
            let first = tx
                .document
                .add(Provider::Amp, "First", "first".into(), key("old"))
                .unwrap();
            let second = tx
                .document
                .add(Provider::Amp, "Second", "second".into(), key("other"))
                .unwrap();
            tx.document.enable_resolved_accounts().unwrap();
            let registry = tx.document.resolved.as_mut().unwrap();
            let proof = crate::domain::VerifiedIdentity {
                subject: "user".into(),
                tenant: None,
            };
            registry.observe(&first, &proof).unwrap();
            registry.observe(&second, &proof).unwrap();
            tx.commit().unwrap();
            (first, second)
        };
        let patch = || PreparedPatch {
            label: None,
            active: None,
            enabled: Some(false),
            expected_credential: Some(key("old")),
            replacement: Some((Provider::Amp, "replacement".into(), key("new"))),
        };
        let intent = || service::MutationIntent::new("replace", "body".into()).unwrap();
        let original = resolved_get(vault.clone(), first.clone()).await.unwrap().id;
        let new_id = source_update_once(vault.clone(), first.clone(), Some(patch()), intent())
            .await
            .unwrap();
        assert_ne!(new_id, original);
        let replaced = resolved_get(vault.clone(), new_id.clone()).await.unwrap();
        assert!(!replaced.enabled);
        assert_eq!(replaced.sources.len(), 1);
        assert_eq!(replaced.sources[0].id, first);
        let survivor = resolved_get(vault.clone(), original).await.unwrap();
        assert!(survivor.enabled);
        assert_eq!(survivor.sources[0].id, second);
        assert_eq!(
            source_update_once(vault.clone(), first.clone(), Some(patch()), intent())
                .await
                .unwrap(),
            new_id
        );
        let stale = service::MutationIntent::new("stale", "body".into()).unwrap();
        assert!(matches!(
            source_update_once(vault.clone(), first.clone(), Some(patch()), stale).await,
            Err(AccountError::Busy)
        ));
        assert!(service::get(vault.clone(), first).await.unwrap().credential == key("new"));
        assert!(service::get(vault, second).await.unwrap().credential == key("other"));
        std::fs::remove_dir_all(dir).unwrap();
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
            expected_credential: None,
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
