use super::*;
use std::{
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::PathBuf,
};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(super::super::random_string().unwrap());
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        Self(root)
    }
    fn envelope(&self) -> PathBuf {
        let path = self.0.join("fixture.qsv");
        let b64 = base64::engine::general_purpose::STANDARD;
        fs::write(
            &path,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "wrappedKey": b64.encode([7; 256]),
                "sealedSecret": b64.encode([8; 48])
            }))
            .unwrap(),
        )
        .unwrap();
        path
    }
    fn inspect(&self, path: &Path) -> Plan {
        assess(path, &"a".repeat(64)).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn swift_envelope_blocks_import_without_claiming_hardware_access() {
    let f = Fixture::new();
    let path = f.envelope();
    let original = fs::read(&path).unwrap();
    let plan = f.inspect(&path);
    assert_eq!(
        plan.envelope_state,
        EnvelopeState::PresentLockedOrUnverified
    );
    assert_eq!(plan.key_access, "not_attempted");
    assert!(plan.migration_blocked);
    assert!(
        plan.protection
            .contains("no_keychain_or_software_vault_fallback")
    );
    assert_eq!(plan.fingerprint_binding, "caller_declared_unverified");
    let json = serde_json::to_string(&plan).unwrap();
    assert!(!json.contains("wrappedKey"));
    assert!(!json.contains("sealedSecret"));
    assert!(!json.contains(path.to_str().unwrap()));
    assert_eq!(fs::read(&path).unwrap(), original);
}

#[test]
fn absent_unreadable_and_unsupported_are_distinct_and_never_fall_back() {
    let f = Fixture::new();
    let path = f.0.join("absent.qsv");
    assert_eq!(f.inspect(&path).envelope_state, EnvelopeState::Absent);
    fs::create_dir(&path).unwrap();
    assert_eq!(f.inspect(&path).envelope_state, EnvelopeState::Unreadable);
    let file = f.envelope();
    for bytes in [
        b"fixture-plaintext-secret".as_slice(),
        br#"{"version":2,"wrappedKey":"AA==","sealedSecret":"AA=="}"#,
        br#"{"version":1,"wrappedKey":"bad","sealedSecret":"bad"}"#,
    ] {
        fs::write(&file, bytes).unwrap();
        let plan = f.inspect(&file);
        assert_eq!(plan.envelope_state, EnvelopeState::UnsupportedEnvelope);
        assert_eq!(plan.envelope_sha256, None);
        assert!(plan.migration_blocked);
        assert!(
            !serde_json::to_string(&plan)
                .unwrap()
                .contains("fixture-plaintext-secret")
        );
    }
}

#[test]
fn receipt_reruns_preserve_original_bytes_and_inode_and_detect_source_change() {
    let f = Fixture::new();
    let source = f.envelope();
    let original = fs::read(&source).unwrap();
    let plan = f.inspect(&source);
    let id = stage(&plan, &f.0).unwrap();
    let receipt = f.0.join(format!("{id}.json"));
    let first = fs::metadata(&receipt).unwrap();
    let bytes = fs::read(&receipt).unwrap();
    assert_eq!(first.mode() & 0o777, 0o600);
    for _ in 0..3 {
        assert_eq!(stage(&f.inspect(&source), &f.0).unwrap(), id);
    }
    assert_eq!(fs::metadata(&receipt).unwrap().ino(), first.ino());
    assert_eq!(fs::read(&receipt).unwrap(), bytes);
    assert_eq!(fs::read(&source).unwrap(), original);
    let mut changed = original;
    changed.push(b' ');
    fs::write(&source, changed).unwrap();
    assert_ne!(stage(&f.inspect(&source), &f.0).unwrap(), id);
    assert_eq!(fs::read(&receipt).unwrap(), bytes);
}

#[test]
fn concurrent_receipts_converge_and_conflicting_receipts_are_never_overwritten() {
    let f = Fixture::new();
    let plan = f.inspect(&f.envelope());
    let ids = std::thread::scope(|s| {
        let workers: Vec<_> = (0..6).map(|_| s.spawn(|| stage(&plan, &f.0))).collect();
        workers
            .into_iter()
            .map(|w| w.join().unwrap())
            .collect::<Vec<_>>()
    });
    for id in &ids {
        assert!(id.is_ok());
    }
    let id = stage(&plan, &f.0).unwrap();
    for value in ids.into_iter().flatten() {
        assert_eq!(value, id);
    }
    let path = f.0.join(format!("{id}.json"));
    fs::write(&path, b"interrupted-or-tampered-fixture").unwrap();
    assert!(matches!(stage(&plan, &f.0), Err(StagingError::Conflict)));
    assert_eq!(fs::read(path).unwrap(), b"interrupted-or-tampered-fixture");
}

#[test]
fn no_symlinks_public_destinations_or_hardlinks() {
    let f = Fixture::new();
    let source = f.envelope();
    let alias = f.0.join("alias.qsv");
    std::os::unix::fs::symlink(&source, &alias).unwrap();
    assert_eq!(f.inspect(&alias).envelope_state, EnvelopeState::Unreadable);
    let dir_alias = f.0.join("alias-dir");
    std::os::unix::fs::symlink(&f.0, &dir_alias).unwrap();
    assert_eq!(
        f.inspect(&dir_alias.join("fixture.qsv")).envelope_state,
        EnvelopeState::Unreadable
    );
    let plan = f.inspect(&source);
    assert!(stage(&plan, &dir_alias).is_err());
    let id = stage(&plan, &f.0).unwrap();
    let receipt = f.0.join(format!("{id}.json"));
    fs::set_permissions(&receipt, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(matches!(stage(&plan, &f.0), Err(StagingError::Conflict)));
    fs::remove_file(&receipt).unwrap();
    std::os::unix::fs::symlink(&source, &receipt).unwrap();
    assert!(stage(&plan, &f.0).is_err());
    fs::hard_link(&source, f.0.join("hardlink")).unwrap();
    assert_eq!(f.inspect(&source).envelope_state, EnvelopeState::Unreadable);
    fs::set_permissions(&f.0, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(stage(&plan, &f.0).is_err());
}

#[test]
fn interrupted_and_uncertain_receipts_recover_without_overwrite() {
    let f = Fixture::new();
    let bytes = b"synthetic-assessment";
    let fail = |_: &std::fs::File| Err(std::io::Error::other("fixture sync failure"));
    assert!(matches!(
        unix::save_with_sync(&f.0, "receipt.json", bytes, fail),
        Err(StagingError::Storage)
    ));
    assert!(!f.0.join("receipt.json").exists());
    // An abandoned temporary file from a killed process is not a completed receipt.
    std::fs::write(f.0.join(".abandoned.tmp"), b"partial-fixture").unwrap();
    let result = unix::save_with_sync(&f.0, "receipt.json", bytes, |file| {
        if file.metadata()?.is_dir() {
            fail(file)
        } else {
            file.sync_all()
        }
    });
    assert!(matches!(result, Err(StagingError::CommitUncertain)));
    let inode = std::fs::metadata(f.0.join("receipt.json")).unwrap().ino();
    unix::save(&f.0, "receipt.json", bytes).unwrap();
    assert_eq!(
        std::fs::metadata(f.0.join("receipt.json")).unwrap().ino(),
        inode
    );
    assert_eq!(std::fs::read(f.0.join("receipt.json")).unwrap(), bytes);
    assert_eq!(
        std::fs::read(f.0.join(".abandoned.tmp")).unwrap(),
        b"partial-fixture"
    );
}

fn mapping() -> Mapping<'static> {
    Mapping {
        account_id: "fixture-account",
        provider: "amp",
        source: "quotioKeychain",
        credential_reference: Some("keychain"),
        service: "app.bytrong.quotio.monitor-auth",
    }
}

fn mapping_files(f: &Fixture) -> (PathBuf, PathBuf) {
    let metadata = f.0.join("accounts-v1.json");
    fs::write(&metadata, br#"{"accounts":[{"id":"fixture-account","provider":"amp","accountKey":"fixture-label","displayName":"fixture-name","source":"quotioKeychain","credentialReference":"keychain","canDelete":true,"isDisabled":false}],"disabledAccountIDs":["fixture-account"]}"#).unwrap();
    let envelope = f.0.join(format!(
        "{}.qsv",
        digest(b"app.bytrong.quotio.monitor-auth\0fixture-account")
    ));
    fs::rename(f.envelope(), &envelope).unwrap();
    (metadata, envelope)
}

#[test]
fn mapping_stages_exact_encrypted_bytes_with_private_restart_and_concurrent_receipts() {
    let f = Fixture::new();
    let dest = Fixture::new();
    let (metadata, envelope) = mapping_files(&f);
    let original_metadata = fs::read(&metadata).unwrap();
    let original_envelope = fs::read(&envelope).unwrap();
    let metadata_mode = fs::metadata(&metadata).unwrap().mode();
    let envelope_mode = fs::metadata(&envelope).unwrap().mode();
    let assess = || assess_mapping(&metadata, &envelope, &"a".repeat(64), &mapping()).unwrap();
    let snapshot = assess();
    let json = serde_json::to_string(snapshot.plan()).unwrap();
    assert!(json.contains("candidate_unverified"));
    assert!(json.contains("\"repository_disabled\":true"));
    assert!(json.contains("\"record_disabled\":false"));
    for sensitive in [
        "fixture-account",
        "fixture-name",
        "fixture-label",
        "fixture-service",
        "wrappedKey",
        f.0.to_str().unwrap(),
    ] {
        assert!(!json.contains(sensitive));
    }
    // Simulate interruption after the first artifact, then restart from source.
    unix::save(
        &dest.0,
        &format!("{}.metadata.json", digest(&original_metadata)),
        &original_metadata,
    )
    .unwrap();
    let id = stage_mapping(&assess(), &dest.0).unwrap();
    let receipt = dest.0.join(format!("{id}.json"));
    let inode = fs::metadata(&receipt).unwrap().ino();
    std::thread::scope(|scope| {
        let workers: Vec<_> = (0..6)
            .map(|_| scope.spawn(|| stage_mapping(&assess(), &dest.0).unwrap()))
            .collect();
        for worker in workers {
            assert_eq!(worker.join().unwrap(), id);
        }
    });
    assert_eq!(fs::metadata(&receipt).unwrap().ino(), inode);
    assert_eq!(fs::read(&metadata).unwrap(), original_metadata);
    assert_eq!(fs::read(&envelope).unwrap(), original_envelope);
    assert_eq!(fs::metadata(&metadata).unwrap().mode(), metadata_mode);
    assert_eq!(fs::metadata(&envelope).unwrap().mode(), envelope_mode);
    let staged = dest.0.join(format!("{}.qsv", digest(&original_envelope)));
    assert_eq!(fs::read(&staged).unwrap(), original_envelope);
    assert_eq!(fs::metadata(&staged).unwrap().mode() & 0o777, 0o600);
    let mut changed = original_metadata;
    changed.push(b' ');
    fs::write(&metadata, changed).unwrap();
    let metadata_changed_id = stage_mapping(&assess(), &dest.0).unwrap();
    assert_ne!(metadata_changed_id, id);
    let mut changed_envelope = original_envelope.clone();
    changed_envelope.push(b' ');
    fs::write(&envelope, changed_envelope).unwrap();
    assert_ne!(
        stage_mapping(&assess(), &dest.0).unwrap(),
        metadata_changed_id
    );
    // Previously assessed snapshots never reopen changed source paths.
    assert_eq!(stage_mapping(&snapshot, &dest.0).unwrap(), id);
    fs::write(&staged, b"tampered").unwrap();
    assert!(matches!(
        stage_mapping(&snapshot, &dest.0),
        Err(StagingError::Conflict)
    ));
    assert_eq!(fs::read(staged).unwrap(), b"tampered");
}

#[test]
fn mapping_rejects_ambiguity_unknown_dates_mismatch_and_unsafe_sources() {
    let f = Fixture::new();
    let (metadata, envelope) = mapping_files(&f);
    let original = fs::read(&metadata).unwrap();
    let valid: serde_json::Value = serde_json::from_slice(&original).unwrap();
    let check = || assess_mapping(&metadata, &envelope, &"a".repeat(64), &mapping());
    for field in ["provider", "source", "credentialReference", "id"] {
        let mut value = valid.clone();
        value["accounts"][0][field] = "wrong".into();
        fs::write(&metadata, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(check().is_err());
    }
    for mutate in 0..4 {
        let mut value = valid.clone();
        match mutate {
            0 => {
                let account = value["accounts"][0].clone();
                value["accounts"].as_array_mut().unwrap().push(account);
            }
            1 => value["disabledAccountIDs"] = serde_json::json!(["unknown", "unknown"]),
            2 => value["accounts"][0]["expiresAt"] = 0.into(),
            _ => value["accounts"][0]["source"] = "path/with\ncontrol".into(),
        }
        fs::write(&metadata, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(check().is_err());
    }
    fs::write(&metadata, &original).unwrap();
    assert!(assess_mapping(&metadata, &f.envelope(), &"a".repeat(64), &mapping()).is_err());
    let alias = f.0.join("metadata-alias");
    std::os::unix::fs::symlink(&metadata, &alias).unwrap();
    assert!(assess_mapping(&alias, &envelope, &"a".repeat(64), &mapping()).is_err());
    fs::write(&metadata, vec![0; 1024 * 1024 + 1]).unwrap();
    assert!(check().is_err());
}

#[test]
fn mapping_destination_descriptor_stays_pinned_when_directory_is_renamed() {
    let f = Fixture::new();
    let target = f.0.join("stage");
    fs::create_dir(&target).unwrap();
    fs::set_permissions(&target, fs::Permissions::from_mode(0o700)).unwrap();
    let pinned = unix::stage_directory(&target).unwrap();
    let moved = f.0.join("moved");
    fs::rename(&target, &moved).unwrap();
    fs::create_dir(&target).unwrap();
    unix::save_to(&pinned, "fixture.json", b"fixture").unwrap();
    assert!(!target.join("fixture.json").exists());
    assert_eq!(fs::read(moved.join("fixture.json")).unwrap(), b"fixture");
}

#[test]
fn mappings_reject_matching_borrowed_and_unknown_declarations() {
    let f = Fixture::new();
    let (metadata, envelope) = mapping_files(&f);
    let valid: serde_json::Value = serde_json::from_slice(&fs::read(&metadata).unwrap()).unwrap();
    for (field, value) in [
        ("source", "nativeCredential"),
        ("source", "localIDE"),
        ("source", "legacyCLIProxy"),
        ("provider", "unknown"),
        ("credentialReference", "arbitrary"),
    ] {
        let mut payload = valid.clone();
        payload["accounts"][0][field] = value.into();
        fs::write(&metadata, serde_json::to_vec(&payload).unwrap()).unwrap();
        let mut declaration = mapping();
        match field {
            "source" => declaration.source = value,
            "provider" => declaration.provider = value,
            _ => declaration.credential_reference = Some(value),
        }
        assert!(assess_mapping(&metadata, &envelope, &"a".repeat(64), &declaration).is_err());
    }
    fs::write(&metadata, serde_json::to_vec(&valid).unwrap()).unwrap();
    let mut declaration = mapping();
    declaration.service = "arbitrary-service";
    let renamed = f.0.join(format!(
        "{}.qsv",
        digest(b"arbitrary-service\0fixture-account")
    ));
    fs::rename(&envelope, &renamed).unwrap();
    assert!(assess_mapping(&metadata, &renamed, &"a".repeat(64), &declaration).is_err());
}

#[test]
fn unmatched_disabled_native_ids_are_preserved_without_discovery() {
    let f = Fixture::new();
    let (metadata, envelope) = mapping_files(&f);
    let mut value: serde_json::Value =
        serde_json::from_slice(&fs::read(&metadata).unwrap()).unwrap();
    value["disabledAccountIDs"] = serde_json::json!(["native-not-persisted"]);
    fs::write(&metadata, serde_json::to_vec(&value).unwrap()).unwrap();
    let assessment = assess_mapping(&metadata, &envelope, &"a".repeat(64), &mapping()).unwrap();
    assert!(!assessment.plan.repository_disabled);
    assert_eq!(assessment.metadata, fs::read(&metadata).unwrap());
    for id in ["", "bad\nidentifier"] {
        value["disabledAccountIDs"] = serde_json::json!([id]);
        fs::write(&metadata, serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(assess_mapping(&metadata, &envelope, &"a".repeat(64), &mapping()).is_err());
    }
}

#[test]
fn destination_mutations_during_verification_are_detected() {
    for preexisting in [false, true] {
        for replace in [false, true] {
            let f = Fixture::new();
            let path = f.0.join("receipt.json");
            if preexisting {
                unix::save(&f.0, "receipt.json", b"expected").unwrap();
            }
            let mutated = std::cell::Cell::new(false);
            let result = unix::save_with_sync(&f.0, "receipt.json", b"expected", |file| {
                // Directory sync occurs after publication and after receipt read.
                if file.metadata()?.is_dir() && !mutated.replace(true) {
                    if replace {
                        let replacement = f.0.join("replacement");
                        fs::write(&replacement, b"expected")?;
                        fs::set_permissions(&replacement, fs::Permissions::from_mode(0o600))?;
                        fs::rename(replacement, &path)?;
                    } else {
                        fs::write(&path, b"modified")?;
                    }
                }
                file.sync_all()
            });
            assert!(
                matches!(result, Err(StagingError::Conflict)),
                "{result:?}; preexisting={preexisting}, replace={replace}"
            );
        }
    }
}

#[test]
fn invalid_fingerprint_paths_and_large_inputs_are_safe() {
    let f = Fixture::new();
    assert!(assess(&f.envelope(), "fixture-secret").is_err());
    assert!(assess(Path::new("relative.qsv"), &"a".repeat(64)).is_err());
    let path = f.envelope();
    fs::write(&path, vec![0; 1024 * 1024 + 1]).unwrap();
    assert_eq!(f.inspect(&path).envelope_state, EnvelopeState::Unreadable);
}
