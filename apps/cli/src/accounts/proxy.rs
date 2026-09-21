//! Read-only CLIProxyAPI auth files supplied by the native parent.
use super::{AccountError, Credential};
use crate::{
    cli::Provider,
    domain::{AccountOrigin, AccountRef, ProviderId},
    error::ProviderError,
    providers::{CredentialStore, FetchFuture, ProviderAdapter, ProviderContext, Secret},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::OpenOptions,
    io::Read,
    path::{Component, Path, PathBuf},
    sync::Arc,
};
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};

const MAX_FILES: usize = 512;
const MAX_FILE_BYTES: u64 = 1024 * 1024;

struct Keys(HashMap<String, String>);
impl CredentialStore for Keys {
    fn get(&self, name: &str) -> Option<Secret> {
        self.0.get(name).cloned().map(Secret)
    }
}

enum Material {
    Codex(Credential),
    Keys(HashMap<String, String>),
}

struct Snapshot {
    digest: String,
    material: Material,
}

struct BorrowedProxyProvider {
    path: PathBuf,
    provider: Provider,
    reference: AccountRef,
}

impl BorrowedProxyProvider {
    fn snapshot(&self, now: OffsetDateTime) -> Result<Snapshot, ProviderError> {
        let bytes = read_file(&self.path)?;
        let value: Value =
            serde_json::from_slice(&bytes).map_err(|_| ProviderError::InvalidData)?;
        let provider = provider(&value).ok_or(ProviderError::InvalidData)?;
        if provider != self.provider {
            return Err(ProviderError::Transient);
        }
        Ok(Snapshot {
            digest: crate::cache::fingerprint(&[
                "cli_proxy_auth_file",
                self.provider.id(),
                &String::from_utf8_lossy(&bytes),
            ]),
            material: material(provider, &value, now, true)?,
        })
    }
}

impl ProviderAdapter for BorrowedProxyProvider {
    fn id(&self) -> ProviderId {
        ProviderId(self.provider.id().into())
    }

    fn account_ref(&self) -> Option<AccountRef> {
        Some(self.reference.clone())
    }

    fn cache_identity<'a>(
        &'a self,
        context: &'a ProviderContext,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<String>> + Send + 'a>> {
        Box::pin(async move {
            self.snapshot(context.clock.now())
                .ok()
                .map(|value| value.digest)
        })
    }

    fn idempotent(&self) -> bool {
        true
    }

    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            let before = self.snapshot(context.clock.now())?;
            let mut usage = match before.material {
                Material::Codex(credential) => {
                    crate::accounts::service::validate(context, self.provider, &credential)
                        .await
                        .map_err(|error| match error {
                            AccountError::Provider(error) => error,
                            _ => ProviderError::Authentication,
                        })?
                }
                Material::Keys(keys) => {
                    let scoped = ProviderContext {
                        http: context.http.clone(),
                        clock: context.clock.clone(),
                        credentials: Arc::new(Keys(keys)),
                    };
                    self.provider.adapter().fetch(&scoped).await?
                }
            };
            if self.snapshot(context.clock.now())?.digest != before.digest {
                return Err(ProviderError::Transient);
            }
            usage.account.label = self.reference.label.clone();
            Ok(usage)
        })
    }
}

pub fn validate_directory(path: &Path) -> Result<(), AccountError> {
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir))
    {
        return Err(AccountError::Input);
    }
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component);
        let Ok(metadata) = std::fs::symlink_metadata(&current) else {
            continue;
        };
        if metadata.file_type().is_symlink() || (!metadata.is_dir() && current != path) {
            return Err(AccountError::Input);
        }
        if current == path && !metadata.is_dir() {
            return Err(AccountError::Input);
        }
    }
    Ok(())
}

