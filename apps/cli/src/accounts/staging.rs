//! Offline assessment and explicit staging of Swift metadata and PIV ciphertext.
//! Receipts are evidence only: no credential is unlocked, imported or activated.
use base64::Engine;
use serde::{Deserialize, Serialize};
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StagingError {
    #[error("use an absolute path without symlinks and a 64-character hexadecimal PIV fingerprint")]
    Input,
    #[error("receipt directory must already exist, be private, and contain no symlink components")]
    Storage,
    #[error("existing receipt differs or is unsafe; nothing was replaced")]
    Conflict,
    #[error("receipt may have been written but durability is uncertain; rerun to verify")]
    CommitUncertain,
    #[error("metadata or explicit mapping is unsupported or inconsistent")]
    Mapping,
    #[error("offline envelope assessment is supported only on Unix")]
    Unsupported,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EnvelopeState {
    Absent,
    Unreadable,
    UnsupportedEnvelope,
    PresentLockedOrUnverified,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct Plan {
    pub version: u8,
    pub scope: &'static str,
    pub envelope_state: EnvelopeState,
    pub protection: &'static str,
    pub key_access: &'static str,
    pub fingerprint_binding: &'static str,
    pub declared_piv_fingerprint: String,
    pub envelope_sha256: Option<String>,
    pub migration_blocked: bool,
    pub next_action: &'static str,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    version: u64,
    #[serde(rename = "wrappedKey")]
    wrapped_key: String,
    #[serde(rename = "sealedSecret")]
    sealed_secret: String,
}

fn digest(bytes: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, bytes)
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn recognized(bytes: &[u8]) -> bool {
    let Ok(envelope) = serde_json::from_slice::<Envelope>(bytes) else {
        return false;
    };
    let base64 = base64::engine::general_purpose::STANDARD;
    envelope.version == 1
        && base64.decode(envelope.wrapped_key).is_ok_and(|key| {
            // Swift provisions RSA-2048 and also accepts externally provisioned RSA identities.
            matches!(key.len(), 256 | 384 | 512)
        })
        && base64
            .decode(envelope.sealed_secret)
            .is_ok_and(|sealed| sealed.len() >= 28)
}

/// The fingerprint is a caller declaration, not proof that a token can open the envelope.
/// Even a structurally valid envelope blocks migration until PIV-backed access exists.
pub fn assess(path: &Path, fingerprint: &str) -> Result<Plan, StagingError> {
    if fingerprint.len() != 64 || !fingerprint.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(StagingError::Input);
    }
    #[cfg(unix)]
    let (state, hash) = unix::inspect(path)?;
    #[cfg(not(unix))]
    let (state, hash) = {
        let _ = path;
        return Err(StagingError::Unsupported);
        #[allow(unreachable_code)]
        (EnvelopeState::Unreadable, None)
    };
    Ok(Plan {
        version: 1,
        scope: "swift_piv_envelope_assessment_only",
        envelope_state: state,
        protection: "piv_required_no_keychain_or_software_vault_fallback",
        key_access: "not_attempted",
        fingerprint_binding: "caller_declared_unverified",
        declared_piv_fingerprint: fingerprint.to_ascii_lowercase(),
        envelope_sha256: hash,
        migration_blocked: true,
        next_action: "retain_originals_until_piv_preserving_import_is_implemented_and_verified",
    })
}

/// Stage the assessment, never the credential. Existing receipts are never replaced.
/// Reruns verify bytes and sync the existing receipt instead of writing it again.
pub fn stage(plan: &Plan, directory: &Path) -> Result<String, StagingError> {
    let bytes = serde_json::to_vec(plan).map_err(|_| StagingError::Storage)?;
    let id = digest(&bytes);
    #[cfg(unix)]
    unix::save(directory, &format!("{id}.json"), &bytes)?;
    #[cfg(not(unix))]
    {
        let _ = directory;
        return Err(StagingError::Unsupported);
    }
    Ok(id)
}

/// Explicit declarations, compared exactly with the selected Swift record.
/// None of these values are echoed in receipts or errors.
pub struct Mapping<'a> {
    pub account_id: &'a str,
    pub provider: &'a str,
    pub source: &'a str,
    pub credential_reference: Option<&'a str>,
    pub service: &'a str,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct SwiftMetadata {
    accounts: Vec<SwiftAccount>,
    #[serde(rename = "disabledAccountIDs")]
    disabled_account_ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct SwiftAccount {
    id: String,
    provider: String,
    account_key: String,
    display_name: String,
    source: String,
    credential_reference: Option<String>,
    #[serde(default)]
    can_delete: bool,
    #[serde(default)]
    is_disabled: bool,
}

#[derive(Serialize)]
pub struct MappingPlan {
    envelope: Plan,
    scope: &'static str,
    metadata_sha256: String,
    account_identifier_sha256: String,
    provider_identifier_sha256: String,
    source: String,
    credential_reference_sha256: Option<String>,
    service_identifier_sha256: String,
    filename_binding: &'static str,
    record_disabled: bool,
    repository_disabled: bool,
    can_delete: bool,
    date_semantics: &'static str,
    migration_blocked: bool,
}

/// An immutable snapshot of validated input bytes. Cannot be constructed by callers.
/// Serialize only `plan()`, never the metadata or ciphertext buffers.
pub struct MappingAssessment {
    plan: MappingPlan,
    metadata: Vec<u8>,
    ciphertext: Vec<u8>,
}

impl MappingAssessment {
    pub fn plan(&self) -> &MappingPlan {
        &self.plan
    }
}

fn identifier(value: &str) -> bool {
    !value.is_empty() && value.len() <= 4096 && !value.chars().any(char::is_control)
}

/// Read only the two supplied files. A filename match is not authenticated binding.
#[cfg(unix)]
pub fn assess_mapping(
    metadata_path: &Path,
    envelope_path: &Path,
    fingerprint: &str,
    mapping: &Mapping<'_>,
) -> Result<MappingAssessment, StagingError> {
    if ![
        mapping.account_id,
        mapping.provider,
        mapping.source,
        mapping.service,
    ]
    .into_iter()
    .all(identifier)
        || mapping.credential_reference.is_some_and(|v| !identifier(v))
    {
        return Err(StagingError::Mapping);
    }
    let metadata = unix::read_input(metadata_path).map_err(|_| StagingError::Mapping)?;
    let payload: SwiftMetadata =
        serde_json::from_slice(&metadata).map_err(|_| StagingError::Mapping)?;
    let mut ids = std::collections::HashSet::new();
    for account in &payload.accounts {
        if !ids.insert(account.id.as_str())
            || ![
                account.id.as_str(),
                &account.provider,
                &account.account_key,
                &account.display_name,
            ]
            .into_iter()
            .all(identifier)
            || !matches!(
                account.source.as_str(),
                "quotioKeychain" | "nativeCredential" | "legacyCLIProxy" | "localIDE" | "apiKey"
            )
            || account
                .credential_reference
                .as_deref()
                .is_some_and(|v| !identifier(v))
        {
            return Err(StagingError::Mapping);
        }
    }
    let mut disabled = std::collections::HashSet::new();
    if payload
        .disabled_account_ids
        .iter()
        .any(|id| !identifier(id) || !disabled.insert(id.as_str()))
    {
        return Err(StagingError::Mapping);
    }
    let account = payload
        .accounts
        .iter()
        .find(|a| a.id == mapping.account_id)
        .ok_or(StagingError::Mapping)?;
    // Swift's owned credential vault uses monitor-auth and the literal keychain reference.
    // Borrowed records must never be promoted merely by renaming an envelope.
    let known_provider = matches!(
        mapping.provider,
        "claude"
            | "codex"
            | "antigravity"
            | "kiro"
            | "github-copilot"
            | "cursor"
            | "factory-droid"
            | "devin"
            | "grok"
            | "openrouter"
            | "amp"
            | "glm"
            | "warp"
            | "clinepass"
    );
    let known_service = matches!(
        mapping.service,
        "app.bytrong.quotio.monitor-auth"
            | "dev.quotio.desktop.monitor-auth"
            | "proseek.io.vn.Quotio.monitor-auth"
            | "com.quotio.monitor-auth"
    );
    if !known_provider
        || !known_service
        || !matches!(mapping.source, "quotioKeychain" | "apiKey")
        || mapping.credential_reference != Some("keychain")
        || account.provider != mapping.provider
        || account.source != mapping.source
        || account.credential_reference.as_deref() != mapping.credential_reference
    {
        return Err(StagingError::Mapping);
    }
    let candidate = format!(
        "{}.qsv",
        digest(format!("{}\0{}", mapping.service, mapping.account_id).as_bytes())
    );
    if envelope_path.file_name().and_then(|v| v.to_str()) != Some(candidate.as_str()) {
        return Err(StagingError::Mapping);
    }
    // Assess and copy the same pinned, bounded snapshot, not a second path lookup.
    let ciphertext = unix::read_input(envelope_path).map_err(|_| StagingError::Mapping)?;
    if !recognized(&ciphertext)
        || fingerprint.len() != 64
        || !fingerprint.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(StagingError::Mapping);
    }
    let envelope = Plan {
        version: 1,
        scope: "swift_piv_envelope_assessment_only",
        envelope_state: EnvelopeState::PresentLockedOrUnverified,
        protection: "piv_required_no_keychain_or_software_vault_fallback",
        key_access: "not_attempted",
        fingerprint_binding: "caller_declared_unverified",
        declared_piv_fingerprint: fingerprint.to_ascii_lowercase(),
        envelope_sha256: Some(digest(&ciphertext)),
        migration_blocked: true,
        next_action: "retain_originals_until_piv_preserving_import_is_implemented_and_verified",
    };
    let plan = MappingPlan {
        envelope,
        scope: "swift_metadata_and_encrypted_envelope_staging_only",
        metadata_sha256: digest(&metadata),
        account_identifier_sha256: digest(account.id.as_bytes()),
        provider_identifier_sha256: digest(account.provider.as_bytes()),
        source: account.source.clone(),
        credential_reference_sha256: account
            .credential_reference
            .as_ref()
            .map(|v| digest(v.as_bytes())),
        service_identifier_sha256: digest(mapping.service.as_bytes()),
        filename_binding: "service_nul_account_id_filename_candidate_unverified",
        record_disabled: account.is_disabled,
        repository_disabled: disabled.contains(account.id.as_str()),
        can_delete: account.can_delete,
        date_semantics: "account_metadata_has_no_dates_swift_default_dates_elsewhere_use_seconds_since_2001_01_01",
        migration_blocked: true,
    };
    Ok(MappingAssessment {
        plan,
        metadata,
        ciphertext,
    })
}

