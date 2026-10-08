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
    pub disabled_proxy_auth_files: Option<Vec<String>>,
    pub automatically_discover_logins: Option<bool>,
    pub quota_history_enabled: Option<bool>,
    pub cache_ttl_seconds: Option<u64>,
    pub refresh_interval: Option<u64>,
    pub provider_timeout: Option<u64>,
}
/// One-time values supplied by the native app before the host starts any work.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NativePreferences {
    pub disabled_providers: Vec<Provider>,
    pub disabled_proxy_auth_files: Vec<String>,
    pub automatically_discover_logins: bool,
    #[serde(default = "history_enabled_default")]
    pub quota_history_enabled: bool,
    pub refresh_interval: u64,
}
fn history_enabled_default() -> bool {
    true
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
    fn read(&self) -> Result<(Config, String, String), SettingsError> {
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
        Ok((config, crate::cache::fingerprint(&[&input]), input))
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
        let (config, revision, _) = self.read()?;
        Ok(self.effective(config, revision))
    }
    pub fn import_native_preferences(
        &self,
        preferences: NativePreferences,
    ) -> Result<SettingsView, SettingsError> {
        use clap::ValueEnum;
        let (_, revision, input) = self.read()?;
        let fields: toml::Table = toml::from_str(&input).map_err(|_| SettingsError::Invalid)?;
        if [
            "enabled_providers",
            "disabled_providers",
            "disabled_proxy_auth_files",
            "automatically_discover_logins",
            "quota_history_enabled",
            "refresh_interval",
        ]
        .iter()
        .all(|key| fields.contains_key(*key))
        {
            return self.load();
        }
        // Preserve explicit host choices. Persist all fields once, so later app launches cannot overwrite them.
        let store = Self::new(self.path.clone(), Overrides::default());
        store.patch(SettingsPatch {
            revision,
            enabled_providers: (!fields.contains_key("enabled_providers")).then(|| {
                Provider::value_variants()
                    .iter()
                    .copied()
                    .filter(|provider| *provider != Provider::Mock)
                    .collect()
            }),
            disabled_providers: (!fields.contains_key("disabled_providers"))
                .then_some(preferences.disabled_providers),
            disabled_proxy_auth_files: (!fields.contains_key("disabled_proxy_auth_files"))
                .then_some(preferences.disabled_proxy_auth_files),
            automatically_discover_logins: (!fields.contains_key("automatically_discover_logins"))
                .then_some(preferences.automatically_discover_logins),
            quota_history_enabled: (!fields.contains_key("quota_history_enabled"))
                .then_some(preferences.quota_history_enabled),
            refresh_interval: (!fields.contains_key("refresh_interval"))
                .then_some(preferences.refresh_interval),
            cache_ttl_seconds: None,
            provider_timeout: None,
        })?;
        self.load()
    }
    pub fn patch(&self, patch: SettingsPatch) -> Result<SettingsView, SettingsError> {
        let parent = self
            .path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(std::path::Path::new("."));
        #[cfg(not(windows))]
        fs::create_dir_all(parent).map_err(|_| SettingsError::Storage)?;
        #[cfg(windows)]
        let _lock = crate::accounts::vault::acquire(&self.path.with_extension("toml.lock"))
            .map_err(|error| {
                if matches!(error, crate::accounts::AccountError::Busy) {
                    SettingsError::Busy
                } else {
                    SettingsError::Storage
                }
            })?;
        #[cfg(not(windows))]
        let _lock = {
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
            lock
        };
        let (mut config, revision, _) = self.read()?;
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
        if let Some(files) = patch.disabled_proxy_auth_files {
            config.disabled_proxy_auth_files = files;
        }
        if let Some(value) = patch.automatically_discover_logins {
            config.automatically_discover_logins = value;
        }
        if let Some(value) = patch.quota_history_enabled {
            config.quota_history_enabled = value;
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
        let mut table = toml::Table::try_from(&config).map_err(|_| SettingsError::Invalid)?;
        // Omitted while enabled so the file stays readable by builds without history.
        if config.quota_history_enabled {
            table.remove("quota_history_enabled");
        }
        let text = toml::to_string(&table).map_err(|_| SettingsError::Invalid)?;
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
            drop(file);
            #[cfg(windows)]
            {
                crate::accounts::windows_vault::replace(&temporary, &self.path)
            }
            #[cfg(not(windows))]
            {
                fs::rename(&temporary, &self.path)?;
                File::open(parent)?.sync_all()
            }
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
    if config.disabled_proxy_auth_files.len() > 512
        || config.disabled_proxy_auth_files.iter().any(|name| {
            name.is_empty()
                || name.len() > 255
                || name == "."
                || name == ".."
                || name.contains(['/', '\\'])
                || name.chars().any(char::is_control)
        })
    {
        return Err(SettingsError::Invalid);
    }
    if config.refresh_interval > 86400 || !(1..=3600).contains(&config.provider_timeout) {
        return Err(SettingsError::Invalid);
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn imports_native_preferences_once_without_overwriting_host_choices() {
        let dir = std::env::temp_dir().join(format!(
            "quotio-preferences-{}",
            crate::accounts::random_string().unwrap()
        ));
        fs::create_dir(&dir).unwrap();
        let path = dir.join("config.toml");
        fs::write(
            &path,
            "refresh_interval = 0\ncache_ttl_seconds = 17\nquota_history_enabled = false\n",
        )
        .unwrap();
        let store = SettingsStore::new(path, Overrides::default());
        let preferences = || NativePreferences {
            disabled_providers: vec![Provider::Amp],
            disabled_proxy_auth_files: vec!["disabled.json".into()],
            automatically_discover_logins: false,
            quota_history_enabled: true,
            refresh_interval: 600,
        };
        let first = store.import_native_preferences(preferences()).unwrap();
        assert_eq!(first.values.refresh_interval, 0);
        assert_eq!(first.values.cache_ttl_seconds, 17);
        assert_eq!(first.values.disabled_providers, vec!["amp"]);
        assert!(!first.values.automatically_discover_logins);
        assert!(!first.values.quota_history_enabled);
        assert!(!first.values.enabled_providers.is_empty());
        assert!(!first.values.enabled_providers.contains(&"mock".into()));
        let second = store
            .import_native_preferences(NativePreferences {
                disabled_providers: vec![],
                disabled_proxy_auth_files: vec![],
                automatically_discover_logins: true,
                quota_history_enabled: true,
                refresh_interval: 30,
            })
            .unwrap();
        assert_eq!(first.revision, second.revision);
        assert!(!second.values.quota_history_enabled);
        assert_eq!(
            second.values.disabled_proxy_auth_files,
            vec!["disabled.json"]
        );
        assert_eq!(second.values.disabled_providers, vec!["amp"]);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn rejects_invalid_disabled_source_names() {
        let mut config = Config::default();
        for name in [
            "",
            ".",
            "..",
            "../auth.json",
            "dir/auth.json",
            "dir\\auth.json",
            "auth\n.json",
        ] {
            config.disabled_proxy_auth_files = vec![name.into()];
            assert_eq!(validate(&config), Err(SettingsError::Invalid));
        }
        config.disabled_proxy_auth_files = vec!["account.json".into()];
        assert_eq!(validate(&config), Ok(()));
    }
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
            quota_history_enabled: None,
            enabled_providers: Some(vec![Provider::Mock]),
            disabled_providers: Some(vec![Provider::Amp]),
            disabled_proxy_auth_files: None,
            automatically_discover_logins: Some(false),
            cache_ttl_seconds: Some(25),
            refresh_interval: Some(30),
            provider_timeout: None,
        };
        let view = store.patch(patch(initial.revision.clone())).unwrap();
        assert_eq!(view.values.cache_ttl_seconds, 25);
        assert!(!store.load().unwrap().values.automatically_discover_logins);
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
