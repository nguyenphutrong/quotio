use super::{AccountError, Document};
use std::{
    collections::HashMap,
    fs::{File, OpenOptions},
    path::PathBuf,
    str::FromStr,
    sync::{
        Arc, Mutex, OnceLock, Weak,
        atomic::{AtomicBool, Ordering},
    },
};

#[cfg(target_os = "macos")]
const PRODUCTION_KEYCHAIN_SERVICE: &str = "app.quotio.cli.accounts.v1";
#[cfg(target_os = "macos")]
const PRODUCTION_KEYCHAIN_ACCOUNT: &str = "vault";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VaultNamespace(String);

impl VaultNamespace {
    #[cfg(target_os = "macos")]
    fn keychain_service(&self) -> String {
        format!("app.quotio.cli.accounts.{}.v1", self.0)
    }

    #[cfg(target_os = "macos")]
    fn keychain_account(&self) -> String {
        format!("vault.{}", self.0)
    }

    fn lock_name(&self) -> String {
        format!("accounts-{}.lock", self.0)
    }

    #[cfg(target_os = "linux")]
    fn vault_name(&self) -> String {
        format!("vault-{}", self.0)
    }
}

impl FromStr for VaultNamespace {
    type Err = &'static str;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        let bytes = value.as_bytes();
        if !(1..=32).contains(&bytes.len())
            || !bytes[0].is_ascii_lowercase()
            || !bytes[bytes.len() - 1].is_ascii_alphanumeric()
            || !bytes
                .iter()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-')
        {
            return Err("namespace must be 1-32 lowercase letters, digits or hyphens");
        }
        Ok(Self(value.to_owned()))
    }
}

pub trait Backend: Send + Sync {
    fn read(&self) -> Result<Option<Vec<u8>>, AccountError>;
    /// Atomically replace this application's document. CommitUncertain means the
    /// replacement is visible but directory durability could not be confirmed.
    /// Other errors leave the previous document intact.
    fn write(&self, bytes: &[u8]) -> Result<(), AccountError>;
}
#[cfg(target_os = "linux")]
struct Locked;
#[cfg(target_os = "linux")]
impl Backend for Locked {
    fn read(&self) -> Result<Option<Vec<u8>>, AccountError> {
        Err(AccountError::Storage)
    }
    fn write(&self, _: &[u8]) -> Result<(), AccountError> {
        Err(AccountError::Storage)
    }
}
pub struct Keychain {
    #[cfg(target_os = "macos")]
    interactive: bool,
    #[cfg(target_os = "macos")]
    service: String,
    #[cfg(target_os = "macos")]
    account: String,
}
#[cfg(target_os = "macos")]
impl Keychain {
    fn production(interactive: bool) -> Self {
        Self {
            interactive,
            service: PRODUCTION_KEYCHAIN_SERVICE.into(),
            account: PRODUCTION_KEYCHAIN_ACCOUNT.into(),
        }
    }

    fn isolated(interactive: bool, namespace: &VaultNamespace) -> Self {
        Self {
            interactive,
            service: namespace.keychain_service(),
            account: namespace.keychain_account(),
        }
    }

    fn options(&self) -> security_framework::passwords::PasswordOptions {
        let mut options = security_framework::passwords::PasswordOptions::new_generic_password(
            &self.service,
            &self.account,
        );
        if !self.interactive {
            use core_foundation::{base::TCFType, string::CFString};
            use security_framework_sys::item::kSecUseAuthenticationUI;
            // This public Security.framework constant is absent from the pinned sys bindings.
            unsafe extern "C" {
                static kSecUseAuthenticationUIFail: core_foundation::string::CFStringRef;
            }
            // The pinned wrapper exposes no setter for this per-query native option.
            #[allow(deprecated)]
            unsafe {
                options.query.push((
                    CFString::wrap_under_get_rule(kSecUseAuthenticationUI),
                    CFString::wrap_under_get_rule(kSecUseAuthenticationUIFail).into_CFType(),
                ));
            }
        }
        options
    }
}
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
impl Keychain {
    fn production(_interactive: bool) -> Self {
        Self {}
    }

