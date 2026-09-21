//! One-way import of Quotio's legacy monitor credentials. Never refreshes the source.
use super::*;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Input {
    pub legacy_id: String,
    pub provider: Provider,
    pub label: String,
    pub enabled: bool,
    pub credential: LegacyCredential,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LegacyCredential {
    access_token: String,
    refresh_token: Option<String>,
    id_token: Option<String>,
    account_id: Option<String>,
    expires_at: Option<i64>,
    #[serde(default)]
    extra: BTreeMap<String, String>,
}
fn secret(value: String) -> Result<String, AccountError> {
    if value.is_empty() || value.len() > 16_384 || value.chars().any(char::is_whitespace) {
        return Err(AccountError::Input);
    }
    if value.chars().any(char::is_control) {
        return Err(AccountError::Input);
    }
    Ok(value)
}
pub fn prepare(
    input: Input,
    context: &ProviderContext,
) -> Result<(PreparedAccount, bool), AccountError> {
    let Input {
        legacy_id,
        provider,
        label,
        enabled,
        credential: old,
    } = input;
    if legacy_id.is_empty() || legacy_id.len() > 256 || legacy_id.chars().any(char::is_control) {
        return Err(AccountError::Input);
    }
    let label = super::super::validate_label(&label)?;
    let access_token = secret(old.access_token)?;
    let expires_at = old.expires_at.unwrap_or(0);
    if expires_at < 0 {
        return Err(AccountError::Input);
    }
    let required = |value: Option<String>| secret(value.ok_or(AccountError::Input)?);
    let credential = match provider {
        Provider::Catalog("claude") => Credential::ClaudeOAuth {
            access_token,
            refresh_token: required(old.refresh_token)?,
            account_id: old
                .account_id
                .map(secret)
                .transpose()?
                .unwrap_or_else(|| legacy_id.clone()),
            email: label.clone(),
            expires_at,
            refresh_pending: false,
        },
        Provider::Codex => Credential::CodexOAuth {
            access_token,
            refresh_token: required(old.refresh_token)?,
            id_token: required(old.id_token)?,
            account_id: required(old.account_id)?,
            email: label.clone(),
            expires_at,
        },
        Provider::Catalog("copilot") => Credential::CopilotOAuth {
            access_token,
            account_id: required(old.account_id)?,
            login: label.clone(),
        },
        Provider::Antigravity => {
            prepare_antigravity_owned(AntigravityOwnedInput {
                kind: AntigravityOwnedKind::AntigravityOwned,
                label: label.clone(),
                access_token,
                refresh_token: required(old.refresh_token)?,
                expires_at,
                client_id: required(old.extra.get("clientId").cloned())?,
                client_secret: required(old.extra.get("clientSecret").cloned())?,
            })?
            .credential
        }
        Provider::Catalog("kiro") => {
            prepare_kiro_owned(KiroOwnedInput {
                kind: KiroOwnedKind::KiroOwned,
                label: label.clone(),
                access_token,
                refresh_token: required(old.refresh_token)?,
                expires_at,
                auth_method: match old.extra.get("authMethod").map(String::as_str) {
                    Some("IdC") => super::super::KiroAuthMethod::IdC,
                    Some("social") => super::super::KiroAuthMethod::Social,
                    _ => return Err(AccountError::Input),
                },
                region: old
                    .extra
                    .get("region")
                    .cloned()
                    .unwrap_or_else(|| "us-east-1".into()),
                profile_arn: old.extra.get("profileArn").cloned(),
                client_id: old.extra.get("clientId").cloned(),
                client_secret: old.extra.get("clientSecret").cloned(),
            })?
            .credential
        }
        _ if old.refresh_token.is_none() && old.id_token.is_none() => super::credential(
            ApiKeyInput {
                provider,
                label: Some(label.clone()),
                api_key: access_token,
                settings: BTreeMap::new(),
                region: old.extra.get("region").cloned(),
                organization: old.extra.get("organizationId").cloned(),
            },
            context,
        )?,
        _ => return Err(AccountError::Unsupported),
    };
    Ok((
        PreparedAccount {
            provider,
            label,
            credential,
            identity: crate::cache::fingerprint(&["quotio-monitor-v1", &legacy_id]),
        },
        enabled,
    ))
}

pub async fn save_once(
    vault: Vault,
    prepared: PreparedAccount,
    enabled: bool,
    intent: service::MutationIntent,
) -> Result<String, AccountError> {
    service::commit_once(vault, intent, move |document| {
        let id = document.add(
            prepared.provider,
            &prepared.label,
            prepared.identity,
            prepared.credential,
        )?;
        document.patch(&id, None, None, Some(enabled))?;
        Ok(id)
    })
    .await
}