pub fn adapters(
    directory: &Path,
    providers: &[Provider],
    account: Option<&str>,
) -> Result<Vec<Arc<dyn ProviderAdapter>>, AccountError> {
    validate_directory(directory)?;
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Ok(Vec::new());
    };
    let mut paths = entries
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| AccountError::Storage)?;
    if paths.len() > MAX_FILES {
        return Err(AccountError::Storage);
    }
    paths.sort_by_key(|entry| entry.file_name());
    Ok(paths
        .into_iter()
        .filter_map(|entry| inspect(entry.path()).ok().flatten())
        .filter(|source| providers.contains(&source.provider))
        .filter(|source| account.is_none_or(|id| source.reference.id == id))
        .map(|source| Arc::new(source) as Arc<dyn ProviderAdapter>)
        .collect())
}

fn inspect(path: PathBuf) -> Result<Option<BorrowedProxyProvider>, AccountError> {
    if path.extension().and_then(|value| value.to_str()) != Some("json") {
        return Ok(None);
    }
    let bytes = read_file(&path).map_err(|_| AccountError::Input)?;
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| AccountError::Input)?;
    let Some(provider) = provider(&value) else {
        return Ok(None);
    };
    material(provider, &value, OffsetDateTime::now_utc(), false)
        .map_err(|_| AccountError::Input)?;
    let filename = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or(AccountError::Input)?;
    let id = crate::cache::fingerprint(&["cli_proxy_auth_file", provider.id(), filename]);
    let label = label(&value).unwrap_or_else(|| {
        let key = filename.strip_suffix(".json").unwrap_or(filename);
        let prefix = if provider == Provider::Codex {
            "codex-"
        } else {
            "github-copilot-"
        };
        key.strip_prefix(prefix).unwrap_or(key).to_owned()
    });
    if !valid(&label, 512) {
        return Err(AccountError::Input);
    }
    Ok(Some(BorrowedProxyProvider {
        path,
        provider,
        reference: AccountRef {
            origin: Some(AccountOrigin::BorrowedProxy),
            id,
            label,
        },
    }))
}

fn read_file(path: &Path) -> Result<Vec<u8>, ProviderError> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = options
        .open(path)
        .map_err(|_| ProviderError::CredentialStorage)?;
    let metadata = file
        .metadata()
        .map_err(|_| ProviderError::CredentialStorage)?;
    if !metadata.is_file() || metadata.len() > MAX_FILE_BYTES {
        return Err(ProviderError::CredentialStorage);
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| ProviderError::CredentialStorage)?;
    if bytes.len() as u64 > MAX_FILE_BYTES {
        return Err(ProviderError::CredentialStorage);
    }
    Ok(bytes)
}

fn provider(value: &Value) -> Option<Provider> {
    match value.get("type")?.as_str()? {
        "codex" => Some(Provider::Codex),
        "claude" => Some(Provider::Catalog("claude")),
        "github-copilot" | "copilot" => Some(Provider::Catalog("copilot")),
        "antigravity" => Some(Provider::Antigravity),
        "kiro" => Some(Provider::Catalog("kiro")),
        "vertex" | "vertexai" => Some(Provider::Catalog("vertexai")),
        _ => None,
    }
}

