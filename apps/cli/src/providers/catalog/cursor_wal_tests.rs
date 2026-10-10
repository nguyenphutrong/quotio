use super::*;
use std::{
    io::{BufRead, BufReader, Write},
    os::{
        fd::AsRawFd,
        unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    },
    process::{Child, Command as StdCommand},
};

struct Fixture {
    directory: PathBuf,
    child: Child,
}

impl Fixture {
    fn new() -> Self {
        let directory = std::env::temp_dir().join(format!(
            "quotio-cursor-fixture-{}",
            crate::accounts::random_string().unwrap()
        ));
        std::fs::create_dir(&directory).unwrap();
        let child = StdCommand::new("/usr/bin/sqlite3")
            .args(["-init", "/dev/null", "-batch", "-bail"])
            .arg(directory.join("state.vscdb"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut fixture = Self { directory, child };
        fixture.sql("CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken','checkpointed-token'); PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;");
        fixture.sql("BEGIN; UPDATE ItemTable SET value='wal-token'; INSERT INTO ItemTable VALUES ('cursorAuth/cachedEmail','wal@example.invalid'), ('cursorAuth/stripeMembershipType','pro'), ('cursorAuth/stripeSubscriptionStatus','active'); COMMIT;");
        fixture
    }

    fn path(&self, suffix: &str) -> PathBuf {
        self.directory.join(format!("state.vscdb{suffix}"))
    }

    fn sql(&mut self, sql: &str) {
        writeln!(
            self.child.stdin.as_mut().unwrap(),
            "{sql}\n.print fixture-ready"
        )
        .unwrap();
        let mut reader = BufReader::new(self.child.stdout.as_mut().unwrap());
        loop {
            let mut line = String::new();
            assert_ne!(reader.read_line(&mut line).unwrap(), 0);
            if line.trim() == "fixture-ready" {
                break;
            }
        }
    }

    fn bytes(&self) -> Vec<(String, Vec<u8>)> {
        let mut entries: Vec<_> = std::fs::read_dir(&self.directory)
            .unwrap()
            .map(|entry| {
                let entry = entry.unwrap();
                (
                    entry.file_name().to_str().unwrap().to_owned(),
                    std::fs::read(entry.path()).unwrap(),
                )
            })
            .collect();
        entries.sort_by(|a, b| a.0.cmp(&b.0));
        entries
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[test]
fn native_file_rejects_same_inode_same_size_mutation_and_path_replacement() {
    let fixture = Fixture::new();
    let path = fixture.directory.join("credentials.toml");
    let original = b"windsurf_api_key='old-key'\n";
    let changed = b"windsurf_api_key='new-key'\n";
    for replace_path in [false, true] {
        std::fs::write(&path, original).unwrap();
        let before = std::fs::metadata(&path).unwrap();
        let result = read_regular_file_with_hook(&path, 1024 * 1024, || {
            if replace_path {
                std::fs::rename(&path, fixture.directory.join("old.toml")).unwrap();
            }
            std::fs::write(&path, changed).unwrap();
            // Force a distinct timestamp even on filesystems with coarse clock resolution.
            std::fs::OpenOptions::new()
                .write(true)
                .open(&path)
                .unwrap()
                .set_modified(std::time::UNIX_EPOCH)
                .unwrap();
            let after = std::fs::metadata(&path).unwrap();
            assert_eq!(before.len(), after.len());
            assert_eq!(before.ino() == after.ino(), !replace_path);
        });
        // No credential bytes escape the reader for a subsequent HTTP request.
        assert_eq!(result.unwrap_err(), ProviderError::CredentialStorage);
        assert_eq!(std::fs::read(&path).unwrap(), changed);
    }
}

#[tokio::test]
async fn cursor_wal_reads_committed_login_without_source_writes() {
    let fixture = Fixture::new();
    assert!(
        !std::fs::read(fixture.path(""))
            .unwrap()
            .windows(9)
            .any(|s| s == b"wal-token")
    );
    let before = fixture.bytes();
    for suffix in ["", "-wal", "-shm"] {
        std::fs::set_permissions(fixture.path(suffix), std::fs::Permissions::from_mode(0o400))
            .unwrap();
    }
    let login = cursor_login(fixture.path("")).await.unwrap();
    assert_eq!(login.token, "wal-token");
    assert_eq!(login.email.as_deref(), Some("wal@example.invalid"));
    assert_eq!(login.membership.as_deref(), Some("pro"));
    assert_eq!(login.subscription_status.as_deref(), Some("active"));
    assert_eq!(fixture.bytes(), before);
    for suffix in ["", "-wal", "-shm"] {
        assert_eq!(
            std::fs::metadata(fixture.path(suffix)).unwrap().mode() & 0o777,
            0o400
        );
    }
}

#[tokio::test]
async fn cursor_wal_ignores_uncommitted_frames_and_rebuilds_missing_shm() {
    let mut fixture = Fixture::new();
    let committed_len = std::fs::metadata(fixture.path("-wal")).unwrap().len();
    fixture.sql("PRAGMA cache_size=1; PRAGMA cache_spill=1; BEGIN; UPDATE ItemTable SET value='uncommitted-token' WHERE key='cursorAuth/accessToken'; INSERT INTO ItemTable VALUES ('padding', hex(zeroblob(2000000)));");
    assert!(std::fs::metadata(fixture.path("-wal")).unwrap().len() > committed_len);
    std::fs::remove_file(fixture.path("-shm")).unwrap();
    let before = fixture.bytes();
    assert_eq!(
        cursor_login(fixture.path("")).await.unwrap().token,
        "wal-token"
    );
    assert_eq!(fixture.bytes(), before);
}

#[tokio::test]
async fn cursor_wal_accepts_checkpointed_empty_wal_and_missing_sidecars() {
    let mut fixture = Fixture::new();
    fixture.sql("PRAGMA wal_checkpoint(TRUNCATE);");
    assert_eq!(std::fs::metadata(fixture.path("-wal")).unwrap().len(), 0);
    let before = fixture.bytes();
    assert_eq!(
        cursor_login(fixture.path("")).await.unwrap().token,
        "wal-token"
    );
    assert_eq!(fixture.bytes(), before);
    for suffix in ["-wal", "-shm"] {
        std::fs::remove_file(fixture.path(suffix)).unwrap();
    }
    let before = fixture.bytes();
    assert_eq!(
        cursor_login(fixture.path("")).await.unwrap().token,
        "wal-token"
    );
    assert_eq!(fixture.bytes(), before);
}

#[tokio::test]
async fn cursor_wal_snapshot_is_private_and_cleaned_up() {
    let fixture = Fixture::new();
    let snapshot = open_cursor_database(&fixture.path("")).unwrap().unwrap();
    let directory = snapshot.directory.clone();
    assert_eq!(std::fs::metadata(&directory).unwrap().mode() & 0o777, 0o700);
    for name in ["state.vscdb", "state.vscdb-wal"] {
        assert_eq!(
            std::fs::metadata(directory.join(name)).unwrap().mode() & 0o777,
            0o600
        );
    }
    let output = cursor_sqlite_output(&snapshot).await.unwrap();
    assert_eq!(
        cursor_token_from_sqlite_output(&output).unwrap().unwrap().0,
        "wal-token"
    );
    assert!(cursor_database_remains_safe(&snapshot).unwrap());
    drop(snapshot);
    assert!(!directory.exists());
}

#[test]
fn cursor_wal_recovers_only_unlocked_owned_snapshots() {
    let fixture = Fixture::new();
    let root = fixture.directory.join("snapshots");
    prepare_cursor_snapshot_root(&root).unwrap();

    let orphan = root.join(format!(
        "{CURSOR_SNAPSHOT_PREFIX}{}-{}",
        std::process::id(),
        "a".repeat(43)
    ));
    std::fs::create_dir(&orphan).unwrap();
    std::fs::set_permissions(&orphan, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(orphan.join(CURSOR_SNAPSHOT_LOCK))
        .unwrap();
    std::fs::write(orphan.join("state.vscdb"), b"orphaned private bytes").unwrap();

    let locked = root.join(format!(
        "{CURSOR_SNAPSHOT_PREFIX}{}-{}",
        i32::MAX - 1,
        "c".repeat(43)
    ));
    std::fs::create_dir(&locked).unwrap();
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o700)).unwrap();
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(locked.join(CURSOR_SNAPSHOT_LOCK))
        .unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);

    let unrelated = root.join("keep-me");
    std::fs::create_dir(&unrelated).unwrap();
    let symlink_target = root.join("symlink-target");
    std::fs::create_dir(&symlink_target).unwrap();
    let symlink = root.join(format!(
        "{CURSOR_SNAPSHOT_PREFIX}{}-{}",
        i32::MAX,
        "b".repeat(43)
    ));
    std::os::unix::fs::symlink(&symlink_target, &symlink).unwrap();

    let active = open_cursor_database_in(&fixture.path(""), &root)
        .unwrap()
        .unwrap();
    let active_directory = active.directory.clone();
    recover_cursor_snapshots(&root).unwrap();

    assert!(!orphan.exists());
    assert!(locked.exists());
    assert!(active_directory.exists());
    assert!(unrelated.exists());
    assert!(symlink.symlink_metadata().unwrap().file_type().is_symlink());
    assert!(symlink_target.exists());
    drop(lock);
    // A sibling test spawning a child briefly duplicates the released descriptor into that
    // child, so one recovery pass can still find the lock held. Recovery is idempotent.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        recover_cursor_snapshots(&root).unwrap();
        if !locked.exists() || std::time::Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(!locked.exists());
    drop(active);
    assert!(!active_directory.exists());
}

#[tokio::test]
async fn cursor_wal_recovers_rollback_reuse_and_partial_tails() {
    let mut fixture = Fixture::new();
    fixture.sql("PRAGMA cache_size=1; PRAGMA cache_spill=1; BEGIN; UPDATE ItemTable SET value='aborted' WHERE key='cursorAuth/accessToken'; INSERT INTO ItemTable VALUES ('padding', hex(zeroblob(2000000)));");
    let spilled_len = std::fs::metadata(fixture.path("-wal")).unwrap().len();
    fixture.sql(
        "ROLLBACK; UPDATE ItemTable SET value='short-commit' WHERE key='cursorAuth/accessToken';",
    );
    assert_eq!(
        std::fs::metadata(fixture.path("-wal")).unwrap().len(),
        spilled_len
    );
    let before = fixture.bytes();
    assert_eq!(
        cursor_login(fixture.path("")).await.unwrap().token,
        "short-commit"
    );
    assert_eq!(fixture.bytes(), before);

    let snapshot = open_cursor_database(&fixture.path("")).unwrap().unwrap();
    let wal = std::fs::read(snapshot.directory.join("state.vscdb-wal")).unwrap();
    assert!(wal.len() < spilled_len as usize);
    std::fs::write(
        fixture.path("-wal"),
        [&wal[..], b"interrupted-frame"].concat(),
    )
    .unwrap();
    let before = fixture.bytes();
    assert_eq!(
        cursor_login(fixture.path("")).await.unwrap().token,
        "short-commit"
    );
    assert_eq!(fixture.bytes(), before);
}

#[tokio::test]
async fn cursor_wal_bounds_hostile_views_and_blocks_file_functions() {
    for expression in [
        "hex(randomblob(400000000))".to_owned(),
        "writefile('should-not-exist', 'payload')".to_owned(),
    ] {
        let mut fixture = Fixture::new();
        let target = fixture.directory.join("should-not-exist");
        let expression = expression.replace("should-not-exist", target.to_str().unwrap());
        fixture.sql(&format!("DROP TABLE ItemTable; CREATE VIEW ItemTable AS SELECT 'cursorAuth/accessToken' AS key, {expression} AS value;"));
        let before = fixture.bytes();
        assert!(cursor_login(fixture.path("")).await.is_err());
        assert!(!target.exists());
        assert_eq!(fixture.bytes(), before);
    }
}

#[tokio::test]
async fn cursor_wal_schema_gate_cannot_be_shadowed() {
    for schema in [
        "",
        "CREATE TABLE pragma_table_list(schema, name, type); INSERT INTO pragma_table_list VALUES ('main','ItemTable','table');",
        "CREATE VIEW pragma_table_list AS SELECT 'main' AS schema, 'ItemTable' AS name, 'table' AS type;",
    ] {
        let mut fixture = Fixture::new();
        fixture.sql(&format!("DROP TABLE ItemTable; CREATE VIEW ItemTable AS SELECT 'cursorAuth/accessToken' AS key, 'spoofed-token' AS value; {schema}"));
        let before = fixture.bytes();
        assert!(cursor_login(fixture.path("")).await.is_err());
        assert_eq!(fixture.bytes(), before);
    }
}

#[tokio::test]
async fn cursor_wal_rejects_virtual_tables_and_bounds_generated_values() {
    for schema in [
        "CREATE VIRTUAL TABLE ItemTable USING fts5(key, value); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'virtual-token');",
        "CREATE TABLE ItemTable(key, value TEXT GENERATED ALWAYS AS(hex(zeroblob(600000))) VIRTUAL); INSERT INTO ItemTable(key) VALUES ('cursorAuth/accessToken');",
    ] {
        let mut fixture = Fixture::new();
        fixture.sql(&format!("DROP TABLE ItemTable; {schema}"));
        let before = fixture.bytes();
        assert!(cursor_login(fixture.path("")).await.is_err());
        assert_eq!(fixture.bytes(), before);
    }
}

#[test]
fn cursor_wal_rejects_changes_during_capture_and_read() {
    for after_read in [false, true] {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            for replace in [false, true] {
                let fixture = Fixture::new();
                let mutate = || {
                    let path = fixture.path(suffix);
                    if replace {
                        if path.exists() {
                            std::fs::remove_file(&path).unwrap();
                        }
                        std::os::unix::fs::symlink(fixture.directory.join("absent"), path).unwrap();
                    } else {
                        std::fs::OpenOptions::new()
                            .append(true)
                            .create(true)
                            .open(path)
                            .unwrap()
                            .write_all(b"changed")
                            .unwrap();
                    }
                };
                let result = open_cursor_database_with_hooks(
                    &fixture.path(""),
                    || {
                        if !after_read {
                            mutate();
                        }
                    },
                    || {
                        if after_read {
                            mutate();
                        }
                    },
                );
                assert!(result.is_err());
            }
        }
    }
}

#[test]
fn cursor_wal_rejects_corrupt_headers_frames_and_oversized_files() {
    for offset in [0, 4, 8, 24, 32 + 16, 32 + 24] {
        let fixture = Fixture::new();
        let path = fixture.path("-wal");
        let mut bytes = std::fs::read(&path).unwrap();
        bytes[offset] ^= 1;
        std::fs::write(&path, bytes).unwrap();
        let before = fixture.bytes();
        assert_eq!(
            open_cursor_database(&fixture.path("")).err(),
            Some(ProviderError::InvalidData)
        );
        assert_eq!(fixture.bytes(), before);
    }
    for suffix in ["", "-wal", "-shm"] {
        let fixture = Fixture::new();
        std::fs::OpenOptions::new()
            .write(true)
            .open(fixture.path(suffix))
            .unwrap()
            .set_len(MAX_CURSOR_DATABASE_BYTES + 1)
            .unwrap();
        assert_eq!(
            open_cursor_database(&fixture.path("")).err(),
            Some(ProviderError::CredentialStorage)
        );
    }
}

#[test]
fn cursor_wal_rejects_symlinks_non_files_and_rollback_journals() {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        for symlink in [false, true] {
            let fixture = Fixture::new();
            let path = fixture.path(suffix);
            if path.exists() {
                std::fs::remove_file(&path).unwrap();
            }
            if symlink {
                std::os::unix::fs::symlink(fixture.directory.join("absent"), &path).unwrap();
            } else {
                std::fs::create_dir(&path).unwrap();
            }
            assert_eq!(
                open_cursor_database(&fixture.path("")).err(),
                Some(ProviderError::CredentialStorage)
            );
        }
    }
    let fixture = Fixture::new();
    std::fs::write(fixture.path("-journal"), b"hot-journal").unwrap();
    assert_eq!(
        open_cursor_database(&fixture.path("")).err(),
        Some(ProviderError::CredentialStorage)
    );
}

