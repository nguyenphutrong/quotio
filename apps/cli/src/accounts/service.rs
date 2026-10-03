use super::{
    Account, AccountError, Credential,
    vault::{Transaction, Vault},
};
use crate::{
    cli::Provider,
    domain::{ProviderId, ProviderUsage},
    error::ProviderError,
    providers::{
        CredentialStore, FetchFuture, ProviderAdapter, ProviderContext, Secret,
        amp::AmpApiProvider, codex_api, factory::FactoryProvider,
    },
};
use clap::ValueEnum;
use std::{collections::HashMap, sync::Arc};

pub struct Keys(HashMap<String, String>);
impl CredentialStore for Keys {
    fn get(&self, name: &str) -> Option<Secret> {
        self.0.get(name).cloned().map(Secret)
    }
}
fn scoped(
    context: &ProviderContext,
    provider: Provider,
    credential: &Credential,
) -> Result<ProviderContext, AccountError> {
    let mut keys = HashMap::new();
    if let Credential::FactoryOAuth {
        refresh_pending: true,
        ..
    }
    | Credential::ClaudeOAuth {
        refresh_pending: true,
        ..
    }
    | Credential::KiroOAuth {
        refresh_pending: true,
        ..
    }
    | Credential::AntigravityOAuth {
        refresh_pending: true,
        ..
    } = credential
    {
        return Err(AccountError::CommitUncertain);
    }
    if let Credential::AntigravityToken { access_token, .. }
    | Credential::AntigravityOAuth { access_token, .. } = credential
    {
        if provider != Provider::Antigravity {
            return Err(AccountError::Unsupported);
        }
        let expires_at = match credential {
            Credential::AntigravityToken { expires_at, .. } => *expires_at,
            Credential::AntigravityOAuth { expires_at, .. } => Some(*expires_at),
            _ => unreachable!(),
        };
        if expires_at.is_some_and(|expiry| expiry <= context.clock.now().unix_timestamp()) {
            return Err(ProviderError::Authentication.into());
        }
        keys.insert("ANTIGRAVITY_ACCESS_TOKEN".into(), access_token.clone());
    }
    if let Credential::GrokOAuth {
        access_token,
        refresh_pending,
        ..
    } = credential
    {
        if provider != Provider::Catalog("grok") {
            return Err(AccountError::Unsupported);
        }
        if *refresh_pending {
            return Err(AccountError::CommitUncertain);
        }
        keys.insert("GROK_OAUTH_TOKEN".into(), access_token.clone());
    }
    if let Credential::CopilotOAuth { access_token, .. } = credential {
        if provider != Provider::Catalog("copilot") {
            return Err(AccountError::Unsupported);
        }
        keys.insert("COPILOT_API_TOKEN".into(), access_token.clone());
    }
    if let Credential::ClaudeOAuth { access_token, .. } = credential {
        if provider != Provider::Catalog("claude") {
            return Err(AccountError::Unsupported);
        }
        keys.insert("CLAUDE_OAUTH_ACCESS_TOKEN".into(), access_token.clone());
    }
    if let Credential::CatalogKey { token, settings } = credential {
        let definition = provider
            .catalog()
            .filter(|d| {
                d.auth == crate::providers::catalog::AuthKind::ApiKey
                    || matches!(
                        provider,
                        Provider::Catalog("cursor" | "grok" | "claude" | "copilot")
                    )
            })
            .ok_or(AccountError::Unsupported)?;
        keys.insert(definition.key_env.into(), token.clone());
        for (name, value) in settings {
            let setting = definition
                .settings
                .iter()
                .find(|s| s.name == name)
                .ok_or(AccountError::Settings)?;
            keys.insert(setting.env.into(), value.clone());
        }
        if definition
            .settings
            .iter()
            .any(|s| s.required && !settings.contains_key(s.name))
        {
            return Err(AccountError::Settings);
        }
    }
    if let Credential::ApiKey {
        token,
        region,
        organization,
    } = credential
    {
        let key = provider.api_key_name().ok_or(AccountError::Unsupported)?;
        if let Some(name) = provider.key_api().and_then(|k| k.region_key())
            && let Some(region) = region
        {
            keys.insert(name.into(), region.clone());
        }
        keys.insert(key.into(), token.clone());
        if provider == Provider::Factory {
            if let Some(region) = region {
                keys.insert("FACTORY_REGION".into(), region.clone());
            }
            if let Some(org) = organization {
                keys.insert("FACTORY_ORG_ID".into(), org.clone());
            }
        }
    }
    Ok(ProviderContext {
        http: context.http.clone(),
        clock: context.clock.clone(),
        credentials: Arc::new(Keys(keys)),
    })
}
pub async fn validate(
    context: &ProviderContext,
    provider: Provider,
    credential: &Credential,
) -> Result<ProviderUsage, AccountError> {
    validate_with_endpoint(context, provider, credential, None).await
}
async fn validate_with_endpoint(
    context: &ProviderContext,
    provider: Provider,
    credential: &Credential,
    endpoint_override: Option<&str>,
) -> Result<ProviderUsage, AccountError> {
    let reference = credential;
    let resolved = reference.resolve_reference(provider).await?;
    let credentials = resolved
        .as_ref()
        .map_or_else(|| vec![credential.clone()], |r| r.credentials.clone());
    let mut usage =
        validate_credentials(context, provider, &credentials, endpoint_override).await?;
    if resolved.is_some()
        && reference.resolve_reference(provider).await?.as_ref() != resolved.as_ref()
    {
        return Err(AccountError::Busy);
    }
    if provider == Provider::Catalog("cursor")
        && let Some(resolved) = resolved
    {
        usage.account.label = resolved.label;
        if usage.account.plan.is_none() {
            usage.account.plan = resolved.plan;
        }
        usage.account.subscription_status = resolved.subscription_status;
    }
    Ok(usage)
}
async fn validate_credentials(
    context: &ProviderContext,
    provider: Provider,
    credentials: &[Credential],
    endpoint_override: Option<&str>,
) -> Result<ProviderUsage, AccountError> {
    if credentials.len() == 1 {
        return validate_credential(context, provider, &credentials[0], endpoint_override).await;
    }
    let budget =
        crate::providers::remaining_fetch_time().unwrap_or(std::time::Duration::from_secs(30));
    let reserve = (budget / 10).min(std::time::Duration::from_millis(100));
    let deadline = tokio::time::Instant::now() + budget.saturating_sub(reserve);
    let mut selected = None;
    let mut failures = Vec::new();
    let mut last_error = AccountError::Input;
    for (index, credential) in credentials.iter().enumerate() {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let key_deadline =
            tokio::time::Instant::now() + remaining / ((credentials.len() - index) as u32);
        let result = tokio::time::timeout_at(
            key_deadline,
            crate::providers::FETCH_DEADLINE.scope(
                key_deadline,
                validate_credential(context, provider, credential, endpoint_override),
            ),
        )
        .await
        .unwrap_or(Err(AccountError::Provider(ProviderError::Timeout)));
        match result {
            Ok(mut usage) => {
                if credentials.len() > 1 {
                    for mut diagnostic in std::mem::take(&mut usage.diagnostics) {
                        diagnostic.source =
                            format!("{}_key_{}:{}", provider.id(), index + 1, diagnostic.source);
                        failures.push(diagnostic);
                    }
                }
                selected = Some(usage);
            }
            Err(error) => {
                let code = match &error {
                    AccountError::Provider(code) => *code,
                    _ => ProviderError::Authentication,
                };
                failures.push(crate::domain::UsageDiagnostic {
                    source: format!("{}_key_{}", provider.id(), index + 1),
                    code,
                });
                last_error = error;
            }
        }
    }
    let mut usage = selected.ok_or(last_error)?;
    usage.diagnostics.extend(failures);
    Ok(usage)
}
async fn validate_credential(
    context: &ProviderContext,
    provider: Provider,
    credential: &Credential,
    endpoint_override: Option<&str>,
) -> Result<ProviderUsage, AccountError> {
    let ctx = scoped(context, provider, credential)?;
    let mut usage = match provider {
        Provider::Amp => match endpoint_override {
            Some(endpoint) => AmpApiProvider.fetch_api(&ctx, endpoint).await?,
            None => AmpApiProvider.fetch(&ctx).await?,
        },
        Provider::Catalog("devin-desktop") if endpoint_override.is_some() => {
            crate::providers::catalog::devin_desktop::fetch_at(&ctx, endpoint_override.unwrap())
                .await?
        }
        Provider::Catalog("cursor") if endpoint_override.is_some() => {
            let endpoint = endpoint_override.unwrap();
            crate::providers::catalog::oauth_editors::fetch_cursor_complete_at(
                &ctx, endpoint, endpoint,
            )
            .await?
        }
        Provider::Catalog("grok") if endpoint_override.is_some() => {
            crate::providers::catalog::oauth_editors::fetch_grok_complete_at(
                &ctx,
                endpoint_override.unwrap(),
                None,
            )
            .await?
        }
        Provider::Catalog("claude") if endpoint_override.is_some() => {
            crate::providers::catalog::oauth_primary::fetch_claude_at(
                &ctx,
                endpoint_override.unwrap(),
            )
            .await?
        }
        Provider::Catalog("copilot") if endpoint_override.is_some() => {
            crate::providers::catalog::oauth_primary::fetch_copilot_at(
                &ctx,
                endpoint_override.unwrap(),
            )
            .await?
        }
        Provider::Catalog("kiro") => {
            crate::providers::catalog::oauth_cloud::fetch_kiro_credential(
                &ctx,
                credential,
                endpoint_override,
            )
            .await?
        }
        Provider::Factory if matches!(credential, Credential::FactoryOAuth { .. }) => {
            crate::providers::factory::fetch_oauth_at(
                context,
                credential,
                endpoint_override.unwrap_or("https://api.factory.ai/api/billing/limits"),
            )
            .await?
        }
        Provider::Factory => FactoryProvider.fetch(&ctx).await?,
        Provider::Antigravity => {
            crate::providers::antigravity::AntigravityProvider
                .fetch(&ctx)
                .await?
        }
        Provider::Codex if endpoint_override.is_some() => {
            let endpoint = endpoint_override.unwrap();
            codex_api::fetch_at(&ctx, credential, endpoint, endpoint, endpoint).await?
        }
        Provider::Codex => codex_api::fetch(&ctx, credential).await?,
        provider if provider.key_api().is_some() || provider.catalog().is_some() => {
            provider.adapter().fetch(&ctx).await?
        }
        _ => return Err(AccountError::Unsupported),
    };
    if let Credential::ClaudeOAuth {
        account_id, email, ..
    }
    | Credential::CopilotOAuth {
        account_id,
        login: email,
        ..
    } = credential
    {
        usage.account.id = account_id.clone();
        usage.account.label = email.clone();
    }
    if usage.windows.is_empty()
        || usage.account.id.is_empty()
        || usage.windows.iter().any(|w| !w.quota.is_valid())
    {
        return Err(ProviderError::InvalidData.into());
    }
    Ok(usage)
}
pub(crate) async fn mutation_guard(
    guard: &tokio::sync::Mutex<()>,
) -> Result<tokio::sync::MutexGuard<'_, ()>, AccountError> {
    tokio::time::timeout(std::time::Duration::from_secs(10), guard.lock())
        .await
        .map_err(|_| AccountError::Busy)
}
async fn begin(vault: Vault) -> Result<Transaction, AccountError> {
    begin_with_timeout(vault, std::time::Duration::from_secs(10)).await
}
async fn begin_with_timeout(
    vault: Vault,
    timeout: std::time::Duration,
) -> Result<Transaction, AccountError> {
    // Only reads are cancellable here. A detached native read cannot commit credentials.
    tokio::time::timeout(timeout, async move {
        loop {
            let copy = vault.clone();
            match tokio::task::spawn_blocking(move || copy.begin())
                .await
                .map_err(|_| AccountError::Storage)?
            {
                Err(AccountError::Busy) => {
                    tokio::time::sleep(std::time::Duration::from_millis(25)).await
                }
                result => return result,
            }
        }
    })
    .await
    .map_err(|_| AccountError::Busy)?
}
async fn refresh_lock(vault: Vault, id: String) -> Result<super::vault::VaultLock, AccountError> {
    loop {
        let copy = vault.clone();
        let account = id.clone();
        match tokio::task::spawn_blocking(move || copy.refresh_lock(&account))
            .await
            .map_err(|_| AccountError::Storage)?
        {
            Err(AccountError::Busy) => {
                tokio::time::sleep(std::time::Duration::from_millis(25)).await
            }
            result => return result,
        }
    }
}
async fn commit(tx: Transaction) -> Result<(), AccountError> {
    tokio::task::spawn_blocking(move || tx.commit())
        .await
        .map_err(|_| AccountError::Storage)?
}
/// Intent fingerprints are stored only in the protected vault, atomically with the write.
#[derive(Clone)]
pub struct MutationIntent {
    key: String,
    fingerprint: String,
}
impl MutationIntent {
    pub fn new(key: &str, fingerprint: String) -> Result<Self, AccountError> {
        if key.is_empty() || key.len() > 128 || !key.bytes().all(|b| b.is_ascii_graphic()) {
            return Err(AccountError::Input);
        }
        Ok(Self {
            key: crate::cache::fingerprint(&[key]),
            fingerprint,
        })
    }
    fn receipt(&self, document: &super::Document) -> Result<Option<String>, AccountError> {
        match document.mutation_receipts.get(&self.key) {
            Some(receipt) if receipt.fingerprint == self.fingerprint => {
                Ok(Some(receipt.account_id.clone()))
            }
            Some(_) => Err(AccountError::IdempotencyConflict),
            None => Ok(None),
        }
    }
}
pub async fn mutation_receipt(
    vault: Vault,
    intent: &MutationIntent,
) -> Result<Option<String>, AccountError> {
    let tx = begin(vault).await?;
    intent.receipt(&tx.document)
}
pub async fn commit_once(
    vault: Vault,
    intent: MutationIntent,
    mutation: impl FnOnce(&mut super::Document) -> Result<String, AccountError> + Send,
) -> Result<String, AccountError> {
    let mut tx = begin(vault).await?;
    if let Some(id) = intent.receipt(&tx.document)? {
        return Ok(id);
    }
    if tx.document.mutation_receipts.len() >= 4096 {
        return Err(AccountError::IdempotencyFull);
    }
    let id = mutation(&mut tx.document)?;
    tx.document.mutation_receipts.insert(
        intent.key,
        super::MutationReceipt {
            fingerprint: intent.fingerprint,
            account_id: id.clone(),
        },
    );
    // Older binaries must reject the document instead of silently discarding receipts.
    tx.document.version = tx.document.version.max(2);
    commit(tx).await?;
    Ok(id)
}

pub async fn add_persisted(
    vault: Vault,
    provider: Provider,
    label: String,
    credential: Credential,
    identity: String,
) -> Result<Account, AccountError> {
    let mut tx = begin(vault).await?;
    let id = tx.document.add(provider, &label, identity, credential)?;
    let account = tx
        .document
        .accounts
        .iter()
        .find(|account| account.id == id)
        .cloned()
        .ok_or(AccountError::Corrupt)?;
    commit(tx).await?;
    Ok(account)
}
pub async fn add(
    vault: Vault,
    provider: Provider,
    label: String,
    credential: Credential,
    identity: String,
) -> Result<String, AccountError> {
    Ok(add_persisted(vault, provider, label, credential, identity)
        .await?
        .id)
}
pub async fn list(vault: Vault) -> Result<Vec<Account>, AccountError> {
    Ok(begin(vault).await?.document.accounts.clone())
}
pub async fn select(vault: Vault, id: String) -> Result<(), AccountError> {
    let mut tx = begin(vault).await?;
    tx.document.select(&id)?;
    commit(tx).await
}
pub async fn remove(vault: Vault, id: String) -> Result<(), AccountError> {
    let mut tx = begin(vault).await?;
    tx.document.remove(&id)?;
    commit(tx).await
}
pub async fn get(vault: Vault, id: String) -> Result<Account, AccountError> {
    begin(vault)
        .await?
        .document
        .accounts
        .into_iter()
        .find(|account| account.id == id)
        .ok_or(AccountError::NotFound)
}
pub async fn rename(vault: Vault, id: String, label: String) -> Result<(), AccountError> {
    let mut tx = begin(vault).await?;
    tx.document.rename(&id, &label)?;
    commit(tx).await
}
pub async fn patch(
    vault: Vault,
    id: String,
    label: Option<String>,
    active: Option<bool>,
    enabled: Option<bool>,
) -> Result<Account, AccountError> {
    let mut tx = begin(vault).await?;
    tx.document.patch(&id, label.as_deref(), active, enabled)?;
    let account = tx
        .document
        .accounts
        .iter()
        .find(|account| account.id == id)
        .cloned()
        .ok_or(AccountError::NotFound)?;
    commit(tx).await?;
    Ok(account)
}
pub fn provider_settings(
    provider: Provider,
    mut values: std::collections::BTreeMap<String, String>,
    context: &ProviderContext,
) -> Result<std::collections::BTreeMap<String, String>, AccountError> {
    let Some(definition) = provider.catalog() else {
        return if values.is_empty() {
            Ok(values)
        } else {
            Err(AccountError::Settings)
        };
    };
    for (name, value) in &values {
        if !definition
            .settings
            .iter()
            .any(|setting| setting.name == name)
            || value.is_empty()
            || value.len() > 2048
            || value.chars().any(char::is_control)
        {
            return Err(AccountError::Settings);
        }
    }
    for setting in definition.settings {
        if !values.contains_key(setting.name)
            && let Some(value) = context.credentials.get(setting.env)
        {
            if value.0.is_empty() || value.0.len() > 2048 || value.0.chars().any(char::is_control) {
                return Err(AccountError::Settings);
            }
            values.insert(setting.name.into(), value.0);
        }
        if setting.required && !values.contains_key(setting.name) {
            return Err(AccountError::Settings);
        }
    }
    Ok(values)
}
pub fn default_label(
    explicit: Option<&str>,
    credential: &Credential,
) -> Result<String, AccountError> {
    if let Some(label) = explicit {
        return super::validate_label(label);
    }
    match credential {
        Credential::QuotioCustomProvider { .. }
        | Credential::AmpNative { .. }
        | Credential::CodexNative { .. }
        | Credential::ClaudeNative { .. }
        | Credential::CopilotNative { .. }
        | Credential::GrokNative { .. }
        | Credential::DevinDesktopNative { .. }
        | Credential::KiroNative { .. }
        | Credential::AntigravityNative { .. }
        | Credential::FactoryNative { .. }
        | Credential::CursorNative { .. } => Err(AccountError::Input),
        Credential::CopilotOAuth { login, .. } => super::validate_label(login),
        Credential::GrokOAuth { .. } => Ok("Grok owned account".into()),
        Credential::KiroToken { .. } | Credential::KiroOAuth { .. } => Ok("Kiro account".into()),
        Credential::AntigravityToken { .. } | Credential::AntigravityOAuth { .. } => {
            Ok("Antigravity account".into())
        }
        Credential::FactoryOAuth { .. } => Ok("Factory owned account".into()),
        Credential::CodexOAuth { email, .. } | Credential::ClaudeOAuth { email, .. } => {
            super::validate_label(email)
        }
        Credential::ApiKey { token, .. } | Credential::CatalogKey { token, .. } => {
            let suffix =
                if token.len() > 8 && token.is_ascii() && !token.chars().any(char::is_control) {
                    &token[token.len() - 4..]
                } else {
                    ""
                };
            Ok(format!("API key ****{suffix}"))
        }
    }
}