    fn isolated(_interactive: bool, _namespace: &VaultNamespace) -> Self {
        Self {}
    }
}
impl Backend for Keychain {
    fn read(&self) -> Result<Option<Vec<u8>>, AccountError> {
        #[cfg(target_os = "macos")]
        {
            match security_framework::passwords::generic_password(self.options()) {
                Ok(bytes) => Ok(Some(bytes)),
                Err(e) if e.code() == -25300 => Ok(None),
                Err(_) => Err(AccountError::Storage),
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err(AccountError::Unsupported)
        }
    }
    fn write(&self, bytes: &[u8]) -> Result<(), AccountError> {
        #[cfg(target_os = "macos")]
        {
            security_framework::passwords::set_generic_password_options(bytes, self.options())
                .map_err(|_| AccountError::Storage)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = bytes;
            Err(AccountError::Unsupported)
        }
    }
}
pub struct VaultLock {
    file: File,
    _process_lock: ProcessLock,
}
struct ProcessLock {
    held: Arc<AtomicBool>,
}
impl Drop for ProcessLock {
    fn drop(&mut self) {
        self.held.store(false, Ordering::Release);
    }
}
impl Drop for VaultLock {
    fn drop(&mut self) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            // Close-on-exec does not release a lock held by a descriptor copied
            // during process creation until exec completes. End our lock scope now.
            unsafe {
                libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
            }
        }
    }
}
fn acquire_process_lock(path: &std::path::Path) -> Result<ProcessLock, AccountError> {
    static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Weak<AtomicBool>>>> = OnceLock::new();
    let held = {
        let mut locks = LOCKS
            .get_or_init(|| Mutex::new(HashMap::new()))
            .lock()
            .map_err(|_| AccountError::Storage)?;
        locks.retain(|_, lock| lock.strong_count() > 0);
        match locks.get(path).and_then(Weak::upgrade) {
            Some(lock) => lock,
            None => {
                let lock = Arc::new(AtomicBool::new(false));
                locks.insert(path.to_owned(), Arc::downgrade(&lock));
                lock
            }
        }
    };
    held.compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
        .map_err(|_| AccountError::Busy)?;
    Ok(ProcessLock { held })
}
#[derive(Clone)]
pub struct Vault {
    backend: Arc<dyn Backend>,
    lock_path: PathBuf,
}
pub struct Transaction {
    backend: Arc<dyn Backend>,
    _lock: VaultLock,
    pub document: Document,
}
impl Vault {
    pub fn system() -> Result<Self, AccountError> {
        Self::system_with_interaction(true, None, None)
    }
    pub fn for_usage() -> Result<Self, AccountError> {
        Self::system_with_interaction(false, None, None)
    }
    pub fn isolated_for_management(
        namespace: &VaultNamespace,
        data_directory: &std::path::Path,
    ) -> Result<Self, AccountError> {
        if !data_directory.is_absolute() {
            return Err(AccountError::Storage);
        }
        Self::system_with_interaction(true, Some(namespace), Some(data_directory.to_owned()))
    }
    fn system_with_interaction(
        _interactive: bool,
        namespace: Option<&VaultNamespace>,
        isolated_directory: Option<PathBuf>,
    ) -> Result<Self, AccountError> {
        let directory = match (namespace, isolated_directory) {
            (Some(_), Some(directory)) => directory,
            (None, None) => directories::ProjectDirs::from("", "", "quotio")
                .map(|dirs| dirs.data_local_dir().to_owned())
                .ok_or(AccountError::Storage)?,
            _ => return Err(AccountError::Storage),
        };
        #[cfg(target_os = "linux")]
        let backend: Arc<dyn Backend> = match super::encrypted_file::EncryptedFile::from_environment(
            &directory.join(
                namespace
                    .map(VaultNamespace::vault_name)
                    .unwrap_or_else(|| "vault".into()),
            ),
        ) {
            Ok(backend) => Arc::new(backend),
            Err(_) => Arc::new(Locked),
        };
        #[cfg(not(target_os = "linux"))]
        let backend: Arc<dyn Backend> = Arc::new(match namespace {
            Some(namespace) => Keychain::isolated(_interactive, namespace),
            None => Keychain::production(_interactive),
        });
        let lock_name = namespace
            .map(VaultNamespace::lock_name)
            .unwrap_or_else(|| "accounts.lock".into());
        Ok(Self::new(backend, directory.join(lock_name)))
    }
    pub fn new(backend: Arc<dyn Backend>, lock_path: PathBuf) -> Self {
        Self { backend, lock_path }
    }
    pub fn refresh_lock(&self, id: &str) -> Result<VaultLock, AccountError> {
        if id.is_empty()
            || id.len() > 80
            || !id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(AccountError::Corrupt);
        }
        acquire(&self.lock_path.with_file_name(format!("refresh-{id}.lock")))
    }
    pub fn begin(&self) -> Result<Transaction, AccountError> {
        let lock = acquire(&self.lock_path)?;
        let document = match self.backend.read()? {
            None => Document::empty(),
            Some(bytes) => {
                if bytes.len() > 1024 * 1024 {
                    return Err(AccountError::Corrupt);
                }
                let doc: Document =
                    serde_json::from_slice(&bytes).map_err(|_| AccountError::Corrupt)?;
                if !matches!(doc.version, 1..=9)
                    || (doc.version < 9 && doc.has_enterprise_copilot())
                    || (doc.version < 8
                        && (!doc.antigravity_refresh_owners.is_empty()
                            || doc.accounts.iter().any(|a| {
                                matches!(a.credential, super::Credential::AntigravityOAuth { .. })
                            })))
                    || (doc.version < 7
                        && (!doc.kiro_refresh_owners.is_empty()
                            || doc.accounts.iter().any(|a| {
                                matches!(a.credential, super::Credential::KiroOAuth { .. })
                            })))
                    || (doc.version < 6
                        && (!doc.claude_refresh_owners.is_empty()
                            || doc.accounts.iter().any(|a| {
                                matches!(
                                    a.credential,
                                    super::Credential::ClaudeOAuth { .. }
                                        | super::Credential::CopilotOAuth { .. }
                                )
                            })))
                    || (doc.version == 1 && !doc.mutation_receipts.is_empty())
                    || (doc.version < 3
                        && doc.accounts.iter().any(|a| {
                            matches!(
                                a.credential,
                                super::Credential::QuotioCustomProvider { .. }
                                    | super::Credential::AmpNative { .. }
                                    | super::Credential::CodexNative { .. }
                                    | super::Credential::ClaudeNative { .. }
                                    | super::Credential::CopilotNative { .. }
                                    | super::Credential::CursorNative { .. }
                                    | super::Credential::GrokNative { .. }
                                    | super::Credential::DevinDesktopNative { .. }
                                    | super::Credential::FactoryNative { .. }
                                    | super::Credential::KiroNative { .. }
                                    | super::Credential::AntigravityNative { .. }
                            )
                        }))
                    || (doc.version < 4 && doc.accounts.iter().any(|a| !a.enabled))
                    || doc.mutation_receipts.len() > 4096
                {
                    return Err(AccountError::Corrupt);
                }
                doc
            }
        };
        Ok(Transaction {
            backend: self.backend.clone(),
            _lock: lock,
            document,
        })
    }
}
fn acquire(path: &std::path::Path) -> Result<VaultLock, AccountError> {
    // `flock` behavior for separate descriptors in one process varies by platform.
    // Pair it with a process-local guard so tasks cannot enter the same lock scope.
    let process_lock = acquire_process_lock(path)?;
    let parent = path.parent().ok_or(AccountError::Storage)?;
    std::fs::create_dir_all(parent).map_err(|_| AccountError::Storage)?;
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let lock = options.open(path).map_err(|_| AccountError::Storage)?;
    if !lock
        .metadata()
        .map_err(|_| AccountError::Storage)?
        .is_file()
    {
        return Err(AccountError::Storage);
    }
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        // Keep the descriptor alive until the protected operation completes.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(AccountError::Busy);
        }
    }
    #[cfg(not(unix))]
    {
        return Err(AccountError::Unsupported);
    }
    Ok(VaultLock {
        file: lock,
        _process_lock: process_lock,
    })
}
impl Transaction {
    pub fn commit(mut self) -> Result<(), AccountError> {
        // Also upgrade reservations written by pre-format-5 builds, even when
        // this mutation touches only an unrelated account or retry receipt.
        if !self.document.factory_refresh_owners.is_empty() {
            self.document.version = self.document.version.max(5);
        }
        if !self.document.antigravity_refresh_owners.is_empty() {
            self.document.version = self.document.version.max(8);
        }
        if !self.document.kiro_refresh_owners.is_empty() {
            self.document.version = self.document.version.max(7);
        }
        if !self.document.claude_refresh_owners.is_empty() {
            self.document.version = self.document.version.max(6);
        }
        // Format-8 readers ignore the Copilot host and would send an enterprise
        // token to GitHub.com, so host-bearing credentials require format 9.
        if self.document.has_enterprise_copilot() {
            self.document.version = self.document.version.max(9);
        }
        let bytes = serde_json::to_vec(&self.document).map_err(|_| AccountError::Corrupt)?;
        if bytes.len() > 1024 * 1024 {
            return Err(AccountError::Input);
        }
        self.backend.write(&bytes)
    }
}
#[cfg(test)]
#[path = "fixtures/pre_antigravity_reservations.rs"]
mod pre_antigravity_reservations;
#[cfg(test)]
#[path = "fixtures/pre_claude_reservations.rs"]
mod pre_claude_reservations;
#[cfg(test)]
#[path = "fixtures/pre_kiro_reservations.rs"]
mod pre_kiro_reservations;

