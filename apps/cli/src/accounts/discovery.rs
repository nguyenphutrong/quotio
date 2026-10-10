//! Explicit local metadata inspection. Never returns native keys, paths or credentials.
pub mod host;
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
    fn identity(&self) -> Result<String, AccountError> {
        match self {
            Self::Grok(source) => source.identity(),
            Self::Copilot(source) => source.identity(),
            Self::Custom(source, _, provider) => Ok(crate::cache::fingerprint(&[
                &source.identity()?,
                provider.id(),
            ])),
        }
    }
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
    entries: HashMap<String, (Instant, String, Reference)>,
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
        for (created, _, _) in self.entries.values_mut() {
            *created = Instant::now() - TTL;
        }
    }
    pub fn get(&mut self, id: &str) -> Result<Reference, AccountError> {
        self.get_for(id, "owner", true)
    }
    pub(crate) fn get_for(
        &mut self,
        id: &str,
        owner: &str,
        admin: bool,
    ) -> Result<Reference, AccountError> {
        self.prune();
        self.entries
            .get(id)
            .filter(|(_, issued_to, _)| admin || issued_to == owner)
            .map(|(_, _, r)| r.clone())
            .ok_or(AccountError::NotFound)
    }
    fn prune(&mut self) {
        self.entries
            .retain(|_, (created, _, _)| created.elapsed() < TTL);
    }
    pub fn inspect(&mut self, request: Request) -> Result<Value, AccountError> {
        self.inspect_for("owner", request)
    }
    /// Readable or Keychain-protected candidates for the provider's native login.
    /// Inspection never prompts or returns a token.
    pub(crate) fn native_candidates(
        &mut self,
        provider: Provider,
        location: Option<String>,
    ) -> Result<Vec<Value>, AccountError> {
        let inspected = self.inspect(Request {
            provider,
            kind: format!("{}_native", provider.id()),
            location,
            domain: None,
            inspect: true,
        })?;
        Ok(inspected["candidates"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|c| {
                matches!(
                    c["status"].as_str(),
                    Some("available" | "permission_required")
                )
            })
            .cloned()
            .collect())
    }
    pub(crate) fn inspect_for(
        &mut self,
        owner: &str,
        request: Request,
    ) -> Result<Value, AccountError> {
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
            if inspect {
                let candidates = choices
                    .into_iter()
                    .filter_map(|mut source| {
                        let status = self.probe(&kind, source["location"].as_str())?;
                        if kind == "factory_native" && status == "permission_required" {
                            source["entry_key"] = crate::providers::factory::keychain_account()
                                .ok()
                                .flatten()?
                                .into();
                        }
                        Some(json!({"label":"Native source","status":status,"source":source}))
                    })
                    .collect::<Vec<_>>();
                let status = if candidates
                    .iter()
                    .any(|candidate| candidate["status"] == "available")
                {
                    "checked"
                } else if candidates
                    .iter()
                    .any(|candidate| candidate["status"] == "permission_required")
                {
                    "permission_required"
                } else {
                    "unavailable"
                };
                return Ok(json!({"schema_version":2,"status":status,"candidates":candidates}));
            }
            return Ok(
                json!({"schema_version":2,"status":"not_checked","candidates":choices.into_iter().map(|source| json!({"label":"Native source","status":"not_checked","source":source})).collect::<Vec<_>>() }),
            );
        }
        if !inspect {
            return Ok(json!({"schema_version":2,"status":"not_checked","candidates":[]}));
        }
        let keychain_account = if kind == "copilot_native"
            && location
                .as_deref()
                .is_none_or(|location| location == "gh_keychain")
        {
            self.home
                .as_ref()
                .and_then(|home| read_native(&home.join(".config/gh/hosts.yml")).ok())
                .and_then(|bytes| {
                    crate::providers::catalog::oauth_primary::copilot_gh_username(&bytes)
                        .ok()
                        .flatten()
                        .map(str::to_owned)
                })
                .filter(|user| {
                    crate::providers::catalog::common::keychain_item_exists(
                        "gh:github.com",
                        Some(user),
                    )
                    .unwrap_or(false)
                })
        } else {
            None
        };
        let keychain_present = keychain_account.is_some();
        let result = if kind == "copilot_native" && location.as_deref() == Some("gh_keychain") {
            Ok(Vec::new())
        } else if kind == "copilot_native" && location.is_none() {
            let mut references = Vec::new();
            let mut failure = None;
            for location in ["apps", "hosts", "gh_hosts"] {
                match self.enumerate(provider, &kind, Some(location), None) {
                    Ok(mut found) if !found.is_empty() => {
                        references.append(&mut found);
                        break;
                    }
                    Ok(_) => (),
                    Err(AccountError::NotFound) => (),
                    Err(error) if failure.is_none() => failure = Some(error),
                    Err(_) => (),
                }
            }
            if references.is_empty() && !keychain_present {
                Err(failure.unwrap_or(AccountError::NotFound))
            } else {
                Ok(references)
            }
        } else {
            self.enumerate(provider, &kind, location.as_deref(), domain)
        };
        let references = match result {
            Ok(r) => r,
            Err(e) => {
                return Ok(
                    json!({"schema_version":2,"status":match e { AccountError::NotFound => "unavailable", AccountError::Unsupported => "unsupported", _ => "unreadable" },"candidates":[]}),
                );
            }
        };
        self.prune();
        let mut candidates = Vec::new();
        if keychain_present && references.is_empty() {
            candidates.push(json!({"label":"GitHub CLI Keychain","status":"permission_required","source":{"kind":"copilot_native","location":"gh_keychain","entry_key":keychain_account}}));
        }
        for (index, reference) in references.into_iter().enumerate() {
            let identity = reference.identity()?;
            let existing = self
                .entries
                .iter()
                .find_map(|(id, (_, issued_to, existing))| {
                    (issued_to == owner && existing.identity().ok().as_ref() == Some(&identity))
                        .then(|| id.clone())
                });
            let id = match existing {
                Some(id) => id,
                None if self.entries.len() < 256 => super::random_string()?,
                None => return Err(AccountError::Busy),
            };
            self.entries
                .insert(id.clone(), (Instant::now(), owner.into(), reference));
            candidates.push(json!({"label":format!("Native entry {}", index + 1),"status":"available","source":{"kind":"discovered","discovery_ref":id}}));
        }
        Ok(
            json!({"schema_version":2,"status":"checked","expires_in_seconds":600,"candidates":candidates}),
        )
    }
    fn probe(&self, kind: &str, location: Option<&str>) -> Option<&'static str> {
        let home = self.home.as_deref()?;
        let file = |relative: &str| native_file_exists(&home.join(relative));
        let keychain = |service, account| {
            crate::providers::catalog::common::keychain_item_exists(service, account).ok()
                == Some(true)
        };
        match (kind, location) {
            ("codex_native", Some("default")) if file(".codex/auth.json") => Some("available"),
            ("codex_native", Some("config")) if file(".config/codex/auth.json") => {
                Some("available")
            }
            ("codex_native", Some("codex_home"))
                if std::env::var_os("CODEX_HOME")
                    .map(PathBuf::from)
                    .is_some_and(|path| native_file_exists(&path.join("auth.json"))) =>
            {
                Some("available")
            }
            ("claude_native", Some("code_file")) if file(".claude/.credentials.json") => {
                Some("available")
            }
            ("claude_native", Some("code_keychain"))
                if keychain("Claude Code-credentials", None) =>
            {
                Some("permission_required")
            }
            ("factory_native", Some(location)) => {
                let name = match location {
                    "v2_file" => "auth.v2.file",
                    "v2_login_keychain" => "auth.v2.loginkeychain",
                    "v2_keyring" => "auth.v2.keyring",
                    "legacy" => "auth.encrypted",
                    _ => return None,
                };
                if !file(&format!(".factory/{name}")) {
                    return None;
                }
                if (location == "legacy"
                    && read_native(&home.join(".factory/auth.encrypted")).is_ok_and(|bytes| {
                        bytes.iter().find(|b| !b.is_ascii_whitespace()) == Some(&b'{')
                    }))
                    || (location == "v2_file" && file(".factory/auth.v2.key"))
                {
                    Some("available")
                } else if location != "v2_file"
                    && [
                        Some("auth-encryption-key-security-cli"),
                        Some("auth-encryption-key"),
                    ]
                    .into_iter()
                    .any(|account| keychain("Factory CLI", account))
                {
                    Some("permission_required")
                } else {
                    None
                }
            }
            ("devin_desktop_native", Some("credentials_toml"))
                if file(".local/share/devin/credentials.toml") =>
            {
                Some("available")
            }
            ("devin_desktop_native", Some("state_database"))
                if file("Library/Application Support/Devin/User/globalStorage/state.vscdb") =>
            {
                Some("available")
            }
            ("antigravity_native", Some("gemini_keychain"))
                if keychain("gemini", Some("antigravity")) =>
            {
                Some("permission_required")
            }
            ("antigravity_native", Some("state_db"))
                if file(
                    "Library/Application Support/Antigravity/User/globalStorage/state.vscdb",
                ) =>
            {
                Some("available")
            }
            ("kiro_native", None) if file(".aws/sso/cache/kiro-auth-token.json") => {
                Some("available")
            }
            ("cursor_native", None)
                if file("Library/Application Support/Cursor/User/globalStorage/state.vscdb") =>
            {
                Some("available")
            }
            ("amp_native", None) if file(".local/share/amp/secrets.json") => Some("available"),
            _ => None,
        }
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
            let present = crate::providers::catalog::oauth_primary::copilot_gh_token(&bytes)
                .map_err(|_| AccountError::Corrupt)?
                .is_some();
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
// Native clients may keep their login files in symlinked directories or files.
// Callers validate the opened target's type and bound any reads.
fn open_native(path: &Path) -> Result<std::fs::File, AccountError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        if !path.is_absolute()
            || path
                .components()
                .any(|part| matches!(part, std::path::Component::ParentDir))
        {
            return Err(AccountError::Input);
        }
        std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
            .open(path)
            .map_err(|error| {
                if error.kind() == std::io::ErrorKind::NotFound {
                    AccountError::NotFound
                } else {
                    AccountError::Storage
                }
            })
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Err(AccountError::Unsupported)
    }
}