type OperationFuture<'a, T> =
    std::pin::Pin<Box<dyn std::future::Future<Output = Result<T, AccountError>> + Send + 'a>>;
trait Operations: Send + Sync {
    fn quota<'a>(
        &'a self,
        context: &'a ProviderContext,
        provider: Provider,
        credential: &'a Credential,
    ) -> OperationFuture<'a, ProviderUsage>;
    fn refresh<'a>(
        &'a self,
        context: &'a ProviderContext,
        credential: &'a Credential,
    ) -> OperationFuture<'a, Credential>;
}
struct Network;
impl Operations for Network {
    fn quota<'a>(
        &'a self,
        c: &'a ProviderContext,
        p: Provider,
        k: &'a Credential,
    ) -> OperationFuture<'a, ProviderUsage> {
        Box::pin(validate(c, p, k))
    }
    fn refresh<'a>(
        &'a self,
        c: &'a ProviderContext,
        k: &'a Credential,
    ) -> OperationFuture<'a, Credential> {
        Box::pin(async move {
            if matches!(k, Credential::AntigravityOAuth { .. }) {
                crate::providers::antigravity_auth::refresh_owned(c, k).await
            } else if matches!(k, Credential::KiroOAuth { .. }) {
                crate::providers::catalog::oauth_cloud::refresh_kiro(c, k).await
            } else if matches!(k, Credential::FactoryOAuth { .. }) {
                crate::providers::factory::refresh(c, k).await
            } else if matches!(k, Credential::ClaudeOAuth { .. }) {
                super::oauth::claude::refresh(c, k).await
            } else if matches!(k, Credential::GrokOAuth { .. }) {
                crate::providers::catalog::oauth_editors::refresh_grok(c, k).await
            } else {
                super::oauth::refresh(c, k).await
            }
        })
    }
}
struct ManagedProvider {
    factory_oauth: bool,
    origin: super::AccountOrigin,
    label: String,
    operations: Arc<dyn Operations>,
    vault: Vault,
    id: String,
    provider: Provider,
    provider_id: ProviderId,
}
impl ManagedProvider {
    async fn read(&self, context: &ProviderContext) -> Result<ProviderUsage, AccountError> {
        let tx = begin(self.vault.clone()).await?;
        let account = tx
            .document
            .accounts
            .iter()
            .find(|a| a.id == self.id && a.provider == self.provider)
            .ok_or(AccountError::NotFound)?
            .clone();
        drop(tx);
        if !account.enabled() {
            return Err(AccountError::SourceDisabled);
        }
        let credential = account.credential;
        if matches!(
            credential,
            Credential::GrokOAuth {
                refresh_pending: true,
                ..
            } | Credential::FactoryOAuth {
                refresh_pending: true,
                ..
            } | Credential::ClaudeOAuth {
                refresh_pending: true,
                ..
            } | Credential::KiroOAuth {
                refresh_pending: true,
                ..
            } | Credential::AntigravityOAuth {
                refresh_pending: true,
                ..
            }
        ) {
            return Err(AccountError::CommitUncertain);
        }
        if !matches!(
            credential,
            Credential::CodexOAuth { .. }
                | Credential::ClaudeOAuth { .. }
                | Credential::GrokOAuth { .. }
                | Credential::FactoryOAuth { .. }
                | Credential::KiroOAuth { .. }
                | Credential::AntigravityOAuth { .. }
        ) {
            let usage = self
                .operations
                .quota(context, self.provider, &credential)
                .await?;
            return self.verify_current(&credential, usage).await;
        }
        let refresh_margin = if self.provider == Provider::Catalog("grok") {
            300
        } else {
            60
        };
        let needs_refresh = matches!(&credential,Credential::CodexOAuth{expires_at,..} | Credential::GrokOAuth{expires_at,..} | Credential::FactoryOAuth{expires_at,..} | Credential::ClaudeOAuth{expires_at,..} | Credential::KiroOAuth{expires_at,..} | Credential::AntigravityOAuth{expires_at,..} if *expires_at<=context.clock.now().unix_timestamp()+refresh_margin);
        if !needs_refresh {
            match self
                .operations
                .quota(context, self.provider, &credential)
                .await
            {
                Ok(usage) => return self.verify_current(&credential, usage).await,
                Err(AccountError::Provider(ProviderError::Authentication)) => (),
                Err(error) => return Err(error),
            }
        }
        let guard = refresh_lock(self.vault.clone(), self.id.clone()).await?;
        let tx = begin(self.vault.clone()).await?;
        let account = tx
            .document
            .accounts
            .iter()
            .find(|a| a.id == self.id && a.provider == self.provider)
            .ok_or(AccountError::NotFound)?;
        if !account.enabled() {
            return Err(AccountError::SourceDisabled);
        }
        let latest = account.credential.clone();
        drop(tx);
        if credential != latest {
            drop(guard);
            let usage = self
                .operations
                .quota(context, self.provider, &latest)
                .await?;
            return self.verify_current(&latest, usage).await;
        }
        // A refresh can consume its token even if the response or vault commit is lost.
        // Persist a fence first so later reads cannot replay that request.
        let mut latest = latest;
        if let Credential::GrokOAuth {
            refresh_pending, ..
        }
        | Credential::FactoryOAuth {
            refresh_pending, ..
        }
        | Credential::ClaudeOAuth {
            refresh_pending, ..
        }
        | Credential::KiroOAuth {
            refresh_pending, ..
        }
        | Credential::AntigravityOAuth {
            refresh_pending, ..
        } = &mut latest
        {
            *refresh_pending = true;
            let mut tx = begin(self.vault.clone()).await?;
            tx.document.reserve_factory_refresh(&self.id, &latest)?;
            let account = tx
                .document
                .accounts
                .iter_mut()
                .find(|a| a.id == self.id)
                .ok_or(AccountError::NotFound)?;
            if !account.enabled() || account.credential != credential {
                return Err(AccountError::Busy);
            }
            account.credential = latest.clone();
            commit(tx).await?;
        }
        let updated = self.operations.refresh(context, &latest).await?;
        let mut tx = begin(self.vault.clone()).await?;
        tx.document.reserve_factory_refresh(&self.id, &updated)?;
        let result = match tx
            .document
            .accounts
            .iter_mut()
            .find(|a| a.id == self.id && a.provider == self.provider)
        {
            None => Err(AccountError::NotFound),
            Some(account) if account.credential != latest => Err(AccountError::Busy),
            Some(account) => {
                account.credential = updated.clone();
                if account.enabled() {
                    Ok(())
                } else {
                    Err(AccountError::SourceDisabled)
                }
            }
        };
        // Persist returned token lineage even when removal or replacement prevents
        // installing the credential. Keep existing mutation receipts in this write.
        commit(tx).await?;
        drop(guard);
        result?;
        let usage = self
            .operations
            .quota(context, self.provider, &updated)
            .await?;
        self.verify_current(&updated, usage).await
    }
    async fn verify_current(
        &self,
        credential: &Credential,
        usage: ProviderUsage,
    ) -> Result<ProviderUsage, AccountError> {
        let tx = begin(self.vault.clone()).await?;
        let current = tx
            .document
            .accounts
            .iter()
            .find(|a| a.id == self.id && a.provider == self.provider)
            .ok_or(AccountError::NotFound)?;
        if !current.enabled() || current.credential != *credential {
            return Err(AccountError::Busy);
        }
        Ok(usage)
    }
}
impl ProviderAdapter for ManagedProvider {
    fn cache_identity<'a>(
        &'a self,
        _: &'a ProviderContext,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<String>> + Send + 'a>> {
        Box::pin(async move {
            let tx = begin(self.vault.clone()).await.ok()?;
            let account = tx
                .document
                .accounts
                .iter()
                .find(|a| a.id == self.id && a.provider == self.provider)?;
            if !account.enabled() {
                return None;
            }
            let account = account.clone();
            drop(tx);
            let scope = match &account.credential {
                Credential::GrokOAuth {
                    refresh_pending: true,
                    ..
                }
                | Credential::FactoryOAuth {
                    refresh_pending: true,
                    ..
                }
                | Credential::ClaudeOAuth {
                    refresh_pending: true,
                    ..
                }
                | Credential::KiroOAuth {
                    refresh_pending: true,
                    ..
                }
                | Credential::AntigravityOAuth {
                    refresh_pending: true,
                    ..
                } => return None,
                Credential::QuotioCustomProvider { .. }
                | Credential::AmpNative { .. }
                | Credential::CodexNative { .. }
                | Credential::ClaudeNative { .. }
                | Credential::CopilotNative { .. }
                | Credential::GrokNative { .. }
                | Credential::DevinDesktopNative { .. }
                | Credential::KiroNative { .. }
                | Credential::AntigravityNative { .. }
                | Credential::FactoryNative { .. }
                | Credential::CursorNative { .. } => serde_json::to_string(
                    &account
                        .credential
                        .resolve_reference(self.provider)
                        .await
                        .ok()??,
                )
                .ok()?,
                Credential::CodexOAuth { account_id, .. } => account_id.clone(),
                credential => serde_json::to_string(credential).ok()?,
            };
            Some(crate::cache::fingerprint(&[
                &account.id,
                &account.identity,
                &scope,
            ]))
        })
    }

    fn account_ref(&self) -> Option<crate::domain::AccountRef> {
        Some(crate::domain::AccountRef {
            origin: Some(self.origin),
            id: self.id.clone(),
            label: self.label.clone(),
        })
    }
    fn id(&self) -> ProviderId {
        self.provider_id.clone()
    }
    fn idempotent(&self) -> bool {
        self.provider != Provider::Codex
            && !self.factory_oauth
            && !(matches!(
                self.provider,
                Provider::Antigravity | Provider::Catalog("grok" | "claude" | "kiro")
            ) && self.origin == super::AccountOrigin::Owned)
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            self.read(context).await.map_err(|e| match e {
                AccountError::Provider(ProviderError::Authentication)
                    if self.origin == super::AccountOrigin::BorrowedNative =>
                {
                    ProviderError::OwnerRefreshRequired
                }
                AccountError::Provider(e) => e,
                AccountError::Busy => ProviderError::Transient,
                AccountError::SourceDisabled => ProviderError::SourceDisabled,
                AccountError::Storage | AccountError::Corrupt | AccountError::CommitUncertain => {
                    ProviderError::CredentialStorage
                }
                _ => ProviderError::Authentication,
            })
        })
    }
}
struct FailedProvider {
    account_ref: Option<crate::domain::AccountRef>,
    provider_id: ProviderId,
}
impl ProviderAdapter for FailedProvider {
    fn account_ref(&self) -> Option<crate::domain::AccountRef> {
        self.account_ref.clone()
    }
    fn id(&self) -> ProviderId {
        self.provider_id.clone()
    }
    fn fetch<'a>(&'a self, _: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async { Err(ProviderError::CredentialStorage) })
    }
}
async fn discover(
    vault: Vault,
    timeout: std::time::Duration,
) -> Result<Vec<Account>, AccountError> {
    tokio::time::timeout(timeout, list(vault))
        .await
        .unwrap_or(Err(AccountError::Busy))
}
fn executable_available(name: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|path| {
        std::env::split_paths(&path).any(|dir| {
            let path = dir.join(if cfg!(windows) {
                format!("{name}.exe")
            } else {
                name.into()
            });
            path.metadata().is_ok_and(|m| {
                if !m.is_file() {
                    return false;
                }
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    m.permissions().mode() & 0o111 != 0
                }
                #[cfg(not(unix))]
                {
                    true
                }
            })
        })
    })
}
async fn local_sources(requested: &[Provider], timeout: std::time::Duration) -> Vec<Provider> {
    let mut sources: Vec<_> = requested
        .iter()
        .copied()
        .filter(|p| {
            let configured = p
                .api_key_name()
                .is_some_and(|name| std::env::var_os(name).is_some());
            if let Some(definition) = p.catalog() {
                definition.auth == crate::providers::catalog::AuthKind::ApiKey
                    && configured
                    && definition
                        .settings
                        .iter()
                        .all(|setting| !setting.required || std::env::var_os(setting.env).is_some())
            } else {
                p.key_api().is_some() && configured
            }
        })
        .collect();
    for (provider, token) in [
        (Provider::Catalog("kiro"), "KIRO_ACCESS_TOKEN"),
        (Provider::Antigravity, "ANTIGRAVITY_ACCESS_TOKEN"),
        (Provider::Antigravity, "ANTIGRAVITY_AUTH_FILE"),
        (Provider::Factory, "FACTORY_API_KEY"),
        (Provider::Catalog("cursor"), "CURSOR_ACCESS_TOKEN"),
        (Provider::Catalog("claude"), "CLAUDE_OAUTH_ACCESS_TOKEN"),
        (Provider::Catalog("copilot"), "COPILOT_API_TOKEN"),
        (Provider::Catalog("devin-desktop"), "DEVIN_DESKTOP_API_KEY"),
    ] {
        if requested.contains(&provider) && std::env::var_os(token).is_some() {
            sources.push(provider);
        }
    }
    if requested.contains(&Provider::Codex) && executable_available("codex") {
        sources.push(Provider::Codex);
    }
    if !requested.contains(&Provider::Amp) {
        return sources;
    }
    if executable_available("amp") {
        sources.push(Provider::Amp);
        return sources;
    }
    let public_amp = std::env::var("AMP_URL").map_or(true, |url| {
        url.trim_end_matches('/') == "https://ampcode.com"
    });
    if public_amp {
        let has_key = if std::env::var_os("AMP_API_KEY").is_some() {
            true
        } else {
            // Reuse the bounded parser so unrelated custom-host keys do not create
            // a local account. Unreadable/malformed credentials remain visible errors.
            tokio::time::timeout(
                timeout,
                tokio::task::spawn_blocking(|| {
                    crate::providers::amp::AmpProvider::default().has_local_key()
                }),
            )
            .await
            .ok()
            .and_then(Result::ok)
            .and_then(Result::ok)
            .unwrap_or(true)
        };
        if has_key {
            sources.push(Provider::Amp);
        }
    }
    sources
}

fn automatically_detected_providers(
    candidates: &[Provider],
    disabled: &[Provider],
    accounts: &[Account],
    local_sources: &[Provider],
) -> Vec<Provider> {
    candidates
        .iter()
        .copied()
        .filter(|provider| {
            *provider != Provider::Mock
                && !disabled.contains(provider)
                && (local_sources.contains(provider)
                    || accounts
                        .iter()
                        .any(|account| account.provider == *provider && account.enabled()))
        })
        .collect()
}

