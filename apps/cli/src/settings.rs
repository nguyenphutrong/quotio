//! Atomic config persistence with optimistic revisions and startup overrides.
use crate::{cli::Provider, config::Config};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::PathBuf,
};

#[derive(Clone, Default)]
pub struct Overrides {
    pub providers: Option<Vec<Provider>>,
    pub refresh_interval: Option<u64>,
    pub provider_timeout: Option<u64>,
}
#[derive(Clone, Serialize)]
pub struct SettingsView {
    pub revision: String,
    #[serde(flatten)]
    pub values: Config,
    pub overridden: Vec<&'static str>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SettingsPatch {
    pub revision: String,
    pub enabled_providers: Option<Vec<Provider>>,
    pub disabled_providers: Option<Vec<Provider>>,
    pub cache_ttl_seconds: Option<u64>,
    pub refresh_interval: Option<u64>,
    pub provider_timeout: Option<u64>,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingsError {
    Invalid,
    Conflict,
    Overridden,
    Busy,
    Storage,
}
#[derive(Clone)]
pub struct SettingsStore {
    path: PathBuf,
    overrides: Overrides,
}
impl SettingsStore {
    pub fn new(path: PathBuf, overrides: Overrides) -> Self {
        Self { path, overrides }
    }
    fn read(&self) -> Result<(Config, String), SettingsError> {
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        let input = match options.open(&self.path) {
            Ok(file) => {
                if !file
                    .metadata()
                    .map_err(|_| SettingsError::Storage)?
                    .is_file()
                {
                    return Err(SettingsError::Storage);
                }
                let mut input = String::new();
                file.take(65537)
                    .read_to_string(&mut input)
                    .map_err(|_| SettingsError::Storage)?;
                if input.len() > 65536 {
                    return Err(SettingsError::Invalid);
                }
                input
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
            Err(_) => return Err(SettingsError::Storage),
        };
        let config = Config::parse(&input).map_err(|_| SettingsError::Invalid)?;
        validate(&config)?;
        Ok((config, crate::cache::fingerprint(&[&input])))
    }
    fn effective(&self, mut values: Config, revision: String) -> SettingsView {
        let mut overridden = Vec::new();
        if let Some(providers) = &self.overrides.providers {
            values.enabled_providers = providers.iter().map(|p| p.id().into()).collect();
            overridden.push("enabled_providers");
        }
        if let Some(value) = self.overrides.refresh_interval {
            values.refresh_interval = value;
            overridden.push("refresh_interval");
        }
        if let Some(value) = self.overrides.provider_timeout {
            values.provider_timeout = value;
            overridden.push("provider_timeout");
        }
        SettingsView {
            revision,
            values,
            overridden,
        }
    }
    pub fn load(&self) -> Result<SettingsView, SettingsError> {
        let (config, revision) = self.read()?;
        Ok(self.effective(config, revision))
    }
    pub fn patch(&self, patch: SettingsPatch) -> Result<SettingsView, SettingsError> {
        let parent = self
            .path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(std::path::Path::new("."));
        fs::create_dir_all(parent).map_err(|_| SettingsError::Storage)?;
        let mut options = OpenOptions::new();
        options.create(true).read(true).write(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        let lock = options
            .open(self.path.with_extension("toml.lock"))
            .map_err(|_| SettingsError::Storage)?;
        if !lock
            .metadata()
            .map_err(|_| SettingsError::Storage)?
            .is_file()
        {
            return Err(SettingsError::Storage);
        }
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
                return Err(SettingsError::Busy);
            }
        }
        #[cfg(not(unix))]
        {
            return Err(SettingsError::Storage);
        }
        let (mut config, revision) = self.read()?;
        if patch.revision != revision {
            return Err(SettingsError::Conflict);
        }
        if (patch.enabled_providers.is_some() && self.overrides.providers.is_some())
            || (patch.refresh_interval.is_some() && self.overrides.refresh_interval.is_some())
            || (patch.provider_timeout.is_some() && self.overrides.provider_timeout.is_some())
        {
            return Err(SettingsError::Overridden);
        }
        if let Some(providers) = patch.enabled_providers {
            config.enabled_providers = providers.iter().map(|p| p.id().into()).collect();
        }
        if let Some(providers) = patch.disabled_providers {
            config.disabled_providers = providers.iter().map(|p| p.id().into()).collect();
        }
        if let Some(value) = patch.cache_ttl_seconds {
            config.cache_ttl_seconds = value;
        }
        if let Some(value) = patch.refresh_interval {
            config.refresh_interval = value;
        }
        if let Some(value) = patch.provider_timeout {
            config.provider_timeout = value;
        }
        validate(&config)?;
        let text = toml::to_string(&config).map_err(|_| SettingsError::Invalid)?;
        let temporary = parent.join(format!(
            ".quotio-settings-{}.tmp",
            crate::accounts::random_string().map_err(|_| SettingsError::Storage)?
        ));
        let result = (|| {
            let mut opts = OpenOptions::new();
            opts.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                opts.mode(0o600);
            }
            let mut file = opts.open(&temporary)?;
            file.write_all(text.as_bytes())?;
            file.sync_all()?;
            fs::rename(&temporary, &self.path)?;
            File::open(parent)?.sync_all()
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
            return Err(SettingsError::Storage);
        }
        Ok(self.effective(config, crate::cache::fingerprint(&[&text])))
    }
}
fn validate(config: &Config) -> Result<(), SettingsError> {
    config.providers().map_err(|_| SettingsError::Invalid)?;
    config
        .disabled_providers()
        .map_err(|_| SettingsError::Invalid)?;
    if config.refresh_interval > 86400 || !(1..=3600).contains(&config.provider_timeout) {
        return Err(SettingsError::Invalid);
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn persists_checks_revisions_and_rejects_overrides() {
        let dir = std::env::temp_dir().join(format!(
            "quotio-settings-test-{}",
            crate::accounts::random_string().unwrap()
        ));
        let store = SettingsStore::new(dir.join("config.toml"), Overrides::default());
        let initial = store.load().unwrap();
        let patch = |revision: String| SettingsPatch {
            revision,
            enabled_providers: Some(vec![Provider::Mock]),
            disabled_providers: Some(vec![Provider::Amp]),
            cache_ttl_seconds: Some(25),
            refresh_interval: Some(30),
            provider_timeout: None,
        };
        let view = store.patch(patch(initial.revision.clone())).unwrap();
        assert_eq!(view.values.cache_ttl_seconds, 25);
        assert_eq!(view.values.disabled_providers, vec!["amp"]);
        assert_eq!(store.load().unwrap().revision, view.revision);
        assert!(matches!(
            store.patch(patch(initial.revision)),
            Err(SettingsError::Conflict)
        ));
        let overridden = SettingsStore::new(
            store.path.clone(),
            Overrides {
                refresh_interval: Some(10),
                ..Default::default()
            },
        );
        assert!(matches!(
            overridden.patch(patch(view.revision.clone())),
            Err(SettingsError::Overridden)
        ));
        assert_eq!(store.load().unwrap().values.refresh_interval, 30);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn preserves_ignored_native_preferences_when_quota_settings_change() {
        let directory = std::env::temp_dir().join(format!(
            "quotio-scope-{}",
            crate::accounts::random_string().unwrap()
        ));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("config.toml");
        std::fs::write(&path, "enabled_providers = []\n[notifications]\nenabled = false\nquota_threshold = 17.0\nquota_low = false\ncooling = true\nproxy_crash = true\nproxy_update = false\n").unwrap();
        let store = SettingsStore::new(path, Overrides::default());
        let original = store.load().unwrap();
        let patch: SettingsPatch = serde_json::from_value(
            serde_json::json!({"revision":original.revision,"cache_ttl_seconds":42}),
        )
        .unwrap();
        store.patch(patch).unwrap();
        let current = store.load().unwrap();
        assert_eq!(current.values.cache_ttl_seconds, 42);
        assert!(!current.values.notifications.unwrap().enabled);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