fn native_file_exists(path: &Path) -> bool {
    open_native(path)
        .and_then(|file| file.metadata().map_err(|_| AccountError::Storage))
        .is_ok_and(|metadata| metadata.is_file())
}

fn read_native(path: &Path) -> Result<Vec<u8>, AccountError> {
    use std::io::Read;
    let file = open_native(path)?;
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

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    #[tokio::test]
    async fn codex_discovery_and_loading_follow_directory_and_file_symlinks() {
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        std::fs::create_dir_all(dir.join("store")).unwrap();
        let home = dir.canonicalize().unwrap();
        let target = home.join("store/login.json");
        let bytes = br#"{"tokens":{"access_token":"fixture","account_id":"first"}}"#;
        std::fs::write(&target, bytes).unwrap();
        std::os::unix::fs::symlink("store", home.join(".codex")).unwrap();
        std::os::unix::fs::symlink("login.json", home.join("store/auth.json")).unwrap();
        let mut registry = Registry {
            home: Some(home.clone()),
            ..Default::default()
        };
        let request = serde_json::from_value(json!({
            "provider":"codex", "kind":"codex_native", "location":"default", "inspect":true
        }))
        .unwrap();
        let discovered = registry.inspect(request).unwrap();
        assert_eq!(discovered["status"], "checked");
        assert_eq!(discovered["candidates"].as_array().unwrap().len(), 1);
        let source = CodexNativeReference {
            path: home.join(".codex/auth.json"),
        };
        let resolved = source.resolve().await.unwrap();
        assert!(
            matches!(&resolved.credentials[0], super::super::Credential::CodexOAuth { account_id, .. } if account_id == "first")
        );
        assert_eq!(std::fs::read(&target).unwrap(), bytes);

        std::fs::write(
            &target,
            br#"{"tokens":{"access_token":"rotated","account_id":"second"}}"#,
        )
        .unwrap();
        let resolved = source.resolve().await.unwrap();
        assert!(
            matches!(&resolved.credentials[0], super::super::Credential::CodexOAuth { account_id, .. } if account_id == "second")
        );
        std::fs::remove_file(&target).unwrap();
        assert!(!native_file_exists(&source.path));
        assert!(matches!(
            source.resolve().await,
            Err(AccountError::NotFound)
        ));
        std::os::unix::fs::symlink("/dev/zero", &target).unwrap();
        assert!(!native_file_exists(&source.path));
        assert!(source.resolve().await.is_err());
        std::fs::remove_file(&target).unwrap();
        std::os::unix::fs::symlink("login.json", &target).unwrap();
        assert!(!native_file_exists(&source.path));
        assert!(source.resolve().await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

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
            std::fs::create_dir(home.join("empty")).unwrap();
            std::os::unix::fs::symlink("empty", home.join(".grok")).unwrap();
            assert_eq!(
                registry.inspect(request(true)).unwrap()["status"],
                "unavailable"
            );
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn factory_discovery_never_marks_keychain_sources_available() {
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        std::fs::create_dir_all(dir.join(".factory")).unwrap();
        let home = dir.canonicalize().unwrap();
        std::fs::write(home.join(".factory/auth.v2.file"), b"encrypted").unwrap();
        std::fs::write(home.join(".factory/auth.v2.key"), [7; 32]).unwrap();
        std::fs::write(home.join(".factory/auth.v2.loginkeychain"), b"encrypted").unwrap();
        std::fs::write(
            home.join(".factory/auth.encrypted"),
            br#"{"access_token":"synthetic-native"}"#,
        )
        .unwrap();
        let mut registry = Registry {
            home: Some(home),
            ..Default::default()
        };
        let request = serde_json::from_value(json!({
            "provider":"factory",
            "kind":"factory_native",
            "inspect":true
        }))
        .unwrap();
        let discovered = registry.inspect(request).unwrap();
        assert_eq!(discovered["status"], "checked");
        let candidates = discovered["candidates"].as_array().unwrap();
        assert!(candidates.iter().any(|candidate| {
            candidate["source"]["location"] == "v2_file" && candidate["status"] == "available"
        }));
        assert!(candidates.iter().any(|candidate| {
            candidate["source"]["location"] == "legacy"
                && candidate["status"] == "available"
                && candidate["source"]["entry_key"].is_null()
        }));
        assert!(!candidates.iter().any(|candidate| {
            candidate["source"]["location"] == "v2_login_keychain"
                && candidate["status"] == "available"
        }));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn cursor_discovery_accepts_large_database_without_reading_it() {
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        let database =
            dir.join("Library/Application Support/Cursor/User/globalStorage/state.vscdb");
        std::fs::create_dir_all(database.parent().unwrap()).unwrap();
        std::fs::File::create(&database)
            .unwrap()
            .set_len(2 * 1024 * 1024)
            .unwrap();
        let mut registry = Registry {
            home: Some(dir.canonicalize().unwrap()),
            ..Default::default()
        };
        let request = serde_json::from_value(json!({
            "provider":"cursor",
            "kind":"cursor_native",
            "inspect":true
        }))
        .unwrap();
        let discovered = registry.inspect(request).unwrap();
        assert_eq!(discovered["status"], "checked");
        assert_eq!(discovered["candidates"][0]["status"], "available");
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
        let editor = dir.join(".config/github-copilot/apps.json");
        std::fs::create_dir_all(editor.parent().unwrap()).unwrap();
        std::fs::write(
            &editor,
            br#"{"github.com":{"oauth_token":"editor-secret"}}"#,
        )
        .unwrap();
        let preferred = registry
            .inspect(
                serde_json::from_value(json!({
                    "provider":"copilot", "kind":"copilot_native", "inspect":true
                }))
                .unwrap(),
            )
            .unwrap();
        assert_eq!(preferred["candidates"].as_array().unwrap().len(), 1);
        let Reference::Copilot(selected) = registry
            .get(
                preferred["candidates"][0]["source"]["discovery_ref"]
                    .as_str()
                    .unwrap(),
            )
            .unwrap()
        else {
            panic!()
        };
        assert!(selected.location == CopilotLocation::Apps);
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
        std::fs::write(&path, b"github.com:\n  user: fixture\n").unwrap();
        assert!(
            registry
                .enumerate(
                    Provider::Catalog("copilot"),
                    "copilot_native",
                    Some("gh_hosts"),
                    None
                )
                .unwrap()
                .is_empty()
        );
        std::fs::remove_file(&path).unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("/dev/zero", &path).unwrap();
            assert!(source.resolve().await.is_err());
        }
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
    fn references_are_reused_only_within_the_requesting_client() {
        let mut registry = Registry {
            preferences: |_| {
                Ok(
                    br#"[{"id":"11111111-1111-1111-1111-111111111111","type":"clinepass"}]"#
                        .to_vec(),
                )
            },
            ..Default::default()
        };
        let request = || {
            serde_json::from_value(json!({"provider":"clinepass","kind":"quotio_custom_provider","domain":"production","inspect":true})).unwrap()
        };
        let first = registry.inspect_for("client-a", request()).unwrap();
        let repeated = registry.inspect_for("client-a", request()).unwrap();
        let other = registry.inspect_for("client-b", request()).unwrap();
        let id = first["candidates"][0]["source"]["discovery_ref"]
            .as_str()
            .unwrap();
        assert_eq!(first["candidates"], repeated["candidates"]);
        assert_ne!(first["candidates"], other["candidates"]);
        assert!(registry.get_for(id, "client-a", false).is_ok());
        assert!(registry.get_for(id, "client-b", false).is_err());
        assert!(registry.get_for(id, "owner", true).is_ok());
    }

    #[test]
    fn repeated_scans_reuse_live_references() {
        let mut registry = Registry {
            preferences: |_| {
                Ok(
                    br#"[{"id":"11111111-1111-1111-1111-111111111111","type":"clinepass"}]"#
                        .to_vec(),
                )
            },
            ..Default::default()
        };
        let mut previous = None;
        for _ in 0..300 {
            let request = serde_json::from_value(json!({"provider":"clinepass","kind":"quotio_custom_provider","domain":"production","inspect":true})).unwrap();
            let report = registry.inspect(request).unwrap();
            let id = report["candidates"][0]["source"]["discovery_ref"]
                .as_str()
                .unwrap()
                .to_owned();
            if let Some(previous) = &previous {
                assert_eq!(&id, previous);
            }
            assert!(registry.get(&id).is_ok());
            previous = Some(id);
        }
        assert_eq!(registry.entries.len(), 1);
        registry.expire_all();
        assert!(registry.get(previous.as_deref().unwrap()).is_err());
    }
    #[test]
    fn discovery_references_expire_and_are_bounded() {
        let source = Reference::Grok(GrokNativeReference {
            path: PathBuf::from("/fixture/auth.json"),
            entry_key: "https://auth.x.ai::fixture".into(),
        });
        let mut registry = Registry::default();
        registry.entries.insert(
            "expired".into(),
            (Instant::now() - TTL, "owner".into(), source.clone()),
        );
        assert!(registry.get("expired").is_err());
        registry
            .entries
            .insert("current".into(), (Instant::now(), "owner".into(), source));
        assert!(registry.get("current").is_ok());
        assert!(registry.get("unknown").is_err());
        let source = registry.get("current").unwrap();
        for i in 0..255 {
            registry.entries.insert(
                i.to_string(),
                (Instant::now(), "owner".into(), source.clone()),
            );
        }
        registry.preferences = |_| {
            Ok(br#"[{"id":"11111111-1111-1111-1111-111111111111","type":"clinepass"}]"#.to_vec())
        };
        let request = serde_json::from_value(json!({"provider":"clinepass","kind":"quotio_custom_provider","domain":"production","inspect":true})).unwrap();
        assert!(matches!(registry.inspect(request), Err(AccountError::Busy)));
    }
}
