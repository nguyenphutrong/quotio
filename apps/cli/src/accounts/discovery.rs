//! Explicit local metadata inspection. Never returns native keys, paths or credentials.
use super::{AccountError, api::SourceInput, sources::*};
use crate::cli::Provider;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

const LIMIT: usize = 64;
const TTL: Duration = Duration::from_secs(600);
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub provider: Provider,
    pub kind: String,
    pub location: Option<String>,
    pub domain: Option<QuotioDomain>,
    #[serde(default)]
    pub inspect: bool,
}
#[derive(Clone)]
pub enum Reference {
    Grok(GrokNativeReference),
    Copilot(CopilotNativeReference),
    Custom(CustomProviderReference, PreferencesReader, Provider),
}
impl Reference {
    pub async fn resolve(self) -> Result<super::api::PreparedAccount, AccountError> {
        let (identity, credential, provider) = match self {
            Self::Grok(source) => {
                let resolved = source.resolve().await?;
                (
                    source.identity()?,
                    super::Credential::GrokNative { source },
                    resolved.provider,
                )
            }
            Self::Copilot(source) => {
                let resolved = source.resolve().await?;
                (
                    source.identity()?,
                    super::Credential::CopilotNative { source },
                    resolved.provider,
                )
            }
            Self::Custom(source, read, provider) => {
                let selected = source.clone();
                let resolved = tokio::time::timeout(
                    Duration::from_secs(10),
                    tokio::task::spawn_blocking(move || {
                        selected.parse(&read(selected.domain.clone())?)
                    }),
                )
                .await
                .map_err(|_| AccountError::Busy)?
                .map_err(|_| AccountError::Storage)??;
                if resolved.provider != provider {
                    return Err(AccountError::Input);
                }
                (
                    source.identity()?,
                    super::Credential::QuotioCustomProvider { source },
                    resolved.provider,
                )
            }
        };
        super::api::PreparedAccount::discovered(provider, identity, credential)
    }
}

