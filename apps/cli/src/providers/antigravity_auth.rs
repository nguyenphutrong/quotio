use super::{ProviderContext, Secret, http};
use crate::{
    accounts::{
        self, AccountError,
        sources::{AntigravityLocation, AntigravityNativeReference},
    },
    error::ProviderError,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Deserialize;
use std::sync::Arc;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

const MAX_CREDENTIAL_BYTES: usize = 1024 * 1024;
const REFRESH_URL: &str = "https://oauth2.googleapis.com/token";
// Public client identifier used by the Swift AntigravityQuotaFetcher. The secret
// must be supplied explicitly and stays inside the owned credential vault.
const CLIENT_ID: &str = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com";

#[derive(Clone, Deserialize)]
pub(crate) struct Credential {
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub expiry: Option<String>,
}
impl Credential {
    fn fingerprint(&self) -> String {
        crate::cache::fingerprint(&[
            "antigravity_native_token",
            self.access_token.as_deref().unwrap_or_default(),
            self.expiry.as_deref().unwrap_or_default(),
        ])
    }
    fn expires_at(&self) -> Option<i64> {
        self.expiry
            .as_ref()
            .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
            .map(|date| date.unix_timestamp())
    }
    fn usable_token(&self, now: OffsetDateTime) -> Option<Secret> {
        if self
            .expires_at()
            .is_some_and(|expiry| expiry <= now.unix_timestamp() + 60)
        {
            return None;
        }
        self.access_token.clone().map(Secret)
    }
}
pub(crate) trait Store: Send + Sync {
    fn credential(&self) -> Result<Credential, ProviderError>;
}
pub(crate) struct NativeStore;

pub(crate) async fn authorize() -> Result<(), ProviderError> {
    tokio::task::spawn_blocking(|| {
        #[cfg(target_os = "macos")]
        {
            let bytes = crate::keychain::with_interaction(true, || {
                security_framework::passwords::get_generic_password("gemini", "antigravity")
            })
            .map_err(|_| ProviderError::LocalCredentialStorage)?;
            parse_credential(&bytes)?;
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err(ProviderError::Unavailable)
        }
    })
    .await
    .map_err(|_| ProviderError::Internal)?
}

async fn keychain_task<T: Send + 'static>(
    operation: impl FnOnce() -> Result<T, ProviderError> + Send + 'static,
) -> Result<T, ProviderError> {
    tokio::time::timeout(
        std::time::Duration::from_secs(5),
        tokio::task::spawn_blocking(operation),
    )
    .await
    .map_err(|_| ProviderError::LocalCredentialStorage)?
    .map_err(|_| ProviderError::Internal)?
}

fn valid_secret(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 16_384
        && !value.chars().any(|c| c.is_whitespace() || c.is_control())
}

fn parse_credential(bytes: &[u8]) -> Result<Credential, ProviderError> {
    if bytes.len() > MAX_CREDENTIAL_BYTES {
        return Err(ProviderError::Authentication);
    }
    let raw = std::str::from_utf8(bytes)
        .map_err(|_| ProviderError::Authentication)?
        .trim();
    let decoded;
    let bytes = if let Some(encoded) = raw.strip_prefix("go-keyring-base64:") {
        decoded = STANDARD
            .decode(encoded)
            .map_err(|_| ProviderError::Authentication)?;
        decoded.as_slice()
    } else {
        raw.as_bytes()
    };
    let mut object: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|_| ProviderError::Authentication)?;
    let token = object
        .get_mut("token")
        .map(serde_json::Value::take)
        .unwrap_or(object);
    let mut credential: Credential =
        serde_json::from_value(token).map_err(|_| ProviderError::Authentication)?;
    for field in [&mut credential.access_token, &mut credential.refresh_token] {
        *field = field
            .take()
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty());
        if field.as_ref().is_some_and(|s| !valid_secret(s)) {
            return Err(ProviderError::Authentication);
        }
    }
    if credential.access_token.is_none()
        || credential
            .expiry
            .as_ref()
            .is_some_and(|expiry| OffsetDateTime::parse(expiry, &Rfc3339).is_err())
    {
        return Err(ProviderError::Authentication);
    }
    Ok(credential)
}