#[cfg(test)]
#[path = "fixtures/pre_factory_reservations.rs"]
mod pre_factory_reservations;

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::{
        accounts::{Credential, random_string},
        cli::Provider,
    };
    use std::sync::{
        Mutex,
        atomic::{AtomicBool, Ordering},
    };
    #[derive(Default)]
    pub struct Memory {
        bytes: Mutex<Option<Vec<u8>>>,
        pub fail: AtomicBool,
    }
    impl Backend for Memory {
        fn read(&self) -> Result<Option<Vec<u8>>, AccountError> {
            Ok(self.bytes.lock().unwrap().clone())
        }
        fn write(&self, b: &[u8]) -> Result<(), AccountError> {
            if self.fail.load(Ordering::SeqCst) {
                return Err(AccountError::Storage);
            }
            *self.bytes.lock().unwrap() = Some(b.to_vec());
            Ok(())
        }
    }
    fn credential() -> Credential {
        Credential::ApiKey {
            token: "secret-sentinel".into(),
            region: None,
            organization: None,
        }
    }
    #[test]
    fn lock_excludes_other_descriptors_in_the_same_process() {
        let dir = std::env::temp_dir().join(random_string().unwrap());
        let path = dir.join("lock");
        let guard = acquire(&path).unwrap();
        assert!(matches!(acquire(&path), Err(AccountError::Busy)));
        drop(guard);
        assert!(acquire(&path).is_ok());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn lock_scope_ends_even_when_a_descriptor_is_duplicated() {
        let dir = std::env::temp_dir().join(random_string().unwrap());
        let path = dir.join("lock");
        let guard = acquire(&path).unwrap();
        let duplicate = guard.file.try_clone().unwrap();
        drop(guard);
        let next = acquire(&path).unwrap();
        drop(next);
        drop(duplicate);
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn owned_enabled_state_requires_format_four_and_survives_new_sources() {
        let memory = Arc::new(Memory::default());
        let dir = std::env::temp_dir().join(random_string().unwrap());
        let vault = Vault::new(memory.clone(), dir.join("lock"));
        let mut tx = vault.begin().unwrap();
        let id = tx
            .document
            .add(Provider::Amp, "Owned", "owned".into(), credential())
            .unwrap();
        tx.document.patch(&id, None, None, Some(false)).unwrap();
        assert_eq!(tx.document.version, 4);
        tx.document
            .add(
                Provider::Amp,
                "Native",
                "native".into(),
                crate::accounts::Credential::AmpNative {
                    source: crate::accounts::sources::AmpNativeReference {
                        path: dir.join("secrets.json"),
                        enabled: true,
                    },
                },
            )
            .unwrap();
        assert_eq!(tx.document.version, 4);
        tx.commit().unwrap();
        assert!(!vault.begin().unwrap().document.accounts[0].enabled());
        let mut value: serde_json::Value =
            serde_json::from_slice(&memory.read().unwrap().unwrap()).unwrap();
        value["version"] = 3.into();
        memory.write(&serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(matches!(vault.begin(), Err(AccountError::Corrupt)));
        std::fs::remove_dir_all(dir).unwrap();
    }
    pub(crate) fn assert_old_reader_rejects(bytes: &[u8]) {
        assert!(matches!(
            pre_factory_reservations::read(bytes),
            Err(AccountError::Corrupt)
        ));
    }

    pub(crate) fn factory_credential() -> Credential {
        Credential::FactoryOAuth {
            access_token: "fixture-access".into(),
            refresh_token: "fixture-refresh".into(),
            organization_id: Some("fixture-org".into()),
            expires_at: 0,
            refresh_pending: true,
        }
    }

    #[test]
    fn antigravity_reservations_reject_downgrade_after_deletion() {
        let dir = std::env::temp_dir().join(random_string().unwrap());
        let memory = Arc::new(Memory::default());
        let vault = Vault::new(memory.clone(), dir.join("lock"));
        let credential = Credential::AntigravityOAuth {
            access_token: "fixture-access".into(),
            refresh_token: "fixture-refresh".into(),
            expires_at: 0,
            client_id: "fixture-client".into(),
            client_secret: "fixture-secret".into(),
            refresh_pending: false,
        };
        let mut tx = vault.begin().unwrap();
        let id = tx
            .document
            .add(
                Provider::Antigravity,
                "Fixture",
                "fixture".into(),
                credential.clone(),
            )
            .unwrap();
        tx.commit().unwrap();
        let mut tx = vault.begin().unwrap();
        tx.document.accounts.clear();
        tx.commit().unwrap();
        let mut tx = vault.begin().unwrap();
        assert_eq!(tx.document.version, 8);
        assert!(matches!(
            tx.document.reserve_factory_refresh("another", &credential),
            Err(AccountError::Duplicate)
        ));
        assert!(
            tx.document
                .reserve_factory_refresh(&id, &credential)
                .is_ok()
        );
        drop(tx);
        let bytes = memory.read().unwrap().unwrap();
        assert!(pre_antigravity_reservations::read(&bytes).is_err());
        let mut downgraded: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        downgraded["version"] = 7.into();
        // The real previous reader accepts format 7 and ignores the new owners.
        // Merely writing 7 would therefore allow refresh lineage to be lost.
        assert!(
            pre_antigravity_reservations::read(&serde_json::to_vec(&downgraded).unwrap()).is_ok()
        );
        memory
            .write(&serde_json::to_vec(&downgraded).unwrap())
            .unwrap();
        assert!(matches!(vault.begin(), Err(AccountError::Corrupt)));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn enterprise_copilot_hosts_require_format_nine() {
        let memory = Arc::new(Memory::default());
        let dir = std::env::temp_dir().join(random_string().unwrap());
        let vault = Vault::new(memory.clone(), dir.join("lock"));
        let credential = crate::accounts::Credential::CopilotOAuth {
            access_token: "fixture-token".into(),
            account_id: "42".into(),
            login: "fixture-login".into(),
            host: Some(
                crate::accounts::github_host::GitHubHost::parse("octocorp.ghe.com").unwrap(),
            ),
        };
        let mut tx = vault.begin().unwrap();
        tx.document
            .add(
                Provider::Catalog("copilot"),
                "Fixture",
                "octocorp.ghe.com:42".into(),
                credential,
            )
            .unwrap();
        tx.commit().unwrap();
        let bytes = memory.read().unwrap().unwrap();
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value["version"], 9);
        // A format-8 reader would ignore the host and query GitHub.com.
        value["version"] = 8.into();
        memory.write(&serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(matches!(vault.begin(), Err(AccountError::Corrupt)));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn kiro_reservations_reject_old_readers_after_deletion() {
        let memory = Arc::new(Memory::default());
        let dir = std::env::temp_dir().join(random_string().unwrap());
        let vault = Vault::new(memory.clone(), dir.join("lock"));
        let credential = crate::providers::catalog::oauth_cloud::kiro_owned_credential(serde_json::from_value(serde_json::json!({
            "kind":"kiro_owned", "label":"Kiro", "access_token":"fixture-access", "refresh_token":"fixture-refresh", "expires_at":0,
            "authMethod":"Social", "region":"us-east-1"
        })).unwrap()).unwrap();
        let mut tx = vault.begin().unwrap();
        let id = tx
            .document
            .add(
                Provider::Catalog("kiro"),
                "Kiro",
                "id".into(),
                credential.clone(),
            )
            .unwrap();
        tx.commit().unwrap();
        let mut tx = vault.begin().unwrap();
        tx.document.remove(&id).unwrap();
        tx.commit().unwrap();
        let bytes = memory.read().unwrap().unwrap();
        assert!(matches!(
            pre_kiro_reservations::read(&bytes),
            Err(AccountError::Corrupt)
        ));
        let mut tx = vault.begin().unwrap();
        assert_eq!(tx.document.version, 7);
        assert!(matches!(
            tx.document.add(
                Provider::Catalog("kiro"),
                "Again",
                "other".into(),
                credential
            ),
            Err(AccountError::Duplicate)
        ));
        drop(tx);
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        value["version"] = 6.into();
        let downgraded = serde_json::to_vec(&value).unwrap();
        let old = pre_kiro_reservations::read(&downgraded).unwrap();
        assert!(
            serde_json::to_value(old)
                .unwrap()
                .get("kiro_refresh_owners")
                .is_none()
        );
        memory.write(&downgraded).unwrap();
        assert!(matches!(vault.begin(), Err(AccountError::Corrupt)));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn claude_reservations_survive_deletion_and_reject_downgraded_format() {
        let memory = Arc::new(Memory::default());
        let dir = std::env::temp_dir().join(random_string().unwrap());
        let vault = Vault::new(memory.clone(), dir.join("lock"));
        let credential = Credential::ClaudeOAuth {
            access_token: "fixture-access".into(),
            refresh_token: "fixture-refresh".into(),
            account_id: "id".into(),
            email: "demo@example.com".into(),
            expires_at: 0,
            refresh_pending: true,
        };
        let mut tx = vault.begin().unwrap();
        let id = tx
            .document
            .add(
                Provider::Catalog("claude"),
                "Claude",
                "id".into(),
                credential.clone(),
            )
            .unwrap();
        tx.commit().unwrap();
        let mut tx = vault.begin().unwrap();
        tx.document.remove(&id).unwrap();
        tx.commit().unwrap();
        let mut tx = vault.begin().unwrap();
        assert_eq!(tx.document.version, 6);
        assert!(matches!(
            tx.document.add(
                Provider::Catalog("claude"),
                "Again",
                "other".into(),
                credential
            ),
            Err(AccountError::Duplicate)
        ));
        drop(tx);
        let bytes = memory.read().unwrap().unwrap();
        assert_old_reader_rejects(&bytes);
        assert!(matches!(
            pre_claude_reservations::read(&bytes),
            Err(AccountError::Corrupt)
        ));
        let mut value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        value["version"] = 5.into();
        let old = pre_claude_reservations::read(&serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(
            serde_json::to_value(old)
                .unwrap()
                .get("claude_refresh_owners")
                .is_none()
        );
        memory.write(&serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(matches!(vault.begin(), Err(AccountError::Corrupt)));
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn factory_reservations_require_format_five_through_all_mutations() {
        let memory = Arc::new(Memory::default());
        let dir = std::env::temp_dir().join(random_string().unwrap());
        let vault = Vault::new(memory.clone(), dir.join("lock"));
        let mut tx = vault.begin().unwrap();
        let factory = tx
            .document
            .add(
                Provider::Factory,
                "Factory",
                "factory".into(),
                factory_credential(),
            )
            .unwrap();
        tx.commit().unwrap();
        assert_old_reader_rejects(&memory.read().unwrap().unwrap());
        let mut tx = vault.begin().unwrap();
        let other = tx
            .document
            .add(Provider::Amp, "Other", "other".into(), credential())
            .unwrap();
        tx.commit().unwrap();
        for action in 0..5 {
            let mut tx = vault.begin().unwrap();
            match action {
                0 => tx.document.rename(&other, "Renamed").unwrap(),
                1 => tx.document.patch(&other, None, None, Some(false)).unwrap(),
                2 => tx.document.select(&other).unwrap(),
                3 => tx.document.remove(&factory).unwrap(),
                _ => tx.document.remove(&other).unwrap(),
            }
            tx.commit().unwrap();
            let bytes = memory.read().unwrap().unwrap();
            assert_old_reader_rejects(&bytes);
            let tx = vault.begin().unwrap();
            assert_eq!(tx.document.version, 5);
            assert_eq!(tx.document.factory_refresh_owners.len(), 1);
        }
        // A pre-fix document is accepted by the old model, which drops the ledger.
        // Any current write must upgrade it, including an unrelated rename.
        let mut value: serde_json::Value =
            serde_json::from_slice(&memory.read().unwrap().unwrap()).unwrap();
        value["version"] = 4.into();
        let bytes = serde_json::to_vec(&value).unwrap();
        let old = pre_factory_reservations::read(&bytes).unwrap();
        assert!(
            serde_json::to_value(old)
                .unwrap()
                .get("factory_refresh_owners")
                .is_none()
        );
        memory.write(&bytes).unwrap();
        let mut tx = vault.begin().unwrap();
        let other = tx
            .document
            .add(Provider::Amp, "Other", "other".into(), credential())
            .unwrap();
        tx.document.rename(&other, "Renamed").unwrap();
        tx.commit().unwrap();
        assert_old_reader_rejects(&memory.read().unwrap().unwrap());
        let mut tx = vault.begin().unwrap();
        assert!(matches!(
            tx.document.add(
                Provider::Factory,
                "Replay",
                "new-org".into(),
                factory_credential()
            ),
            Err(AccountError::Duplicate)
        ));
        drop(tx);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn transactions_select_remove_and_rollback() {
        let memory = Arc::new(Memory::default());
        let dir = std::env::temp_dir().join(random_string().unwrap());
        let vault = Vault::new(memory.clone(), dir.join("lock"));
        let mut tx = vault.begin().unwrap();
        let a = tx
            .document
            .add(Provider::Amp, "first", "id1".into(), credential())
            .unwrap();
        assert!(matches!(vault.begin(), Err(AccountError::Busy)));
        assert!(
            tx.document
                .add(Provider::Amp, "first", "id2".into(), credential())
                .is_err()
        );
        let b = tx
            .document
            .add(Provider::Amp, "second", "id2".into(), credential())
            .unwrap();
        tx.commit().unwrap();
        let mut tx = vault.begin().unwrap();
        tx.document.select(&b).unwrap();
        tx.commit().unwrap();
        let mut tx = vault.begin().unwrap();
        assert!(
            tx.document
                .accounts
                .iter()
                .find(|a| a.id == b)
                .unwrap()
                .active
        );
        let visible = serde_json::to_string(
            &tx.document
                .accounts
                .iter()
                .map(|a| a.info())
                .collect::<Vec<_>>(),
        )
        .unwrap();
        assert!(!visible.contains("secret-sentinel"));
        tx.document.remove(&b).unwrap();
        memory.fail.store(true, Ordering::SeqCst);
        assert!(tx.commit().is_err());
        memory.fail.store(false, Ordering::SeqCst);
        let mut tx = vault.begin().unwrap();
        assert_eq!(tx.document.accounts.len(), 2);
        tx.document.remove(&b).unwrap();
        tx.commit().unwrap();
        let tx = vault.begin().unwrap();
        assert_eq!(tx.document.accounts[0].id, a);
        assert!(tx.document.accounts[0].active);
        drop(tx);
        std::fs::remove_file(dir.join("lock")).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn usage_keychain_queries_fail_instead_of_prompting() {
        use core_foundation::{base::TCFType, string::CFString};
        use security_framework_sys::item::kSecUseAuthenticationUI;
        unsafe extern "C" {
            static kSecUseAuthenticationUIFail: core_foundation::string::CFStringRef;
        }
        let key = unsafe { CFString::wrap_under_get_rule(kSecUseAuthenticationUI) };
        let fail =
            unsafe { CFString::wrap_under_get_rule(kSecUseAuthenticationUIFail).into_CFType() };
        #[allow(deprecated)]
        let noninteractive = Keychain::production(false).options().query;
        #[allow(deprecated)]
        let interactive = Keychain::production(true).options().query;
        assert!(noninteractive.iter().any(|(k, v)| k == &key && v == &fail));
        assert!(!interactive.iter().any(|(k, _)| k == &key));
    }
    #[test]
    fn isolated_namespace_changes_keychain_tuple_and_lock() {
        let namespace: VaultNamespace = "manual-test".parse().unwrap();
        #[cfg(target_os = "macos")]
        assert_eq!(
            namespace.keychain_service(),
            "app.quotio.cli.accounts.manual-test.v1"
        );
        #[cfg(target_os = "macos")]
        assert_eq!(namespace.keychain_account(), "vault.manual-test");
        assert_eq!(namespace.lock_name(), "accounts-manual-test.lock");
        for invalid in ["", "Manual", "-manual", "manual-", "manual_test", "a/../b"] {
            assert!(invalid.parse::<VaultNamespace>().is_err());
        }
    }
    #[test]
    fn isolated_account_data_directory_must_be_absolute() {
        let namespace: VaultNamespace = "manual-test".parse().unwrap();
        assert!(
            Vault::isolated_for_management(&namespace, std::path::Path::new("relative")).is_err()
        );
        let isolated =
            Vault::isolated_for_management(&namespace, std::path::Path::new("/isolated/accounts"))
                .unwrap();
        assert_eq!(
            isolated.lock_path,
            PathBuf::from("/isolated/accounts/accounts-manual-test.lock")
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "explicit native Keychain smoke; synthetic isolated item only"]
    fn native_keychain_round_trip() {
        use security_framework::passwords::{
            delete_generic_password, get_generic_password, set_generic_password,
        };
        let service = format!("app.quotio.cli.verification.{}", random_string().unwrap());
        assert!(get_generic_password(&service, "test").is_err());
        set_generic_password(&service, "test", b"synthetic-first").unwrap();
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = delete_generic_password(&self.0, "test");
            }
        }
        let _cleanup = Cleanup(service.clone());
        assert_eq!(
            get_generic_password(&service, "test").unwrap(),
            b"synthetic-first"
        );
        set_generic_password(&service, "test", b"synthetic-updated").unwrap();
        assert_eq!(
            get_generic_password(&service, "test").unwrap(),
            b"synthetic-updated"
        );
        delete_generic_password(&service, "test").unwrap();
        assert!(get_generic_password(&service, "test").is_err());
    }
}