type PreferencesReader = fn(QuotioDomain) -> Result<Vec<u8>, AccountError>;
pub struct Registry {
    pub home: Option<PathBuf>,
    pub preferences: PreferencesReader,
    entries: HashMap<String, (Instant, Reference)>,
}
impl Default for Registry {
    fn default() -> Self {
        Self {
            home: std::env::var_os("HOME").map(PathBuf::from),
            preferences: super::sources::read_preferences,
            entries: HashMap::new(),
        }
    }
}
impl Registry {
    #[cfg(test)]
    pub(crate) fn expire_all(&mut self) {
        for (created, _) in self.entries.values_mut() {
            *created = Instant::now() - TTL;
        }
    }
    pub fn get(&mut self, id: &str) -> Result<Reference, AccountError> {
        self.prune();
        self.entries
            .get(id)
            .map(|(_, r)| r.clone())
            .ok_or(AccountError::NotFound)
    }
    fn prune(&mut self) {
        self.entries
            .retain(|_, (created, _)| created.elapsed() < TTL);
    }
    pub fn inspect(&mut self, request: Request) -> Result<Value, AccountError> {
        let Request {
            provider,
            kind,
            location,
            domain,
            inspect,
        } = request;
        if !crate::providers::capabilities::capability(provider)
            .source_references
            .iter()
            .any(|s| s.kind == kind)
        {
            return Err(AccountError::Input);
        }
        let locations: &[&str] = match kind.as_str() {
            "codex_native" => &["default", "config", "codex_home"],
            "claude_native" => &["code_file", "code_keychain"],
            "copilot_native" => &["apps", "hosts", "gh_hosts", "gh_keychain"],
            "factory_native" => &["v2_file", "v2_login_keychain", "v2_keyring", "legacy"],
            "devin_desktop_native" => &["credentials_toml", "state_database"],
            "antigravity_native" => &["gemini_keychain", "state_db"],
            _ => &[],
        };
        if location.as_deref().is_some_and(|l| !locations.contains(&l))
            || (domain.is_some() != (kind == "quotio_custom_provider"))
        {
            return Err(AccountError::Input);
        }
        let exact = matches!(
            kind.as_str(),
            "grok_native" | "copilot_native" | "quotio_custom_provider"
        );
        if !exact {
            if inspect {
                return Err(AccountError::Unsupported);
            }
            let choices: Vec<Value> = if locations.is_empty() {
                vec![json!({"kind":kind})]
            } else {
                locations
                    .iter()
                    .filter(|l| location.as_deref().is_none_or(|selected| selected == **l))
                    .map(|l| json!({"kind":kind,"location":l}))
                    .collect()
            };
            // Validate descriptors through the same input contract as registration.
            for choice in &choices {
                serde_json::from_value::<SourceInput>(choice.clone())
                    .map_err(|_| AccountError::Input)?;
            }
            return Ok(
                json!({"schema_version":1,"status":"not_checked","candidates":choices.into_iter().map(|source| json!({"label":"Native source","status":"not_checked","source":source})).collect::<Vec<_>>() }),
            );
        }
        if !inspect {
            return Ok(json!({"schema_version":1,"status":"not_checked","candidates":[]}));
        }
        if kind == "copilot_native" && location.is_none() {
            return Err(AccountError::Input);
        }
        if location.as_deref() == Some("gh_keychain") {
            return Ok(json!({"schema_version":1,"status":"unsupported","candidates":[]}));
        }
        let result = self.enumerate(provider, &kind, location.as_deref(), domain);
        let references = match result {
            Ok(r) => r,
            Err(e) => {
                return Ok(
                    json!({"schema_version":1,"status":match e { AccountError::NotFound => "unavailable", AccountError::Unsupported => "unsupported", _ => "unreadable" },"candidates":[]}),
                );
            }
        };
        self.prune();
        if self.entries.len() + references.len() > 256 {
            return Err(AccountError::Busy);
        }
        let mut candidates = Vec::new();
        for (index, reference) in references.into_iter().enumerate() {
            let id = super::random_string()?;
            self.entries.insert(id.clone(), (Instant::now(), reference));
            candidates.push(json!({"label":format!("Native entry {}", index + 1),"status":"available","source":{"kind":"discovered","discovery_ref":id}}));
        }
        Ok(
            json!({"schema_version":1,"status":"checked","expires_in_seconds":600,"candidates":candidates}),
        )
    }
    fn enumerate(
        &self,
        provider: Provider,
        kind: &str,
        location: Option<&str>,
        domain: Option<QuotioDomain>,
    ) -> Result<Vec<Reference>, AccountError> {
        if kind == "quotio_custom_provider" {
            let domain = domain.ok_or(AccountError::Input)?;
            return custom_references(
                provider,
                domain.clone(),
                &(self.preferences)(domain)?,
                self.preferences,
            );
        }
        let home = self.home.as_deref().ok_or(AccountError::NotFound)?;
        let relative = match (kind, location) {
            ("grok_native", _) => ".grok/auth.json",
            ("copilot_native", Some("apps")) => ".config/github-copilot/apps.json",
            ("copilot_native", Some("hosts")) => ".config/github-copilot/hosts.json",
            ("copilot_native", Some("gh_hosts")) => ".config/gh/hosts.yml",
            _ => return Err(AccountError::Input),
        };
        let path = home.join(relative);
        let bytes = read_native(&path)?;
        if kind == "copilot_native" && location == Some("gh_hosts") {
            let present = crate::providers::catalog::oauth_primary::copilot_gh_host_present(&bytes)
                .map_err(|_| AccountError::Corrupt)?;
            return Ok(if present {
                vec![Reference::Copilot(CopilotNativeReference {
                    path: Some(path),
                    entry_key: "github.com".into(),
                    location: CopilotLocation::GhHosts,
                })]
            } else {
                Vec::new()
            });
        }
        let value: Value = serde_json::from_slice(&bytes).map_err(|_| AccountError::Corrupt)?;
        let entries = value.as_object().ok_or(AccountError::Corrupt)?;
        if entries.len() > LIMIT {
            return Err(AccountError::Corrupt);
        }
        let mut result = Vec::new();
        for (key, value) in entries {
            if !value.is_object() {
                continue;
            }
            if kind == "grok_native" {
                let source = GrokNativeReference {
                    path: path.clone(),
                    entry_key: key.clone(),
                };
                if source.identity().is_ok() {
                    result.push(Reference::Grok(source));
                }
            } else {
                let source = CopilotNativeReference {
                    path: Some(path.clone()),
                    entry_key: key.clone(),
                    location: if location == Some("apps") {
                        CopilotLocation::Apps
                    } else {
                        CopilotLocation::Hosts
                    },
                };
                if source.identity().is_ok() {
                    result.push(Reference::Copilot(source));
                }
            }
        }
        Ok(result)
    }
}
fn custom_references(
    provider: Provider,
    domain: QuotioDomain,
    bytes: &[u8],
    read: PreferencesReader,
) -> Result<Vec<Reference>, AccountError> {
    if bytes.len() > 1024 * 1024 {
        return Err(AccountError::Corrupt);
    }
    let records: Vec<Value> = serde_json::from_slice(bytes).map_err(|_| AccountError::Corrupt)?;
    if records.len() > LIMIT {
        return Err(AccountError::Corrupt);
    }
    let mut result = Vec::new();
    for record in records {
        let kind = match provider {
            Provider::Zai => "glm-api-key",
            Provider::Catalog("clinepass") => "clinepass",
            _ => return Err(AccountError::Input),
        };
        if record["type"] != kind || record["is-enabled"] == false {
            continue;
        }
        let Some(id) = record["id"].as_str() else {
            continue;
        };
        let source = CustomProviderReference {
            domain: domain.clone(),
            record_id: id.into(),
        };
        if source.identity().is_ok() {
            result.push(Reference::Custom(source, read, provider));
        }
    }
    Ok(result)
}
// Walk every path component with openat: neither parent nor leaf symlinks may
// redirect this explicit inspection into another credential store.
fn read_native(path: &Path) -> Result<Vec<u8>, AccountError> {
    use std::io::Read;
    #[cfg(unix)]
    {
        use std::os::fd::{AsRawFd, FromRawFd};
        if !path.is_absolute() {
            return Err(AccountError::Input);
        }
        let mut file = std::fs::File::open("/").map_err(|_| AccountError::Storage)?;
        let parts: Vec<_> = path.components().skip(1).collect();
        for (i, part) in parts.iter().enumerate() {
            let std::path::Component::Normal(name) = part else {
                return Err(AccountError::Input);
            };
            use std::os::unix::ffi::OsStrExt;
            let name = std::ffi::CString::new(name.as_bytes()).map_err(|_| AccountError::Input)?;
            let flags = libc::O_RDONLY
                | libc::O_NOFOLLOW
                | libc::O_NONBLOCK
                | libc::O_CLOEXEC
                | if i + 1 < parts.len() {
                    libc::O_DIRECTORY
                } else {
                    0
                };
            let fd = unsafe { libc::openat(file.as_raw_fd(), name.as_ptr(), flags) };
            if fd < 0 {
                return Err(
                    if std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound {
                        AccountError::NotFound
                    } else {
                        AccountError::Storage
                    },
                );
            }
            file = unsafe { std::fs::File::from_raw_fd(fd) };
        }
        let metadata = file.metadata().map_err(|_| AccountError::Storage)?;
        if !metadata.is_file() || metadata.len() > 1024 * 1024 {
            return Err(AccountError::Corrupt);
        }
        let mut bytes = Vec::new();
        file.take(1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| AccountError::Storage)?;
        if bytes.len() > 1024 * 1024 {
            return Err(AccountError::Corrupt);
        }
        Ok(bytes)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Err(AccountError::Unsupported)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(inspect: bool) -> Request {
        serde_json::from_value(json!({"provider":"grok","kind":"grok_native","inspect":inspect}))
            .unwrap()
    }
    #[test]
    fn native_discovery_bounds_and_sanitizes_hostile_sources() {
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        std::fs::create_dir_all(dir.join(".grok")).unwrap();
        let home = dir.canonicalize().unwrap();
        let path = home.join(".grok/auth.json");
        let mut registry = Registry {
            home: Some(home.clone()),
            ..Default::default()
        };
        assert_eq!(
            registry.inspect(request(false)).unwrap()["status"],
            "not_checked"
        );
        assert_eq!(
            registry.inspect(request(true)).unwrap()["status"],
            "unavailable"
        );
        for bytes in [
            b"planted-secret".to_vec(),
            vec![b'x'; 1024 * 1024 + 1],
            serde_json::to_vec(
                &(0..65)
                    .map(|i| (format!("https://auth.x.ai::{i}"), json!({})))
                    .collect::<serde_json::Map<_, _>>(),
            )
            .unwrap(),
        ] {
            std::fs::write(&path, bytes).unwrap();
            let result = registry.inspect(request(true)).unwrap();
            assert_eq!(result["status"], "unreadable");
            assert!(!result.to_string().contains("planted-secret"));
            assert!(!result.to_string().contains(home.to_str().unwrap()));
        }
        std::fs::remove_file(&path).unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("/dev/zero", &path).unwrap();
            assert_eq!(
                registry.inspect(request(true)).unwrap()["status"],
                "unreadable"
            );
            std::fs::remove_file(&path).unwrap();
            std::fs::remove_dir(home.join(".grok")).unwrap();
            std::os::unix::fs::symlink("/", home.join(".grok")).unwrap();
            assert_eq!(
                registry.inspect(request(true)).unwrap()["status"],
                "unreadable"
            );
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[tokio::test]
    async fn copilot_gh_hosts_discovery_is_opaque_and_observes_rotation() {
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        std::fs::create_dir(&dir).unwrap();
        let home = dir.canonicalize().unwrap();
        let path = home.join(".config/gh/hosts.yml");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"github.com:\n  oauth_token: first-secret\n").unwrap();
        let mut registry = Registry {
            home: Some(home),
            ..Default::default()
        };
        let request = serde_json::from_value(json!({
            "provider":"copilot",
            "kind":"copilot_native",
            "location":"gh_hosts",
            "inspect":true
        }))
        .unwrap();
        let discovered = registry.inspect(request).unwrap();
        assert_eq!(discovered["status"], "checked");
        assert_eq!(discovered["candidates"].as_array().unwrap().len(), 1);
        assert!(!discovered.to_string().contains("first-secret"));
        assert!(!discovered.to_string().contains("github.com"));
        let reference = registry
            .get(
                discovered["candidates"][0]["source"]["discovery_ref"]
                    .as_str()
                    .unwrap(),
            )
            .unwrap();
        let Reference::Copilot(source) = reference else {
            panic!("Copilot reference expected")
        };
        std::fs::write(&path, b"github.com:\n  oauth_token: second-secret\n").unwrap();
        let resolved = source.resolve().await.unwrap();
        assert!(
            matches!(&resolved.credentials[0], crate::accounts::Credential::CatalogKey { token, .. } if token == "second-secret")
        );
        std::fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink("/dev/zero", &path).unwrap();
        assert!(source.resolve().await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[tokio::test]
    async fn custom_reference_rejects_provider_rotation_after_inspection() {
        let mut registry = Registry {
            preferences: |_| {
                Ok(br#"[{"id":"11111111-1111-1111-1111-111111111111","type":"clinepass","name":"Fixture","api-keys":[{"api-key":"fixture"}]}]"#.to_vec())
            },
            ..Default::default()
        };
        // The reader returns a valid Z.ai record when registration re-reads it.
        fn rotated(_: QuotioDomain) -> Result<Vec<u8>, AccountError> {
            Ok(br#"[{"id":"11111111-1111-1111-1111-111111111111","type":"glm-api-key","name":"Fixture","base-url":"https://api.z.ai","api-keys":[{"api-key":"fixture"}]}]"#.to_vec())
        }
        let request = serde_json::from_value(json!({"provider":"clinepass","kind":"quotio_custom_provider","domain":"production","inspect":true})).unwrap();
        let discovered = registry.inspect(request).unwrap();
        let reference = registry
            .get(
                discovered["candidates"][0]["source"]["discovery_ref"]
                    .as_str()
                    .unwrap(),
            )
            .unwrap();
        let Reference::Custom(source, _, provider) = reference else {
            panic!("custom reference expected")
        };
        assert_eq!(
            source
                .parse(&rotated(source.domain.clone()).unwrap())
                .unwrap()
                .provider,
            Provider::Zai
        );
        assert!(matches!(
            Reference::Custom(source, rotated, provider).resolve().await,
            Err(AccountError::Input)
        ));
    }
    #[test]
    fn discovery_references_expire_and_are_bounded() {
        let source = Reference::Grok(GrokNativeReference {
            path: PathBuf::from("/fixture/auth.json"),
            entry_key: "https://auth.x.ai::fixture".into(),
        });
        let mut registry = Registry::default();
        registry
            .entries
            .insert("expired".into(), (Instant::now() - TTL, source.clone()));
        assert!(registry.get("expired").is_err());
        registry
            .entries
            .insert("current".into(), (Instant::now(), source));
        assert!(registry.get("current").is_ok());
        assert!(registry.get("unknown").is_err());
        let source = registry.get("current").unwrap();
        for i in 0..255 {
            registry
                .entries
                .insert(i.to_string(), (Instant::now(), source.clone()));
        }
        registry.preferences = |_| {
            Ok(br#"[{"id":"11111111-1111-1111-1111-111111111111","type":"clinepass"}]"#.to_vec())
        };
        let request = serde_json::from_value(json!({"provider":"clinepass","kind":"quotio_custom_provider","domain":"production","inspect":true})).unwrap();
        assert!(matches!(registry.inspect(request), Err(AccountError::Busy)));
    }
}
