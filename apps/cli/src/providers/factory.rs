use super::{FetchFuture, ProviderAdapter, ProviderContext, http};
use crate::{domain::*, error::ProviderError};
use serde::Deserialize;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

pub struct FactoryProvider;

pub(crate) fn valid_keychain_account(account: &str) -> bool {
    matches!(
        account,
        "auth-encryption-key-security-cli" | "auth-encryption-key"
    )
}

pub(crate) fn select_keychain_account(
    mut exists: impl FnMut(&str) -> Result<bool, ProviderError>,
) -> Result<Option<String>, ProviderError> {
    for account in ["auth-encryption-key-security-cli", "auth-encryption-key"] {
        if exists(account)? {
            return Ok(Some(account.into()));
        }
    }
    Ok(None)
}

pub(crate) fn keychain_account() -> Result<Option<String>, ProviderError> {
    select_keychain_account(|account| {
        super::catalog::common::keychain_item_exists("Factory CLI", Some(account))
    })
}

pub(crate) async fn load_native(
    source: &crate::accounts::sources::FactoryNativeReference,
) -> Result<crate::accounts::Credential, crate::accounts::AccountError> {
    load_native_with_keychain(source, |account| async move {
        super::catalog::oauth_primary::native_keychain("Factory CLI", Some(&account)).await
    })
    .await
}

async fn load_native_with_keychain<F, Fut>(
    source: &crate::accounts::sources::FactoryNativeReference,
    read_key: F,
) -> Result<crate::accounts::Credential, crate::accounts::AccountError>
where
    F: FnOnce(String) -> Fut,
    Fut: std::future::Future<Output = Result<Option<Vec<u8>>, ProviderError>>,
{
    use super::catalog::oauth_primary::native_file;
    use crate::accounts::{AccountError, sources::FactoryLocation};
    let bytes = native_file(source.directory.join(source.location.filename()))
        .await?
        .ok_or(AccountError::NotFound)?;
    if source.location == FactoryLocation::Legacy
        && bytes.iter().find(|b| !b.is_ascii_whitespace()) == Some(&b'{')
    {
        return parse_native(&bytes);
    }
    let key = if source.location == FactoryLocation::V2File {
        native_file(source.directory.join("auth.v2.key"))
            .await?
            .ok_or(AccountError::NotFound)?
    } else {
        let account = source
            .entry_key
            .as_deref()
            .ok_or(ProviderError::CredentialStorage)?;
        read_key(account.to_owned())
            .await?
            .ok_or(AccountError::NotFound)?
    };
    parse_native(&decrypt_native(&bytes, &key)?)
}
fn decrypt_native(bytes: &[u8], key: &[u8]) -> Result<Vec<u8>, crate::accounts::AccountError> {
    use crate::accounts::AccountError;
    use aes_gcm::{
        Aes256Gcm, AesGcm,
        aead::{Aead, KeyInit, consts::U16},
        aes::Aes256,
    };
    use base64::{Engine, engine::general_purpose::STANDARD};
    let key = if key.len() == 32 {
        key.to_vec()
    } else {
        STANDARD
            .decode(
                std::str::from_utf8(key)
                    .map_err(|_| AccountError::Corrupt)?
                    .trim(),
            )
            .map_err(|_| AccountError::Corrupt)?
    };
    let text = std::str::from_utf8(bytes).map_err(|_| AccountError::Corrupt)?;
    let parts: Vec<_> = text.trim().split(':').collect();
    if parts.len() != 3 {
        return Err(AccountError::Corrupt);
    }
    let decode = |s| STANDARD.decode(s).map_err(|_| AccountError::Corrupt);
    let nonce = decode(parts[0])?;
    let tag = decode(parts[1])?;
    if tag.len() != 16 {
        return Err(AccountError::Corrupt);
    }
    let mut ciphertext = decode(parts[2])?;
    ciphertext.extend_from_slice(&tag);
    match nonce.len() {
        12 => Aes256Gcm::new_from_slice(&key)
            .map_err(|_| AccountError::Corrupt)?
            .decrypt(nonce.as_slice().into(), ciphertext.as_slice()),
        16 => AesGcm::<Aes256, U16>::new_from_slice(&key)
            .map_err(|_| AccountError::Corrupt)?
            .decrypt(nonce.as_slice().into(), ciphertext.as_slice()),
        _ => return Err(AccountError::Corrupt),
    }
    .map_err(|_| AccountError::Corrupt)
}
fn parse_native(
    bytes: &[u8],
) -> Result<crate::accounts::Credential, crate::accounts::AccountError> {
    use crate::accounts::{AccountError, Credential};
    #[derive(Deserialize)]
    struct Native {
        access_token: String,
        active_organization_id: Option<String>,
    }
    let native: Native = serde_json::from_slice(bytes).map_err(|_| AccountError::Corrupt)?;
    let access_token = native.access_token.trim().to_owned();
    let organization_id = native
        .active_organization_id
        .map(|id| id.trim().to_owned())
        .filter(|id| !id.is_empty());
    if !valid_token(&access_token)
        || organization_id
            .as_ref()
            .is_some_and(|id| !valid_token(id) || id.len() > 256)
    {
        return Err(AccountError::Corrupt);
    }
    // The owner's refresh token is deliberately not decoded or returned.
    Ok(Credential::FactoryOAuth {
        expires_at: token_expiry(&access_token),
        access_token,
        refresh_token: String::new(),
        organization_id,
        refresh_pending: false,
    })
}

