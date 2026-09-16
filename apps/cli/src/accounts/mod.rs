pub mod api;
pub mod command;
pub mod discovery;
#[cfg(any(target_os = "linux", all(test, unix)))]
mod encrypted_file;
mod input;
pub mod oauth;
pub mod service;
pub mod sources;
pub mod staging;
pub mod vault;
use crate::{cli::Provider, error::ProviderError};
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AccountError {
    #[error("account storage is unavailable or access was denied")]
    Storage,
    #[error(
        "account data was replaced but durable storage could not be confirmed; inspect accounts before retrying"
    )]
    CommitUncertain,
    #[error("the credential source is disabled by its owner")]
    SourceDisabled,
    #[error("idempotency key was already used for a different request")]
    IdempotencyConflict,
    #[error("durable account retry ledger is full")]
    IdempotencyFull,
    #[error("saved account data is invalid; no changes were made")]
    Corrupt,
    #[error("another account operation is in progress; retry shortly")]
    Busy,
    #[error("account not found")]
    NotFound,
    #[error("this provider already has that label or account identity")]
    Duplicate,
    #[error("label must be 1–80 characters without control characters")]
    Label,
    #[error("this provider does not support the selected login method")]
    Unsupported,
    #[error("credential input is empty, too large, or invalid")]
    Input,
    #[error("enter the API key in a terminal without --token-stdin, or pipe it with --token-stdin")]
    InputMode,
    #[error("invalid or missing provider setting; run quotio providers for required settings")]
    Settings,
    #[error("this provider uses a native OAuth login; sign in through its app/CLI or set {0}")]
    NativeOAuth(&'static str),
    #[error("provider denied quota access")]
    QuotaForbidden,
    #[error("credential validation failed: {0}")]
    Provider(#[from] ProviderError),
    #[error("login timed out or was cancelled")]
    Cancelled,
    #[error("cannot listen on localhost:1455; close another Codex login and retry")]
    CallbackPort,
    #[error("OAuth callback or token response is invalid")]
    OAuth,
}

#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum KiroAuthMethod {
    Social,
    IdC,
}