fn managed(vault: &Vault, account: &Account) -> Arc<dyn ProviderAdapter> {
    Arc::new(ManagedProvider {
        factory_oauth: matches!(account.credential, Credential::FactoryOAuth { .. }),
        origin: account.origin(),
        label: account.label.clone(),
        operations: Arc::new(Network),
        vault: vault.clone(),
        id: account.id.clone(),
        provider: account.provider,
        provider_id: account.provider.adapter().id(),
    })
}
fn native_amp_selection(has_key: bool, url: Option<&str>) -> bool {
    !has_key
        && url.is_none_or(|url| {
            reqwest::Url::parse(url)
                .ok()
                .and_then(|url| {
                    url.host_str()
                        .map(|host| host.eq_ignore_ascii_case("ampcode.com"))
                })
                .unwrap_or(true)
        })
}
pub(crate) fn uses_native_amp_source() -> bool {
    native_amp_selection(
        std::env::var_os("AMP_API_KEY").is_some(),
        std::env::var("AMP_URL").ok().as_deref(),
    )
}
pub(crate) fn native_reference_replaces_local(provider: Provider, credential: &Credential) -> bool {
    match credential {
        Credential::DevinDesktopNative { .. } => {
            provider == Provider::Catalog("devin-desktop")
                && std::env::var_os("DEVIN_DESKTOP_API_KEY").is_none()
        }
        Credential::AntigravityNative { source } => {
            provider == Provider::Antigravity
                && std::env::var_os("ANTIGRAVITY_ACCESS_TOKEN").is_none()
                && std::env::var_os("ANTIGRAVITY_AUTH_FILE").is_none()
                && source.location == super::sources::AntigravityLocation::GeminiKeychain
                && source.path.is_none()
        }
        Credential::KiroNative { .. } => {
            provider == Provider::Catalog("kiro") && std::env::var_os("KIRO_ACCESS_TOKEN").is_none()
        }
        Credential::FactoryNative { .. } => {
            provider == Provider::Factory && std::env::var_os("FACTORY_API_KEY").is_none()
        }
        Credential::CopilotNative { .. } => {
            provider == Provider::Catalog("copilot")
                && std::env::var_os("COPILOT_API_TOKEN").is_none()
        }
        Credential::ClaudeNative { .. } => {
            provider == Provider::Catalog("claude")
                && std::env::var_os("CLAUDE_OAUTH_ACCESS_TOKEN").is_none()
        }
        Credential::CodexNative { source } => {
            provider == Provider::Codex
                && super::sources::CodexNativeReference::system(
                    if std::env::var_os("CODEX_HOME").is_some() {
                        super::sources::CodexLocation::CodexHome
                    } else {
                        super::sources::CodexLocation::Default
                    },
                )
                .is_ok_and(|local| local == *source)
        }
        Credential::AmpNative { .. } => provider == Provider::Amp && uses_native_amp_source(),
        Credential::GrokNative { .. } => {
            provider == Provider::Catalog("grok") && std::env::var_os("GROK_OAUTH_TOKEN").is_none()
        }
        Credential::CursorNative { .. } => {
            provider == Provider::Catalog("cursor")
                && std::env::var_os("CURSOR_ACCESS_TOKEN").is_none()
        }
        _ => false,
    }
}
fn choose(
    providers: Vec<Provider>,
    filter: Option<&str>,
    accounts: Result<Vec<Account>, AccountError>,
    vault: &Vault,
    local_sources: &[Provider],
) -> Result<Vec<Arc<dyn ProviderAdapter>>, AccountError> {
    if let Some(id) = filter {
        let accounts = accounts?;
        let account = accounts
            .iter()
            .find(|a| a.id == id && providers.contains(&a.provider))
            .ok_or(AccountError::NotFound)?;
        return Ok(vec![managed(vault, account)]);
    }
    let mut selected = Vec::new();
    for provider in providers {
        if !provider.supports_accounts() {
            selected.push(provider.adapter());
            continue;
        }
        match &accounts {
            Ok(accounts) => {
                let matching: Vec<_> = accounts.iter().filter(|a| a.provider == provider).collect();
                let independent_antigravity_state = provider == Provider::Antigravity
                    && matching.iter().any(|a| {
                        matches!(&a.credential,
                        Credential::AntigravityNative { source }
                        if source.location == super::sources::AntigravityLocation::StateDb)
                    });
                if (local_sources.contains(&provider)
                    || matching.is_empty()
                    || independent_antigravity_state)
                    && !matching
                        .iter()
                        .any(|a| native_reference_replaces_local(provider, &a.credential))
                {
                    selected.push(provider.adapter());
                }
                selected.extend(matching.into_iter().map(|a| managed(vault, a)));
            }
            Err(_) => {
                if local_sources.contains(&provider) {
                    selected.push(provider.adapter());
                }
                selected.push(Arc::new(FailedProvider {
                    provider_id: provider.adapter().id(),
                    account_ref: Some(crate::domain::AccountRef {
                        origin: None,
                        id: "saved".into(),
                        label: "Saved accounts".into(),
                    }),
                }));
            }
        }
    }
    Ok(selected)
}
pub async fn adapters(
    providers: Vec<Provider>,
    saved: bool,
    timeout: std::time::Duration,
    filter: Option<&str>,
) -> Result<Vec<Arc<dyn ProviderAdapter>>, AccountError> {
    adapters_with_vault(providers, saved, true, timeout, filter, Vault::for_usage).await
}

pub async fn detected_adapters(
    disabled: Vec<Provider>,
    saved: bool,
    timeout: std::time::Duration,
) -> Result<Vec<Arc<dyn ProviderAdapter>>, AccountError> {
    let candidates: Vec<_> = Provider::value_variants()
        .iter()
        .copied()
        .filter(|provider| *provider != Provider::Mock && !disabled.contains(provider))
        .collect();
    if !saved || !cfg!(any(target_os = "macos", target_os = "linux")) {
        let local_sources = local_sources(&candidates, timeout).await;
        return Ok(local_sources.into_iter().map(Provider::adapter).collect());
    }
    let vault = Vault::for_usage()?;
    let (accounts, local_sources) = tokio::join!(
        discover(vault.clone(), timeout),
        local_sources(&candidates, timeout)
    );
    let accounts = accounts?;
    let providers =
        automatically_detected_providers(&candidates, &disabled, &accounts, &local_sources);
    let enabled_accounts = accounts
        .into_iter()
        .filter(Account::enabled)
        .collect::<Vec<_>>();
    choose(
        providers,
        None,
        Ok(enabled_accounts),
        &vault,
        &local_sources,
    )
}

pub(crate) async fn adapters_in_vault(
    providers: Vec<Provider>,
    include_owned: bool,
    timeout: std::time::Duration,
    filter: Option<&str>,
    vault: Vault,
) -> Result<Vec<Arc<dyn ProviderAdapter>>, AccountError> {
    adapters_with_vault(providers, true, include_owned, timeout, filter, move || {
        Ok(vault.clone())
    })
    .await
}