pub(crate) fn valid_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 16_384
        && !value.chars().any(|c| c.is_control() || c.is_whitespace())
}
// WorkOS uses JWT expiry. Opaque or malformed tokens need refresh, as in Swift.
pub(crate) fn token_expiry(token: &str) -> i64 {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    let parts: Vec<_> = token.split('.').collect();
    if parts.len() != 3 {
        return 0;
    }
    URL_SAFE_NO_PAD
        .decode(parts[1])
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
        .and_then(|value| value.get("exp").and_then(serde_json::Value::as_i64))
        .filter(|expiry| *expiry >= 0)
        .unwrap_or(0)
}
// Factory stores its own organization ID as `external_org_id`; WorkOS uses `org_id`.
// This is a binding check, not signature verification; Factory must accept the bearer
// before any decoded identity is returned to the caller.
fn token_organization(token: &str, claim: &str) -> Option<String> {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
    let parts: Vec<_> = token.split('.').collect();
    if parts.len() != 3 {
        return None;
    }
    let bytes = URL_SAFE_NO_PAD.decode(parts[1]).ok()?;
    let claims: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    claims
        .get(claim)?
        .as_str()
        .filter(|id| valid_token(id) && id.len() <= 256)
        .map(str::to_owned)
}

pub(crate) async fn refresh(
    context: &ProviderContext,
    previous: &crate::accounts::Credential,
) -> Result<crate::accounts::Credential, crate::accounts::AccountError> {
    refresh_at(
        context,
        previous,
        "https://api.workos.com/user_management/authenticate",
    )
    .await
}
async fn refresh_at(
    context: &ProviderContext,
    previous: &crate::accounts::Credential,
    endpoint: &str,
) -> Result<crate::accounts::Credential, crate::accounts::AccountError> {
    use crate::accounts::{AccountError, Credential};
    let Credential::FactoryOAuth {
        refresh_token,
        organization_id,
        ..
    } = previous
    else {
        return Err(AccountError::Unsupported);
    };
    #[derive(Deserialize)]
    struct Tokens {
        access_token: String,
        refresh_token: Option<String>,
    }
    let mut form = vec![
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token.as_str()),
        ("client_id", "client_01HNM792M5G5G1A2THWPXKFMXB"),
    ];
    if let Some(org) = organization_id {
        form.push(("organization_id", org));
    }
    let tokens: Tokens = http::json(
        context
            .http
            .post(endpoint)
            .header("Accept", "application/json")
            .form(&form),
        context.clock.now(),
    )
    .await?;
    let rotated = tokens
        .refresh_token
        .unwrap_or_else(|| refresh_token.clone());
    if !valid_token(&tokens.access_token) || !valid_token(&rotated) {
        return Err(AccountError::OAuth);
    }
    Ok(Credential::FactoryOAuth {
        expires_at: token_expiry(&tokens.access_token),
        access_token: tokens.access_token,
        refresh_token: rotated,
        organization_id: organization_id.clone(),
        refresh_pending: false,
    })
}
pub(crate) async fn fetch_oauth_at(
    context: &ProviderContext,
    credential: &crate::accounts::Credential,
    endpoint: &str,
) -> Result<ProviderUsage, crate::accounts::AccountError> {
    use crate::accounts::{AccountError, Credential};
    let Credential::FactoryOAuth {
        access_token,
        organization_id,
        refresh_pending,
        ..
    } = credential
    else {
        return Err(AccountError::Unsupported);
    };
    if *refresh_pending {
        return Err(AccountError::CommitUncertain);
    }
    let token_org = token_organization(access_token, "org_id");
    let factory_org = token_organization(access_token, "external_org_id");
    if organization_id.as_ref().is_some_and(|requested| {
        token_org.as_ref() != Some(requested) && factory_org.as_ref() != Some(requested)
    }) {
        return Err(AccountError::OAuth);
    }
    let response = context
        .http
        .get(endpoint)
        .header(
            "Authorization",
            http::sensitive(&format!("Bearer {access_token}"))?,
        )
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|error| {
            if error.is_timeout() {
                ProviderError::Timeout
            } else {
                ProviderError::Transient
            }
        })?;
    // Unlike 401, a forbidden quota request must not consume a refresh token.
    if response.status() == reqwest::StatusCode::FORBIDDEN {
        return Err(AccountError::QuotaForbidden);
    }
    let response: Response = http::json_response(response, context.clock.now()).await?;
    let id = token_org.unwrap_or_else(|| "Factory Droid".into());
    let windows = parse_windows(response, context.clock.now())?;
    let label = profile_email(context, endpoint, access_token)
        .await
        .unwrap_or_else(|| id.clone());
    Ok(ProviderUsage {
        reset_credits: None,
        antigravity_subscription: None,
        codex_profile: None,
        codex_reset_credits: None,
        diagnostics: vec![],
        account_ref: None,
        provider: ProviderId("factory".into()),
        account: AccountIdentity {
            verified: None,
            id: id.clone(),
            label,
            plan: None,
            subscription_status: None,
        },
        windows,
    })
}

