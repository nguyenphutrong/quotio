use super::vault::{Vault, VaultNamespace};
use std::path::PathBuf;

pub struct Source {
    pub namespace: VaultNamespace,
    pub data_dir: PathBuf,
    pub config: Option<PathBuf>,
}

#[derive(serde::Serialize)]
struct Marker {
    schema_version: u32,
    #[serde(with = "time::serde::rfc3339")]
    adopted_at: time::OffsetDateTime,
    accounts_added: usize,
    accounts_refreshed: usize,
    history_rows: u64,
}

impl Source {
    fn marker_path(&self) -> PathBuf {
        self.data_dir
            .join(self.namespace.lock_name())
            .with_extension("adopted")
    }

    pub(crate) fn adopted(&self) -> bool {
        std::fs::symlink_metadata(self.marker_path()).is_ok_and(|meta| meta.is_file())
    }
}

/// Returns whether config adoption is complete; a transient failure retries next launch.
pub fn config(source: &Source, store: &crate::settings::SettingsStore) -> bool {
    let Some(path) = &source.config else {
        return true;
    };
    if source.adopted() {
        return true;
    }
    match store.seed_from_file(path) {
        Ok(keys) => {
            tracing::info!(keys, "vault_adoption_config_seeded");
            true
        }
        Err(crate::settings::SettingsError::Invalid) => {
            tracing::warn!("vault_adoption_config_invalid");
            true
        }
        Err(error) => {
            tracing::warn!(?error, "vault_adoption_config_skipped");
            false
        }
    }
}

pub async fn vault(
    source: &Source,
    target: &Vault,
    history: Option<&crate::history::History>,
    config_adopted: bool,
) -> bool {
    if source.adopted() {
        return false;
    }
    // The former Keychain item trusts only the helper that created it. A helper
    // signed under another identifier needs the user's approval to read it once.
    let former = match Vault::isolated_interactive(&source.namespace, &source.data_dir) {
        Ok(former) => former,
        Err(error) => {
            tracing::warn!(?error, "vault_adoption_source_unavailable");
            return false;
        }
    };
    let reader = former.clone();
    // No timeout: the read waits for the user to answer the prompt.
    let read = tokio::task::spawn_blocking(move || reader.begin())
        .await
        .map_err(|_| super::AccountError::Storage)
        .and_then(|read| read);
    let document = match read {
        Ok(transaction) => transaction.document,
        Err(error) => {
            tracing::warn!(?error, "vault_adoption_source_unavailable");
            return false;
        }
    };
    let absorbed = match absorb(target, document).await {
        Ok(absorbed) => absorbed,
        Err(error) => {
            tracing::warn!(?error, "vault_adoption_target_unavailable");
            return false;
        }
    };
    let rows = match absorbed.history {
        None => Ok(0),
        Some(rewrite) => match history {
            Some(history) => history.absorb(former.history_path(), rewrite).await,
            None => match crate::history::History::open(
                target.history_path(),
                time::OffsetDateTime::now_utc(),
            )
            .await
            {
                Ok(history) => history.absorb(former.history_path(), rewrite).await,
                Err(error) => Err(error),
            },
        },
    };
    let rows = match rows {
        Ok(rows) => rows,
        Err(error) => {
            tracing::warn!(?error, "vault_adoption_history_failed");
            return absorbed.changed;
        }
    };
    if !config_adopted {
        tracing::info!("vault_adoption_marker_deferred");
        return absorbed.changed || rows > 0;
    }
    let marker = Marker {
        schema_version: 1,
        adopted_at: time::OffsetDateTime::now_utc(),
        accounts_added: absorbed.added,
        accounts_refreshed: absorbed.refreshed,
        history_rows: rows,
    };
    match write_marker(source, &marker) {
        Ok(()) => tracing::info!(
            added = absorbed.added,
            refreshed = absorbed.refreshed,
            skipped = absorbed.skipped,
            rows,
            "vault_adoption_done"
        ),
        Err(error) => tracing::warn!(?error, "vault_adoption_marker_failed"),
    }
    absorbed.changed || rows > 0
}

async fn absorb(
    target: &Vault,
    document: super::Document,
) -> Result<super::Absorbed, super::AccountError> {
    let mut transaction = super::service::begin(target.clone()).await?;
    let absorbed = transaction.document.absorb(document)?;
    if absorbed.changed {
        tokio::task::spawn_blocking(move || transaction.commit())
            .await
            .map_err(|_| super::AccountError::Storage)??;
    }
    Ok(absorbed)
}

fn write_marker(source: &Source, marker: &Marker) -> std::io::Result<()> {
    use std::io::Write;
    let bytes = serde_json::to_vec(marker)?;
    let path = source.marker_path();
    let temporary = path.with_extension("adopted.tmp");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options.open(&temporary)?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    drop(file);
    std::fs::rename(&temporary, &path)?;
    #[cfg(unix)]
    std::fs::File::open(&source.data_dir)?.sync_all()?;
    Ok(())
}