async fn adapters_with_vault(
    providers: Vec<Provider>,
    saved: bool,
    include_owned: bool,
    timeout: std::time::Duration,
    filter: Option<&str>,
    vault: impl Fn() -> Result<Vault, AccountError>,
) -> Result<Vec<Arc<dyn ProviderAdapter>>, AccountError> {
    if filter.is_some() && providers.len() != 1 {
        return Err(AccountError::Unsupported);
    }
    if filter == Some("local") {
        if saved
            && providers.iter().any(|p| {
                matches!(
                    p,
                    Provider::Codex
                        | Provider::Antigravity
                        | Provider::Factory
                        | Provider::Amp
                        | Provider::Catalog(
                            "cursor" | "grok" | "claude" | "copilot" | "devin-desktop" | "kiro"
                        )
                )
            })
        {
            let accounts = discover(vault()?, timeout).await?;
            if accounts.iter().any(|a| {
                providers.contains(&a.provider)
                    && native_reference_replaces_local(a.provider, &a.credential)
            }) {
                return Err(AccountError::Unsupported);
            }
        }
        return Ok(providers.into_iter().map(Provider::adapter).collect());
    }
    if !saved || !cfg!(any(target_os = "macos", target_os = "linux")) {
        if filter.is_some() {
            return Err(AccountError::Unsupported);
        }
        return Ok(providers.into_iter().map(Provider::adapter).collect());
    }
    if !providers.iter().any(|p| p.supports_accounts()) {
        if filter.is_some() {
            return Err(AccountError::NotFound);
        }
        return Ok(providers.into_iter().map(Provider::adapter).collect());
    }
    let vault = vault()?;
    let (accounts, local_sources) = tokio::join!(discover(vault.clone(), timeout), async {
        if filter.is_none() {
            local_sources(&providers, timeout).await
        } else {
            Vec::new()
        }
    });
    let accounts = accounts.map(|mut accounts| {
        if !include_owned {
            accounts.retain(|account| {
                account.origin() != super::AccountOrigin::Owned
                    || (account.provider == Provider::Catalog("warp")
                        && account.label.starts_with("__quotio_local_warp__:"))
            });
        }
        accounts
    });
    choose(providers, filter, accounts, &vault, &local_sources)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        accounts::{
            random_string,
            vault::{Backend, tests::Memory},
        },
        fetch::{Cancellation, CollectRequest, Collector},
        providers::{http, mock::MockProvider},
    };
    use std::{
        sync::atomic::{AtomicUsize, Ordering},
        time::Duration,
    };
    #[tokio::test]
    async fn vault_contention_times_out_before_mutation_and_recovers() {
        let path = std::env::temp_dir().join(format!(
            "quotio-contention-{}.lock",
            random_string().unwrap()
        ));
        let vault = Vault::new(Arc::new(Memory::default()), path.clone());
        let held = vault.begin().unwrap();
        assert!(matches!(
            begin_with_timeout(vault.clone(), Duration::from_millis(50)).await,
            Err(AccountError::Busy)
        ));
        drop(held);
        assert!(
            begin_with_timeout(vault, Duration::from_secs(1))
                .await
                .is_ok()
        );
        std::fs::remove_file(path).unwrap();
    }
    #[tokio::test(start_paused = true)]
    async fn mutation_guard_has_a_deadline() {
        let lock = tokio::sync::Mutex::new(());
        let held = lock.lock().await;
        assert!(matches!(
            mutation_guard(&lock).await,
            Err(AccountError::Busy)
        ));
        drop(held);
        assert!(mutation_guard(&lock).await.is_ok());
    }
    struct Fake {
        memory: Arc<Memory>,
        started: tokio::sync::Notify,
        delay: bool,
        refresh_fails: bool,
        quota_fails: bool,
        refreshes: AtomicUsize,
        quota_calls: AtomicUsize,
        wait_for_refresh: std::sync::atomic::AtomicBool,
        release_refresh: tokio::sync::Notify,
        stall_first_refresh: std::sync::atomic::AtomicBool,
    }
    impl Operations for Fake {
        fn quota<'a>(
            &'a self,
            c: &'a ProviderContext,
            p: Provider,
            k: &'a Credential,
        ) -> OperationFuture<'a, ProviderUsage> {
            Box::pin(async move {
                self.quota_calls.fetch_add(1, Ordering::SeqCst);
                if p == Provider::Codex && self.delay {
                    self.started.notify_one();
                    tokio::time::sleep(Duration::from_millis(500)).await;
                }
                if let Credential::CodexOAuth { access_token, .. } = k
                    && access_token == "new"
                {
                    let doc: super::super::Document =
                        serde_json::from_slice(&self.memory.read().unwrap().unwrap()).unwrap();
                    assert!(
                        doc.accounts.iter().any(|a| matches!((&a.credential,k),(Credential::CodexOAuth{refresh_token,account_id:stored,..},Credential::CodexOAuth{account_id:expected,..}) if refresh_token=="rotated" && stored==expected))
                    );
                }
                if let Credential::GrokOAuth { access_token, .. }
                | Credential::FactoryOAuth { access_token, .. }
                | Credential::ClaudeOAuth { access_token, .. }
                | Credential::KiroOAuth { access_token, .. }
                | Credential::AntigravityOAuth { access_token, .. } = k
                {
                    assert_eq!(access_token, "new");
                    let doc: super::super::Document =
                        serde_json::from_slice(&self.memory.read().unwrap().unwrap()).unwrap();
                    assert!(doc.accounts.iter().any(|a| a.credential == *k));
                }
                if self.quota_fails {
                    return Err(ProviderError::Unavailable.into());
                }
                let mut usage = MockProvider.fetch(c).await?;
                usage.provider = p.adapter().id();
                Ok(usage)
            })
        }
        fn refresh<'a>(
            &'a self,
            _: &'a ProviderContext,
            k: &'a Credential,
        ) -> OperationFuture<'a, Credential> {
            Box::pin(async move {
                self.refreshes.fetch_add(1, Ordering::SeqCst);
                let doc: super::super::Document =
                    serde_json::from_slice(&self.memory.read().unwrap().unwrap()).unwrap();
                if self.wait_for_refresh.load(Ordering::SeqCst) {
                    self.started.notify_one();
                    self.release_refresh.notified().await;
                }
                if self.stall_first_refresh.load(Ordering::SeqCst)
                    && matches!(k,Credential::CodexOAuth{account_id,..} if account_id=="codex-id")
                {
                    self.started.notify_one();
                    std::future::pending::<()>().await;
                }
                if self.delay {
                    tokio::time::sleep(Duration::from_millis(75)).await;
                }
                if self.refresh_fails {
                    return Err(ProviderError::Transient.into());
                }
                let mut k = k.clone();
                if let Credential::GrokOAuth {
                    access_token,
                    refresh_token,
                    expires_at,
                    refresh_pending,
                }
                | Credential::FactoryOAuth {
                    access_token,
                    refresh_token,
                    expires_at,
                    refresh_pending,
                    ..
                }
                | Credential::ClaudeOAuth {
                    access_token,
                    refresh_token,
                    expires_at,
                    refresh_pending,
                    ..
                }
                | Credential::KiroOAuth {
                    access_token,
                    refresh_token,
                    expires_at,
                    refresh_pending,
                    ..
                }
                | Credential::AntigravityOAuth {
                    access_token,
                    refresh_token,
                    expires_at,
                    refresh_pending,
                    ..
                } = &mut k
                {
                    assert!(*refresh_pending);
                    assert!(doc.accounts.iter().any(|a| matches!(
                        a.credential,
                        Credential::GrokOAuth {
                            refresh_pending: true,
                            ..
                        } | Credential::FactoryOAuth {
                            refresh_pending: true,
                            ..
                        } | Credential::ClaudeOAuth {
                            refresh_pending: true,
                            ..
                        } | Credential::KiroOAuth {
                            refresh_pending: true,
                            ..
                        } | Credential::AntigravityOAuth {
                            refresh_pending: true,
                            ..
                        }
                    )));
                    *access_token = "new".into();
                    *refresh_token = "rotated".into();
                    *expires_at = 3600;
                    *refresh_pending = false;
                }
                if let Credential::CodexOAuth {
                    access_token,
                    refresh_token,
                    expires_at,
                    ..
                } = &mut k
                {
                    *access_token = "new".into();
                    *refresh_token = "rotated".into();
                    *expires_at = 3600;
                }
                Ok(k)
            })
        }
    }

    #[test]
    fn claude_and_copilot_selection_uses_isolated_environment() {
        let dir = std::env::temp_dir().join(random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        for mode in 0..3 {
            let mut command = std::process::Command::new(std::env::current_exe().unwrap());
            command
                .args([
                    "--exact",
                    "accounts::service::tests::claude_and_copilot_selection_child",
                    "--nocapture",
                ])
                .env("HOME", &dir)
                .env("QUOTIO_SELECTION_FIXTURE", &dir)
                .env_remove("CLAUDE_OAUTH_ACCESS_TOKEN")
                .env_remove("COPILOT_API_TOKEN")
                .env_remove("KIRO_ACCESS_TOKEN")
                .env_remove("ANTIGRAVITY_ACCESS_TOKEN")
                .env_remove("ANTIGRAVITY_AUTH_FILE")
                .env_remove("FACTORY_API_KEY")
                .env_remove("DEVIN_DESKTOP_API_KEY");
            if mode > 0 {
                command
                    .env("CLAUDE_OAUTH_ACCESS_TOKEN", "independent-claude-fixture")
                    .env("COPILOT_API_TOKEN", "independent-copilot-fixture")
                    .env("KIRO_ACCESS_TOKEN", "independent-kiro-fixture")
                    .env(
                        "ANTIGRAVITY_ACCESS_TOKEN",
                        "independent-antigravity-fixture",
                    )
                    .env("FACTORY_API_KEY", "independent-factory-fixture")
                    .env("DEVIN_DESKTOP_API_KEY", "independent-desktop-fixture");
            }
            if mode == 2 {
                command
                    .env_remove("ANTIGRAVITY_ACCESS_TOKEN")
                    .env("ANTIGRAVITY_AUTH_FILE", dir.join("independent-auth.json"));
            }
            let output = command.output().unwrap();
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn claude_and_copilot_selection_child() {
        let Ok(dir) = std::env::var("QUOTIO_SELECTION_FIXTURE") else {
            return;
        };
        let dir = std::path::PathBuf::from(dir);
        let missing = dir.join("missing-native-credentials");
        assert!(!missing.exists());
        // Selection must not probe the real Keychain. state_db is independent of
        // the default Keychain alias, even without an environment credential.
        let vault = Vault::new(
            Arc::new(Memory::default()),
            dir.join("state-selection.lock"),
        );
        let mut tx = vault.begin().unwrap();
        tx.document
            .add(
                Provider::Antigravity,
                "State",
                "state".into(),
                Credential::AntigravityNative {
                    source: super::super::sources::AntigravityNativeReference {
                        location: super::super::sources::AntigravityLocation::StateDb,
                        path: Some(missing.join("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")),
                    },
                },
            )
            .unwrap();
        let accounts = tx.document.accounts.clone();
        drop(tx);
        let selected =
            choose(vec![Provider::Antigravity], None, Ok(accounts), &vault, &[]).unwrap();
        assert_eq!(selected.len(), 2);
        assert!(
            selected
                .iter()
                .any(|adapter| adapter.account_ref().unwrap().id == "local")
        );
        for (provider, token, credential) in [
            (
                Provider::Antigravity,
                "ANTIGRAVITY_ACCESS_TOKEN",
                Credential::AntigravityNative {
                    source: super::super::sources::AntigravityNativeReference {
                        location: super::super::sources::AntigravityLocation::GeminiKeychain,
                        path: None,
                    },
                },
            ),
            (
                Provider::Catalog("kiro"),
                "KIRO_ACCESS_TOKEN",
                Credential::KiroNative {
                    source: super::super::sources::KiroNativeReference {
                        path: missing.join(".aws/sso/cache/kiro-auth-token.json"),
                    },
                },
            ),
            (
                Provider::Catalog("devin-desktop"),
                "DEVIN_DESKTOP_API_KEY",
                Credential::DevinDesktopNative {
                    source: super::super::sources::DevinDesktopNativeReference {
                        path: missing.clone(),
                        location: super::super::sources::DevinDesktopLocation::CredentialsToml,
                    },
                },
            ),
            (
                Provider::Factory,
                "FACTORY_API_KEY",
                Credential::FactoryNative {
                    source: super::super::sources::FactoryNativeReference {
                        directory: missing.clone(),
                        location: super::super::sources::FactoryLocation::Legacy,
                    },
                },
            ),
            (
                Provider::Catalog("claude"),
                "CLAUDE_OAUTH_ACCESS_TOKEN",
                Credential::ClaudeNative {
                    source: super::super::sources::ClaudeNativeReference {
                        location: super::super::sources::ClaudeLocation::CodeFile,
                        path: Some(missing.clone()),
                    },
                },
            ),
            (
                Provider::Catalog("copilot"),
                "COPILOT_API_TOKEN",
                Credential::CopilotNative {
                    source: super::super::sources::CopilotNativeReference {
                        location: super::super::sources::CopilotLocation::Apps,
                        path: Some(missing.clone()),
                        entry_key: "github.com:fixture".into(),
                    },
                },
            ),
        ] {
            let independent = std::env::var_os(token).is_some()
                || (provider == Provider::Antigravity
                    && std::env::var_os("ANTIGRAVITY_AUTH_FILE").is_some());
            for enabled in [false, true] {
                let vault = Vault::new(Arc::new(Memory::default()), dir.join("selection.lock"));
                let mut tx = vault.begin().unwrap();
                let id = tx
                    .document
                    .add(provider, "Native", "source".into(), credential.clone())
                    .unwrap();
                tx.document.patch(&id, None, None, Some(enabled)).unwrap();
                tx.commit().unwrap();

                // A disabled reference must block the local alias before native reads,
                // even when its source is missing. An independent token remains usable.
                let local = adapters_with_vault(
                    vec![provider],
                    true,
                    false,
                    Duration::from_secs(1),
                    Some("local"),
                    || Ok(vault.clone()),
                )
                .await;
                if independent {
                    let local = local.unwrap();
                    assert_eq!(local.len(), 1);
                    assert_eq!(local[0].account_ref().unwrap().id, "local");
                } else {
                    assert!(matches!(local, Err(AccountError::Unsupported)));
                }

                let selected = adapters_with_vault(
                    vec![provider],
                    true,
                    false,
                    Duration::from_secs(1),
                    None,
                    || Ok(vault.clone()),
                )
                .await
                .unwrap();
                let ids: Vec<_> = selected
                    .iter()
                    .map(|a| a.account_ref().unwrap().id)
                    .collect();
                assert_eq!(ids.contains(&"local".to_string()), independent);
                assert_eq!(ids.len(), if independent { 2 } else { 1 });
                assert!(ids.contains(&id));
            }
        }
    }

    #[tokio::test]
    async fn excluding_owned_accounts_restores_native_adapter_selection() {
        let path = std::env::temp_dir().join(random_string().unwrap());
        let vault = Vault::new(Arc::new(Memory::default()), path.clone());
        for provider in [
            Provider::Catalog("claude"),
            Provider::Catalog("copilot"),
            Provider::Catalog("kiro"),
            Provider::Factory,
            Provider::Catalog("devin-desktop"),
            Provider::Catalog("grok"),
        ] {
            let id = add(
                vault.clone(),
                provider,
                "Owned".into(),
                Credential::ApiKey {
                    token: "synthetic-key".into(),
                    region: None,
                    organization: None,
                },
                provider.id().into(),
            )
            .await
            .unwrap();
            for include_owned in [false, true] {
                let selected = adapters_in_vault(
                    vec![provider],
                    include_owned,
                    Duration::from_secs(1),
                    None,
                    vault.clone(),
                )
                .await
                .unwrap();
                assert_eq!(
                    selected
                        .iter()
                        .any(|a| a.account_ref().is_some_and(|r| r.id == id)),
                    include_owned,
                );
                if !include_owned {
                    assert_eq!(selected.len(), 1);
                    let reference = selected[0].account_ref().unwrap();
                    assert_eq!(reference.id, "local");
                    assert_eq!(reference.origin, None);
                }
            }
            assert!(matches!(
                adapters_in_vault(
                    vec![provider],
                    false,
                    Duration::from_secs(1),
                    Some(&id),
                    vault.clone(),
                )
                .await,
                Err(AccountError::NotFound)
            ));
        }
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn native_selection_preserves_independent_environment_and_custom_host_sources() {
        assert!(native_amp_selection(false, None));
        assert!(native_amp_selection(false, Some("https://ampcode.com/")));
        assert!(native_amp_selection(
            false,
            Some("HTTPS://AMPCODE.COM:443/")
        ));
        assert!(native_amp_selection(
            false,
            Some("https://ampcode.com/path")
        ));
        assert!(native_amp_selection(false, Some("invalid-url")));
        assert!(!native_amp_selection(true, None));
        assert!(!native_amp_selection(false, Some("https://custom.example")));
    }
    #[tokio::test]
    async fn devin_desktop_native_http_fences_rotation_disable_and_owner_refresh() {
        struct HttpQuota(String);
        impl Operations for HttpQuota {
            fn quota<'a>(
                &'a self,
                c: &'a ProviderContext,
                p: Provider,
                k: &'a Credential,
            ) -> OperationFuture<'a, ProviderUsage> {
                Box::pin(validate_with_endpoint(c, p, k, Some(&self.0)))
            }
            fn refresh<'a>(
                &'a self,
                _: &'a ProviderContext,
                _: &'a Credential,
            ) -> OperationFuture<'a, Credential> {
                panic!("borrowed credentials must never refresh")
            }
        }
        for status in [200, 401, 403] {
            for rotate in [false, true] {
                let dir = std::env::temp_dir().join(random_string().unwrap());
                std::fs::create_dir(&dir).unwrap();
                let path = dir.join("credentials.toml");
                let original = b"windsurf_api_key = 'fixture-first'\n";
                std::fs::write(&path, original).unwrap();
                let credential = Credential::DevinDesktopNative {
                    source: super::super::sources::DevinDesktopNativeReference {
                        path: path.clone(),
                        location: super::super::sources::DevinDesktopLocation::CredentialsToml,
                    },
                };
                let vault = Vault::new(Arc::new(Memory::default()), dir.join("lock"));
                let mut tx = vault.begin().unwrap();
                let id = tx
                    .document
                    .add(
                        Provider::Catalog("devin-desktop"),
                        "Fixture",
                        "source".into(),
                        credential.clone(),
                    )
                    .unwrap();
                let account = tx.document.accounts[0].clone();
                assert_eq!(
                    account.origin(),
                    crate::domain::AccountOrigin::BorrowedNative
                );
                assert!(
                    !serde_json::to_string(&tx.document)
                        .unwrap()
                        .contains("fixture-first")
                );
                tx.commit().unwrap();
                let adapter = super::managed(&vault, &account);
                let context = http::fixture::context();
                let before = adapter.cache_identity(&context).await.unwrap();
                let changed = path.clone();
                let (endpoint, server) = http::fixture::server_status_with_action(
                    vec![(
                        status,
                        serde_json::json!({"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":50}}}),
                    )],
                    move |_| {
                        if rotate {
                            std::fs::write(&changed, b"windsurf_api_key = 'fixture-second'\n")
                                .unwrap();
                        }
                    },
                )
                .await;
                let reader = ManagedProvider {
                    factory_oauth: false,
                    origin: account.origin(),
                    label: account.label.clone(),
                    operations: Arc::new(HttpQuota(endpoint)),
                    vault: vault.clone(),
                    id: id.clone(),
                    provider: Provider::Catalog("devin-desktop"),
                    provider_id: ProviderId("devin-desktop".into()),
                };
                let result = reader.fetch(&context).await;
                if status == 401 || status == 403 {
                    assert!(matches!(result, Err(ProviderError::OwnerRefreshRequired)));
                } else if rotate {
                    assert!(matches!(result, Err(ProviderError::Transient)));
                } else {
                    assert!(result.is_ok());
                }
                let requests = server.await.unwrap();
                assert_eq!(requests.len(), 1);
                assert!(requests[0].starts_with("POST ") && requests[0].contains("fixture-first"));
                if rotate {
                    assert_ne!(adapter.cache_identity(&context).await.unwrap(), before);
                } else {
                    assert_eq!(std::fs::read(&path).unwrap(), original);
                }
                patch(vault, id, None, None, Some(false)).await.unwrap();
                assert!(adapter.cache_identity(&context).await.is_none());
                assert!(matches!(
                    adapter.fetch(&context).await,
                    Err(ProviderError::SourceDisabled)
                ));
                std::fs::remove_dir_all(dir).unwrap();
            }
        }
    }
    #[tokio::test]
    async fn factory_native_http_fences_rotation_disable_and_owner_refresh() {
        struct HttpQuota(String);
        impl Operations for HttpQuota {
            fn quota<'a>(
                &'a self,
                c: &'a ProviderContext,
                p: Provider,
                k: &'a Credential,
            ) -> OperationFuture<'a, ProviderUsage> {
                Box::pin(validate_with_endpoint(c, p, k, Some(&self.0)))
            }
            fn refresh<'a>(
                &'a self,
                _: &'a ProviderContext,
                _: &'a Credential,
            ) -> OperationFuture<'a, Credential> {
                panic!("borrowed credentials must never refresh")
            }
        }
        for status in [200, 401, 403] {
            for rotate in [false, true] {
                let dir = std::env::temp_dir().join(random_string().unwrap());
                std::fs::create_dir(&dir).unwrap();
                let path = dir.join("auth.encrypted");
                let original = br#"{"access_token":"fixture-first","refresh_token":"owner-only"}"#;
                std::fs::write(&path, original).unwrap();
                let credential = Credential::FactoryNative {
                    source: super::super::sources::FactoryNativeReference {
                        directory: dir.clone(),
                        location: super::super::sources::FactoryLocation::Legacy,
                    },
                };
                let vault = Vault::new(Arc::new(Memory::default()), dir.join("lock"));
                let mut tx = vault.begin().unwrap();
                let id = tx
                    .document
                    .add(
                        Provider::Factory,
                        "Fixture",
                        "source".into(),
                        credential.clone(),
                    )
                    .unwrap();
                let account = tx.document.accounts[0].clone();
                assert_eq!(
                    account.origin(),
                    crate::domain::AccountOrigin::BorrowedNative
                );
                assert!(
                    !serde_json::to_string(&tx.document)
                        .unwrap()
                        .contains("owner-only")
                );
                tx.commit().unwrap();
                let adapter = super::managed(&vault, &account);
                let context = http::fixture::context();
                let before = adapter.cache_identity(&context).await.unwrap();
                let changed = path.clone();
                let (endpoint, server) = http::fixture::server_status_with_action(
                    vec![(
                        status,
                        serde_json::json!({"usesTokenRateLimitsBilling":false}),
                    )],
                    move |_| {
                        if rotate {
                            std::fs::write(&changed, br#"{"access_token":"fixture-second"}"#)
                                .unwrap();
                        }
                    },
                )
                .await;
                let reader = ManagedProvider {
                    factory_oauth: false,
                    origin: account.origin(),
                    label: account.label.clone(),
                    operations: Arc::new(HttpQuota(endpoint)),
                    vault: vault.clone(),
                    id: id.clone(),
                    provider: Provider::Factory,
                    provider_id: ProviderId("factory".into()),
                };
                let result = reader.fetch(&context).await;
                if status == 401 {
                    assert!(matches!(result, Err(ProviderError::OwnerRefreshRequired)));
                } else if status == 403 {
                    assert!(matches!(result, Err(ProviderError::Authentication)));
                } else if rotate {
                    assert!(matches!(result, Err(ProviderError::Transient)));
                } else {
                    assert!(result.is_ok());
                }
                let requests = server.await.unwrap();
                assert_eq!(requests.len(), 1);
                assert!(
                    requests[0].starts_with("GET ") && requests[0].contains("Bearer fixture-first")
                );
                assert!(!requests[0].contains("owner-only"));
                if rotate {
                    assert_ne!(adapter.cache_identity(&context).await.unwrap(), before);
                } else {
                    assert_eq!(std::fs::read(&path).unwrap(), original);
                }
                patch(vault, id, None, None, Some(false)).await.unwrap();
                assert!(adapter.cache_identity(&context).await.is_none());
                assert!(matches!(
                    adapter.fetch(&context).await,
                    Err(ProviderError::SourceDisabled)
                ));
                std::fs::remove_dir_all(dir).unwrap();
            }
        }
    }
    #[tokio::test]
    async fn copilot_native_http_fences_rotation_and_disable() {
        for rotate in [false, true] {
            let dir = std::env::temp_dir().join(random_string().unwrap());
            std::fs::create_dir(&dir).unwrap();
            let path = dir.join("apps.json");
            let original = br#"{"github.com:fixture":{"oauth_token":"native-first-fixture","refresh_token":"owner-only"},"github.com:other":{"oauth_token":"unselected"}}"#;
            std::fs::write(&path, original).unwrap();
            let credential = Credential::CopilotNative {
                source: super::super::sources::CopilotNativeReference {
                    location: super::super::sources::CopilotLocation::Apps,
                    path: Some(path.clone()),
                    entry_key: "github.com:fixture".into(),
                },
            };
            let provider = Provider::Catalog("copilot");
            let vault = Vault::new(Arc::new(Memory::default()), dir.join("lock"));
            let mut tx = vault.begin().unwrap();
            let id = tx
                .document
                .add(provider, "Fixture", "source".into(), credential.clone())
                .unwrap();
            let account = tx.document.accounts[0].clone();
            assert_eq!(
                account.origin(),
                crate::domain::AccountOrigin::BorrowedNative
            );
            let stored = serde_json::to_string(&tx.document).unwrap();
            assert!(!stored.contains("owner-only") && !stored.contains("native-first-fixture"));
            tx.commit().unwrap();
            let adapter = super::managed(&vault, &account);
            let context = http::fixture::context();
            let before = adapter.cache_identity(&context).await.unwrap();
            let changed = path.clone();
            let (endpoint, server) = http::fixture::server_status_with_action(vec![(200, serde_json::json!({"quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":250,"unlimited":false}}}))], move |_| {
                if rotate { std::fs::write(&changed, br#"{"github.com:fixture":{"oauth_token":"native-second-fixture"}}"#).unwrap(); }
            }).await;
            let result =
                validate_with_endpoint(&context, provider, &credential, Some(&endpoint)).await;
            if rotate {
                assert!(matches!(result, Err(AccountError::Busy)));
                assert_ne!(adapter.cache_identity(&context).await.unwrap(), before);
            } else {
                assert!(result.is_ok());
                assert_eq!(std::fs::read(&path).unwrap(), original);
            }
            let requests = server.await.unwrap();
            assert_eq!(requests.len(), 1);
            assert!(requests[0].starts_with("GET "));
            assert!(requests[0].contains("native-first-fixture"));
            assert!(!requests[0].contains("owner-only") && !requests[0].contains("unselected"));
            let mut tx = vault.begin().unwrap();
            tx.document.patch(&id, None, None, Some(false)).unwrap();
            tx.commit().unwrap();
            assert!(adapter.cache_identity(&context).await.is_none());
            std::fs::remove_file(&path).unwrap();
            assert!(credential.resolve_reference(provider).await.is_err());
            std::fs::remove_dir_all(dir).unwrap();
        }
    }
    #[tokio::test]
    async fn kiro_native_fences_rotation_and_disable() {
        let dir = std::env::temp_dir().join(random_string().unwrap());
        let path = dir.join(".aws/sso/cache/kiro-auth-token.json");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let original = br#"{"accessToken":"kiro-first","refreshToken":"owner-only","clientId":"stable-client"}"#;
        std::fs::write(&path, original).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let credential = Credential::KiroNative {
            source: super::super::sources::KiroNativeReference { path: path.clone() },
        };
        let provider = Provider::Catalog("kiro");
        let vault = Vault::new(Arc::new(Memory::default()), dir.join("lock"));
        let mut tx = vault.begin().unwrap();
        let id = tx
            .document
            .add(provider, "Fixture", "source".into(), credential.clone())
            .unwrap();
        let account = tx.document.accounts[0].clone();
        assert!(
            !serde_json::to_string(&tx.document)
                .unwrap()
                .contains("owner-only")
        );
        tx.commit().unwrap();
        let adapter = super::managed(&vault, &account);
        let context = http::fixture::context();
        let before = adapter.cache_identity(&context).await.unwrap();
        let changed = path.clone();
        let (endpoint, server) = http::fixture::server_status_with_action(
            vec![(200, serde_json::json!({"usageBreakdownList":[{"resourceType":"CREDIT","usageLimit":100,"currentUsage":25}]}))],
            move |_| { std::fs::write(&changed, br#"{"accessToken":"kiro-second","refreshToken":"owner-only","clientId":"stable-client"}"#).unwrap(); },
        ).await;
        assert!(matches!(
            validate_with_endpoint(&context, provider, &credential, Some(&endpoint)).await,
            Err(AccountError::Busy)
        ));
        assert_ne!(adapter.cache_identity(&context).await.unwrap(), before);
        let requests = server.await.unwrap();
        assert_eq!(requests.len(), 1);
        assert!(requests[0].starts_with("GET "));
        assert!(requests[0].contains("Bearer kiro-first"));
        assert!(!requests[0].contains("owner-only"));
        let mut tx = vault.begin().unwrap();
        tx.document.patch(&id, None, None, Some(false)).unwrap();
        tx.commit().unwrap();
        assert!(adapter.cache_identity(&context).await.is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn claude_native_http_fences_rotation_and_disable() {
        for rotate in [false, true] {
            let dir = std::env::temp_dir().join(random_string().unwrap());
            std::fs::create_dir(&dir).unwrap();
            let path = dir.join("credentials.json");
            let original = br#"{"claudeAiOauth":{"accessToken":"native-first-fixture","refreshToken":"owner-only","scopes":["user:profile"]}}"#;
            std::fs::write(&path, original).unwrap();
            let credential = Credential::ClaudeNative {
                source: super::super::sources::ClaudeNativeReference {
                    location: super::super::sources::ClaudeLocation::CodeFile,
                    path: Some(path.clone()),
                },
            };
            let provider = Provider::Catalog("claude");
            let vault = Vault::new(Arc::new(Memory::default()), dir.join("lock"));
            let mut tx = vault.begin().unwrap();
            let id = tx
                .document
                .add(provider, "Fixture", "source".into(), credential.clone())
                .unwrap();
            let account = tx.document.accounts[0].clone();
            assert_eq!(
                account.origin(),
                crate::domain::AccountOrigin::BorrowedNative
            );
            assert!(
                !serde_json::to_string(&tx.document)
                    .unwrap()
                    .contains("owner-only")
            );
            tx.commit().unwrap();
            let adapter = super::managed(&vault, &account);
            let context = http::fixture::context();
            let before = adapter.cache_identity(&context).await.unwrap();
            let changed = path.clone();
            let (endpoint, server) = http::fixture::server_status_with_action(
                vec![(200, serde_json::json!({"five_hour":{"utilization":25}}))],
                move |_| {
                    if rotate {
                        std::fs::write(
                            &changed,
                            br#"{"claudeAiOauth":{"accessToken":"native-second-fixture"}}"#,
                        )
                        .unwrap();
                    }
                },
            )
            .await;
            let result =
                validate_with_endpoint(&context, provider, &credential, Some(&endpoint)).await;
            if rotate {
                assert!(matches!(result, Err(AccountError::Busy)));
                assert_ne!(adapter.cache_identity(&context).await.unwrap(), before);
            } else {
                assert!(result.is_ok());
                assert_eq!(std::fs::read(&path).unwrap(), original);
            }
            let requests = server.await.unwrap();
            assert_eq!(requests.len(), 1);
            assert!(requests[0].starts_with("GET "));
            assert!(requests[0].contains("Bearer native-first-fixture"));
            assert!(!requests[0].contains("owner-only"));
            let mut tx = vault.begin().unwrap();
            tx.document.patch(&id, None, None, Some(false)).unwrap();
            tx.commit().unwrap();
            assert!(adapter.cache_identity(&context).await.is_none());
            std::fs::remove_file(&path).unwrap();
            assert!(credential.resolve_reference(provider).await.is_err());
            std::fs::remove_dir_all(dir).unwrap();
        }
    }
    #[tokio::test]
    async fn codex_native_http_is_read_only_and_fences_source_and_account_changes() {
        for rotate in [false, true] {
            let dir = std::env::temp_dir().join(random_string().unwrap());
            std::fs::create_dir(&dir).unwrap();
            let path = dir.join("auth.json");
            let original = br#"{"tokens":{"access_token":"native-first-fixture","account_id":"fixture-account","refresh_token":"owner-only"}}"#;
            std::fs::write(&path, original).unwrap();
            let credential = Credential::CodexNative {
                source: super::super::sources::CodexNativeReference { path: path.clone() },
            };
            let vault = Vault::new(Arc::new(Memory::default()), dir.join("lock"));
            let mut tx = vault.begin().unwrap();
            let id = tx
                .document
                .add(
                    Provider::Codex,
                    "Fixture",
                    "source".into(),
                    credential.clone(),
                )
                .unwrap();
            let account = tx.document.accounts[0].clone();
            assert!(
                !serde_json::to_string(&tx.document)
                    .unwrap()
                    .contains("native-first-fixture")
            );
            tx.commit().unwrap();
            let adapter = super::managed(&vault, &account);
            let context = http::fixture::context();
            let before = adapter.cache_identity(&context).await.unwrap();
            let change_path = path.clone();
            let (endpoint, server) = http::fixture::server_status_with_action(vec![
                (200, serde_json::json!({"rate_limit":{"primary_window":{"used_percent":25,"limit_window_seconds":18000}}})),
                (200, serde_json::json!({})), (200, serde_json::json!({})),
            ], move |_| {
                if rotate {
                    std::fs::write(&change_path, br#"{"tokens":{"access_token":"native-second-fixture","account_id":"fixture-account"}}"#).unwrap();
                }
            }).await;
            let result =
                validate_with_endpoint(&context, Provider::Codex, &credential, Some(&endpoint))
                    .await;
            if rotate {
                assert!(matches!(result, Err(AccountError::Busy)));
                assert_ne!(adapter.cache_identity(&context).await.unwrap(), before);
            } else {
                let usage = result.unwrap();
                assert_eq!(usage.account.id, "fixture-account");
                assert_eq!(std::fs::read(&path).unwrap(), original);
                let managed = ManagedProvider {
                    factory_oauth: false,
                    origin: account.origin(),
                    label: account.label.clone(),
                    operations: Arc::new(Network),
                    vault: vault.clone(),
                    id: id.clone(),
                    provider: Provider::Codex,
                    provider_id: Provider::Codex.adapter().id(),
                };
                let mut tx = vault.begin().unwrap();
                tx.document.remove(&id).unwrap();
                tx.commit().unwrap();
                assert!(matches!(
                    managed.verify_current(&credential, usage).await,
                    Err(AccountError::NotFound)
                ));
            }
            let requests = server.await.unwrap();
            assert_eq!(requests.len(), 3);
            for request in requests {
                assert!(request.starts_with("GET "));
                assert!(request.contains("Bearer native-first-fixture"));
                assert!(
                    request
                        .to_ascii_lowercase()
                        .contains("chatgpt-account-id: fixture-account")
                );
                assert!(!request.contains("owner-only"));
            }
            if rotate {
                let mut tx = vault.begin().unwrap();
                tx.document.patch(&id, None, None, Some(false)).unwrap();
                tx.commit().unwrap();
            }
            assert!(adapter.cache_identity(&context).await.is_none());
            std::fs::remove_dir_all(dir).unwrap();
        }
    }
    #[tokio::test]
    async fn amp_native_resolution_reaches_http_and_rejects_rotation_during_response() {
        for rotate in [false, true] {
            let dir = std::env::temp_dir().join(random_string().unwrap());
            std::fs::create_dir(&dir).unwrap();
            let path = dir.join("secrets.json");
            std::fs::write(
                &path,
                br#"{"apiKey@https://ampcode.com/":"native-first-fixture"}"#,
            )
            .unwrap();
            let credential = Credential::AmpNative {
                source: super::super::sources::AmpNativeReference {
                    path: path.clone(),
                    enabled: true,
                },
            };
            let vault = Vault::new(Arc::new(Memory::default()), dir.join("lock"));
            let mut tx = vault.begin().unwrap();
            let id = tx
                .document
                .add(
                    Provider::Amp,
                    "Fixture",
                    "native-source".into(),
                    credential.clone(),
                )
                .unwrap();
            let account = tx.document.accounts[0].clone();
            tx.commit().unwrap();
            let adapter = super::managed(&vault, &account);
            let context = http::fixture::context();
            let before = adapter.cache_identity(&context).await.unwrap();
            let change_path = path.clone();
            let (endpoint, server) = http::fixture::server_status_with_action(vec![(200, serde_json::json!({"ok":true,"result":{"displayText":"Signed in as demo@example.com (Pro)\nAmp Free: 75% remaining today (resets daily)"}}))], move |_| {
                if rotate { std::fs::write(&change_path, br#"{"apiKey@https://ampcode.com/":"native-second-fixture"}"#).unwrap(); }
            }).await;
            let result =
                validate_with_endpoint(&context, Provider::Amp, &credential, Some(&endpoint)).await;
            if rotate {
                assert!(matches!(result, Err(AccountError::Busy)));
                assert_ne!(adapter.cache_identity(&context).await.unwrap(), before);
            } else {
                let usage = result.unwrap();
                assert_eq!(usage.account.id, "demo@example.com");
                assert_eq!(usage.windows[0].metric_id.as_deref(), Some("amp-free"));
            }
            let requests = server.await.unwrap();
            assert!(requests[0].contains("Bearer native-first-fixture"));
            let mut tx = vault.begin().unwrap();
            tx.document.patch(&id, None, None, Some(false)).unwrap();
            tx.commit().unwrap();
            assert!(adapter.cache_identity(&context).await.is_none());
            std::fs::remove_dir_all(dir).unwrap();
        }
    }
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn cursor_reference_scopes_requests_and_invalidates_changed_native_login() {
        for rotate in [false, true] {
            let dir = std::env::temp_dir().join(random_string().unwrap());
            std::fs::create_dir(&dir).unwrap();
            let path = dir.join("state.vscdb");
            let status = std::process::Command::new("/usr/bin/sqlite3").arg(&path).arg("CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','native-first-fixture'),('cursorAuth/cachedEmail','cursor@example.com'),('cursorAuth/stripeMembershipType','pro'),('cursorAuth/stripeSubscriptionStatus','active');").status().unwrap();
            assert!(status.success());
            let original = std::fs::read(&path).unwrap();
            let source = super::super::sources::CursorNativeReference { path: path.clone() };
            let credential = Credential::CursorNative {
                source: source.clone(),
            };
            assert!(matches!(
                credential.resolve_reference(Provider::Amp).await,
                Err(AccountError::Unsupported)
            ));
            let vault = Vault::new(Arc::new(Memory::default()), dir.join("lock"));
            let mut tx = vault.begin().unwrap();
            let id = tx
                .document
                .add(
                    Provider::Catalog("cursor"),
                    "Cursor",
                    source.identity().unwrap(),
                    credential.clone(),
                )
                .unwrap();
            let account = tx.document.accounts[0].clone();
            tx.commit().unwrap();
            let adapter = super::managed(&vault, &account);
            let context = http::fixture::context();
            let before = adapter.cache_identity(&context).await.unwrap();
            let changed_path = path.clone();
            let payload = serde_json::json!({"membershipType":"pro","isUnlimited":true,"planUsage":{"totalPercentUsed":20}});
            let (endpoint, server) = http::fixture::server_status_with_action(vec![(200,payload.clone()),(200,payload)], move |_| {
                if rotate {
                    assert!(std::process::Command::new("/usr/bin/sqlite3").arg(&changed_path).arg("UPDATE ItemTable SET value='native-second-fixture' WHERE key='cursorAuth/accessToken';").status().unwrap().success());
                }
            }).await;
            let result = validate_with_endpoint(
                &context,
                Provider::Catalog("cursor"),
                &credential,
                Some(&endpoint),
            )
            .await;
            if rotate {
                assert!(matches!(result, Err(AccountError::Busy)));
                assert_ne!(adapter.cache_identity(&context).await.unwrap(), before);
            } else {
                let usage = result.unwrap();
                assert_eq!(usage.account.label, "cursor@example.com");
                assert_eq!(usage.account.subscription_status.as_deref(), Some("active"));
                assert_eq!(original, std::fs::read(&path).unwrap());
                let encoded = serde_json::to_string(&usage).unwrap();
                assert!(!encoded.contains("native-first-fixture"));
            }
            for request in server.await.unwrap() {
                assert!(
                    request
                        .to_ascii_lowercase()
                        .contains("authorization: bearer native-first-fixture")
                );
                assert!(
                    !request
                        .lines()
                        .next()
                        .unwrap()
                        .contains("native-first-fixture")
                );
            }
            let mut tx = vault.begin().unwrap();
            tx.document.patch(&id, None, None, Some(false)).unwrap();
            assert_eq!(
                tx.document.accounts[0].origin(),
                super::super::AccountOrigin::BorrowedNative
            );
            assert!(
                !serde_json::to_string(&tx.document)
                    .unwrap()
                    .contains("native-first-fixture")
            );
            tx.commit().unwrap();
            assert!(adapter.cache_identity(&context).await.is_none());
            assert_eq!(
                adapter.fetch(&context).await.unwrap_err(),
                ProviderError::SourceDisabled
            );
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    #[tokio::test]
    async fn grok_references_fence_rotation_and_keep_entries_separate() {
        for rotate in [false, true] {
            let dir = std::env::temp_dir().join(random_string().unwrap());
            std::fs::create_dir(&dir).unwrap();
            let path = dir.join("auth.json");
            let data = serde_json::json!({
                "https://auth.x.ai::first": {"key":"fixture-first", "expires_at":"2099-01-01T00:00:00Z"},
                "https://auth.x.ai::second": {"key":"fixture-second", "expires_at":"2099-01-01T00:00:00Z"}
            });
            std::fs::write(&path, data.to_string()).unwrap();
            let source = super::super::sources::GrokNativeReference {
                path: path.clone(),
                entry_key: "https://auth.x.ai::first".into(),
            };
            let mut second = source.clone();
            second.entry_key = "https://auth.x.ai::second".into();
            assert_ne!(source.identity().unwrap(), second.identity().unwrap());
            assert!(
                source.resolve().await.unwrap().credentials
                    != second.resolve().await.unwrap().credentials
            );
            let credential = Credential::GrokNative {
                source: source.clone(),
            };
            let vault = Vault::new(Arc::new(Memory::default()), dir.join("lock"));
            let mut tx = vault.begin().unwrap();
            let id = tx
                .document
                .add(
                    Provider::Catalog("grok"),
                    "First",
                    source.identity().unwrap(),
                    credential.clone(),
                )
                .unwrap();
            let account = tx.document.accounts[0].clone();
            tx.commit().unwrap();
            let adapter = super::managed(&vault, &account);
            let context = http::fixture::context();
            let before = adapter.cache_identity(&context).await.unwrap();
            let changed = path.clone();
            let original = std::fs::read(&path).unwrap();
            let (endpoint, server) = http::fixture::server_status_with_action(
                vec![(200, serde_json::json!({"config":{"creditUsagePercent":20}}))],
                move |_| {
                    if rotate {
                        let mut data = data.clone();
                        data["https://auth.x.ai::first"]["key"] = "fixture-rotated".into();
                        std::fs::write(&changed, data.to_string()).unwrap();
                    }
                },
            )
            .await;
            let result = validate_with_endpoint(
                &context,
                Provider::Catalog("grok"),
                &credential,
                Some(&endpoint),
            )
            .await;
            if rotate {
                assert!(matches!(result, Err(AccountError::Busy)));
                assert_ne!(adapter.cache_identity(&context).await.unwrap(), before);
            } else {
                assert!(result.is_ok());
                assert_eq!(original, std::fs::read(&path).unwrap());
            }
            assert!(server.await.unwrap()[0].contains("Bearer fixture-first"));
            let mut tx = vault.begin().unwrap();
            assert!(
                !serde_json::to_string(&tx.document)
                    .unwrap()
                    .contains("fixture-first")
            );
            tx.document.patch(&id, None, None, Some(false)).unwrap();
            tx.commit().unwrap();
            assert!(adapter.cache_identity(&context).await.is_none());
            assert_eq!(
                adapter.fetch(&context).await.unwrap_err(),
                ProviderError::SourceDisabled
            );
            std::fs::remove_file(&path).unwrap();
            assert!(source.resolve().await.is_err());
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    #[tokio::test]
    async fn credential_group_keeps_last_success_and_reports_later_key_failure() {
        let (endpoint, server) = http::fixture::server_status(vec![
            (200, serde_json::json!({"ok":true,"result":{"displayText":"Signed in as first@example.com\nAmp Free: 20% remaining"}})),
            (200, serde_json::json!({"ok":true,"result":{"displayText":"Signed in as last@example.com\nAmp Free: 80% remaining"}})),
            (401, serde_json::json!({"error":"fixture"})),
        ]).await;
        let credentials = ["first", "last", "rejected"].map(|token| Credential::ApiKey {
            token: token.into(),
            region: None,
            organization: None,
        });
        let result = validate_credentials(
            &http::fixture::context(),
            Provider::Amp,
            &credentials,
            Some(&endpoint),
        )
        .await
        .unwrap();
        assert_eq!(result.account.id, "last@example.com");
        assert_eq!(result.diagnostics.len(), 1);
        assert_eq!(result.diagnostics[0].source, "amp_key_3");
        assert_eq!(server.await.unwrap().len(), 3);
    }
    #[tokio::test]
    async fn group_retains_success_when_a_later_key_exceeds_collector_budget() {
        struct GroupFixture(String);
        impl ProviderAdapter for GroupFixture {
            fn id(&self) -> ProviderId {
                ProviderId("amp".into())
            }
            fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
                Box::pin(async move {
                    let credentials = ["first", "slow"].map(|token| Credential::ApiKey {
                        token: token.into(),
                        region: None,
                        organization: None,
                    });
                    validate_credentials(context, Provider::Amp, &credentials, Some(&self.0))
                        .await
                        .map_err(|e| match e {
                            AccountError::Provider(e) => e,
                            _ => ProviderError::Internal,
                        })
                })
            }
        }
        let response = serde_json::json!({"ok":true,"result":{"displayText":"Signed in as demo@example.com\nAmp Free: 70% remaining"}});
        let (endpoint, server) = http::fixture::server_status_with_async_action(
            vec![(200, response.clone()), (200, response)],
            |index| async move {
                if index == 1 {
                    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                }
            },
        )
        .await;
        let report = Collector {
            context: http::fixture::context(),
        }
        .collect(CollectRequest {
            providers: vec![Arc::new(GroupFixture(endpoint))],
            timeout: std::time::Duration::from_millis(600),
            cancellation: Cancellation::default(),
        })
        .await;
        server.abort();
        let _ = server.await;
        assert_eq!(report.providers.len(), 1);
        assert_eq!(report.providers[0].account.id, "demo@example.com");
        assert_eq!(report.failures[0].code, ProviderError::Timeout);
        assert_eq!(report.providers[0].diagnostics[0].source, "amp_key_2");
    }
    struct MutateDuringQuota {
        vault: Vault,
        id: String,
        remove: bool,
    }
    impl Operations for MutateDuringQuota {
        fn quota<'a>(
            &'a self,
            context: &'a ProviderContext,
            _: Provider,
            _: &'a Credential,
        ) -> OperationFuture<'a, ProviderUsage> {
            Box::pin(async move {
                let mut tx = self.vault.begin()?;
                if self.remove {
                    tx.document.remove(&self.id)?;
                } else {
                    tx.document
                        .accounts
                        .iter_mut()
                        .find(|a| a.id == self.id)
                        .unwrap()
                        .credential = Credential::ApiKey {
                        token: "rotated-fixture".into(),
                        region: None,
                        organization: None,
                    };
                }
                tx.commit()?;
                Ok(MockProvider.fetch(context).await?)
            })
        }
        fn refresh<'a>(
            &'a self,
            _: &'a ProviderContext,
            _: &'a Credential,
        ) -> OperationFuture<'a, Credential> {
            panic!("borrowed source must never refresh")
        }
    }
    #[tokio::test]
    async fn borrowed_results_are_rejected_after_account_removal_or_replacement() {
        for remove in [true, false] {
            let path = std::env::temp_dir().join(random_string().unwrap());
            let vault = Vault::new(Arc::new(Memory::default()), path.join("lock"));
            let source = super::super::sources::CustomProviderReference {
                domain: super::super::sources::QuotioDomain::Production,
                record_id: "01234567-89ab-cdef-0123-456789abcdef".into(),
            };
            let mut tx = vault.begin().unwrap();
            let id = tx
                .document
                .add(
                    Provider::Catalog("clinepass"),
                    "Fixture",
                    source.identity().unwrap(),
                    Credential::QuotioCustomProvider { source },
                )
                .unwrap();
            tx.commit().unwrap();
            let adapter = ManagedProvider {
                factory_oauth: false,
                origin: super::super::AccountOrigin::BorrowedProxy,
                label: "Fixture".into(),
                operations: Arc::new(MutateDuringQuota {
                    vault: vault.clone(),
                    id: id.clone(),
                    remove,
                }),
                vault,
                id,
                provider: Provider::Catalog("clinepass"),
                provider_id: ProviderId("clinepass".into()),
            };
            let result = adapter.read(&http::fixture::context()).await;
            assert!(matches!(
                result,
                Err(AccountError::NotFound | AccountError::Busy)
            ));
            cleanup(path);
        }
    }
    fn setup(
        expires_at: i64,
        delay: bool,
        refresh_fails: bool,
        quota_fails: bool,
    ) -> (Vault, Arc<Fake>, String, String, std::path::PathBuf) {
        let memory = Arc::new(Memory::default());
        let path = std::env::temp_dir().join(random_string().unwrap());
        let vault = Vault::new(memory.clone(), path.join("lock"));
        let mut tx = vault.begin().unwrap();
        let codex = tx
            .document
            .add(
                Provider::Codex,
                "Codex",
                "codex-id".into(),
                Credential::CodexOAuth {
                    access_token: "old".into(),
                    refresh_token: "refresh".into(),
                    id_token: "unused".into(),
                    account_id: "codex-id".into(),
                    email: "demo@example.com".into(),
                    expires_at,
                },
            )
            .unwrap();
        let amp = tx
            .document
            .add(
                Provider::Amp,
                "Amp",
                "amp-id".into(),
                Credential::ApiKey {
                    token: "api-key".into(),
                    region: None,
                    organization: None,
                },
            )
            .unwrap();
        tx.commit().unwrap();
        let fake = Arc::new(Fake {
            memory,
            started: tokio::sync::Notify::new(),
            delay,
            refresh_fails,
            quota_fails,
            refreshes: AtomicUsize::new(0),
            quota_calls: AtomicUsize::new(0),
            wait_for_refresh: std::sync::atomic::AtomicBool::new(false),
            release_refresh: tokio::sync::Notify::new(),
            stall_first_refresh: std::sync::atomic::AtomicBool::new(false),
        });
        (vault, fake, codex, amp, path)
    }
    fn managed(
        vault: Vault,
        operations: Arc<Fake>,
        id: String,
        provider: Provider,
    ) -> ManagedProvider {
        ManagedProvider {
            factory_oauth: provider == Provider::Factory,
            origin: super::super::AccountOrigin::Owned,
            label: "Test account".into(),
            vault,
            operations,
            id,
            provider,
            provider_id: provider.adapter().id(),
        }
    }
    fn cleanup(path: std::path::PathBuf) {
        for entry in std::fs::read_dir(&path).unwrap() {
            std::fs::remove_file(entry.unwrap().path()).unwrap();
        }
        std::fs::remove_dir(path).unwrap();
    }
    fn factory_fixture(token: &str, org: &str) -> Credential {
        Credential::FactoryOAuth {
            access_token: "fixture".into(),
            refresh_token: token.into(),
            organization_id: Some(org.into()),
            expires_at: 0,
            refresh_pending: false,
        }
    }
    #[tokio::test]
    async fn factory_registration_serializes_refresh_ownership_across_organizations() {
        let (vault, _, _, _, path) = setup(0, false, false, false);
        let (a, b) = tokio::join!(
            add(
                vault.clone(),
                Provider::Factory,
                "A".into(),
                factory_fixture("shared", "A"),
                "old-org-A-identity".into()
            ),
            add(
                vault.clone(),
                Provider::Factory,
                "B".into(),
                factory_fixture("shared", "B"),
                "old-org-B-identity".into()
            ),
        );
        assert_eq!(usize::from(a.is_ok()) + usize::from(b.is_ok()), 1);
        assert!(matches!(
            if a.is_err() { a } else { b },
            Err(AccountError::Duplicate)
        ));
        cleanup(path);
    }
    #[tokio::test]
    async fn factory_registration_rejects_pending_and_rotated_token_lineage() {
        let (vault, _, _, _, path) = setup(0, false, false, false);
        let original = factory_fixture("original", "A");
        let id = add(
            vault.clone(),
            Provider::Factory,
            "A".into(),
            original.clone(),
            "legacy-identity".into(),
        )
        .await
        .unwrap();
        for pending in [false, true] {
            let mut tx = vault.begin().unwrap();
            let account = tx
                .document
                .accounts
                .iter_mut()
                .find(|a| a.id == id)
                .unwrap();
            if let Credential::FactoryOAuth {
                refresh_pending, ..
            } = &mut account.credential
            {
                *refresh_pending = pending;
            }
            tx.commit().unwrap();
            assert!(matches!(
                add(
                    vault.clone(),
                    Provider::Factory,
                    "B".into(),
                    factory_fixture("original", "B"),
                    "different".into()
                )
                .await,
                Err(AccountError::Duplicate)
            ));
        }
        let rotated = factory_fixture("rotated", "A");
        let mut tx = vault.begin().unwrap();
        tx.document.reserve_factory_refresh(&id, &rotated).unwrap();
        tx.document
            .accounts
            .iter_mut()
            .find(|a| a.id == id)
            .unwrap()
            .credential = rotated;
        tx.commit().unwrap();
        for token in ["original", "rotated"] {
            assert!(matches!(
                add(
                    vault.clone(),
                    Provider::Factory,
                    "B".into(),
                    factory_fixture(token, "B"),
                    "different".into()
                )
                .await,
                Err(AccountError::Duplicate)
            ));
        }
        let mut tx = vault.begin().unwrap();
        tx.document.remove(&id).unwrap();
        tx.commit().unwrap();
        assert!(matches!(
            add(
                vault.clone(),
                Provider::Factory,
                "B".into(),
                original,
                "different".into()
            )
            .await,
            Err(AccountError::Duplicate)
        ));
        cleanup(path);
    }
    #[tokio::test]
    async fn copilot_owned_reads_never_refresh_or_rewrite_tokens() {
        let (vault, fake, id, _, path) = setup(0, false, false, true);
        let mut tx = vault.begin().unwrap();
        tx.document.accounts[0].provider = Provider::Catalog("copilot");
        let credential = Credential::CopilotOAuth {
            access_token: "fixture-token".into(),
            account_id: "42".into(),
            login: "fixture-login".into(),
        };
        tx.document.accounts[0].credential = credential.clone();
        tx.document.version = 6;
        tx.commit().unwrap();
        let adapter = managed(
            vault.clone(),
            fake.clone(),
            id,
            Provider::Catalog("copilot"),
        );
        assert!(adapter.read(&http::fixture::context()).await.is_err());
        assert_eq!(fake.refreshes.load(Ordering::SeqCst), 0);
        assert!(vault.begin().unwrap().document.accounts[0].credential == credential);
        cleanup(path);
    }
    fn antigravity_fixture(refresh: &str) -> Credential {
        Credential::AntigravityOAuth {
            access_token: "old".into(),
            refresh_token: refresh.into(),
            expires_at: 0,
            client_id: "fixture-client".into(),
            client_secret: "fixture-secret".into(),
            refresh_pending: false,
        }
    }
    #[tokio::test]
    async fn antigravity_lineage_survives_rotation_and_removal() {
        let (vault, fake, id, _, path) = setup(0, false, false, false);
        let original = antigravity_fixture("refresh");
        let mut tx = vault.begin().unwrap();
        tx.document.accounts[0].provider = Provider::Antigravity;
        tx.document.accounts[0].credential = original.clone();
        tx.document.reserve_factory_refresh(&id, &original).unwrap();
        tx.commit().unwrap();
        let adapter = managed(
            vault.clone(),
            fake.clone(),
            id.clone(),
            Provider::Antigravity,
        );
        assert!(adapter.read(&http::fixture::context()).await.is_ok());
        assert_eq!(fake.refreshes.load(Ordering::SeqCst), 1);
        let mut tx = vault.begin().unwrap();
        tx.document.remove(&id).unwrap();
        tx.commit().unwrap();
        let mut tx = vault.begin().unwrap();
        for token in ["refresh", "rotated"] {
            assert!(matches!(
                tx.document.add(
                    Provider::Antigravity,
                    "again",
                    "different".into(),
                    antigravity_fixture(token)
                ),
                Err(AccountError::Duplicate)
            ));
        }
        drop(tx);
        cleanup(path);
    }
    #[test]
    fn antigravity_scoping_rejects_expiry_and_isolates_credentials() {
        let context = http::fixture::context();
        let credential = Credential::AntigravityToken {
            access_token: "fixture".into(),
            expires_at: None,
        };
        let ctx = scoped(&context, Provider::Antigravity, &credential).unwrap();
        assert_eq!(
            ctx.credentials.get("ANTIGRAVITY_ACCESS_TOKEN").unwrap().0,
            "fixture"
        );
        assert!(ctx.credentials.get("ANTIGRAVITY_AUTH_FILE").is_none());
        assert!(scoped(&context, Provider::Codex, &credential).is_err());
        assert!(matches!(
            scoped(
                &context,
                Provider::Antigravity,
                &antigravity_fixture("refresh")
            ),
            Err(AccountError::Provider(ProviderError::Authentication))
        ));
        let mut pending = antigravity_fixture("refresh");
        if let Credential::AntigravityOAuth {
            refresh_pending, ..
        } = &mut pending
        {
            *refresh_pending = true;
        }
        assert!(matches!(
            scoped(&context, Provider::Antigravity, &pending),
            Err(AccountError::CommitUncertain)
        ));
    }
    fn kiro_fixture(refresh: &str) -> Credential {
        Credential::KiroOAuth {
            access_token: "old".into(),
            refresh_token: refresh.into(),
            expires_at: 0,
            auth_method: super::super::KiroAuthMethod::Social,
            region: "us-east-1".into(),
            profile_arn: None,
            client_id: None,
            client_secret: None,
            machine: "stable-machine".into(),
            refresh_pending: false,
        }
    }
    #[tokio::test]
    async fn removed_or_replaced_accounts_keep_late_refresh_reservations() {
        for provider in [
            Provider::Factory,
            Provider::Catalog("claude"),
            Provider::Catalog("kiro"),
            Provider::Antigravity,
            Provider::Catalog("grok"),
        ] {
            for replace in [false, true] {
                let (vault, fake, id, _, path) = setup(0, false, false, false);
                let original = match provider {
                    Provider::Factory => factory_fixture("refresh", "org"),
                    Provider::Antigravity => antigravity_fixture("refresh"),
                    Provider::Catalog("kiro") => kiro_fixture("refresh"),
                    Provider::Catalog("claude") => Credential::ClaudeOAuth {
                        access_token: "old".into(),
                        refresh_token: "refresh".into(),
                        account_id: "id".into(),
                        email: "demo@example.com".into(),
                        expires_at: 0,
                        refresh_pending: false,
                    },
                    _ => Credential::GrokOAuth {
                        access_token: "old".into(),
                        refresh_token: "refresh".into(),
                        expires_at: 0,
                        refresh_pending: false,
                    },
                };
                let mut tx = vault.begin().unwrap();
                tx.document.accounts[0].provider = provider;
                tx.document.accounts[0].credential = original.clone();
                tx.document.reserve_factory_refresh(&id, &original).unwrap();
                tx.commit().unwrap();
                fake.wait_for_refresh.store(true, Ordering::SeqCst);
                let adapter = managed(vault.clone(), fake.clone(), id.clone(), provider);
                let running =
                    tokio::spawn(async move { adapter.read(&http::fixture::context()).await });
                fake.started.notified().await;
                let intent = MutationIntent::new("remove-or-replace", "fixture".into()).unwrap();
                let changed_id = id.clone();
                let replacement = original.clone();
                commit_once(vault.clone(), intent.clone(), move |doc| {
                    if replace {
                        doc.accounts
                            .iter_mut()
                            .find(|a| a.id == changed_id)
                            .unwrap()
                            .credential = replacement;
                    } else {
                        doc.remove(&changed_id)?;
                    }
                    Ok(changed_id)
                })
                .await
                .unwrap();
                fake.release_refresh.notify_one();
                let result = running.await.unwrap();
                assert!(if replace {
                    matches!(result, Err(AccountError::Busy))
                } else {
                    matches!(result, Err(AccountError::NotFound))
                });
                assert_eq!(fake.quota_calls.load(Ordering::SeqCst), 0);
                let reopened = Vault::new(fake.memory.clone(), path.join("lock"));
                assert_eq!(
                    mutation_receipt(reopened.clone(), &intent).await.unwrap(),
                    Some(id.clone())
                );
                let mut tx = reopened.begin().unwrap();
                if replace {
                    assert!(
                        tx.document
                            .accounts
                            .iter()
                            .find(|a| a.id == id)
                            .unwrap()
                            .credential
                            == original
                    );
                } else {
                    assert!(!tx.document.accounts.iter().any(|a| a.id == id));
                }
                let mut rotated = original.clone();
                match &mut rotated {
                    Credential::FactoryOAuth { refresh_token, .. }
                    | Credential::ClaudeOAuth { refresh_token, .. }
                    | Credential::KiroOAuth { refresh_token, .. }
                    | Credential::AntigravityOAuth { refresh_token, .. }
                    | Credential::GrokOAuth { refresh_token, .. } => {
                        *refresh_token = "rotated".into()
                    }
                    _ => unreachable!(),
                }
                // Grok has a replay fence but no persistent lineage reservation.
                if provider != Provider::Catalog("grok") {
                    assert!(matches!(
                        tx.document
                            .add(provider, "again", "different".into(), rotated),
                        Err(AccountError::Duplicate)
                    ));
                }
                drop(tx);
                cleanup(path);
            }
        }
    }

    #[tokio::test]
    async fn kiro_http_refresh_after_deletion_keeps_returned_token_reserved() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        struct KiroHttp(String);
        impl Operations for KiroHttp {
            fn quota<'a>(
                &'a self,
                _: &'a ProviderContext,
                _: Provider,
                _: &'a Credential,
            ) -> OperationFuture<'a, ProviderUsage> {
                panic!("deleted account must not start quota")
            }
            fn refresh<'a>(
                &'a self,
                c: &'a ProviderContext,
                k: &'a Credential,
            ) -> OperationFuture<'a, Credential> {
                Box::pin(crate::providers::catalog::oauth_cloud::refresh_kiro_at(
                    c,
                    k,
                    Some(&self.0),
                ))
            }
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}/refreshToken", listener.local_addr().unwrap());
        let (started, pending) = tokio::sync::oneshot::channel();
        let (resume, released) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            loop {
                let mut buffer = [0; 1024];
                let n = stream.read(&mut buffer).await.unwrap();
                assert!(n > 0);
                request.extend_from_slice(&buffer[..n]);
                if request.ends_with(b"{\"refreshToken\":\"refresh\"}") {
                    break;
                }
            }
            started.send(()).unwrap();
            released.await.unwrap();
            let body = r#"{"accessToken":"new","refreshToken":"rotated","expiresIn":3600}"#;
            stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
        });
        let (vault, fake, id, _, path) = setup(0, false, false, false);
        let original = kiro_fixture("refresh");
        let mut tx = vault.begin().unwrap();
        tx.document.accounts[0].provider = Provider::Catalog("kiro");
        tx.document.accounts[0].credential = original.clone();
        tx.document.reserve_factory_refresh(&id, &original).unwrap();
        tx.commit().unwrap();
        let mut adapter = managed(
            vault.clone(),
            fake.clone(),
            id.clone(),
            Provider::Catalog("kiro"),
        );
        adapter.operations = Arc::new(KiroHttp(endpoint));
        let running = tokio::spawn(async move { adapter.read(&http::fixture::context()).await });
        pending.await.unwrap();
        let intent = MutationIntent::new("delete-http", "fixture".into()).unwrap();
        let removed = id.clone();
        commit_once(vault.clone(), intent.clone(), move |doc| {
            doc.remove(&removed)?;
            Ok(removed)
        })
        .await
        .unwrap();
        resume.send(()).unwrap();
        assert!(matches!(
            running.await.unwrap(),
            Err(AccountError::NotFound)
        ));
        server.await.unwrap();
        let reopened = Vault::new(fake.memory.clone(), path.join("lock"));
        assert_eq!(
            mutation_receipt(reopened.clone(), &intent).await.unwrap(),
            Some(id.clone())
        );
        let mut tx = reopened.begin().unwrap();
        assert!(!tx.document.accounts.iter().any(|a| a.id == id));
        assert!(matches!(
            tx.document.add(
                Provider::Catalog("kiro"),
                "again",
                "different".into(),
                kiro_fixture("rotated")
            ),
            Err(AccountError::Duplicate)
        ));
        drop(tx);
        cleanup(path);
    }

    #[tokio::test]
    async fn kiro_lineage_survives_rotation_restart_and_removal() {
        let (vault, fake, id, _, path) = setup(0, false, false, false);
        let original = kiro_fixture("refresh");
        let mut tx = vault.begin().unwrap();
        tx.document.accounts[0].provider = Provider::Catalog("kiro");
        tx.document.accounts[0].credential = original.clone();
        tx.document.reserve_factory_refresh(&id, &original).unwrap();
        tx.commit().unwrap();
        let adapter = managed(
            vault.clone(),
            fake.clone(),
            id.clone(),
            Provider::Catalog("kiro"),
        );
        assert!(adapter.read(&http::fixture::context()).await.is_ok());
        assert_eq!(fake.refreshes.load(Ordering::SeqCst), 1);
        let mut tx = vault.begin().unwrap();
        tx.document.remove(&id).unwrap();
        tx.commit().unwrap();
        let mut tx = vault.begin().unwrap();
        for token in ["refresh", "rotated"] {
            assert!(matches!(
                tx.document.add(
                    Provider::Catalog("kiro"),
                    "again",
                    "different".into(),
                    kiro_fixture(token)
                ),
                Err(AccountError::Duplicate)
            ));
        }
        assert_eq!(tx.document.version, 7);
        drop(tx);
        cleanup(path);
    }
    #[tokio::test]
    async fn claude_refresh_fence_survives_failure_restart_and_removal() {
        for failure in [false, true] {
            let (vault, fake, id, _, path) = setup(0, false, failure, false);
            let original = Credential::ClaudeOAuth {
                access_token: "old".into(),
                refresh_token: "refresh".into(),
                account_id: "id".into(),
                email: "demo@example.com".into(),
                expires_at: 0,
                refresh_pending: false,
            };
            let mut tx = vault.begin().unwrap();
            tx.document.accounts[0].provider = Provider::Catalog("claude");
            tx.document.accounts[0].credential = original.clone();
            tx.document.reserve_factory_refresh(&id, &original).unwrap();
            tx.commit().unwrap();
            let adapter = managed(
                vault.clone(),
                fake.clone(),
                id.clone(),
                Provider::Catalog("claude"),
            );
            assert_eq!(
                adapter.read(&http::fixture::context()).await.is_ok(),
                !failure
            );
            let restarted = managed(
                vault.clone(),
                fake.clone(),
                id.clone(),
                Provider::Catalog("claude"),
            );
            if failure {
                assert!(matches!(
                    restarted.read(&http::fixture::context()).await,
                    Err(AccountError::CommitUncertain)
                ));
                assert!(
                    restarted
                        .cache_identity(&http::fixture::context())
                        .await
                        .is_none()
                );
            } else {
                assert!(restarted.read(&http::fixture::context()).await.is_ok());
            }
            assert_eq!(fake.refreshes.load(Ordering::SeqCst), 1);
            let mut tx = vault.begin().unwrap();
            tx.document.remove(&id).unwrap();
            assert_eq!(tx.document.version, 6);
            assert!(matches!(
                tx.document.add(
                    Provider::Catalog("claude"),
                    "again",
                    "again".into(),
                    original
                ),
                Err(AccountError::Duplicate)
            ));
            drop(tx);
            cleanup(path);
        }
    }
    #[test]
    fn factory_saved_api_keys_keep_idempotent_quota_reads() {
        let (vault, _, _, _, path) = setup(0, false, false, false);
        let account = Account {
            id: "fixture".into(),
            provider: Provider::Factory,
            label: "API key".into(),
            identity: "fixture".into(),
            active: true,
            enabled: true,
            credential: Credential::ApiKey {
                token: "fixture".into(),
                region: None,
                organization: None,
            },
        };
        assert!(super::managed(&vault, &account).idempotent());
        cleanup(path);
    }
    #[tokio::test]
    async fn factory_and_kiro_inflight_refresh_cancellation_and_disable_are_fenced() {
        for (provider, cancel) in [
            Provider::Factory,
            Provider::Catalog("kiro"),
            Provider::Antigravity,
        ]
        .into_iter()
        .flat_map(|p| [false, true].map(|cancel| (p, cancel)))
        {
            let (vault, fake, id, _, path) = setup(0, false, false, false);
            let mut tx = vault.begin().unwrap();
            tx.document.accounts[0].provider = provider;
            tx.document.accounts[0].credential = if provider == Provider::Factory {
                Credential::FactoryOAuth {
                    access_token: "old".into(),
                    refresh_token: "refresh".into(),
                    organization_id: None,
                    expires_at: 0,
                    refresh_pending: false,
                }
            } else if provider == Provider::Antigravity {
                antigravity_fixture("refresh")
            } else {
                kiro_fixture("refresh")
            };
            let credential = tx.document.accounts[0].credential.clone();
            tx.document
                .reserve_factory_refresh(&id, &credential)
                .unwrap();
            tx.commit().unwrap();
            fake.wait_for_refresh.store(true, Ordering::SeqCst);
            let adapter = managed(vault.clone(), fake.clone(), id.clone(), provider);
            let running =
                tokio::spawn(async move { adapter.read(&http::fixture::context()).await });
            fake.started.notified().await;
            let concurrent = managed(vault.clone(), fake.clone(), id.clone(), provider);
            assert!(matches!(
                concurrent.read(&http::fixture::context()).await,
                Err(AccountError::CommitUncertain)
            ));
            if cancel {
                running.abort();
                let _ = running.await;
            } else {
                patch(vault.clone(), id.clone(), None, None, Some(false))
                    .await
                    .unwrap();
                fake.release_refresh.notify_one();
                assert!(matches!(
                    running.await.unwrap(),
                    Err(AccountError::SourceDisabled)
                ));
            }
            assert_eq!(fake.refreshes.load(Ordering::SeqCst), 1);
            assert_eq!(fake.quota_calls.load(Ordering::SeqCst), 0);
            let tx = vault.begin().unwrap();
            assert!(
                matches!(&tx.document.accounts[0].credential, Credential::FactoryOAuth { refresh_pending, refresh_token, .. } | Credential::KiroOAuth { refresh_pending, refresh_token, .. } | Credential::AntigravityOAuth { refresh_pending, refresh_token, .. } if *refresh_pending == cancel && refresh_token == if cancel {"refresh"} else {"rotated"})
            );
            drop(tx);
            assert!(
                concurrent
                    .cache_identity(&http::fixture::context())
                    .await
                    .is_none()
            );
            cleanup(path);
        }
    }
    #[tokio::test]
    async fn factory_and_claude_rotation_and_uncertain_writes_never_replay() {
        struct FailingWrite {
            memory: Arc<Memory>,
            mode: u8,
        }
        impl Backend for FailingWrite {
            fn read(&self) -> Result<Option<Vec<u8>>, AccountError> {
                self.memory.read()
            }
            fn write(&self, bytes: &[u8]) -> Result<(), AccountError> {
                let rotated = String::from_utf8_lossy(bytes).contains("rotated");
                if (self.mode == 1 && !rotated) || (self.mode >= 2 && rotated) {
                    if self.mode == 3 {
                        self.memory.write(bytes)?;
                    }
                    return Err(AccountError::CommitUncertain);
                }
                self.memory.write(bytes)
            }
        }
        for (provider, mode) in [
            Provider::Factory,
            Provider::Catalog("claude"),
            Provider::Catalog("kiro"),
            Provider::Antigravity,
        ]
        .into_iter()
        .flat_map(|p| (0..=4).map(move |mode| (p, mode)))
        {
            let (vault, fake, id, _, path) = setup(0, false, mode == 4, true);
            let mut tx = vault.begin().unwrap();
            tx.document.accounts[0].provider = provider;
            tx.document.accounts[0].credential = if provider == Provider::Factory {
                Credential::FactoryOAuth {
                    access_token: "old".into(),
                    refresh_token: "refresh".into(),
                    organization_id: Some("org".into()),
                    expires_at: 0,
                    refresh_pending: false,
                }
            } else if provider == Provider::Antigravity {
                antigravity_fixture("refresh")
            } else if provider == Provider::Catalog("kiro") {
                kiro_fixture("refresh")
            } else {
                Credential::ClaudeOAuth {
                    access_token: "old".into(),
                    refresh_token: "refresh".into(),
                    account_id: "id".into(),
                    email: "demo@example.com".into(),
                    expires_at: 0,
                    refresh_pending: false,
                }
            };
            let credential = tx.document.accounts[0].credential.clone();
            tx.document
                .reserve_factory_refresh(&id, &credential)
                .unwrap();
            tx.commit().unwrap();
            let failing = Vault::new(
                Arc::new(FailingWrite {
                    memory: fake.memory.clone(),
                    mode,
                }),
                path.join("lock"),
            );
            let adapter = managed(failing, fake.clone(), id.clone(), provider);
            assert!(!adapter.idempotent());
            let context = http::fixture::context();
            assert!(adapter.read(&context).await.is_err());
            assert_eq!(
                fake.refreshes.load(Ordering::SeqCst),
                usize::from(mode != 1)
            );
            assert_eq!(
                fake.quota_calls.load(Ordering::SeqCst),
                usize::from(mode == 0)
            );
            if mode != 1 {
                let restarted = managed(
                    Vault::new(fake.memory.clone(), path.join("lock")),
                    fake.clone(),
                    id,
                    provider,
                );
                assert!(restarted.read(&context).await.is_err());
                assert_eq!(fake.refreshes.load(Ordering::SeqCst), 1);
                if mode == 2 || mode == 4 {
                    assert!(restarted.cache_identity(&context).await.is_none());
                }
            }
            cleanup(path);
        }
    }

    #[tokio::test]
    async fn grok_owned_rotation_persists_before_quota_and_uncertainty_blocks_replay() {
        for refresh_fails in [false, true] {
            let (vault, fake, id, _, path) = setup(0, true, refresh_fails, true);
            let mut tx = vault.begin().unwrap();
            let account = &mut tx.document.accounts[0];
            account.provider = Provider::Catalog("grok");
            account.credential = Credential::GrokOAuth {
                access_token: "old".into(),
                refresh_token: "refresh".into(),
                expires_at: 0,
                refresh_pending: false,
            };
            tx.commit().unwrap();
            let adapter = managed(
                vault.clone(),
                fake.clone(),
                id.clone(),
                Provider::Catalog("grok"),
            );
            assert!(!adapter.idempotent());
            let context = http::fixture::context();
            let (a, b) = tokio::join!(adapter.read(&context), adapter.read(&context));
            assert!(a.is_err() && b.is_err());
            assert_eq!(fake.refreshes.load(Ordering::SeqCst), 1);
            let tx = vault.begin().unwrap();
            assert!(
                matches!(&tx.document.accounts[0].credential, Credential::GrokOAuth { refresh_pending, refresh_token, .. } if *refresh_pending == refresh_fails && refresh_token == if refresh_fails {"refresh"} else {"rotated"})
            );
            drop(tx);
            let restarted = managed(
                Vault::new(fake.memory.clone(), path.join("lock")),
                fake.clone(),
                id,
                Provider::Catalog("grok"),
            );
            assert!(restarted.read(&context).await.is_err());
            assert_eq!(fake.refreshes.load(Ordering::SeqCst), 1);
            if refresh_fails {
                assert_eq!(fake.quota_calls.load(Ordering::SeqCst), 0);
                assert!(restarted.cache_identity(&context).await.is_none());
            }
            cleanup(path);
        }
    }

    #[tokio::test]
    async fn grok_uncertain_rotation_commit_never_replays_refresh_or_starts_quota() {
        struct Uncertain {
            memory: Arc<Memory>,
            persisted: bool,
        }
        impl Backend for Uncertain {
            fn read(&self) -> Result<Option<Vec<u8>>, AccountError> {
                self.memory.read()
            }
            fn write(&self, bytes: &[u8]) -> Result<(), AccountError> {
                if String::from_utf8_lossy(bytes).contains("rotated") {
                    if self.persisted {
                        self.memory.write(bytes)?;
                    }
                    return Err(AccountError::CommitUncertain);
                }
                self.memory.write(bytes)
            }
        }
        for persisted in [false, true] {
            let (vault, fake, id, _, path) = setup(0, false, false, false);
            let mut tx = vault.begin().unwrap();
            tx.document.accounts[0].provider = Provider::Catalog("grok");
            tx.document.accounts[0].credential = Credential::GrokOAuth {
                access_token: "old".into(),
                refresh_token: "refresh".into(),
                expires_at: 0,
                refresh_pending: false,
            };
            tx.commit().unwrap();
            let vault = Vault::new(
                Arc::new(Uncertain {
                    memory: fake.memory.clone(),
                    persisted,
                }),
                path.join("lock"),
            );
            let adapter = managed(vault, fake.clone(), id.clone(), Provider::Catalog("grok"));
            assert!(matches!(
                adapter.read(&http::fixture::context()).await,
                Err(AccountError::CommitUncertain)
            ));
            assert_eq!(fake.quota_calls.load(Ordering::SeqCst), 0);
            let restarted = managed(
                Vault::new(fake.memory.clone(), path.join("lock")),
                fake.clone(),
                id,
                Provider::Catalog("grok"),
            );
            assert_eq!(
                restarted.read(&http::fixture::context()).await.is_ok(),
                persisted
            );
            assert_eq!(fake.refreshes.load(Ordering::SeqCst), 1);
            cleanup(path);
        }
    }

    #[tokio::test]
    async fn disabled_owned_accounts_skip_quota_cache_and_refresh() {
        let (vault, fake, codex, amp, path) = setup(0, false, false, false);
        for (id, provider) in [(codex, Provider::Codex), (amp, Provider::Amp)] {
            let mut tx = vault.begin().unwrap();
            tx.document.patch(&id, None, None, Some(false)).unwrap();
            tx.commit().unwrap();
            let adapter = managed(vault.clone(), fake.clone(), id, provider);
            let context = http::fixture::context();
            assert!(adapter.cache_identity(&context).await.is_none());
            assert!(matches!(
                adapter.read(&context).await,
                Err(AccountError::SourceDisabled)
            ));
        }
        assert_eq!(fake.refreshes.load(Ordering::SeqCst), 0);
        cleanup(path);
    }
    #[tokio::test]
    async fn disabling_during_refresh_preserves_rotation_without_starting_quota() {
        let (vault, fake, id, _, path) = setup(0, false, false, false);
        fake.wait_for_refresh.store(true, Ordering::SeqCst);
        let adapter = managed(vault.clone(), fake.clone(), id.clone(), Provider::Codex);
        let running = tokio::spawn(async move { adapter.read(&http::fixture::context()).await });
        fake.started.notified().await;
        patch(vault.clone(), id, None, None, Some(false))
            .await
            .unwrap();
        fake.release_refresh.notify_one();
        assert!(matches!(
            running.await.unwrap(),
            Err(AccountError::SourceDisabled)
        ));
        assert_eq!(fake.quota_calls.load(Ordering::SeqCst), 0);
        let tx = vault.begin().unwrap();
        assert!(!tx.document.accounts[0].enabled());
        assert!(
            matches!(&tx.document.accounts[0].credential, Credential::CodexOAuth { refresh_token, .. } if refresh_token == "rotated")
        );
        drop(tx);
        cleanup(path);
    }
    #[tokio::test]
    async fn disabling_during_quota_discards_the_result() {
        let (vault, fake, id, _, path) = setup(3600, true, false, false);
        let adapter = managed(vault.clone(), fake.clone(), id.clone(), Provider::Codex);
        let running = tokio::spawn(async move { adapter.read(&http::fixture::context()).await });
        fake.started.notified().await;
        patch(vault, id, None, None, Some(false)).await.unwrap();
        assert!(matches!(running.await.unwrap(), Err(AccountError::Busy)));
        assert_eq!(fake.refreshes.load(Ordering::SeqCst), 0);
        cleanup(path);
    }
    #[tokio::test]
    async fn ordinary_codex_fetch_does_not_lock_out_other_providers() {
        let (vault, fake, codex, amp, path) = setup(3600, true, false, false);
        let provider = managed(vault.clone(), fake.clone(), codex, Provider::Codex);
        let context = http::fixture::context();
        let running = tokio::spawn(async move { provider.read(&context).await });
        fake.started.notified().await;
        let amp = managed(vault, fake, amp, Provider::Amp);
        assert!(
            tokio::time::timeout(
                Duration::from_millis(200),
                amp.read(&http::fixture::context())
            )
            .await
            .unwrap()
            .is_ok()
        );
        assert!(running.await.unwrap().is_ok());
        cleanup(path);
    }
    #[tokio::test]
    async fn uncertain_refresh_is_not_replayed() {
        let (vault, fake, id, _, path) = setup(0, false, true, false);
        let provider = managed(vault, fake.clone(), id, Provider::Codex);
        assert!(!provider.idempotent());
        let report = Collector {
            context: http::fixture::context(),
        }
        .collect(CollectRequest {
            providers: vec![Arc::new(provider)],
            timeout: Duration::from_secs(2),
            cancellation: Cancellation::default(),
        })
        .await;
        assert_eq!(report.exit_code(), 3);
        assert_eq!(fake.refreshes.load(Ordering::SeqCst), 1);
        cleanup(path);
    }
    #[tokio::test]
    async fn rotation_is_saved_before_failed_quota_and_storage_errors_fail_closed() {
        for fail_write in [false, true] {
            let (vault, fake, id, _, path) = setup(0, false, false, true);
            fake.memory.fail.store(fail_write, Ordering::SeqCst);
            let provider = managed(vault.clone(), fake.clone(), id, Provider::Codex);
            let result = provider.read(&http::fixture::context()).await;
            if fail_write {
                assert!(matches!(result, Err(AccountError::Storage)));
            } else {
                assert!(matches!(
                    result,
                    Err(AccountError::Provider(ProviderError::Unavailable))
                ));
            }
            let tx = begin(vault.clone()).await.unwrap();
            assert!(
                matches!(&tx.document.accounts[0].credential,Credential::CodexOAuth{access_token,..} if access_token==if fail_write{"old"}else{"new"})
            );
            drop(tx);
            cleanup(path);
        }
    }
    #[tokio::test]
    async fn discovery_obeys_timeout_while_another_transaction_holds_lock() {
        let (vault, _, _, _, path) = setup(3600, false, false, false);
        let held = vault.begin().unwrap();
        assert!(matches!(
            discover(vault, std::time::Duration::from_millis(30)).await,
            Err(AccountError::Busy)
        ));
        drop(held);
        cleanup(path);
    }
    #[test]
    fn added_key_providers_scope_credentials_and_select_all_accounts() {
        for provider in [
            Provider::Synthetic,
            Provider::OpenRouter,
            Provider::Zai,
            Provider::MiniMax,
        ] {
            let (vault, _, _, _, path) = setup(3600, false, false, false);
            let credential = Credential::ApiKey {
                token: "saved-test-key".into(),
                region: provider
                    .key_api()
                    .unwrap()
                    .region_key()
                    .map(|_| "cn".into()),
                organization: None,
            };
            let ctx = scoped(&http::fixture::context(), provider, &credential).unwrap();
            assert_eq!(
                ctx.credentials
                    .get(provider.api_key_name().unwrap())
                    .unwrap()
                    .0,
                "saved-test-key"
            );
            assert!(ctx.credentials.get("FACTORY_API_KEY").is_none());
            if let Some(name) = provider.key_api().unwrap().region_key() {
                assert_eq!(ctx.credentials.get(name).unwrap().0, "cn");
            }
            let mut tx = vault.begin().unwrap();
            let first = tx
                .document
                .add(provider, "First", "key:first".into(), credential.clone())
                .unwrap();
            let second = tx
                .document
                .add(provider, "Second", "key:second".into(), credential)
                .unwrap();
            let accounts = tx.document.accounts.clone();
            drop(tx);
            let selected = choose(
                vec![provider],
                None,
                Ok(accounts.clone()),
                &vault,
                &[provider],
            )
            .unwrap();
            assert_eq!(
                selected
                    .iter()
                    .map(|p| p.account_ref().unwrap().id)
                    .collect::<Vec<_>>(),
                vec!["local".to_owned(), first, second.clone()]
            );
            let selected = choose(
                vec![provider],
                Some(&second),
                Ok(accounts),
                &vault,
                &[provider],
            )
            .unwrap();
            assert_eq!(selected.len(), 1);
            assert_eq!(selected[0].account_ref().unwrap().id, second);
            cleanup(path);
        }
    }
    #[test]
    fn amp_selection_keeps_local_and_all_saved_accounts() {
        let (vault, _, _, first, path) = setup(3600, false, false, false);
        let mut tx = vault.begin().unwrap();
        let second = tx
            .document
            .add(
                Provider::Amp,
                "Second Amp",
                "second@example.invalid".into(),
                Credential::ApiKey {
                    token: "synthetic-second".into(),
                    region: None,
                    organization: None,
                },
            )
            .unwrap();
        let accounts = tx.document.accounts.clone();
        drop(tx);
        let selected = choose(
            vec![Provider::Amp],
            None,
            Ok(accounts.clone()),
            &vault,
            &[Provider::Amp],
        )
        .unwrap();
        let refs: Vec<_> = selected
            .iter()
            .map(|p| p.account_ref().map(|a| a.id))
            .collect();
        assert_eq!(
            refs,
            vec![
                Some("local".into()),
                Some(first.clone()),
                Some(second.clone())
            ]
        );
        let only_saved =
            choose(vec![Provider::Amp], None, Ok(accounts.clone()), &vault, &[]).unwrap();
        assert_eq!(only_saved.len(), 2);
        assert!(
            only_saved
                .iter()
                .all(|p| p.account_ref().unwrap().id != "local")
        );
        let filtered = choose(
            vec![Provider::Amp],
            Some(&second),
            Ok(accounts),
            &vault,
            &[Provider::Amp],
        )
        .unwrap();
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].account_ref().unwrap().id, second);
        let denied = choose(
            vec![Provider::Amp],
            None,
            Err(AccountError::Storage),
            &vault,
            &[Provider::Amp],
        )
        .unwrap();
        assert_eq!(
            denied
                .iter()
                .map(|p| p.account_ref().unwrap().id)
                .collect::<Vec<_>>(),
            vec!["local", "saved"]
        );
        cleanup(path);
    }
    #[test]
    fn automatic_detection_excludes_mock_disabled_providers_and_disabled_accounts() {
        let account = |provider: Provider, enabled| Account {
            id: format!("{}-account", provider.id()),
            provider,
            label: "Test".into(),
            identity: "test".into(),
            active: true,
            enabled,
            credential: Credential::ApiKey {
                token: "test-key".into(),
                region: None,
                organization: None,
            },
        };
        let candidates = Provider::value_variants();
        let detected = automatically_detected_providers(
            candidates,
            &[Provider::Factory],
            &[
                account(Provider::Codex, true),
                account(Provider::Amp, false),
            ],
            &[Provider::Factory, Provider::Mock],
        );
        assert_eq!(detected, vec![Provider::Codex]);
    }
    #[test]
    fn codex_selection_includes_inactive_accounts_and_filters_by_id() {
        let (vault, _, first, amp, path) = setup(3600, false, false, false);
        let mut tx = vault.begin().unwrap();
        let mut credential = tx.document.accounts[0].credential.clone();
        if let Credential::CodexOAuth {
            account_id, email, ..
        } = &mut credential
        {
            *account_id = "second-id".into();
            *email = "second@example.com".into();
        }
        let second = tx
            .document
            .add(Provider::Codex, "Second", "second-id".into(), credential)
            .unwrap();
        assert!(!tx.document.accounts[2].active);
        let accounts = tx.document.accounts.clone();
        drop(tx);
        let refs = |adapters: Vec<Arc<dyn ProviderAdapter>>| {
            adapters
                .iter()
                .map(|a| a.account_ref().unwrap().id)
                .collect::<Vec<_>>()
        };
        assert_eq!(
            refs(
                choose(
                    vec![Provider::Codex],
                    None,
                    Ok(accounts.clone()),
                    &vault,
                    &[Provider::Codex]
                )
                .unwrap()
            ),
            vec!["local".to_owned(), first.clone(), second.clone()]
        );
        assert_eq!(
            refs(
                choose(
                    vec![Provider::Codex],
                    None,
                    Ok(accounts.clone()),
                    &vault,
                    &[]
                )
                .unwrap()
            ),
            vec![first, second.clone()]
        );
        assert_eq!(
            refs(
                choose(
                    vec![Provider::Codex],
                    Some(&second),
                    Ok(accounts.clone()),
                    &vault,
                    &[Provider::Codex]
                )
                .unwrap()
            ),
            vec![second]
        );
        assert!(matches!(
            choose(
                vec![Provider::Codex],
                Some(&amp),
                Ok(accounts.clone()),
                &vault,
                &[Provider::Codex]
            ),
            Err(AccountError::NotFound)
        ));
        assert!(matches!(
            choose(
                vec![Provider::Codex],
                Some("missing"),
                Ok(accounts),
                &vault,
                &[Provider::Codex]
            ),
            Err(AccountError::NotFound)
        ));
        assert_eq!(
            refs(
                choose(
                    vec![Provider::Codex],
                    None,
                    Err(AccountError::Storage),
                    &vault,
                    &[Provider::Codex]
                )
                .unwrap()
            ),
            vec!["local", "saved"]
        );
        cleanup(path);
    }
    #[tokio::test]
    async fn stalled_refresh_does_not_block_another_saved_account() {
        for expiry in [3600, 0] {
            let (vault, fake, first, _, path) = setup(0, false, false, false);
            let mut tx = vault.begin().unwrap();
            let mut credential = tx.document.accounts[0].credential.clone();
            if let Credential::CodexOAuth {
                account_id,
                email,
                expires_at,
                ..
            } = &mut credential
            {
                *account_id = "second-id".into();
                *email = "second@example.com".into();
                *expires_at = expiry;
            }
            let second = tx
                .document
                .add(Provider::Codex, "Second", "second-id".into(), credential)
                .unwrap();
            tx.commit().unwrap();
            fake.stall_first_refresh.store(true, Ordering::SeqCst);
            let slow = managed(vault.clone(), fake.clone(), first, Provider::Codex);
            let running = tokio::spawn(async move { slow.read(&http::fixture::context()).await });
            fake.started.notified().await;
            let other = managed(vault, fake, second, Provider::Codex);
            let result = tokio::time::timeout(
                Duration::from_millis(300),
                other.read(&http::fixture::context()),
            )
            .await;
            running.abort();
            let _ = running.await;
            cleanup(path);
            assert!(
                result.is_ok_and(|r| r.is_ok()),
                "one account's refresh blocked another account"
            );
        }
    }
    #[tokio::test]
    async fn concurrent_reads_of_one_expired_account_refresh_only_once() {
        let (vault, fake, id, _, path) = setup(0, true, false, false);
        let first = managed(vault.clone(), fake.clone(), id.clone(), Provider::Codex);
        let second = managed(vault, fake.clone(), id, Provider::Codex);
        let context = http::fixture::context();
        let (a, b) = tokio::join!(first.read(&context), second.read(&context));
        assert!(a.is_ok());
        assert!(b.is_ok());
        assert_eq!(fake.refreshes.load(Ordering::SeqCst), 1);
        cleanup(path);
    }
}