/// Explicit staging only. Publish artifacts without replacement, then the receipt.
/// Rerunning a fresh assessment verifies existing bytes and completes partial staging.
#[cfg(unix)]
pub fn stage_mapping(
    assessment: &MappingAssessment,
    directory: &Path,
) -> Result<String, StagingError> {
    let directory = unix::stage_directory(directory)?;
    unix::save_to(
        &directory,
        &format!("{}.metadata.json", digest(&assessment.metadata)),
        &assessment.metadata,
    )?;
    unix::save_to(
        &directory,
        &format!("{}.qsv", digest(&assessment.ciphertext)),
        &assessment.ciphertext,
    )?;
    let bytes = serde_json::to_vec(&assessment.plan).map_err(|_| StagingError::Storage)?;
    let id = digest(&bytes);
    unix::save_to(&directory, &format!("{id}.json"), &bytes)?;
    Ok(id)
}

#[cfg(unix)]
mod unix {
    use super::*;
    use std::{
        ffi::CString,
        fs::File,
        io::{Read, Write},
        os::{
            fd::{AsRawFd, FromRawFd},
            unix::{
                ffi::OsStrExt,
                fs::{FileExt, MetadataExt},
            },
        },
        path::Component,
    };
    const LIMIT: u64 = 1024 * 1024;