fn material(
    provider: Provider,
    value: &Value,
    now: OffsetDateTime,
    enforce_expiry: bool,
) -> Result<Material, ProviderError> {
    let token = text(
        value,
        &["access_token", "accessToken", "session_key", "oauth_token"],
    )
    .ok_or(ProviderError::Authentication)?;
    if enforce_expiry
        && let Some(expiry) = expiry(value)?
        && expiry <= now + Duration::minutes(5)
    {
        return Err(ProviderError::OwnerRefreshRequired);
    }
    if provider == Provider::Codex {
        let claims = jwt_claims(token);
        let account_id = text(value, &["account_id", "accountId"])
            .or_else(|| {
                claims
                    .as_ref()?
                    .get("https://api.openai.com/auth")?
                    .get("chatgpt_account_id")?
                    .as_str()
            })
            .filter(|value| valid(value, 256))
            .ok_or(ProviderError::Authentication)?;
        let email = text(value, &["email"])
            .or_else(|| claims.as_ref()?.get("email")?.as_str())
            .filter(|value| valid(value, 256))
            .unwrap_or("CLIProxyAPI Codex");
        return Ok(Material::Codex(Credential::CodexOAuth {
            access_token: token.into(),
            refresh_token: String::new(),
            id_token: String::new(),
            account_id: account_id.into(),
            email: email.into(),
            expires_at: i64::MAX,
        }));
    }
    let mut keys = HashMap::new();
    let key = match provider {
        Provider::Catalog("claude") => "CLAUDE_OAUTH_ACCESS_TOKEN",
        Provider::Catalog("copilot") => "COPILOT_API_TOKEN",
        Provider::Catalog("kiro") => "KIRO_ACCESS_TOKEN",
        Provider::Catalog("vertexai") => "VERTEXAI_ACCESS_TOKEN",
        Provider::Antigravity => "ANTIGRAVITY_ACCESS_TOKEN",
        _ => return Err(ProviderError::InvalidData),
    };
    keys.insert(key.into(), token.into());
    if provider == Provider::Catalog("kiro") {
        if let Some(value) = text(value, &["region"]) {
            keys.insert("KIRO_REGION".into(), value.into());
        }
        if let Some(value) = text(value, &["profile_arn", "profileArn"]) {
            keys.insert("KIRO_PROFILE_ARN".into(), value.into());
        }
    } else if provider == Provider::Catalog("vertexai")
        && let Some(value) = text(value, &["project_id", "projectId", "project"])
    {
        keys.insert("VERTEXAI_PROJECT_ID".into(), value.into());
    }
    Ok(Material::Keys(keys))
}

fn label(value: &Value) -> Option<String> {
    text(value, &["email", "username", "login"])
        .filter(|value| valid(value, 512))
        .map(str::to_owned)
}

fn text<'a>(value: &'a Value, names: &[&str]) -> Option<&'a str> {
    names
        .iter()
        .find_map(|name| value.get(name)?.as_str())
        .map(str::trim)
        .filter(|value| valid(value, 16_384))
}

fn valid(value: &str, maximum: usize) -> bool {
    !value.is_empty() && value.len() <= maximum && !value.chars().any(char::is_control)
}

fn expiry(value: &Value) -> Result<Option<OffsetDateTime>, ProviderError> {
    let Some(value) = ["expired", "expiry", "expires_at", "expiresAt"]
        .iter()
        .find_map(|name| value.get(name))
    else {
        return Ok(None);
    };
    if let Some(value) = value.as_str() {
        return OffsetDateTime::parse(value, &Rfc3339)
            .map(Some)
            .map_err(|_| ProviderError::InvalidData);
    }
    let seconds = value.as_i64().ok_or(ProviderError::InvalidData)?;
    let seconds = if seconds > 10_000_000_000 {
        seconds / 1_000
    } else {
        seconds
    };
    OffsetDateTime::from_unix_timestamp(seconds)
        .map(Some)
        .map_err(|_| ProviderError::InvalidData)
}