#[cfg(test)]
mod catalog_credential_tests {
    use super::*;
    #[test]
    fn saved_catalog_settings_are_isolated_and_roundtrip() {
        for definition in crate::providers::catalog::definitions()
            .filter(|d| d.auth == crate::providers::catalog::AuthKind::ApiKey)
        {
            let settings = definition
                .settings
                .iter()
                .map(|s| (s.name.to_owned(), "scope-value".to_owned()))
                .collect();
            let credential = Credential::CatalogKey {
                token: "saved-synthetic-key".into(),
                settings,
            };
            let serialized = serde_json::to_string(&credential).unwrap();
            let decoded: Credential = serde_json::from_str(&serialized).unwrap();
            assert!(decoded == credential);
            let context = scoped(
                &crate::providers::http::fixture::context(),
                Provider::Catalog(definition.id),
                &credential,
            )
            .unwrap();
            assert_eq!(
                context.credentials.get(definition.key_env).unwrap().0,
                "saved-synthetic-key"
            );
            assert!(context.credentials.get("FACTORY_API_KEY").is_none());
            for setting in definition.settings {
                assert_eq!(
                    context.credentials.get(setting.env).unwrap().0,
                    "scope-value"
                );
            }
            let invalid = Credential::CatalogKey {
                token: "saved-synthetic-key".into(),
                settings: [("unknown".into(), "private-value".into())]
                    .into_iter()
                    .collect(),
            };
            assert!(matches!(
                scoped(&context, Provider::Catalog(definition.id), &invalid),
                Err(AccountError::Settings)
            ));
        }
    }
}

