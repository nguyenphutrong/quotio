pub(crate) use crate::providers::http::json;
use crate::{
    domain::*,
    error::ProviderError,
    providers::{ProviderContext, Secret},
};
use serde_json::Value;
use time::OffsetDateTime;

pub fn key(context: &ProviderContext, env: &str) -> Result<Secret, ProviderError> {
    let key = context
        .credentials
        .get(env)
        .ok_or(ProviderError::Authentication)?;
    if key.0.trim().is_empty() || key.0.len() > 16384 || key.0.chars().any(char::is_control) {
        return Err(ProviderError::Authentication);
    }
    Ok(key)
}
pub fn number(value: Option<&Value>) -> Result<Option<f64>, ProviderError> {
    crate::providers::key_api::number(value)
}
pub fn date(value: Option<&Value>) -> Result<Option<OffsetDateTime>, ProviderError> {
    crate::providers::key_api::date(value)
}
#[allow(clippy::too_many_arguments)]
pub fn window(
    label: &str,
    used: Option<f64>,
    limit: Option<f64>,
    remaining: Option<f64>,
    unit: &str,
    resets_at: Option<OffsetDateTime>,
    source: &str,
    now: OffsetDateTime,
) -> Result<QuotaWindow, ProviderError> {
    if label.trim().is_empty()
        || unit.trim().is_empty()
        || [used, limit, remaining]
            .into_iter()
            .flatten()
            .any(|v| !v.is_finite() || v < 0.0)
    {
        return Err(ProviderError::InvalidData);
    }
    if limit
        .zip(remaining)
        .is_some_and(|(limit, remaining)| remaining > limit)
    {
        return Err(ProviderError::InvalidData);
    }
    let remaining = remaining.or_else(|| limit.zip(used).map(|(l, u)| (l - u).max(0.0)));
    let quota = limit
        .filter(|l| *l > 0.0)
        .zip(remaining)
        .map(|(l, r)| Quota::from_remaining(Some(r / l * 100.0)))
        .unwrap_or(Quota::Unknown);
    Ok(QuotaWindow {
        note: None,
        metric_id: None,
        label: label.into(),
        quota,
        consumption: used.map(|used| Consumption {
            used,
            unit: unit.into(),
        }),
        amounts: remaining.map(|remaining| QuotaAmounts {
            remaining,
            limit,
            unit: unit.into(),
        }),
        resets_at,
        reset_description: None,
        provenance: Provenance {
            source: source.into(),
            confidence: if used.is_some() || remaining.is_some() {
                Confidence::Exact
            } else {
                Confidence::Unknown
            },
        },
        fetched_at: now,
    })
}
pub fn usage(
    id: &str,
    key: &Secret,
    scope: &str,
    windows: Vec<QuotaWindow>,
) -> Result<ProviderUsage, ProviderError> {
    if windows.is_empty()
        || windows
            .iter()
            .all(|w| w.quota == Quota::Unknown && w.amounts.is_none() && w.consumption.is_none())
        || windows.iter().any(|w| !w.quota.is_valid())
    {
        return Err(ProviderError::InvalidData);
    }
    Ok(ProviderUsage {
        reset_credits: None,
        antigravity_subscription: None,
        codex_profile: None,
        codex_reset_credits: None,
        diagnostics: vec![],
        account_ref: None,
        provider: ProviderId(id.into()),
        account: account_identity(id, key, scope),
        windows,
    })
}
pub fn account_identity(id: &str, key: &Secret, scope: &str) -> AccountIdentity {
    let digest = ring::digest::digest(
        &ring::digest::SHA256,
        format!("{id}\0{scope}\0{}", key.0).as_bytes(),
    );
    let fingerprint: String = digest.as_ref()[..16]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    AccountIdentity {
        subscription_status: None,
        id: format!("key:{fingerprint}"),
        label: format!("{id} API key"),
        plan: None,
    }
}
#[cfg(target_os = "macos")]
fn keychain_options(
    service: &str,
    account: &str,
) -> security_framework::passwords::PasswordOptions {
    use core_foundation::{base::TCFType, string::CFString};
    use security_framework_sys::item::kSecUseAuthenticationUI;
    unsafe extern "C" {
        static kSecUseAuthenticationUIFail: core_foundation::string::CFStringRef;
    }
    let mut options =
        security_framework::passwords::PasswordOptions::new_generic_password(service, account);
    #[allow(deprecated)]
    unsafe {
        options.query.push((
            CFString::wrap_under_get_rule(kSecUseAuthenticationUI),
            CFString::wrap_under_get_rule(kSecUseAuthenticationUIFail).into_CFType(),
        ));
    }
    options
}
#[cfg(target_os = "macos")]
pub(crate) fn keychain_item_exists(
    service: &str,
    account: Option<&str>,
) -> Result<bool, ProviderError> {
    use core_foundation::{
        base::{CFType, TCFType},
        dictionary::CFDictionary,
        string::CFString,
    };
    use security_framework_sys::item::kSecAttrAccount;
    #[allow(deprecated)]
    let mut query = keychain_options(service, account.unwrap_or_default()).query;
    if account.is_none() {
        unsafe {
            let account_key = CFString::wrap_under_get_rule(kSecAttrAccount);
            query.retain(|(key, _)| key != &account_key);
        }
    }
    let query = CFDictionary::<CFString, CFType>::from_CFType_pairs(&query);
    use security_framework_sys::keychain_item::SecItemCopyMatching;
    let status = unsafe { SecItemCopyMatching(query.as_concrete_TypeRef(), std::ptr::null_mut()) };
    match status {
        0 => Ok(true),
        -25300 => Ok(false),
        _ => Err(ProviderError::CredentialStorage),
    }
}
#[cfg(not(target_os = "macos"))]
pub(crate) fn keychain_item_exists(_: &str, _: Option<&str>) -> Result<bool, ProviderError> {
    Err(ProviderError::Unavailable)
}
#[cfg(target_os = "macos")]
fn unique_keychain_account(
    value: &core_foundation::base::CFType,
) -> Result<Option<String>, ProviderError> {
    use core_foundation::{
        array::CFArray,
        base::{CFType, TCFType},
        dictionary::CFDictionary,
        string::CFString,
    };
    if value.type_of() != CFArray::<CFType>::type_id() {
        return Err(ProviderError::CredentialStorage);
    }
    let entries = unsafe { CFArray::<CFType>::wrap_under_get_rule(value.as_CFTypeRef().cast()) };
    if entries.is_empty() {
        return Ok(None);
    }
    if entries.len() != 1 {
        return Err(ProviderError::CredentialStorage);
    }
    let entry = entries.get(0).ok_or(ProviderError::CredentialStorage)?;
    if entry.type_of() != CFDictionary::<CFString, CFType>::type_id() {
        return Err(ProviderError::CredentialStorage);
    }
    let attributes = unsafe {
        CFDictionary::<CFString, CFType>::wrap_under_get_rule(entry.as_CFTypeRef().cast())
    };
    let account_key =
        unsafe { CFString::wrap_under_get_rule(security_framework_sys::item::kSecAttrAccount) };
    let account = attributes
        .find(&account_key)
        .and_then(|v| v.downcast::<CFString>())
        .ok_or(ProviderError::CredentialStorage)?
        .to_string();
    if account.len() > 4096 {
        return Err(ProviderError::CredentialStorage);
    }
    Ok(Some(account))
}
#[cfg(target_os = "macos")]
fn discover_keychain_account(service: &str) -> Result<Option<String>, ProviderError> {
    use core_foundation::{
        base::{CFType, TCFType},
        boolean::CFBoolean,
        dictionary::CFDictionary,
        string::CFString,
    };
    use security_framework_sys::item::{
        kSecAttrAccount, kSecMatchLimit, kSecMatchLimitAll, kSecReturnAttributes,
    };
    #[allow(deprecated)]
    let mut query = keychain_options(service, "").query;
    unsafe {
        let account_key = CFString::wrap_under_get_rule(kSecAttrAccount);
        query.retain(|(key, _)| key != &account_key);
        query.push((
            CFString::wrap_under_get_rule(kSecMatchLimit),
            CFString::wrap_under_get_rule(kSecMatchLimitAll).into_CFType(),
        ));
        query.push((
            CFString::wrap_under_get_rule(kSecReturnAttributes),
            CFBoolean::true_value().into_CFType(),
        ));
    }
    let query = CFDictionary::from_CFType_pairs(&query);
    use security_framework_sys::keychain_item::SecItemCopyMatching;
    let mut result: core_foundation::base::CFTypeRef = std::ptr::null();
    let status = unsafe { SecItemCopyMatching(query.as_concrete_TypeRef(), &mut result) };
    let value = if result.is_null() {
        None
    } else {
        Some(unsafe { CFType::wrap_under_create_rule(result) })
    };
    if status == -25300 {
        return Ok(None);
    }
    if status != 0 {
        return Err(ProviderError::CredentialStorage);
    }
    unique_keychain_account(&value.ok_or(ProviderError::CredentialStorage)?)
}
pub fn read_keychain(
    service: &str,
    account: Option<&str>,
) -> Result<Option<Vec<u8>>, ProviderError> {
    #[cfg(target_os = "macos")]
    {
        let discovered;
        let account = match account {
            Some(account) => account,
            None => {
                discovered = discover_keychain_account(service)?;
                let Some(account) = discovered.as_deref() else {
                    return Ok(None);
                };
                account
            }
        };
        match security_framework::passwords::generic_password(keychain_options(service, account)) {
            Ok(bytes) if bytes.len() <= 1024 * 1024 => Ok(Some(bytes)),
            Ok(_) => Err(ProviderError::InvalidData),
            Err(error) if error.code() == -25300 => Ok(None),
            Err(_) => Err(ProviderError::CredentialStorage),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (service, account);
        Err(ProviderError::Unavailable)
    }
}
#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use core_foundation::{
        array::CFArray,
        base::{CFType, TCFType},
        dictionary::CFDictionary,
        string::CFString,
    };
    #[test]
    fn keychain_metadata_requires_one_explicit_account() {
        for names in [vec![], vec!["account-a"], vec!["account-a", "account-b"]] {
            let entries: Vec<CFType> = names
                .iter()
                .map(|name| {
                    CFDictionary::from_CFType_pairs(&[(
                        CFString::new("acct"),
                        CFString::new(name).into_CFType(),
                    )])
                    .into_CFType()
                })
                .collect();
            let result = unique_keychain_account(&CFArray::from_CFTypes(&entries).into_CFType());
            match names.len() {
                0 => assert_eq!(result.unwrap(), None),
                1 => assert_eq!(result.unwrap().as_deref(), Some("account-a")),
                _ => assert_eq!(result.unwrap_err(), ProviderError::CredentialStorage),
            }
        }
    }
}