#[cfg(target_os = "macos")]
fn options(service: &str, account: &str) -> security_framework::passwords::PasswordOptions {
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
fn read_password(service: &str, account: &str) -> Result<Option<Vec<u8>>, ProviderError> {
    #[cfg(target_os = "macos")]
    {
        match crate::keychain::with_interaction(false, || {
            security_framework::passwords::generic_password(options(service, account))
        }) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.code() == -25300 => Ok(None),
            Err(_) => Err(ProviderError::LocalCredentialStorage),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (service, account);
        Err(ProviderError::Unavailable)
    }
}
impl Store for NativeStore {
    fn credential(&self) -> Result<Credential, ProviderError> {
        read_keychain("gemini", "antigravity")
    }
}
fn read_keychain(service: &str, account: &str) -> Result<Credential, ProviderError> {
    parse_credential(&read_password(service, account)?.ok_or(ProviderError::Authentication)?)
}

pub(crate) struct Session {
    pub token: Secret,
    credential: Credential,
    store: Arc<dyn Store>,
}
impl Session {
    pub async fn load(
        store: Arc<dyn Store>,
        context: &ProviderContext,
    ) -> Result<Self, ProviderError> {
        let source = store.clone();
        let credential = keychain_task(move || source.credential()).await?;
        let token = credential
            .usable_token(context.clock.now())
            .ok_or(ProviderError::OwnerRefreshRequired)?;
        Ok(Self {
            token,
            credential,
            store,
        })
    }
    pub async fn verify(&self) -> Result<(), ProviderError> {
        let store = self.store.clone();
        let fingerprint = self.credential.fingerprint();
        keychain_task(move || {
            if store.credential()?.fingerprint() != fingerprint {
                return Err(ProviderError::Authentication);
            }
            Ok(())
        })
        .await
    }
}

pub(crate) async fn usage_cache_identity() -> Option<String> {
    keychain_task(|| {
        let credential = NativeStore.credential()?;
        credential
            .usable_token(OffsetDateTime::now_utc())
            .ok_or(ProviderError::Authentication)?;
        Ok(credential.fingerprint())
    })
    .await
    .ok()
}

pub async fn reference_token(
    source: &AntigravityNativeReference,
) -> Result<accounts::Credential, AccountError> {
    source.identity()?;
    let credential = match source.location {
        AntigravityLocation::GeminiKeychain => {
            if source.path.is_some() {
                return Err(AccountError::Input);
            }
            keychain_task(move || read_keychain("gemini", "antigravity")).await?
        }
        AntigravityLocation::StateDb => {
            let path = source.path.clone().ok_or(AccountError::Input)?;
            if !path.is_absolute() {
                return Err(AccountError::Input);
            }
            let bytes = super::catalog::oauth_editors::native_sqlite_rows(path,
                "SELECT json_group_array(json_object('key',key,'value',value)) FROM (SELECT key,value FROM ItemTable WHERE key IN ('antigravityUnifiedStateSync.oauthToken','jetskiStateSync.agentManagerInitState') ORDER BY CASE key WHEN 'antigravityUnifiedStateSync.oauthToken' THEN 0 ELSE 1 END LIMIT 1);").await?;
            parse_state_rows(&bytes)?
        }
    };
    let expires_at = credential.expires_at();
    let access_token = credential
        .usable_token(OffsetDateTime::now_utc())
        .ok_or(ProviderError::OwnerRefreshRequired)?
        .0;
    Ok(accounts::Credential::AntigravityToken {
        access_token,
        expires_at,
    })
}

fn parse_state_rows(bytes: &[u8]) -> Result<Credential, ProviderError> {
    let rows: Vec<serde_json::Value> =
        serde_json::from_slice(bytes).map_err(|_| ProviderError::InvalidData)?;
    if rows.len() != 1 {
        return Err(ProviderError::Authentication);
    }
    let value = rows[0]
        .get("value")
        .and_then(serde_json::Value::as_str)
        .ok_or(ProviderError::InvalidData)?;
    if value.len() > MAX_CREDENTIAL_BYTES {
        return Err(ProviderError::InvalidData);
    }
    let data = STANDARD
        .decode(value)
        .map_err(|_| ProviderError::InvalidData)?;
    if rows[0].get("key").and_then(serde_json::Value::as_str)
        == Some("antigravityUnifiedStateSync.oauthToken")
    {
        let mut oauth = None;
        visit_fields(&data, |number, wire, entry| {
            if number != 1 {
                return Ok(());
            }
            if wire != 2 {
                return Err(ProviderError::InvalidData);
            }
            if find_field(entry, 1)? != Some(b"oauthTokenInfoSentinelKey".as_slice()) {
                return Ok(());
            }
            if oauth.is_some() {
                return Err(ProviderError::InvalidData);
            }
            let value = find_field(entry, 2)?.ok_or(ProviderError::InvalidData)?;
            let encoded = find_field(value, 1)?.ok_or(ProviderError::InvalidData)?;
            let token = STANDARD
                .decode(encoded)
                .map_err(|_| ProviderError::InvalidData)?;
            oauth = Some(protobuf_credential(&token)?);
            Ok(())
        })?;
        return oauth.ok_or(ProviderError::Authentication);
    }
    // agentManagerInitState stores OAuth credentials in top-level field 6.
    // Unrelated length-delimited fields are opaque, never credential candidates.
    protobuf_credential(find_field(&data, 6)?.ok_or(ProviderError::Authentication)?)
}
fn protobuf_credential(data: &[u8]) -> Result<Credential, ProviderError> {
    let token = find_field(data, 1)?.ok_or(ProviderError::Authentication)?;
    // Validate token type and refresh shape, although borrowed reads discard them.
    find_field(data, 2)?;
    find_field(data, 3)?;
    let token = std::str::from_utf8(token).map_err(|_| ProviderError::InvalidData)?;
    if !valid_secret(token) {
        return Err(ProviderError::Authentication);
    }
    let expiry = match find_field(data, 4)? {
        Some(bytes) => {
            let mut seconds = None;
            let mut nanos = None;
            visit_fields(bytes, |number, wire, value| {
                let slot = match number {
                    1 => &mut seconds,
                    2 => &mut nanos,
                    _ => return Ok(()),
                };
                if wire != 0 || slot.is_some() {
                    return Err(ProviderError::InvalidData);
                }
                *slot = Some(varint(value, 0)?.0);
                Ok(())
            })?;
            if nanos.is_some_and(|value| value > 999_999_999) {
                return Err(ProviderError::InvalidData);
            }
            let seconds = seconds.ok_or(ProviderError::InvalidData)?;
            let seconds = i64::try_from(seconds).map_err(|_| ProviderError::InvalidData)?;
            let seconds = if seconds > 10_000_000_000 {
                seconds / 1000
            } else {
                seconds
            };
            Some(
                OffsetDateTime::from_unix_timestamp(seconds)
                    .map_err(|_| ProviderError::InvalidData)?
                    .format(&Rfc3339)
                    .map_err(|_| ProviderError::InvalidData)?,
            )
        }
        None => None,
    };
    // Borrowed references deliberately discard refresh material.
    Ok(Credential {
        access_token: Some(token.into()),
        refresh_token: None,
        expiry,
    })
}
fn varint(data: &[u8], mut offset: usize) -> Result<(u64, usize), ProviderError> {
    let mut value = 0u64;
    for index in 0..10 {
        let byte = *data.get(offset).ok_or(ProviderError::InvalidData)?;
        if index == 9 && byte > 1 {
            return Err(ProviderError::InvalidData);
        }
        value |= u64::from(byte & 0x7f) << (index * 7);
        offset += 1;
        if byte & 0x80 == 0 {
            return Ok((value, offset));
        }
    }
    Err(ProviderError::InvalidData)
}
fn delimited(data: &[u8], offset: usize) -> Result<&[u8], ProviderError> {
    let (length, start) = varint(data, offset)?;
    let length = usize::try_from(length).map_err(|_| ProviderError::InvalidData)?;
    data.get(
        start
            ..start
                .checked_add(length)
                .ok_or(ProviderError::InvalidData)?,
    )
    .ok_or(ProviderError::InvalidData)
}
fn find_field(data: &[u8], target: u64) -> Result<Option<&[u8]>, ProviderError> {
    let mut found = None;
    visit_fields(data, |number, wire, value| {
        if number == target {
            if wire != 2 || found.is_some() {
                return Err(ProviderError::InvalidData);
            }
            found = Some(value);
        }
        Ok(())
    })?;
    Ok(found)
}
fn visit_fields<'a>(
    data: &'a [u8],
    mut visit: impl FnMut(u64, u64, &'a [u8]) -> Result<(), ProviderError>,
) -> Result<(), ProviderError> {
    let mut offset = 0;
    while offset < data.len() {
        let (tag, start) = varint(data, offset)?;
        if tag >> 3 == 0 || tag >> 3 > 0x1fff_ffff {
            return Err(ProviderError::InvalidData);
        }
        let wire = tag & 7;
        offset = match wire {
            0 => varint(data, start)?.1,
            1 => start.checked_add(8).ok_or(ProviderError::InvalidData)?,
            2 => {
                let (length, value_start) = varint(data, start)?;
                value_start
                    .checked_add(usize::try_from(length).map_err(|_| ProviderError::InvalidData)?)
                    .ok_or(ProviderError::InvalidData)?
            }
            5 => start.checked_add(4).ok_or(ProviderError::InvalidData)?,
            _ => return Err(ProviderError::InvalidData),
        };
        if offset > data.len() {
            return Err(ProviderError::InvalidData);
        }
        let value = if wire == 2 {
            delimited(data, start)?
        } else {
            &data[start..offset]
        };
        visit(tag >> 3, wire, value)?;
    }
    Ok(())
}

pub fn owned_credential(
    input: accounts::api::AntigravityOwnedInput,
) -> Result<accounts::Credential, AccountError> {
    if !valid_secret(&input.access_token)
        || !valid_secret(&input.refresh_token)
        || !valid_secret(&input.client_secret)
        || input.client_id != CLIENT_ID
        || input.expires_at < 0
    {
        return Err(AccountError::Input);
    }
    Ok(accounts::Credential::AntigravityOAuth {
        access_token: input.access_token,
        refresh_token: input.refresh_token,
        expires_at: input.expires_at,
        client_id: input.client_id,
        client_secret: input.client_secret,
        refresh_pending: false,
    })
}

pub async fn refresh_owned(
    context: &ProviderContext,
    credential: &accounts::Credential,
) -> Result<accounts::Credential, AccountError> {
    refresh_owned_at(context, credential, REFRESH_URL).await
}
async fn refresh_owned_at(
    context: &ProviderContext,
    credential: &accounts::Credential,
    endpoint: &str,
) -> Result<accounts::Credential, AccountError> {
    let accounts::Credential::AntigravityOAuth {
        refresh_token,
        client_id,
        client_secret,
        ..
    } = credential
    else {
        return Err(AccountError::Unsupported);
    };
    if client_id != CLIENT_ID || !valid_secret(client_secret) || !valid_secret(refresh_token) {
        return Err(AccountError::Input);
    }
    let response = context
        .http
        .post(endpoint)
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token.as_str()),
            ("client_id", client_id.as_str()),
            ("client_secret", client_secret.as_str()),
        ])
        .send()
        .await
        .map_err(|error| {
            if error.is_timeout() {
                ProviderError::Timeout
            } else {
                ProviderError::Transient
            }
        })?;
    if matches!(response.status().as_u16(), 400 | 401 | 403) {
        return Err(ProviderError::Authentication.into());
    }
    #[derive(Deserialize)]
    struct Response {
        access_token: String,
        refresh_token: Option<String>,
        expires_in: i64,
    }
    let response: Response = http::json_response(response, context.clock.now()).await?;
    if !valid_secret(&response.access_token)
        || response
            .refresh_token
            .as_ref()
            .is_some_and(|value| !valid_secret(value))
        || !(61..=86400).contains(&response.expires_in)
    {
        return Err(AccountError::OAuth);
    }
    let expiry = context
        .clock
        .now()
        .unix_timestamp()
        .checked_add(response.expires_in)
        .ok_or(AccountError::OAuth)?;
    let mut updated = credential.clone();
    if let accounts::Credential::AntigravityOAuth {
        access_token,
        refresh_token,
        expires_at,
        refresh_pending,
        ..
    } = &mut updated
    {
        *access_token = response.access_token;
        if let Some(rotated) = response.refresh_token {
            *refresh_token = rotated;
        }
        *expires_at = expiry;
        *refresh_pending = false;
    }
    Ok(updated)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Mutex;

    struct MemoryStore(Mutex<Credential>);
    impl Store for MemoryStore {
        fn credential(&self) -> Result<Credential, ProviderError> {
            Ok(self.0.lock().unwrap().clone())
        }
    }
    #[tokio::test]
    async fn borrowed_session_never_refreshes() {
        let store = Arc::new(MemoryStore(Mutex::new(Credential {
            access_token: Some("original".into()),
            refresh_token: Some("owner-refresh".into()),
            expiry: None,
        })));
        let context = http::fixture::context();
        let session = Session::load(store.clone(), &context).await.unwrap();
        assert_eq!(session.token.0, "original");
        // Access rotation with an unchanged refresh token must invalidate the read.
        store.0.lock().unwrap().access_token = Some("rotated-access".into());
        assert_eq!(session.verify().await, Err(ProviderError::Authentication));
        store.0.lock().unwrap().expiry = Some(context.clock.now().format(&Rfc3339).unwrap());
        assert!(matches!(
            Session::load(store, &context).await,
            Err(ProviderError::OwnerRefreshRequired)
        ));
    }
    #[test]
    fn keychain_fixtures_are_bounded_and_validated() {
        let raw = br#"{"token":{"access_token":" access ","refresh_token":"refresh","expiry":"2026-09-05T10:00:00Z"}}"#;
        for bytes in [
            raw.to_vec(),
            format!("go-keyring-base64:{}", STANDARD.encode(raw)).into_bytes(),
        ] {
            let credential = parse_credential(&bytes).unwrap();
            assert_eq!(credential.access_token.as_deref(), Some("access"));
            let expiry =
                OffsetDateTime::parse(credential.expiry.as_ref().unwrap(), &Rfc3339).unwrap();
            assert!(
                credential
                    .usable_token(expiry - time::Duration::seconds(60))
                    .is_none()
            );
            assert!(
                credential
                    .usable_token(expiry - time::Duration::seconds(61))
                    .is_some()
            );
        }
        for raw in [
            "{}",
            "raw-token",
            "{\"refresh_token\":\"x\"}",
            "{\"access_token\":\"x\",\"expiry\":\"bad\"}",
            "go-keyring-base64:bad",
        ] {
            assert!(parse_credential(raw.as_bytes()).is_err());
        }
        assert!(parse_credential(&vec![b'a'; MAX_CREDENTIAL_BYTES + 1]).is_err());
    }
    fn encode_varint(mut value: u64) -> Vec<u8> {
        let mut bytes = vec![];
        while value >= 128 {
            bytes.push(value as u8 | 0x80);
            value >>= 7;
        }
        bytes.push(value as u8);
        bytes
    }
    fn field(number: u8, value: &[u8]) -> Vec<u8> {
        let mut bytes = vec![number << 3 | 2];
        bytes.extend(encode_varint(value.len() as u64));
        bytes.extend(value);
        bytes
    }
    fn state_fixture(milliseconds: bool) -> String {
        let mut oauth = field(1, format!("ya29.{}", "a".repeat(120)).as_bytes());
        oauth.extend(field(3, b"owner-refresh"));
        let mut timestamp = vec![8];
        timestamp.extend(encode_varint(if milliseconds {
            1_800_000_000_000
        } else {
            1_800_000_000
        }));
        oauth.extend(field(4, &timestamp));
        STANDARD.encode(field(6, &oauth))
    }
    #[test]
    fn protobuf_seconds_milliseconds_and_malformed_lengths() {
        for milliseconds in [false, true] {
            let credential = parse_state_rows(
                &serde_json::to_vec(&json!([{"value":state_fixture(milliseconds)}])).unwrap(),
            )
            .unwrap();
            assert_eq!(credential.expires_at(), Some(1_800_000_000));
            assert!(credential.refresh_token.is_none());
        }
        for malformed in [vec![0x32, 0xff], vec![0x32, 0x7f, 1], vec![0xff; 11]] {
            assert!(
                parse_state_rows(
                    &serde_json::to_vec(&json!([{"value":STANDARD.encode(malformed)}])).unwrap()
                )
                .is_err()
            );
        }
    }
    fn parse_proto(data: &[u8]) -> Result<Credential, ProviderError> {
        parse_state_rows(&serde_json::to_vec(&json!([{"value": STANDARD.encode(data)}])).unwrap())
    }
    #[test]
    fn protobuf_ignores_embedded_credentials_and_validates_the_entire_message() {
        let legitimate = field(1, b"ya29.legitimate");
        let decoy = field(1, format!("ya29.{}", "decoy".repeat(30)).as_bytes());
        for number in [1, 2, 5, 7] {
            let mut message = field(number, &field(6, &decoy));
            message.extend(field(6, &legitimate));
            assert_eq!(
                parse_proto(&message).unwrap().access_token.as_deref(),
                Some("ya29.legitimate")
            );
            assert!(parse_proto(&field(number, &field(6, &decoy))).is_err());
        }
        let valid = field(6, &legitimate);
        for suffix in [
            field(6, &legitimate),
            vec![0x30, 0],
            vec![0x80],
            vec![0],
            vec![0x39, 1],
            vec![0x45, 1],
            vec![0x48, 0xff],
        ] {
            let mut message = valid.clone();
            message.extend(suffix);
            assert!(parse_proto(&message).is_err());
        }
        for number in [1, 2, 3, 4] {
            let value = if number == 4 {
                vec![8, 1]
            } else {
                b"synthetic".to_vec()
            };
            for wire in [0, 1, 5] {
                let mut oauth = legitimate.clone();
                oauth.push(number << 3 | wire);
                oauth.extend(vec![
                    0;
                    match wire {
                        1 => 8,
                        5 => 4,
                        _ => 1,
                    }
                ]);
                assert!(parse_proto(&field(6, &oauth)).is_err());
            }
            let mut oauth = if number == 1 {
                vec![]
            } else {
                legitimate.clone()
            };
            oauth.extend(field(number, &value));
            oauth.extend(field(number, &value));
            assert!(parse_proto(&field(6, &oauth)).is_err());
        }
        assert!(parse_proto(&valid).unwrap().expiry.is_none());
        for timestamp in [
            vec![],
            vec![8],
            vec![8, 1, 8, 2],
            vec![10, 0],
            vec![8, 1, 0],
            vec![8, 1, 16],
            vec![8, 1, 16, 0, 16, 0],
            vec![8, 1, 21, 0, 0, 0, 0],
            vec![8, 1, 0x80],
            [vec![8], vec![0xff; 10]].concat(),
            [vec![8, 1, 16], encode_varint(1_000_000_000)].concat(),
        ] {
            let mut oauth = legitimate.clone();
            oauth.extend(field(4, &timestamp));
            assert!(
                parse_proto(&field(6, &oauth)).is_err(),
                "accepted malformed timestamp"
            );
        }
        for value in ["not-base64!", "Mg", "", "===="] {
            assert!(
                parse_state_rows(&serde_json::to_vec(&json!([{"value":value}])).unwrap()).is_err()
            );
        }
        for data in [
            vec![0xff; 11],
            [vec![0x32], vec![0xff; 10]].concat(),
            [vec![0x48], vec![0xff; 10]].concat(),
        ] {
            assert!(parse_proto(&data).is_err());
        }
    }
    #[tokio::test]
    async fn native_state_rotation_invalidates_borrowed_session() {
        struct StateStore(Mutex<Vec<u8>>);
        impl Store for StateStore {
            fn credential(&self) -> Result<Credential, ProviderError> {
                parse_state_rows(&self.0.lock().unwrap())
            }
        }
        let store = Arc::new(StateStore(Mutex::new(
            include_bytes!("fixtures/antigravity-native-state.json").to_vec(),
        )));
        let context = http::fixture::context();
        let session = Session::load(store.clone(), &context).await.unwrap();
        session.verify().await.unwrap();
        let rotated = field(6, &field(1, b"ya29.rotated-native-access"));
        *store.0.lock().unwrap() =
            serde_json::to_vec(&json!([{"value":STANDARD.encode(rotated)}])).unwrap();
        assert_eq!(session.verify().await, Err(ProviderError::Authentication));
        let next = Session::load(store, &context).await.unwrap();
        assert_eq!(next.token.0, "ya29.rotated-native-access");
    }
    #[test]
    fn unified_state_reads_only_the_oauth_token_entry() {
        let oauth = field(1, b"ya29.synthetic-unified-access");
        let entry = |name: &[u8], value: &[u8]| {
            field(1, &[field(1, name), field(2, &field(1, value))].concat())
        };
        let state = [
            entry(b"authStateWithContextSentinelKey", b"unrelated"),
            entry(
                b"oauthTokenInfoSentinelKey",
                STANDARD.encode(oauth).as_bytes(),
            ),
        ]
        .concat();
        let rows = serde_json::to_vec(&json!([{"key":"antigravityUnifiedStateSync.oauthToken","value":STANDARD.encode(&state)}])).unwrap();
        let credential = parse_state_rows(&rows).unwrap();
        assert_eq!(
            credential.access_token.as_deref(),
            Some("ya29.synthetic-unified-access")
        );
        assert!(credential.refresh_token.is_none());
        for state in [
            entry(b"other", b"ignored"),
            entry(b"oauthTokenInfoSentinelKey", b"!bad-base64"),
            [state.clone(), state].concat(),
        ] {
            let rows = serde_json::to_vec(&json!([{"key":"antigravityUnifiedStateSync.oauthToken","value":STANDARD.encode(state)}])).unwrap();
            assert!(parse_state_rows(&rows).is_err());
        }
    }
    #[test]
    fn native_reader_wire_fixture() {
        // Synthetic field layout from NativeAntigravityCredentialReader.swift:
        // agentManagerInitState.6 -> access=1, refresh=3, Timestamp=4.
        let credential =
            parse_state_rows(include_bytes!("fixtures/antigravity-native-state.json")).unwrap();
        assert_eq!(
            credential.access_token.as_deref(),
            Some("ya29.synthetic-native-access")
        );
        assert_eq!(credential.expires_at(), Some(1_800_000_000));
        assert!(credential.refresh_token.is_none());
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn explicit_state_reference_reads_wal_without_owner_writes() {
        use std::{
            io::{BufRead, BufReader, Write},
            process::{Command, Stdio},
        };
        struct Fixture {
            directory: std::path::PathBuf,
            child: std::process::Child,
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = self.child.kill();
                let _ = self.child.wait();
                let _ = std::fs::remove_dir_all(&self.directory);
            }
        }
        let directory = std::env::temp_dir().join(format!(
            "quotio-antigravity-fixture-{}",
            accounts::random_string().unwrap()
        ));
        let database_directory =
            directory.join("Library/Application Support/Antigravity/User/globalStorage");
        std::fs::create_dir_all(&database_directory).unwrap();
        let path = database_directory.join("state.vscdb");
        let child = Command::new("/usr/bin/sqlite3")
            .args(["-init", "/dev/null", "-batch", "-bail"])
            .arg(&path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut fixture = Fixture { directory, child };
        writeln!(fixture.child.stdin.as_mut().unwrap(),
            "CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT); PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO ItemTable VALUES ('jetskiStateSync.agentManagerInitState','{}');\n.print ready", state_fixture(false)).unwrap();
        let mut output = BufReader::new(fixture.child.stdout.as_mut().unwrap());
        loop {
            let mut line = String::new();
            assert_ne!(output.read_line(&mut line).unwrap(), 0);
            if line.trim() == "ready" {
                break;
            }
        }
        let snapshot = || {
            let mut entries: Vec<_> = std::fs::read_dir(&database_directory)
                .unwrap()
                .map(|entry| {
                    let entry = entry.unwrap();
                    (entry.file_name(), std::fs::read(entry.path()).unwrap())
                })
                .collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            entries
        };
        let before = snapshot();
        assert!(
            before
                .iter()
                .any(|(name, bytes)| name.to_string_lossy().ends_with("-wal") && !bytes.is_empty())
        );
        let reference = AntigravityNativeReference {
            location: AntigravityLocation::StateDb,
            path: Some(path),
        };
        let token = reference_token(&reference).await.unwrap();
        assert!(
            matches!(token, accounts::Credential::AntigravityToken { access_token, expires_at: Some(1_800_000_000) } if access_token.starts_with("ya29."))
        );
        assert_eq!(before, snapshot());
        let missing = AntigravityNativeReference {
            location: AntigravityLocation::StateDb,
            path: Some(fixture.directory.join("missing.vscdb")),
        };
        assert!(reference_token(&missing).await.is_err());
    }
    fn owned() -> accounts::Credential {
        owned_credential(serde_json::from_value(json!({"kind":"antigravity_owned","label":"synthetic","access_token":"original","refresh_token":"owned-refresh","expires_at":1,"client_id":CLIENT_ID,"client_secret":"synthetic-secret"})).unwrap()).unwrap()
    }
    #[tokio::test]
    async fn owned_refresh_rotates_without_mutating_input() {
        let context = http::fixture::context();
        let credential = owned();
        let before = serde_json::to_vec(&credential).unwrap();
        let (base, task) = http::fixture::server(vec![
            json!({"access_token":"fresh","refresh_token":"rotated","expires_in":3600}),
        ])
        .await;
        let updated = refresh_owned_at(&context, &credential, &base)
            .await
            .unwrap();
        assert_eq!(before, serde_json::to_vec(&credential).unwrap());
        assert!(
            matches!(updated, accounts::Credential::AntigravityOAuth { access_token, refresh_token, refresh_pending: false, .. } if access_token == "fresh" && refresh_token == "rotated")
        );
        let requests = task.await.unwrap();
        assert_eq!(requests.len(), 1);
        assert!(requests[0].contains("refresh_token=owned-refresh"));
        assert!(requests[0].contains("client_secret=synthetic-secret"));
        let borrowed = accounts::Credential::AntigravityToken {
            access_token: "borrowed".into(),
            expires_at: None,
        };
        assert!(matches!(
            refresh_owned_at(&context, &borrowed, &base).await,
            Err(AccountError::Unsupported)
        ));
    }
    #[tokio::test]
    async fn owned_refresh_preserves_unrotated_refresh_token() {
        let context = http::fixture::context();
        let (base, task) =
            http::fixture::server(vec![json!({"access_token":"fresh","expires_in":3600})]).await;
        let updated = refresh_owned_at(&context, &owned(), &base).await.unwrap();
        assert!(
            matches!(updated, accounts::Credential::AntigravityOAuth { refresh_token, expires_at, .. }
            if refresh_token == "owned-refresh" && expires_at == context.clock.now().unix_timestamp() + 3600)
        );
        assert_eq!(task.await.unwrap().len(), 1);
    }
    #[tokio::test]
    async fn owned_refresh_rejects_errors_and_invalid_responses() {
        for (status, value) in [
            (400, json!({"error":"invalid_grant"})),
            (429, json!({})),
            (503, json!({})),
            (200, json!({"access_token":"", "expires_in":3600})),
            (200, json!({"access_token":"fresh", "expires_in":0})),
            (
                200,
                json!({"access_token":"fresh", "refresh_token":"", "expires_in":3600}),
            ),
        ] {
            let (base, task) = http::fixture::server_status(vec![(status, value)]).await;
            assert!(
                refresh_owned_at(&http::fixture::context(), &owned(), &base)
                    .await
                    .is_err()
            );
            assert_eq!(task.await.unwrap().len(), 1);
        }
    }
    #[test]
    fn owned_intake_requires_the_supported_client_and_explicit_secret() {
        for (key, value) in [
            ("client_id", json!("123-other.apps.googleusercontent.com")),
            ("client_secret", json!("")),
            ("access_token", json!("bad token")),
            ("refresh_token", json!("")),
            ("expires_at", json!(-1)),
        ] {
            let mut input = json!({"kind":"antigravity_owned","label":"synthetic","access_token":"original","refresh_token":"owned-refresh","expires_at":1,"client_id":CLIENT_ID,"client_secret":"synthetic-secret"});
            input[key] = value;
            assert!(owned_credential(serde_json::from_value(input).unwrap()).is_err());
        }
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn keychain_queries_never_request_interaction() {
        use core_foundation::{base::TCFType, string::CFString};
        #[allow(deprecated)]
        let query = options("synthetic-service", "synthetic-account").query;
        let key = CFString::new("u_AuthUI");
        let fail = CFString::new("u_AuthUIF").into_CFType();
        assert!(query.iter().any(|(k, v)| k == &key && v == &fail));
    }
}