#[cfg(test)]
mod receipt_tests {
    use super::*;
    use crate::accounts::vault::{Backend, tests::Memory};
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn fixture() -> (Vault, Arc<Memory>, std::path::PathBuf) {
        let path = std::env::temp_dir().join(format!(
            "quotio-receipt-{}.lock",
            crate::accounts::random_string().unwrap()
        ));
        let backend = Arc::new(Memory::default());
        (Vault::new(backend.clone(), path.clone()), backend, path)
    }
    fn intent(key: &str, body: &str) -> MutationIntent {
        MutationIntent::new(key, crate::cache::fingerprint(&[body])).unwrap()
    }
    fn create(document: &mut crate::accounts::Document) -> Result<String, AccountError> {
        document.add(
            Provider::Amp,
            "label",
            "identity".into(),
            Credential::ApiKey {
                token: "fixture-private-credential".into(),
                region: None,
                organization: None,
            },
        )
    }

    struct UncertainWrite(Memory);
    impl crate::accounts::vault::Backend for UncertainWrite {
        fn read(&self) -> Result<Option<Vec<u8>>, AccountError> {
            self.0.read()
        }
        fn write(&self, bytes: &[u8]) -> Result<(), AccountError> {
            self.0.write(bytes)?;
            Err(AccountError::CommitUncertain)
        }
    }
    #[tokio::test]
    async fn uncertain_commit_preserves_receipt_for_recovery_without_second_write() {
        let path = std::env::temp_dir().join(format!(
            "quotio-uncertain-{}",
            crate::accounts::random_string().unwrap()
        ));
        let vault = Vault::new(Arc::new(UncertainWrite(Memory::default())), path.clone());
        let intent = intent("uncertain-fixture", "create");
        assert!(matches!(
            commit_once(vault.clone(), intent.clone(), create).await,
            Err(AccountError::CommitUncertain)
        ));
        let id = mutation_receipt(vault.clone(), &intent)
            .await
            .unwrap()
            .unwrap();
        let retry = commit_once(vault.clone(), intent, |_| {
            panic!("must recover committed receipt")
        })
        .await
        .unwrap();
        assert_eq!(id, retry);
        assert_eq!(list(vault).await.unwrap().len(), 1);
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test]
    async fn uncertain_factory_receipt_keeps_reservations_and_rejects_old_reader() {
        use crate::accounts::vault::tests::{assert_old_reader_rejects, factory_credential};
        let path = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        let backend = Arc::new(UncertainWrite(Memory::default()));
        let vault = Vault::new(backend.clone(), path.clone());
        let intent = intent("factory-uncertain", "create");
        assert!(matches!(
            commit_once(vault.clone(), intent.clone(), |document| {
                document.add(
                    Provider::Factory,
                    "Factory",
                    "fixture".into(),
                    factory_credential(),
                )
            })
            .await,
            Err(AccountError::CommitUncertain)
        ));
        let before = backend.read().unwrap().unwrap();
        assert_old_reader_rejects(&before);
        let id = mutation_receipt(vault.clone(), &intent)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            commit_once(vault.clone(), intent, |_| panic!("must not replay"))
                .await
                .unwrap(),
            id
        );
        assert_eq!(backend.read().unwrap().unwrap(), before);
        let tx = vault.begin().unwrap();
        assert_eq!(tx.document.version, 5);
        assert_eq!(tx.document.factory_refresh_owners.len(), 1);
        drop(tx);
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test]
    async fn replay_after_reopening_vault_does_not_repeat_write_or_resurrect_deleted_account() {
        let (vault, backend, path) = fixture();
        let id = commit_once(vault.clone(), intent("intent", "create"), create)
            .await
            .unwrap();
        assert_eq!(vault.begin().unwrap().document.version, 2);
        remove(vault, id.clone()).await.unwrap();
        let reopened = Vault::new(backend, path.clone());
        let replay = commit_once(reopened.clone(), intent("intent", "create"), |_| {
            panic!("replayed mutation")
        })
        .await
        .unwrap();
        assert_eq!(replay, id);
        assert!(list(reopened.clone()).await.unwrap().is_empty());
        assert!(matches!(
            mutation_receipt(reopened, &intent("intent", "other body")).await,
            Err(AccountError::IdempotencyConflict)
        ));
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn failed_native_write_commits_neither_account_nor_receipt_and_retry_recovers() {
        let (vault, backend, path) = fixture();
        backend.fail.store(true, Ordering::SeqCst);
        assert!(matches!(
            commit_once(vault.clone(), intent("intent", "create"), create).await,
            Err(AccountError::Storage)
        ));
        assert!(
            mutation_receipt(vault.clone(), &intent("intent", "create"))
                .await
                .unwrap()
                .is_none()
        );
        assert!(list(vault.clone()).await.unwrap().is_empty());
        backend.fail.store(false, Ordering::SeqCst);
        commit_once(vault.clone(), intent("intent", "create"), create)
            .await
            .unwrap();
        assert_eq!(list(vault).await.unwrap().len(), 1);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn concurrent_retries_commit_once_and_keep_keys_out_of_serialized_receipts() {
        let (vault, backend, path) = fixture();
        let writes = Arc::new(AtomicUsize::new(0));
        let mut tasks = Vec::new();
        for _ in 0..8 {
            let vault = vault.clone();
            let writes = writes.clone();
            tasks.push(tokio::spawn(async move {
                commit_once(vault, intent("private-retry-key", "body"), |document| {
                    writes.fetch_add(1, Ordering::SeqCst);
                    create(document)
                })
                .await
                .unwrap()
            }));
        }
        let first = tasks.remove(0).await.unwrap();
        for task in tasks {
            assert_eq!(task.await.unwrap(), first);
        }
        assert_eq!(writes.load(Ordering::SeqCst), 1);
        let bytes = backend.read().unwrap().unwrap();
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        let receipts = value["mutation_receipts"].to_string();
        assert!(!receipts.contains("private-retry-key"));
        assert!(!receipts.contains("fixture-private-credential"));
        let _ = std::fs::remove_file(path);
    }
}