    fn openat(dir: &File, name: &CString, flags: i32) -> std::io::Result<File> {
        let fd = unsafe {
            libc::openat(
                dir.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
                0o600,
            )
        };
        if fd < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(unsafe { File::from_raw_fd(fd) })
        }
    }

    // Walk with pinned directory descriptors, refusing symlinks at every component.
    fn directory(path: &Path) -> Result<File, StagingError> {
        if !path.is_absolute() {
            return Err(StagingError::Input);
        }
        let mut dir = File::open("/").map_err(|_| StagingError::Storage)?;
        for component in path.components() {
            match component {
                Component::RootDir => {}
                Component::Normal(name) => {
                    let name = CString::new(name.as_bytes()).map_err(|_| StagingError::Input)?;
                    dir = openat(&dir, &name, libc::O_RDONLY | libc::O_DIRECTORY)
                        .map_err(|_| StagingError::Storage)?;
                }
                _ => return Err(StagingError::Input),
            }
        }
        Ok(dir)
    }

    fn regular(file: &File, private: bool) -> bool {
        file.metadata().is_ok_and(|m| {
            m.is_file()
                && m.nlink() == 1
                && m.uid() == unsafe { libc::geteuid() }
                && (!private || m.mode() & 0o077 == 0)
        })
    }

    fn unchanged(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
        a.dev() == b.dev()
            && a.ino() == b.ino()
            && a.len() == b.len()
            && a.mode() == b.mode()
            && a.uid() == b.uid()
            && a.nlink() == b.nlink()
            && a.mtime() == b.mtime()
            && a.mtime_nsec() == b.mtime_nsec()
            && a.ctime() == b.ctime()
            && a.ctime_nsec() == b.ctime_nsec()
    }

    pub(super) fn read_input(path: &Path) -> Result<Vec<u8>, StagingError> {
        let parent = directory(path.parent().ok_or(StagingError::Input)?)?;
        let name = CString::new(path.file_name().ok_or(StagingError::Input)?.as_bytes())
            .map_err(|_| StagingError::Input)?;
        let mut file = openat(&parent, &name, libc::O_RDONLY).map_err(|_| StagingError::Mapping)?;
        if !regular(&file, false) {
            return Err(StagingError::Mapping);
        }
        let before = file.metadata().map_err(|_| StagingError::Mapping)?;
        let mut bytes = Vec::new();
        (&mut file)
            .take(LIMIT + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| StagingError::Mapping)?;
        let after = file.metadata().map_err(|_| StagingError::Mapping)?;
        if bytes.len() as u64 > LIMIT
            || before.len() != after.len()
            || before.mtime() != after.mtime()
            || before.mtime_nsec() != after.mtime_nsec()
            || before.ctime() != after.ctime()
            || before.ctime_nsec() != after.ctime_nsec()
            || !regular(&file, false)
        {
            return Err(StagingError::Mapping);
        }
        Ok(bytes)
    }

    pub(super) fn inspect(path: &Path) -> Result<(EnvelopeState, Option<String>), StagingError> {
        if !path.is_absolute() {
            return Err(StagingError::Input);
        }
        let name = path.file_name().ok_or(StagingError::Input)?;
        let name = CString::new(name.as_bytes()).map_err(|_| StagingError::Input)?;
        let parent = match directory(path.parent().ok_or(StagingError::Input)?) {
            Ok(parent) => parent,
            Err(_) => return Ok((EnvelopeState::Unreadable, None)),
        };
        let file = match openat(&parent, &name, libc::O_RDONLY) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Ok((EnvelopeState::Absent, None));
            }
            Err(_) => return Ok((EnvelopeState::Unreadable, None)),
        };
        if !regular(&file, false) {
            return Ok((EnvelopeState::Unreadable, None));
        }
        let mut bytes = Vec::new();
        if file.take(LIMIT + 1).read_to_end(&mut bytes).is_err() || bytes.len() as u64 > LIMIT {
            return Ok((EnvelopeState::Unreadable, None));
        }
        // Do not expose hashes of unknown inputs, which might contain low-entropy plaintext secrets.
        if !recognized(&bytes) {
            return Ok((EnvelopeState::UnsupportedEnvelope, None));
        }
        Ok((
            EnvelopeState::PresentLockedOrUnverified,
            Some(digest(&bytes)),
        ))
    }

    pub(super) fn save(path: &Path, name: &str, bytes: &[u8]) -> Result<(), StagingError> {
        save_with_sync(path, name, bytes, File::sync_all)
    }

    pub(super) fn save_with_sync(
        path: &Path,
        name: &str,
        bytes: &[u8],
        sync: impl Fn(&File) -> std::io::Result<()>,
    ) -> Result<(), StagingError> {
        let dir = stage_directory(path)?;
        save_to_with_sync(&dir, name, bytes, sync)
    }

    pub(super) fn stage_directory(path: &Path) -> Result<File, StagingError> {
        let dir = directory(path)?;
        let meta = dir.metadata().map_err(|_| StagingError::Storage)?;
        if meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
            return Err(StagingError::Storage);
        }
        Ok(dir)
    }

    pub(super) fn save_to(dir: &File, name: &str, bytes: &[u8]) -> Result<(), StagingError> {
        save_to_with_sync(dir, name, bytes, File::sync_all)
    }

    fn save_to_with_sync(
        dir: &File,
        name: &str,
        bytes: &[u8],
        sync: impl Fn(&File) -> std::io::Result<()>,
    ) -> Result<(), StagingError> {
        let name = CString::new(name).unwrap();
        let verify = || {
            let mut existing =
                openat(dir, &name, libc::O_RDONLY).map_err(|_| StagingError::Conflict)?;
            if !regular(&existing, true) {
                return Err(StagingError::Conflict);
            }
            let before = existing.metadata().map_err(|_| StagingError::Conflict)?;
            let mut saved = Vec::new();
            (&mut existing)
                .take(LIMIT + 1)
                .read_to_end(&mut saved)
                .map_err(|_| StagingError::Conflict)?;
            if saved != bytes {
                return Err(StagingError::Conflict);
            }
            let stable = || {
                let after = existing.metadata().map_err(|_| StagingError::Conflict)?;
                let named = openat(dir, &name, libc::O_RDONLY)
                    .and_then(|f| f.metadata())
                    .map_err(|_| StagingError::Conflict)?;
                if !regular(&existing, true)
                    || !unchanged(&before, &after)
                    || !unchanged(&after, &named)
                {
                    return Err(StagingError::Conflict);
                }
                Ok(())
            };
            stable()?;
            sync(&existing)
                .and_then(|_| sync(dir))
                .map_err(|_| StagingError::CommitUncertain)?;
            // Same-length writes can share timestamps on coarse-resolution filesystems.
            let mut verified = vec![0; bytes.len()];
            existing
                .read_exact_at(&mut verified, 0)
                .map_err(|_| StagingError::Conflict)?;
            if verified != bytes {
                return Err(StagingError::Conflict);
            }
            stable()
        };
        match openat(dir, &name, libc::O_RDONLY) {
            Ok(_) => return verify(),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(StagingError::Conflict),
        }
        let temp = CString::new(format!(
            ".{}.tmp",
            super::super::random_string().map_err(|_| StagingError::Storage)?
        ))
        .unwrap();
        let mut file = openat(dir, &temp, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL)
            .map_err(|_| StagingError::Storage)?;
        let result = (|| {
            file.write_all(bytes)
                .and_then(|_| sync(&file))
                .map_err(|_| StagingError::Storage)?;
            // Publish complete bytes without replacement or a crash-sensitive hardlink window.
            #[cfg(target_os = "macos")]
            let published = unsafe {
                libc::renameatx_np(
                    dir.as_raw_fd(),
                    temp.as_ptr(),
                    dir.as_raw_fd(),
                    name.as_ptr(),
                    libc::RENAME_EXCL,
                )
            };
            #[cfg(target_os = "linux")]
            let published = unsafe {
                libc::renameat2(
                    dir.as_raw_fd(),
                    temp.as_ptr(),
                    dir.as_raw_fd(),
                    name.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            };
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            let published = {
                return Err(StagingError::Unsupported);
            };
            if published != 0 {
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::AlreadyExists {
                    return Err(StagingError::Storage);
                }
            }
            Ok(())
        })();
        let removed = unsafe { libc::unlinkat(dir.as_raw_fd(), temp.as_ptr(), 0) } == 0
            || std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound;
        result?;
        if !removed {
            return Err(StagingError::CommitUncertain);
        }
        verify()
    }
}

#[cfg(all(test, unix))]
mod tests;