// These values are serialized only inside the OS-protected vault, never reports.
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Credential {
    CopilotOAuth {
        access_token: String,
        account_id: String,
        login: String,
    },
    ClaudeOAuth {
        access_token: String,
        refresh_token: String,
        account_id: String,
        email: String,
        expires_at: i64,
        #[serde(default)]
        refresh_pending: bool,
    },
    DevinDesktopNative {
        source: sources::DevinDesktopNativeReference,
    },
    AntigravityNative {
        source: sources::AntigravityNativeReference,
    },
    AntigravityToken {
        access_token: String,
        expires_at: Option<i64>,
    },
    AntigravityOAuth {
        access_token: String,
        refresh_token: String,
        expires_at: i64,
        client_id: String,
        client_secret: String,
        refresh_pending: bool,
    },
    KiroOAuth {
        access_token: String,
        refresh_token: String,
        expires_at: i64,
        auth_method: KiroAuthMethod,
        region: String,
        profile_arn: Option<String>,
        client_id: Option<String>,
        client_secret: Option<String>,
        machine: String,
        refresh_pending: bool,
    },
    KiroNative {
        source: sources::KiroNativeReference,
    },
    KiroToken {
        access_token: String,
        region: String,
        profile_arn: Option<String>,
        machine: String,
        expires_at: Option<i64>,
    },
    FactoryNative {
        source: sources::FactoryNativeReference,
    },
    FactoryOAuth {
        access_token: String,
        refresh_token: String,
        organization_id: Option<String>,
        expires_at: i64,
        #[serde(default)]
        refresh_pending: bool,
    },
    GrokOAuth {
        access_token: String,
        refresh_token: String,
        expires_at: i64,
        #[serde(default)]
        refresh_pending: bool,
    },
    GrokNative {
        source: sources::GrokNativeReference,
    },
    CodexNative {
        source: sources::CodexNativeReference,
    },
    ClaudeNative {
        source: sources::ClaudeNativeReference,
    },
    CopilotNative {
        source: sources::CopilotNativeReference,
    },
    CursorNative {
        source: sources::CursorNativeReference,
    },
    AmpNative {
        source: sources::AmpNativeReference,
    },
    QuotioCustomProvider {
        source: sources::CustomProviderReference,
    },
    CatalogKey {
        token: String,
        settings: std::collections::BTreeMap<String, String>,
    },
    ApiKey {
        token: String,
        region: Option<String>,
        organization: Option<String>,
    },
    CodexOAuth {
        access_token: String,
        refresh_token: String,
        id_token: String,
        account_id: String,
        email: String,
        expires_at: i64,
    },
}
pub use crate::domain::AccountOrigin;
fn enabled_default() -> bool {
    true
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Account {
    pub id: String,
    pub provider: Provider,
    pub label: String,
    pub identity: String,
    pub active: bool,
    #[serde(default = "enabled_default")]
    pub enabled: bool,
    pub credential: Credential,
}
#[derive(Serialize)]
pub struct AccountInfo<'a> {
    pub id: &'a str,
    pub provider: Provider,
    pub label: &'a str,
    pub active: bool,
    pub origin: AccountOrigin,
    pub enabled: bool,
}
impl Account {
    pub fn enabled(&self) -> bool {
        self.enabled
            && match &self.credential {
                Credential::AmpNative { source } => source.enabled,
                _ => true,
            }
    }
    pub fn origin(&self) -> AccountOrigin {
        match self.credential {
            Credential::QuotioCustomProvider { .. } => AccountOrigin::BorrowedProxy,
            Credential::AmpNative { .. }
            | Credential::DevinDesktopNative { .. }
            | Credential::FactoryNative { .. }
            | Credential::AntigravityNative { .. }
            | Credential::KiroNative { .. }
            | Credential::CopilotNative { .. }
            | Credential::ClaudeNative { .. }
            | Credential::CodexNative { .. }
            | Credential::CursorNative { .. }
            | Credential::GrokNative { .. } => AccountOrigin::BorrowedNative,
            _ => AccountOrigin::Owned,
        }
    }
    pub fn info(&self) -> AccountInfo<'_> {
        AccountInfo {
            id: &self.id,
            provider: self.provider,
            label: &self.label,
            active: self.active,
            origin: self.origin(),
            enabled: self.enabled(),
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct MutationReceipt {
    pub fingerprint: String,
    pub account_id: String,
}

#[derive(Default, Serialize, Deserialize)]
pub struct Document {
    pub version: u8,
    pub accounts: Vec<Account>,
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub mutation_receipts: std::collections::BTreeMap<String, MutationReceipt>,
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub factory_refresh_owners: std::collections::BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub claude_refresh_owners: std::collections::BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub kiro_refresh_owners: std::collections::BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub antigravity_refresh_owners: std::collections::BTreeMap<String, String>,
}
impl Document {
    pub fn empty() -> Self {
        Self {
            version: 1,
            accounts: vec![],
            mutation_receipts: Default::default(),
            factory_refresh_owners: Default::default(),
            claude_refresh_owners: Default::default(),
            kiro_refresh_owners: Default::default(),
            antigravity_refresh_owners: Default::default(),
        }
    }
    // Retain token lineage after rotation/removal so registration cannot bypass a fence.
    pub fn reserve_factory_refresh(
        &mut self,
        id: &str,
        credential: &Credential,
    ) -> Result<(), AccountError> {
        if let Credential::AntigravityOAuth { refresh_token, .. } = credential {
            let fingerprint = crate::cache::fingerprint(&["antigravity_owned", refresh_token]);
            if self.antigravity_refresh_owners.get(&fingerprint).is_some_and(|owner| owner != id)
                || self.accounts.iter().any(|account| {
                    account.id != id && matches!(&account.credential,
                        Credential::AntigravityOAuth { refresh_token: existing, .. } if existing == refresh_token)
                })
            {
                return Err(AccountError::Duplicate);
            }
            self.antigravity_refresh_owners
                .insert(fingerprint, id.to_owned());
            self.version = self.version.max(8);
            return Ok(());
        }
        if let Credential::KiroOAuth { refresh_token, .. } = credential {
            let fingerprint = crate::cache::fingerprint(&["kiro_owned", refresh_token]);
            if self.kiro_refresh_owners.get(&fingerprint).is_some_and(|owner| owner != id)
                || self.accounts.iter().any(|account| {
                    account.id != id && matches!(&account.credential,
                        Credential::KiroOAuth { refresh_token: existing, .. } if existing == refresh_token)
                })
            {
                return Err(AccountError::Duplicate);
            }
            self.kiro_refresh_owners.insert(fingerprint, id.to_owned());
            self.version = self.version.max(7);
            return Ok(());
        }
        if let Credential::ClaudeOAuth { refresh_token, .. } = credential {
            let fingerprint = crate::cache::fingerprint(&["claude_owned", refresh_token]);
            if self.claude_refresh_owners.get(&fingerprint).is_some_and(|owner| owner != id)
                || self.accounts.iter().any(|account| {
                    account.id != id && matches!(&account.credential,
                        Credential::ClaudeOAuth { refresh_token: existing, .. } if existing == refresh_token)
                })
            {
                return Err(AccountError::Duplicate);
            }
            self.claude_refresh_owners
                .insert(fingerprint, id.to_owned());
            self.version = self.version.max(6);
            return Ok(());
        }
        let Credential::FactoryOAuth { refresh_token, .. } = credential else {
            return Ok(());
        };
        let fingerprint = crate::cache::fingerprint(&["factory_owned", refresh_token]);
        if self.factory_refresh_owners.get(&fingerprint).is_some_and(|owner| owner != id)
            || self.accounts.iter().any(|account| {
                account.id != id && matches!(&account.credential,
                    Credential::FactoryOAuth { refresh_token: existing, .. } if existing == refresh_token)
            })
        {
            return Err(AccountError::Duplicate);
        }
        self.factory_refresh_owners
            .insert(fingerprint, id.to_owned());
        self.version = self.version.max(5);
        Ok(())
    }
    pub fn add(
        &mut self,
        provider: Provider,
        label: &str,
        identity: String,
        credential: Credential,
    ) -> Result<String, AccountError> {
        let label = validate_label(label)?;
        if self
            .accounts
            .iter()
            .any(|a| a.provider == provider && (a.label == label || a.identity == identity))
        {
            return Err(AccountError::Duplicate);
        }
        let id = random_string()?;
        self.reserve_factory_refresh(&id, &credential)?;
        let active = !self
            .accounts
            .iter()
            .any(|a| a.provider == provider && a.active);
        if matches!(
            credential,
            Credential::QuotioCustomProvider { .. }
                | Credential::AmpNative { .. }
                | Credential::DevinDesktopNative { .. }
                | Credential::FactoryNative { .. }
                | Credential::AntigravityNative { .. }
                | Credential::KiroNative { .. }
                | Credential::ClaudeNative { .. }
                | Credential::CopilotNative { .. }
                | Credential::CodexNative { .. }
                | Credential::CursorNative { .. }
                | Credential::GrokNative { .. }
        ) {
            self.version = self.version.max(3);
        }
        if matches!(credential, Credential::CopilotOAuth { .. }) {
            self.version = self.version.max(6);
        }
        self.accounts.push(Account {
            id: id.clone(),
            provider,
            label,
            identity,
            active,
            credential,
            enabled: true,
        });
        Ok(id)
    }
    pub fn select(&mut self, id: &str) -> Result<(), AccountError> {
        let provider = self
            .accounts
            .iter()
            .find(|a| a.id == id)
            .ok_or(AccountError::NotFound)?
            .provider;
        for a in &mut self.accounts {
            if a.provider == provider {
                a.active = a.id == id;
            }
        }
        Ok(())
    }
    pub fn remove(&mut self, id: &str) -> Result<(), AccountError> {
        let index = self
            .accounts
            .iter()
            .position(|a| a.id == id)
            .ok_or(AccountError::NotFound)?;
        let account = self.accounts[index].clone();
        self.reserve_factory_refresh(&account.id, &account.credential)?;
        let removed = self.accounts.remove(index);
        if removed.active
            && let Some(next) = self
                .accounts
                .iter_mut()
                .find(|a| a.provider == removed.provider)
        {
            next.active = true;
        }
        Ok(())
    }
    pub fn rename(&mut self, id: &str, label: &str) -> Result<(), AccountError> {
        let label = validate_label(label)?;
        let provider = self
            .accounts
            .iter()
            .find(|account| account.id == id)
            .ok_or(AccountError::NotFound)?
            .provider;
        if self.accounts.iter().any(|candidate| {
            candidate.id != id && candidate.provider == provider && candidate.label == label
        }) {
            return Err(AccountError::Duplicate);
        }
        self.accounts
            .iter_mut()
            .find(|account| account.id == id)
            .expect("account was checked")
            .label = label;
        Ok(())
    }
    pub fn patch(
        &mut self,
        id: &str,
        label: Option<&str>,
        active: Option<bool>,
        enabled: Option<bool>,
    ) -> Result<(), AccountError> {
        if let Some(enabled) = enabled {
            let account = self
                .accounts
                .iter_mut()
                .find(|a| a.id == id)
                .ok_or(AccountError::NotFound)?;
            account.enabled = enabled;
            if let Credential::AmpNative { source } = &mut account.credential {
                source.enabled = enabled;
            }
            self.version = self.version.max(4);
        }
        if active == Some(false) {
            return Err(AccountError::Unsupported);
        }
        if let Some(label) = label {
            self.rename(id, label)?;
        }
        if active == Some(true) {
            self.select(id)?;
        }
        if self.accounts.iter().any(|account| account.id == id) {
            Ok(())
        } else {
            Err(AccountError::NotFound)
        }
    }

    pub fn replace_api_key(
        &mut self,
        id: &str,
        provider: Provider,
        identity: String,
        credential: Credential,
    ) -> Result<(), AccountError> {
        let account = self
            .accounts
            .iter()
            .find(|account| account.id == id)
            .ok_or(AccountError::NotFound)?;
        if account.provider != provider
            || !matches!(
                (&account.credential, &credential),
                (Credential::ApiKey { .. }, Credential::ApiKey { .. })
                    | (Credential::CatalogKey { .. }, Credential::CatalogKey { .. })
            )
        {
            return Err(AccountError::Unsupported);
        }
        if self.accounts.iter().any(|candidate| {
            candidate.id != id && candidate.provider == provider && candidate.identity == identity
        }) {
            return Err(AccountError::Duplicate);
        }
        let account = self
            .accounts
            .iter_mut()
            .find(|account| account.id == id)
            .expect("account was checked");
        account.identity = identity;
        account.credential = credential;
        Ok(())
    }
}
pub fn validate_label(label: &str) -> Result<String, AccountError> {
    let label = label.trim();
    if label.is_empty() || label.chars().count() > 80 || label.chars().any(char::is_control) {
        return Err(AccountError::Label);
    }
    Ok(label.to_owned())
}
pub(crate) fn random_string() -> Result<String, AccountError> {
    use base64::Engine;
    use ring::rand::SecureRandom;
    let mut bytes = [0; 32];
    ring::rand::SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| AccountError::Storage)?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}