fn jwt_claims(token: &str) -> Option<Value> {
    let payload = token.split('.').nth(1)?;
    URL_SAFE_NO_PAD
        .decode(payload)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn directory() -> PathBuf {
        let path = std::env::temp_dir().join(crate::accounts::random_string().unwrap());
        std::fs::create_dir(&path).unwrap();
        path.canonicalize().unwrap()
    }

    #[test]
    fn scans_known_files_without_exposing_or_modifying_credentials() {
        let directory = directory();
        let fixtures: [(&str, &[u8]); 6] = [
            (
                "claude-demo.json",
                br#"{"type":"claude","email":"demo@example.test","access_token":"private-token","refresh_token":"owner-only"}"#,
            ),
            (
                "codex-demo.json",
                br#"{"type":"codex","account_id":"account","access_token":"private-token"}"#,
            ),
            (
                "copilot-demo.json",
                br#"{"type":"github-copilot","access_token":"private-token"}"#,
            ),
            (
                "antigravity-demo.json",
                br#"{"type":"antigravity","access_token":"private-token"}"#,
            ),
            (
                "kiro-demo.json",
                br#"{"type":"kiro","accessToken":"private-token","region":"us-east-1"}"#,
            ),
            (
                "vertex-demo.json",
                br#"{"type":"vertex","access_token":"private-token","project_id":"project"}"#,
            ),
        ];
        for (name, bytes) in fixtures {
            std::fs::write(directory.join(name), bytes).unwrap();
        }

        let providers = [
            Provider::Catalog("claude"),
            Provider::Codex,
            Provider::Catalog("copilot"),
            Provider::Antigravity,
            Provider::Catalog("kiro"),
            Provider::Catalog("vertexai"),
        ];
        let scanned = adapters(&directory, &providers, None).unwrap();
        assert_eq!(scanned.len(), providers.len());
        let claude = scanned
            .iter()
            .find(|adapter| adapter.id().0 == "claude")
            .unwrap();
        let reference = claude.account_ref().unwrap();
        assert_eq!(reference.origin, Some(AccountOrigin::BorrowedProxy));
        assert_eq!(reference.label, "demo@example.test");
        assert!(!reference.id.contains("private-token"));
        for (name, bytes) in fixtures {
            assert_eq!(std::fs::read(directory.join(name)).unwrap(), bytes);
        }

        let claude_path = directory.join("claude-demo.json");
        std::fs::write(
            &claude_path,
            br#"{"type":"claude","email":"rotated@example.test","access_token":"rotated-token"}"#,
        )
        .unwrap();
        let rescanned = adapters(&directory, &[Provider::Catalog("claude")], None).unwrap();
        assert_eq!(
            rescanned[0].account_ref().unwrap().label,
            "rotated@example.test"
        );
        std::fs::remove_file(claude_path).unwrap();
        assert!(
            adapters(&directory, &[Provider::Catalog("claude")], None)
                .unwrap()
                .is_empty()
        );

        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn unlabeled_files_use_swift_compatible_filename_keys() {
        let directory = directory();
        for (filename, provider, expected, extra) in [
            ("kiro-work.json", "kiro", "kiro-work", ""),
            (
                "kiro-profile.json",
                "kiro",
                "kiro-profile",
                r#", "profileArn":"arn:aws:codewhisperer:us-east-1:123:profile/example""#,
            ),
            (
                "codex-work.json",
                "codex",
                "work",
                r#", "account_id":"account""#,
            ),
            ("github-copilot-work.json", "github-copilot", "work", ""),
            ("claude-work.json", "claude", "claude-work", ""),
        ] {
            let path = directory.join(filename);
            std::fs::write(
                &path,
                format!(r#"{{"type":"{provider}","accessToken":"test-token"{extra}}}"#),
            )
            .unwrap();
            let source = inspect(path).unwrap().unwrap();
            assert_eq!(source.reference.label, expected);
            assert_eq!(
                source.reference.id,
                crate::cache::fingerprint(&["cli_proxy_auth_file", source.provider.id(), filename])
            );
            let selected =
                adapters(&directory, &[source.provider], Some(&source.reference.id)).unwrap();
            assert_eq!(selected.len(), 1);
            assert_eq!(selected[0].account_ref().unwrap().label, expected);
        }
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn skips_unknown_oversized_and_symbolic_link_files() {
        let directory = directory();
        std::fs::write(
            directory.join("claude-\n.json"),
            br#"{"type":"claude","access_token":"test-token"}"#,
        )
        .unwrap();
        std::fs::write(
            directory.join("unknown.json"),
            br#"{"type":"qwen","access_token":"x"}"#,
        )
        .unwrap();
        std::fs::write(
            directory.join("oversized.json"),
            vec![b'x'; MAX_FILE_BYTES as usize + 1],
        )
        .unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(directory.join("unknown.json"), directory.join("link.json"))
            .unwrap();

        assert!(
            adapters(&directory, &[Provider::Catalog("claude")], None)
                .unwrap()
                .is_empty()
        );
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_relative_and_symbolic_link_directories() {
        assert!(validate_directory(Path::new("relative")).is_err());
        #[cfg(unix)]
        {
            let directory = directory();
            let link = directory.with_extension("link");
            std::os::unix::fs::symlink(&directory, &link).unwrap();
            assert!(validate_directory(&link).is_err());
            std::fs::remove_file(link).unwrap();
            std::fs::remove_dir_all(directory).unwrap();
        }
    }
}