async fn profile_email(context: &ProviderContext, endpoint: &str, token: &str) -> Option<String> {
    let endpoint = reqwest::Url::parse(endpoint)
        .ok()?
        .join("/api/app/auth/me")
        .ok()?;
    // Leave time for account-result validation and the collector to retain valid quota.
    let cap = std::time::Duration::from_secs(2);
    let budget =
        super::remaining_fetch_time().map_or(cap, |remaining| remaining.mul_f64(0.5).min(cap));
    let profile: serde_json::Value = tokio::time::timeout(
        budget,
        http::json(
            context
                .http
                .get(endpoint)
                .header(
                    "Authorization",
                    http::sensitive(&format!("Bearer {token}")).ok()?,
                )
                .header("Accept", "application/json"),
            context.clock.now(),
        ),
    )
    .await
    .ok()?
    .ok()?;
    let email = profile.pointer("/userProfile/email")?.as_str()?;
    if email.len() > 254 || email.chars().any(char::is_control) || email.contains(token) {
        return None;
    }
    let email = email.trim();
    let (local, domain) = email.split_once('@')?;
    if local.is_empty()
        || domain.is_empty()
        || domain.contains('@')
        || email.chars().any(char::is_whitespace)
    {
        return None;
    }
    Some(email.to_owned())
}