#[tokio::test]
async fn cursor_wal_rejects_source_changes_after_snapshot() {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let fixture = Fixture::new();
        let snapshot = open_cursor_database(&fixture.path("")).unwrap().unwrap();
        let path = fixture.path(suffix);
        let replacement = fixture.directory.join("replacement");
        let bytes = std::fs::read(&path).unwrap_or_default();
        std::fs::write(&replacement, bytes).unwrap();
        std::fs::rename(replacement, &path).unwrap();
        assert!(!cursor_database_remains_safe(&snapshot).unwrap());
        // The query stays confined to the captured snapshot, even after replacement.
        assert_eq!(
            cursor_token_from_sqlite_output(&cursor_sqlite_output(&snapshot).await.unwrap())
                .unwrap()
                .unwrap()
                .0,
            "wal-token"
        );
    }
    let mut fixture = Fixture::new();
    let snapshot = open_cursor_database(&fixture.path("")).unwrap().unwrap();
    fixture.sql("UPDATE ItemTable SET value='rotated-token' WHERE key='cursorAuth/accessToken';");
    assert!(!cursor_database_remains_safe(&snapshot).unwrap());
    assert_eq!(
        cursor_login(fixture.path("")).await.unwrap().token,
        "rotated-token"
    );
}

#[test]
fn cursor_wal_rejects_sidecar_removal_and_symlink_races() {
    for suffix in ["-wal", "-shm"] {
        for symlink in [false, true] {
            let fixture = Fixture::new();
            let snapshot = open_cursor_database(&fixture.path("")).unwrap().unwrap();
            let path = fixture.path(suffix);
            std::fs::remove_file(&path).unwrap();
            if symlink {
                std::os::unix::fs::symlink(fixture.directory.join("absent"), path).unwrap();
                assert_eq!(
                    cursor_database_remains_safe(&snapshot).err(),
                    Some(ProviderError::CredentialStorage)
                );
            } else {
                assert!(!cursor_database_remains_safe(&snapshot).unwrap());
            }
        }
    }
}

#[test]
fn recovery_cannot_claim_a_snapshot_before_its_creator_acquires_the_lock() {
    let fixture = Fixture::new();
    let root = fixture.directory.join("snapshots");
    let snapshot = open_cursor_database_at_with_hooks(
        &fixture.path(""),
        &root,
        || {},
        || {},
        || recover_cursor_snapshots(&root).unwrap(),
    )
    .unwrap()
    .unwrap();
    assert!(snapshot.directory.join("state.vscdb").exists());
}