#[derive(Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Identity {
    user_id: String,
    org_id: String,
    region: Option<String>,
    #[serde(default)]
    is_on_prem: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    uses_token_rate_limits_billing: Option<bool>,
    #[serde(default)]
    limits: serde_json::Value,
    extra_usage_balance_cents: Option<f64>,
}
#[derive(Deserialize)]
struct Limits {
    standard: Option<Pool>,
    core: Option<Pool>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Pool {
    five_hour: Option<Window>,
    weekly: Option<Window>,
    monthly: Option<Window>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Window {
    used_percent: Option<f64>,
    window_end: Option<String>,
}
fn parse(
    identity: Identity,
    response: Response,
    now: OffsetDateTime,
) -> Result<ProviderUsage, ProviderError> {
    if identity.user_id.trim().is_empty()
        || identity.org_id.trim().is_empty()
        || identity.is_on_prem
    {
        return Err(ProviderError::InvalidData);
    }
    let windows = parse_windows(response, now)?;
    let verified = crate::domain::VerifiedIdentity {
        subject: identity.user_id.clone(),
        tenant: Some(identity.org_id.clone()),
    };
    if !verified.is_valid() {
        return Err(ProviderError::InvalidData);
    }
    Ok(ProviderUsage {
        reset_credits: None,
        antigravity_subscription: None,
        codex_profile: None,
        codex_reset_credits: None,
        diagnostics: vec![],
        account_ref: None,
        provider: ProviderId("factory".into()),
        account: AccountIdentity {
            verified: Some(verified),
            subscription_status: None,
            plan: None,
            id: format!("{}:{}", identity.user_id, identity.org_id),
            label: format!("{} / {}", identity.user_id, identity.org_id),
        },
        windows,
    })
}
fn parse_windows(
    response: Response,
    now: OffsetDateTime,
) -> Result<Vec<QuotaWindow>, ProviderError> {
    if response.uses_token_rate_limits_billing == Some(false) {
        return Ok(vec![QuotaWindow {
            note: Some("legacy-billing".into()),
            metric_id: Some("factory-billing-mode".into()),
            consumption: None,
            reset_description: None,
            label: "Billing mode".into(),
            quota: Quota::Unknown,
            amounts: None,
            resets_at: None,
            fetched_at: now,
            provenance: Provenance {
                source: "factory_billing_limits".into(),
                confidence: Confidence::Unknown,
            },
        }]);
    }
    let limits: Limits =
        serde_json::from_value(response.limits).map_err(|_| ProviderError::InvalidData)?;
    if limits.standard.is_none() && limits.core.is_none() {
        return Err(ProviderError::InvalidData);
    }
    let mut windows = Vec::new();
    for (name, id, pool) in [
        ("Standard", "standard", limits.standard),
        ("Droid Core", "core", limits.core),
    ] {
        let pool = pool.unwrap_or(Pool {
            five_hour: None,
            weekly: None,
            monthly: None,
        });
        for (label, period, window) in [
            ("5 hours", "five-hour", pool.five_hour),
            ("weekly", "weekly", pool.weekly),
            ("monthly", "monthly", pool.monthly),
        ] {
            let (used, resets_at) = match window {
                Some(window) => (
                    window.used_percent,
                    window
                        .window_end
                        .map(|s| OffsetDateTime::parse(&s, &Rfc3339))
                        .transpose()
                        .map_err(|_| ProviderError::InvalidData)?,
                ),
                None => (None, None),
            };
            // An expired bucket does not establish the value of its replacement.
            let quota = if resets_at.is_some_and(|reset| reset <= now) {
                Quota::Unknown
            } else {
                Quota::from_used(used)
            };
            let confidence = if quota == Quota::Unknown {
                Confidence::Unknown
            } else {
                Confidence::Exact
            };
            windows.push(QuotaWindow {
                note: None,
                metric_id: Some(format!("factory-{id}-{period}")),
                consumption: None,
                reset_description: None,
                label: format!("{name} {label}"),
                quota,
                amounts: None,
                resets_at,
                fetched_at: now,
                provenance: Provenance {
                    source: "factory_billing_limits".into(),
                    confidence,
                },
            });
        }
    }
    if let Some(cents) = response.extra_usage_balance_cents {
        if !cents.is_finite() || cents < 0.0 {
            return Err(ProviderError::InvalidData);
        }
        windows.push(QuotaWindow {
            note: None,
            metric_id: Some("factory-extra-balance".into()),
            consumption: None,
            reset_description: None,
            label: "Extra usage credits".into(),
            quota: Quota::Unknown,
            amounts: Some(QuotaAmounts {
                remaining: cents / 100.0,
                limit: None,
                unit: "USD".into(),
            }),
            resets_at: None,
            fetched_at: now,
            provenance: Provenance {
                source: "factory_billing_limits".into(),
                confidence: Confidence::Exact,
            },
        });
    }
    Ok(windows)
}
impl FactoryProvider {
    async fn fetch_api(
        &self,
        context: &ProviderContext,
        global: &str,
        eu: &str,
    ) -> Result<ProviderUsage, ProviderError> {
        let key = context
            .credentials
            .get("FACTORY_API_KEY")
            .filter(|key| !key.0.trim().is_empty())
            .ok_or(ProviderError::Authentication)?;
        let region = context.credentials.get("FACTORY_REGION");
        let base = match region
            .as_ref()
            .map(|value| value.0.as_str())
            .unwrap_or("global")
        {
            "global" => global,
            "eu" => eu,
            _ => return Err(ProviderError::InvalidData),
        };
        let authorization = http::sensitive(&format!("Bearer {}", key.0))?;
        let organization = context.credentials.get("FACTORY_ORG_ID");
        let mut who = context
            .http
            .get(format!("{base}/api/cli/whoami"))
            .header("Authorization", authorization.clone())
            .header("X-Factory-Whoami-Extended", "true");
        if let Some(org) = &organization {
            who = who.header("X-Factory-Org-Id", http::sensitive(&org.0)?);
        }
        let before: Identity = http::json(who, context.clock.now()).await?;
        if before.is_on_prem
            || before.org_id.is_empty()
            || before.user_id.is_empty()
            || before.region.as_deref().is_some_and(|actual| {
                actual != region.as_ref().map(|r| r.0.as_str()).unwrap_or("global")
            })
        {
            return Err(ProviderError::InvalidData);
        }
        if organization
            .as_ref()
            .is_some_and(|org| org.0 != before.org_id)
        {
            return Err(ProviderError::InvalidData);
        }
        let org = http::sensitive(&before.org_id)?;
        let response: Response = http::json(
            context
                .http
                .get(format!("{base}/api/billing/limits"))
                .header("Authorization", authorization.clone())
                .header("X-Factory-Org-Id", org.clone()),
            context.clock.now(),
        )
        .await?;
        let after: Identity = http::json(
            context
                .http
                .get(format!("{base}/api/cli/whoami"))
                .header("Authorization", authorization)
                .header("X-Factory-Whoami-Extended", "true")
                .header("X-Factory-Org-Id", org),
            context.clock.now(),
        )
        .await?;
        if before != after {
            return Err(ProviderError::InvalidData);
        }
        let mut usage = parse(after, response, context.clock.now())?;
        if let Some(email) = profile_email(context, base, &key.0).await {
            usage.account.label = email;
        }
        Ok(usage)
    }
}
impl ProviderAdapter for FactoryProvider {
    fn account_ref(&self) -> Option<AccountRef> {
        Some(AccountRef {
            origin: None,
            id: "local".into(),
            label: "Local Factory account".into(),
        })
    }
    fn id(&self) -> ProviderId {
        ProviderId("factory".into())
    }
    fn idempotent(&self) -> bool {
        true
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(self.fetch_api(
            context,
            "https://api.factory.ai",
            "https://api.eu.factory.ai",
        ))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keychain_selection_only_probes_known_exact_accounts() {
        let mut queried = Vec::new();
        let selected = select_keychain_account(|account| {
            queried.push(account.to_owned());
            Ok(account == "auth-encryption-key")
        })
        .unwrap();
        assert_eq!(selected.as_deref(), Some("auth-encryption-key"));
        assert_eq!(
            queried,
            ["auth-encryption-key-security-cli", "auth-encryption-key"]
        );
        assert!(!valid_keychain_account("unrelated-account"));
    }

    #[test]
    fn native_login_supports_factory_sixteen_byte_iv() {
        // Synthetic Node.js AES-256-GCM fixture matching Factory's 16-byte IV.
        let encoded = b"BwcHBwcHBwcHBwcHBwcHBw==:punBh0Y+Qneod4+vE9SjMg==:ekf+7xaZyoP5JjRwIi/uiggDIBp6sHaVxDZ5txQ8gMcI8Fu1f2+7+FZM80osdd70dNWWVbfH121VJvq7rUGkNVxZRAdnFulvAmN3AU0wns+k";
        let plaintext = decrypt_native(encoded, &[42; 32]).unwrap();
        assert!(parse_native(&plaintext).is_ok());
        assert!(decrypt_native(encoded, &[43; 32]).is_err());
        let tampered = String::from_utf8(encoded.to_vec())
            .unwrap()
            .replace("punB", "qunB");
        assert!(decrypt_native(tampered.as_bytes(), &[42; 32]).is_err());
    }
    #[tokio::test]
    async fn native_keychain_read_uses_the_frozen_selector_without_fallback() {
        use base64::{Engine, engine::general_purpose::STANDARD};
        use ring::aead;
        let directory = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        std::fs::create_dir_all(&directory).unwrap();
        let key = [42u8; 32];
        let nonce = [7u8; 12];
        let cipher =
            aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_256_GCM, &key).unwrap());
        let mut bytes =
            br#"{"access_token":"synthetic-factory-token","active_organization_id":"fixture-org"}"#
                .to_vec();
        cipher
            .seal_in_place_append_tag(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::empty(),
                &mut bytes,
            )
            .unwrap();
        let tag = bytes.split_off(bytes.len() - 16);
        std::fs::write(
            directory.join("auth.v2.keyring"),
            format!(
                "{}:{}:{}",
                STANDARD.encode(nonce),
                STANDARD.encode(tag),
                STANDARD.encode(bytes)
            ),
        )
        .unwrap();
        let mut source = crate::accounts::sources::FactoryNativeReference {
            directory: directory.clone(),
            location: crate::accounts::sources::FactoryLocation::V2Keyring,
            entry_key: Some("auth-encryption-key".into()),
        };
        assert!(
            load_native_with_keychain(&source, |account| async move {
                assert_eq!(account, "auth-encryption-key");
                Ok(Some(key.to_vec()))
            })
            .await
            .is_ok()
        );
        source.entry_key = None;
        assert!(
            load_native_with_keychain(&source, |_| async { panic!("unbound keychain read") })
                .await
                .is_err()
        );
        std::fs::remove_dir_all(directory).unwrap();
    }

    fn jwt(claims: serde_json::Value) -> String {
        use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
        format!("e30.{}.fixture", URL_SAFE_NO_PAD.encode(claims.to_string()))
    }
    #[tokio::test]
    async fn oauth_organization_disagreement_fails_before_http() {
        use crate::accounts::{AccountError, Credential};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        for token in [
            jwt(serde_json::json!({"org_id":"A", "exp":4102444800_i64})),
            jwt(serde_json::json!({"organization_id":"B", "exp":4102444800_i64})),
            jwt(serde_json::json!({"org_id":"A", "external_org_id":"C", "exp":4102444800_i64})),
            "opaque".into(),
        ] {
            let owned = Credential::FactoryOAuth {
                access_token: token.clone(),
                refresh_token: "fixture-refresh".into(),
                organization_id: Some("B".into()),
                expires_at: 4102444800,
                refresh_pending: false,
            };
            let native = parse_native(
                &serde_json::to_vec(&serde_json::json!({
                    "access_token":token, "active_organization_id":"B"
                }))
                .unwrap(),
            )
            .unwrap();
            for credential in [owned, native] {
                assert!(matches!(
                    fetch_oauth_at(&http::fixture::context(), &credential, &endpoint).await,
                    Err(AccountError::OAuth)
                ));
            }
        }
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(20), listener.accept())
                .await
                .is_err()
        );
    }
    #[tokio::test]
    async fn oauth_accepts_factory_external_organization_binding() {
        let credential = crate::accounts::Credential::FactoryOAuth {
            access_token: jwt(
                serde_json::json!({"org_id":"workos-org", "external_org_id":"factory-org", "exp":4102444800_i64}),
            ),
            refresh_token: String::new(),
            organization_id: Some("factory-org".into()),
            expires_at: 4102444800,
            refresh_pending: false,
        };
        let (endpoint, server) = http::fixture::server(vec![
            serde_json::json!({"usesTokenRateLimitsBilling":false}),
        ])
        .await;
        let usage = fetch_oauth_at(&http::fixture::context(), &credential, &endpoint)
            .await
            .unwrap();
        assert_eq!(usage.account.id, "workos-org");
        assert_eq!(server.await.unwrap().len(), 1);
    }
    #[tokio::test]
    async fn oauth_reports_only_token_organization_after_provider_acceptance() {
        use crate::accounts::Credential;
        for binding in [None, Some("A".into())] {
            let token = jwt(serde_json::json!({"org_id":"A", "exp":4102444800_i64}));
            let credential = Credential::FactoryOAuth {
                access_token: token,
                refresh_token: "fixture-refresh".into(),
                organization_id: binding,
                expires_at: 4102444800,
                refresh_pending: false,
            };
            let (endpoint, server) = http::fixture::server(vec![
                serde_json::json!({"usesTokenRateLimitsBilling":false}),
            ])
            .await;
            let usage = fetch_oauth_at(&http::fixture::context(), &credential, &endpoint)
                .await
                .unwrap();
            assert_eq!(usage.account.id, "A");
            assert_eq!(server.await.unwrap().len(), 1);
        }
    }
    #[tokio::test]
    async fn workos_contract_rotation_and_quota_are_separate() {
        use crate::accounts::Credential;
        let credential = Credential::FactoryOAuth {
            access_token: "old".into(),
            refresh_token: "refresh+&".into(),
            organization_id: Some("org+&".into()),
            expires_at: 0,
            refresh_pending: true,
        };
        for rotated in [None, Some("rotated")] {
            let token = jwt(serde_json::json!({"org_id":"org+&"}));
            let (endpoint, server) = http::fixture::server(vec![
                serde_json::json!({"access_token":token, "refresh_token":rotated}),
            ])
            .await;
            let updated = refresh_at(&http::fixture::context(), &credential, &endpoint)
                .await
                .unwrap();
            assert!(
                matches!(&updated, Credential::FactoryOAuth { refresh_token, refresh_pending: false, expires_at: 0, .. } if refresh_token == rotated.unwrap_or("refresh+&"))
            );
            let requests = server.await.unwrap();
            assert_eq!(requests.len(), 1);
            assert!(requests[0].starts_with("POST "));
            assert!(requests[0].contains("client_id=client_01HNM792M5G5G1A2THWPXKFMXB"));
            assert!(requests[0].contains("refresh_token=refresh%2B%26"));
            assert!(requests[0].contains("organization_id=org%2B%26"));
            assert!(
                requests[0]
                    .to_lowercase()
                    .contains("application/x-www-form-urlencoded")
            );
            let (endpoint, server) = http::fixture::server(vec![
                serde_json::json!({"usesTokenRateLimitsBilling":false}),
            ])
            .await;
            let usage = fetch_oauth_at(&http::fixture::context(), &updated, &endpoint)
                .await
                .unwrap();
            assert_eq!(usage.account.id, "org+&");
            assert_eq!(usage.windows[0].note.as_deref(), Some("legacy-billing"));
            let requests = server.await.unwrap();
            assert_eq!(requests.len(), 1);
            assert!(
                requests[0].starts_with("GET ") && requests[0].contains(&format!("Bearer {token}"))
            );
            assert!(!requests[0].to_lowercase().contains("x-factory-org-id"));
        }
        for body in [
            serde_json::json!({}),
            serde_json::json!({"access_token":""}),
            serde_json::json!({"access_token":"new", "refresh_token":""}),
        ] {
            let (endpoint, server) = http::fixture::server(vec![body]).await;
            assert!(
                refresh_at(&http::fixture::context(), &credential, &endpoint)
                    .await
                    .is_err()
            );
            assert_eq!(server.await.unwrap().len(), 1);
        }
    }
    #[tokio::test]
    async fn optional_profile_is_bounded_and_never_replaces_organization_identity() {
        use crate::accounts::Credential;
        for (status, email, expected) in [
            (
                200,
                serde_json::json!(" demo@example.invalid "),
                Some("demo@example.invalid"),
            ),
            (200, serde_json::json!("bad\n@example.invalid"), None),
            (200, serde_json::json!("x".repeat(255)), None),
            (200, serde_json::json!(42), None),
            (401, serde_json::json!("demo@example.invalid"), None),
            (500, serde_json::Value::Null, None),
        ] {
            let credential = Credential::FactoryOAuth {
                access_token: jwt(serde_json::json!({"org_id":"A"})),
                refresh_token: "refresh-sentinel".into(),
                organization_id: Some("A".into()),
                expires_at: 0,
                refresh_pending: false,
            };
            let (base, server) = http::fixture::server_status(vec![
                (
                    200,
                    serde_json::json!({"limits":{"standard":{"fiveHour":{"usedPercent":25}}}}),
                ),
                (
                    status,
                    serde_json::json!({"userProfile":{"email":email},"secret":"refresh-sentinel"}),
                ),
            ])
            .await;
            let usage = fetch_oauth_at(&http::fixture::context(), &credential, &base)
                .await
                .unwrap();
            assert_eq!(usage.account.id, "A");
            assert_eq!(usage.account.label, expected.unwrap_or("A"));
            assert_eq!(usage.windows[0].quota, Quota::from_used(Some(25.0)));
            assert!(
                !serde_json::to_string(&usage)
                    .unwrap()
                    .contains("refresh-sentinel")
            );
            let requests = server.await.unwrap();
            assert!(requests[1].starts_with("GET /api/app/auth/me "));
            assert!(!requests[1].to_lowercase().contains("x-factory-org-id"));
        }
    }
    #[tokio::test]
    async fn slow_profile_preserves_quota_inside_collector_deadline() {
        let (base, server) = http::fixture::server_status_with_async_action(
            vec![
                (200, serde_json::json!({"userId":"u","orgId":"o"})),
                (200, serde_json::json!({"usesTokenRateLimitsBilling":false})),
                (200, serde_json::json!({"userId":"u","orgId":"o"})),
                (
                    200,
                    serde_json::json!({"userProfile":{"email":"late@example.invalid"}}),
                ),
            ],
            |index| async move {
                if index == 3 {
                    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                }
            },
        )
        .await;
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_millis(400);
        let context = http::fixture::context();
        let usage = super::super::FETCH_DEADLINE
            .scope(
                deadline,
                tokio::time::timeout_at(
                    deadline,
                    FactoryProvider.fetch_api(&context, &base, &base),
                ),
            )
            .await
            .unwrap()
            .unwrap();
        assert_eq!(usage.account.id, "u:o");
        assert_eq!(usage.account.label, "u / o");
        assert_eq!(usage.windows[0].note.as_deref(), Some("legacy-billing"));
        server.await.unwrap();
    }
    fn identity() -> Identity {
        Identity {
            user_id: "demo-user".into(),
            org_id: "demo-org".into(),
            region: Some("global".into()),
            is_on_prem: false,
        }
    }
    #[test]
    fn pools_balances_and_expired_windows() {
        let response = serde_json::from_value(serde_json::json!({"limits":{"standard":{"fiveHour":{"usedPercent":20,"windowEnd":"2026-09-06T00:00:00Z"},"weekly":{"usedPercent":100,"windowEnd":"2026-09-01T00:00:00Z"}},"core":{"monthly":{"usedPercent":100}}},"extraUsageBalanceCents":1234})).unwrap();
        let now = OffsetDateTime::parse("2026-09-05T00:00:00Z", &Rfc3339).unwrap();
        let usage = parse(identity(), response, now).unwrap();
        assert_eq!(usage.windows.len(), 7);
        assert_eq!(
            usage
                .windows
                .iter()
                .map(|w| w.metric_id.as_deref().unwrap())
                .collect::<Vec<_>>(),
            [
                "factory-standard-five-hour",
                "factory-standard-weekly",
                "factory-standard-monthly",
                "factory-core-five-hour",
                "factory-core-weekly",
                "factory-core-monthly",
                "factory-extra-balance",
            ]
        );
        assert_eq!(usage.windows[0].quota, Quota::from_used(Some(20.0)));
        assert_eq!(usage.windows[1].quota, Quota::Unknown);
        assert_eq!(usage.windows[5].quota, Quota::from_used(Some(100.0)));
        assert_eq!(usage.windows[6].amounts.as_ref().unwrap().remaining, 12.34);
    }
    #[test]
    fn malformed_response_and_missing_pools_fail() {
        let response = serde_json::from_value::<Response>(
            serde_json::json!({"limits":{"standard":{"fiveHour":{"usedPercent":"bad"}}}}),
        )
        .unwrap();
        assert!(parse(identity(), response, OffsetDateTime::UNIX_EPOCH).is_err());
        let response = serde_json::from_value(serde_json::json!({"limits":{}})).unwrap();
        assert!(parse(identity(), response, OffsetDateTime::UNIX_EPOCH).is_err());
    }
    #[tokio::test]
    async fn legacy_billing_ignores_missing_or_stale_limits_and_keeps_identity_fence() {
        for limits in [
            serde_json::Value::Null,
            serde_json::json!({"standard":{"fiveHour":{"usedPercent":90,"windowEnd":"2000-01-01T00:00:00Z"}}}),
            serde_json::json!({"standard":"stale"}),
        ] {
            for changed in [false, true] {
                let before = serde_json::json!({"userId":"demo-user","orgId":"demo-org"});
                let after = if changed {
                    serde_json::json!({"userId":"demo-user","orgId":"other-org"})
                } else {
                    before.clone()
                };
                let mut response = serde_json::json!({"usesTokenRateLimitsBilling":false,"extraUsageBalanceCents":1234});
                if !limits.is_null() {
                    response["limits"] = limits.clone();
                }
                let (base, task) = http::fixture::server(vec![before, response, after]).await;
                let result = FactoryProvider
                    .fetch_api(&http::fixture::context(), &base, &base)
                    .await;
                if changed {
                    assert_eq!(result.unwrap_err(), ProviderError::InvalidData);
                } else {
                    let usage = result.unwrap();
                    assert_eq!(usage.account.id, "demo-user:demo-org");
                    assert_eq!(usage.windows.len(), 1);
                    assert_eq!(
                        usage.windows[0].metric_id.as_deref(),
                        Some("factory-billing-mode")
                    );
                    assert_eq!(usage.windows[0].note.as_deref(), Some("legacy-billing"));
                    assert_eq!(usage.windows[0].quota, Quota::Unknown);
                    assert!(usage.windows[0].amounts.is_none());
                }
                assert_eq!(task.await.unwrap().len(), 3);
            }
        }
    }
    #[test]
    fn token_billing_still_requires_limits_and_preserves_partial_unknowns() {
        for mode in [serde_json::Value::Null, serde_json::json!(true)] {
            for limits in [serde_json::Value::Null, serde_json::json!({})] {
                let response = serde_json::from_value(
                    serde_json::json!({"usesTokenRateLimitsBilling":mode,"limits":limits}),
                )
                .unwrap();
                assert_eq!(
                    parse(identity(), response, OffsetDateTime::UNIX_EPOCH).unwrap_err(),
                    ProviderError::InvalidData
                );
            }
            let response = serde_json::from_value(serde_json::json!({"usesTokenRateLimitsBilling":mode,"limits":{"core":{"monthly":{"usedPercent":25}}}})).unwrap();
            let usage = parse(identity(), response, OffsetDateTime::UNIX_EPOCH).unwrap();
            assert!(usage.windows[..5].iter().all(|w| w.quota == Quota::Unknown));
            assert_eq!(usage.windows[5].quota, Quota::from_used(Some(25.0)));
        }
    }
    #[tokio::test]
    async fn identity_and_org_are_checked_across_requests() {
        for changed in [false, true] {
            let before =
                serde_json::json!({"userId":"demo-user","orgId":"demo-org","region":"global"});
            let after = if changed {
                serde_json::json!({"userId":"different-user","orgId":"demo-org","region":"global"})
            } else {
                before.clone()
            };
            let (base, task) = http::fixture::server(vec![
                before,
                serde_json::json!({"limits":{"standard":{"fiveHour":{"usedPercent":25}}}}),
                after,
            ])
            .await;
            let context = http::fixture::context();
            let result = FactoryProvider.fetch_api(&context, &base, &base).await;
            assert_eq!(result.is_err(), changed);
            if let Ok(usage) = result {
                let identity = usage.account.verified.unwrap();
                assert_eq!(identity.subject, "demo-user");
                assert_eq!(identity.tenant.as_deref(), Some("demo-org"));
            }
            let requests = task.await.unwrap();
            assert!(requests[0].starts_with("GET /api/cli/whoami "));
            assert!(requests[1].starts_with("GET /api/billing/limits "));
            assert!(
                requests[1]
                    .to_lowercase()
                    .contains("x-factory-org-id: demo-org")
            );
            assert!(
                requests
                    .iter()
                    .all(|r| r.contains("Bearer synthetic-token"))
            );
        }
    }
}
