//! Durable logical-account bindings. Only authenticated provider evidence can merge sources.
//! Credential records remain separate so grouping never removes or rewrites a native login.
use super::{Account, AccountError, random_string};
use crate::{cli::Provider, domain::VerifiedIdentity};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashSet};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Binding {
    provider: Provider,
    account_id: String,
    verified: Option<VerifiedIdentity>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registry {
    pub host_id: String,
    pub revision: u64,
    bindings: BTreeMap<String, Binding>,
    redirects: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    labels: BTreeMap<String, Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) snapshot_digest: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    suppressed_sources: BTreeMap<String, BTreeSet<String>>,
    #[serde(default)]
    history_verified_epochs: Vec<(String, VerifiedIdentity, String)>,
    #[serde(default)]
    history_owned_epochs: BTreeMap<String, String>,
}

impl Registry {
    pub fn new(accounts: &[Account]) -> Result<Self, AccountError> {
        let mut state = Self {
            host_id: random_string()?,
            revision: 0,
            bindings: BTreeMap::new(),
            redirects: BTreeMap::new(),
            labels: BTreeMap::new(),
            snapshot_digest: None,
            suppressed_sources: BTreeMap::new(),
            history_verified_epochs: Vec::new(),
            history_owned_epochs: BTreeMap::new(),
        };
        state.synchronize(accounts)?;
        Ok(state)
    }

    pub(crate) fn history_epoch(
        &mut self,
        provider: &str,
        identity: &VerifiedIdentity,
    ) -> Result<(String, bool), AccountError> {
        if let Some((_, _, epoch)) = self
            .history_verified_epochs
            .iter()
            .find(|(p, i, _)| p == provider && i == identity)
        {
            return Ok((epoch.clone(), false));
        }
        let epoch = random_string()?;
        self.history_verified_epochs
            .push((provider.into(), identity.clone(), epoch.clone()));
        Ok((epoch, true))
    }

    pub(crate) fn verified_for_account(&self, account: &str) -> Option<&VerifiedIdentity> {
        self.bindings
            .values()
            .find(|binding| binding.account_id == account)
            .and_then(|binding| binding.verified.as_ref())
    }

    pub(crate) fn owned_history_epoch(&self, account: &str) -> String {
        self.history_owned_epochs
            .get(account)
            .cloned()
            .unwrap_or_else(|| account.into())
    }
    pub(crate) fn set_owned_history_epoch(&mut self, account: &str, epoch: String) {
        self.history_owned_epochs.insert(account.into(), epoch);
    }

    pub fn account_id_for_source(&self, source_id: &str) -> Option<&str> {
        self.bindings
            .get(source_id)
            .map(|binding| binding.account_id.as_str())
    }

    fn suppression_keys(account: &Account) -> Vec<String> {
        let metadata = super::api::AccountDto::from(account);
        let mut keys = vec![crate::cache::fingerprint(&["identity", &account.identity])];
        if let Some(kind) = metadata.source_kind {
            let mut permission = vec![
                "permission",
                kind,
                metadata.source_location.as_deref().unwrap_or(""),
            ];
            if let Some(account) = account.keychain_account() {
                permission.push(account);
            }
            keys.push(crate::cache::fingerprint(&permission));
        }
        keys
    }

    pub fn suppress(&mut self, account: &Account) {
        self.suppressed_sources
            .entry(account.provider.id().into())
            .or_default()
            .extend(Self::suppression_keys(account));
    }

    pub fn restore(&mut self, account: &Account) {
        if let Some(keys) = self.suppressed_sources.get_mut(account.provider.id()) {
            for key in Self::suppression_keys(account) {
                keys.remove(&key);
            }
        }
        self.suppressed_sources.retain(|_, keys| !keys.is_empty());
    }

    pub fn is_suppressed(&self, provider: Provider, identity: &str) -> bool {
        self.suppressed_sources
            .get(provider.id())
            .is_some_and(|keys| keys.contains(&crate::cache::fingerprint(&["identity", identity])))
    }

    pub fn permission_suppressed(
        &self,
        provider: Provider,
        kind: &str,
        location: Option<&str>,
        account: Option<&str>,
    ) -> bool {
        self.suppressed_sources
            .get(provider.id())
            .is_some_and(|keys| {
                keys.contains(&crate::cache::fingerprint(&[
                    "permission",
                    kind,
                    location.unwrap_or(""),
                ])) || account.is_some_and(|account| {
                    keys.contains(&crate::cache::fingerprint(&[
                        "permission",
                        kind,
                        location.unwrap_or(""),
                        account,
                    ]))
                })
            })
    }

    pub fn restore_provider(&mut self, provider: Provider) -> bool {
        self.suppressed_sources.remove(provider.id()).is_some()
    }

    pub(crate) fn suppressed_providers(&self) -> std::collections::HashSet<String> {
        self.suppressed_sources.keys().cloned().collect()
    }

    pub fn has_suppressions(&self) -> bool {
        !self.suppressed_sources.is_empty()
    }

    pub fn resolve_id(&self, id: &str) -> Option<&str> {
        self.bindings
            .values()
            .find(|binding| binding.account_id == id)
            .map(|binding| binding.account_id.as_str())
            .or_else(|| self.redirects.get(id).map(String::as_str))
    }

    pub fn source_ids(&self, account_id: &str) -> Result<Vec<String>, AccountError> {
        let canonical = self.resolve_id(account_id).ok_or(AccountError::NotFound)?;
        Ok(self
            .bindings
            .iter()
            .filter(|(_, binding)| binding.account_id == canonical)
            .map(|(id, _)| id.clone())
            .collect())
    }

    pub fn set_label(&mut self, id: &str, label: Option<&str>) -> Result<(), AccountError> {
        let id = self
            .resolve_id(id)
            .ok_or(AccountError::NotFound)?
            .to_owned();
        let label = label.map(super::validate_label).transpose()?;
        self.labels.insert(id, label);
        Ok(())
    }

    pub fn has_labels(&self) -> bool {
        !self.labels.is_empty()
    }

    pub fn preferred_source(&self, accounts: &[Account], id: &str) -> Result<String, AccountError> {
        let ids = self.source_ids(id)?;
        accounts
            .iter()
            .filter(|account| ids.contains(&account.id) && account.enabled())
            .min_by_key(|account| {
                (
                    if account.origin() == crate::domain::AccountOrigin::Owned {
                        0
                    } else {
                        1
                    },
                    account.id.clone(),
                )
            })
            .map(|account| account.id.clone())
            .ok_or(AccountError::SourceDisabled)
    }

    /// A live failed fetch must not erase the last confirmed identity.
    /// Call invalidate explicitly when replacing a credential with a different account.
    pub fn observe(
        &mut self,
        source_id: &str,
        identity: &VerifiedIdentity,
    ) -> Result<bool, AccountError> {
        if !identity.is_valid() {
            return Err(AccountError::Input);
        }
        let previous = self
            .bindings
            .get(source_id)
            .ok_or(AccountError::NotFound)?
            .clone();
        if previous.verified.as_ref() == Some(identity) {
            return Ok(false);
        }
        let existing = self
            .bindings
            .iter()
            .filter(|(id, binding)| {
                id.as_str() != source_id
                    && binding.provider == previous.provider
                    && binding.verified.as_ref() == Some(identity)
            })
            .map(|(_, binding)| binding.account_id.clone())
            .min();
        let changed_identity = previous.verified.is_some();
        let account_id = match existing {
            Some(id) => id,
            None if changed_identity => random_string()?,
            None => previous.account_id.clone(),
        };
        let current = self.bindings.get_mut(source_id).expect("source checked");
        current.verified = Some(identity.clone());
        current.account_id = account_id.clone();
        if account_id != previous.account_id
            && !self
                .bindings
                .values()
                .any(|binding| binding.account_id == previous.account_id)
        {
            if !changed_identity {
                for target in self
                    .redirects
                    .values_mut()
                    .filter(|target| **target == previous.account_id)
                {
                    *target = account_id.clone();
                }
                if let Some(label) = self.labels.get(&previous.account_id).cloned() {
                    self.labels.entry(account_id.clone()).or_insert(label);
                }
                self.redirects.insert(previous.account_id, account_id);
            } else {
                // An old account bookmark must never silently switch to a different identity.
                self.redirects
                    .retain(|_, target| target != &previous.account_id);
            }
        }
        Ok(true)
    }

    pub fn invalidate(&mut self, source_id: &str) -> Result<(), AccountError> {
        let binding = self
            .bindings
            .get_mut(source_id)
            .ok_or(AccountError::NotFound)?;
        let previous = binding.account_id.clone();
        binding.account_id = random_string()?;
        binding.verified = None;
        if !self
            .bindings
            .values()
            .any(|binding| binding.account_id == previous)
        {
            self.redirects.retain(|_, target| target != &previous);
        }
        Ok(())
    }

    pub fn account_list(
        &self,
        records: &[Account],
    ) -> Result<crate::contract::AccountList, AccountError> {
        use super::{Credential, LabelOrigin};
        use crate::{contract as view, domain::AccountOrigin};
        self.validate(records)?;
        let mut groups: BTreeMap<&str, Vec<&Account>> = BTreeMap::new();
        for record in records {
            groups
                .entry(
                    self.account_id_for_source(&record.id)
                        .expect("validated binding"),
                )
                .or_default()
                .push(record);
        }
        let accounts = groups
            .into_iter()
            .map(|(id, mut records)| {
                // Explicit labels win; ambiguous legacy labels are preserved before generated names.
                let priority =
                    |record: &Account| match record.naming.as_ref().map(|name| name.origin) {
                        Some(LabelOrigin::User) => 0,
                        None => 1,
                        Some(LabelOrigin::Generated) => 2,
                    };
                records.sort_by(|a, b| priority(a).cmp(&priority(b)).then_with(|| a.id.cmp(&b.id)));
                let named = records[0];
                let enabled = records.iter().any(|record| record.enabled());
                let verified = self.bindings[&named.id].verified.is_some();
                let sources = records
                    .iter()
                    .map(|record| {
                        let metadata = super::api::AccountDto::from(*record);
                        let owner = if record.origin() != AccountOrigin::Owned {
                            view::RefreshOwner::ProviderTool
                        } else if matches!(
                            record.credential,
                            Credential::CodexOAuth { .. }
                                | Credential::ClaudeOAuth { .. }
                                | Credential::GrokOAuth { .. }
                                | Credential::FactoryOAuth { .. }
                                | Credential::KiroOAuth { .. }
                                | Credential::AntigravityOAuth { .. }
                        ) {
                            view::RefreshOwner::Host
                        } else {
                            view::RefreshOwner::None
                        };
                        view::Source {
                            id: record.id.clone(),
                            origin: record.origin(),
                            kind: metadata.source_kind.unwrap_or("owned_credential").into(),
                            location: metadata.source_location,
                            keychain_account: record.keychain_account().map(str::to_owned),
                            enabled: record.enabled(),
                            selected: false,
                            state: if record.enabled() {
                                view::ConnectionState::NotChecked
                            } else {
                                view::ConnectionState::Disabled
                            },
                            refresh_owner: owner,
                            issue: None,
                            actions: ["set_source_enabled", "remove_source"]
                                .into_iter()
                                .chain(
                                    matches!(
                                        record.credential,
                                        Credential::ApiKey { .. } | Credential::CatalogKey { .. }
                                    )
                                    .then_some("replace_api_key"),
                                )
                                .map(|kind| view::Action {
                                    kind: kind.into(),
                                    available: true,
                                    reason: None,
                                    interaction: view::InteractionLocation::Host,
                                })
                                .collect(),
                        }
                    })
                    .collect();
                let inherited_label = named
                    .naming
                    .as_ref()
                    .is_some_and(|name| name.origin == LabelOrigin::User)
                    .then(|| named.label.clone());
                let (display_name, user_label) = match self.labels.get(id) {
                    Some(Some(label)) => (label.clone(), Some(label.clone())),
                    Some(None) => (
                        named
                            .naming
                            .as_ref()
                            .and_then(|name| name.observed_name.clone())
                            .unwrap_or_else(|| format!("{} account", named.provider.id())),
                        None,
                    ),
                    None => (named.display_name().into(), inherited_label),
                };
                view::Account {
                    id: id.to_owned(),
                    provider_id: named.provider.id().into(),
                    display_name,
                    user_label,
                    identity: view::Identity {
                        evidence: if verified {
                            view::IdentityEvidence::Verified
                        } else {
                            view::IdentityEvidence::Unknown
                        },
                        username: None,
                        email: None,
                    },
                    active: records.iter().any(|record| record.active),
                    enabled,
                    state: if enabled {
                        view::ConnectionState::NotChecked
                    } else {
                        view::ConnectionState::Disabled
                    },
                    sources,
                    actions: ["rename", "set_enabled", "select", "remove"]
                        .into_iter()
                        .map(|kind| view::Action {
                            kind: kind.into(),
                            available: kind != "select" || enabled,
                            reason: (kind == "select" && !enabled)
                                .then(|| "account_disabled".into()),
                            interaction: view::InteractionLocation::Host,
                        })
                        .collect(),
                }
            })
            .collect();
        Ok(view::AccountList {
            schema_version: 2,
            account_redirects: self.redirects.clone(),
            revision: self.revision,
            host: view::Host {
                id: self.host_id.clone(),
                platform: std::env::consts::OS.into(),
                api_versions: vec![2],
                capabilities: BTreeMap::from([
                    (
                        "account_read".into(),
                        view::Availability {
                            available: true,
                            reason: None,
                        },
                    ),
                    (
                        "account_write_v2".into(),
                        view::Availability {
                            available: true,
                            reason: None,
                        },
                    ),
                ]),
            },
            accounts,
        })
    }

    pub fn synchronize(&mut self, accounts: &[Account]) -> Result<(), AccountError> {
        let ids: HashSet<_> = accounts.iter().map(|account| account.id.as_str()).collect();
        if ids.len() != accounts.len() {
            return Err(AccountError::Corrupt);
        }
        self.bindings.retain(|id, _| ids.contains(id.as_str()));
        for account in accounts {
            self.bindings
                .entry(account.id.clone())
                .or_insert_with(|| Binding {
                    provider: account.provider,
                    account_id: account.id.clone(),
                    verified: None,
                });
        }
        let active: HashSet<_> = self
            .bindings
            .values()
            .map(|binding| binding.account_id.as_str())
            .collect();
        self.redirects
            .retain(|_, target| active.contains(target.as_str()));
        self.labels
            .retain(|id, _| active.contains(id.as_str()) || self.redirects.contains_key(id));
        self.history_owned_epochs
            .retain(|id, _| active.contains(id.as_str()));
        self.validate(accounts)
    }

    pub fn validate(&self, accounts: &[Account]) -> Result<(), AccountError> {
        use clap::ValueEnum;
        if self.suppressed_sources.iter().any(|(provider, keys)| {
            Provider::from_str(provider, false).is_err()
                || keys
                    .iter()
                    .any(|key| key.len() != 64 || !key.bytes().all(|byte| byte.is_ascii_hexdigit()))
        }) {
            return Err(AccountError::Corrupt);
        }
        if self.snapshot_digest.as_ref().is_some_and(|digest| {
            digest.len() != 64 || !digest.bytes().all(|byte| byte.is_ascii_hexdigit())
        }) {
            return Err(AccountError::Corrupt);
        }
        let valid_id = |id: &str| {
            !id.is_empty()
                && id.len() <= 256
                && id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
        };
        let mut epochs = HashSet::new();
        if self
            .history_verified_epochs
            .iter()
            .any(|(provider, identity, epoch)| {
                Provider::from_str(provider, false).is_err()
                    || !identity.is_valid()
                    || !valid_id(epoch)
                    || !epochs.insert(epoch)
            })
            || self
                .history_owned_epochs
                .iter()
                .any(|(account, epoch)| !valid_id(account) || !valid_id(epoch))
        {
            return Err(AccountError::Corrupt);
        }
        if !valid_id(&self.host_id) || self.bindings.len() != accounts.len() {
            return Err(AccountError::Corrupt);
        }
        let mut groups: BTreeMap<&str, (Provider, &Option<VerifiedIdentity>)> = BTreeMap::new();
        let mut ids = HashSet::new();
        for account in accounts {
            if !ids.insert(&account.id) {
                return Err(AccountError::Corrupt);
            }
            let binding = self
                .bindings
                .get(&account.id)
                .ok_or(AccountError::Corrupt)?;
            if binding.provider != account.provider
                || !valid_id(&binding.account_id)
                || binding
                    .verified
                    .as_ref()
                    .is_some_and(|identity| !identity.is_valid())
            {
                return Err(AccountError::Corrupt);
            }
            if let Some((provider, identity)) =
                groups.insert(&binding.account_id, (binding.provider, &binding.verified))
                && (provider != binding.provider
                    || identity.is_none()
                    || identity != &binding.verified)
            {
                return Err(AccountError::Corrupt);
            }
        }
        if self.labels.iter().any(|(id, label)| {
            (!groups.contains_key(id.as_str()) && !self.redirects.contains_key(id))
                || label
                    .as_deref()
                    .is_some_and(|label| super::validate_label(label).is_err())
        }) {
            return Err(AccountError::Corrupt);
        }
        if self.redirects.iter().any(|(old, target)| {
            !valid_id(old)
                || groups.contains_key(old.as_str())
                || !groups.contains_key(target.as_str())
        }) {
            return Err(AccountError::Corrupt);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accounts::{Credential, Document};

    fn document() -> Document {
        let mut doc = Document::empty();
        for (provider, label) in [
            (Provider::Amp, "One"),
            (Provider::Amp, "Two"),
            (Provider::Codex, "Three"),
        ] {
            doc.add(
                provider,
                label,
                label.into(),
                Credential::ApiKey {
                    token: format!("fixture-{label}"),
                    region: None,
                    organization: None,
                },
            )
            .unwrap();
        }
        doc
    }
    fn identity(tenant: &str) -> VerifiedIdentity {
        VerifiedIdentity {
            subject: "same-user".into(),
            tenant: Some(tenant.into()),
        }
    }

    #[test]
    fn only_verified_same_provider_and_tenant_merge_and_survive_restart() {
        let doc = document();
        let ids: Vec<_> = doc
            .accounts
            .iter()
            .map(|account| account.id.clone())
            .collect();
        let mut registry = Registry::new(&doc.accounts).unwrap();
        assert_ne!(
            registry.account_id_for_source(&ids[0]),
            registry.account_id_for_source(&ids[1])
        );
        registry.observe(&ids[0], &identity("team-a")).unwrap();
        registry.observe(&ids[1], &identity("team-b")).unwrap();
        assert_ne!(
            registry.account_id_for_source(&ids[0]),
            registry.account_id_for_source(&ids[1])
        );
        registry.observe(&ids[2], &identity("team-a")).unwrap();
        assert_ne!(
            registry.account_id_for_source(&ids[0]),
            registry.account_id_for_source(&ids[2])
        );
        // A new observation proves the second source now belongs to the first identity.
        registry.observe(&ids[1], &identity("team-a")).unwrap();
        assert_eq!(
            registry.account_id_for_source(&ids[0]),
            registry.account_id_for_source(&ids[1])
        );
        assert!(registry.resolve_id(&ids[1]).is_none()); // Never redirect an old, different identity.
        let restored: Registry =
            serde_json::from_slice(&serde_json::to_vec(&registry).unwrap()).unwrap();
        restored.validate(&doc.accounts).unwrap();
        assert_eq!(restored.host_id, registry.host_id);
        assert_eq!(
            restored.account_id_for_source(&ids[1]),
            registry.account_id_for_source(&ids[0])
        );
    }

    #[test]
    fn merging_unknown_sources_preserves_aliases_and_deleting_one_source_keeps_the_account() {
        let mut doc = document();
        let first = doc.accounts[0].id.clone();
        let second = doc.accounts[1].id.clone();
        let mut registry = Registry::new(&doc.accounts).unwrap();
        registry.observe(&first, &identity("team")).unwrap();
        registry.observe(&second, &identity("team")).unwrap();
        assert_eq!(registry.resolve_id(&second), Some(first.as_str()));
        doc.rename(&second, "User chosen name").unwrap();
        let view = registry.account_list(&doc.accounts).unwrap();
        let grouped = view
            .accounts
            .iter()
            .find(|account| account.id == first)
            .unwrap();
        assert_eq!(grouped.sources.len(), 2);
        assert_eq!(grouped.display_name, "User chosen name");
        assert_eq!(grouped.user_label.as_deref(), Some("User chosen name"));
        assert!(
            grouped
                .actions
                .iter()
                .any(|action| action.kind == "rename" && action.available)
        );
        doc.remove(&first).unwrap();
        registry.synchronize(&doc.accounts).unwrap();
        assert_eq!(
            registry.account_id_for_source(&second),
            Some(first.as_str())
        );
        registry.validate(&doc.accounts).unwrap();
        registry.invalidate(&second).unwrap();
        assert_ne!(
            registry.account_id_for_source(&second),
            Some(first.as_str())
        );
        assert!(registry.resolve_id(&first).is_none());
        assert!(registry.resolve_id(&second).is_none());
        registry.validate(&doc.accounts).unwrap();
        doc.remove(&second).unwrap();
        registry.synchronize(&doc.accounts).unwrap();
        assert!(registry.account_id_for_source(&second).is_none());
    }

    #[test]
    fn malformed_or_unproved_shared_bindings_are_rejected() {
        let doc = document();
        let registry = Registry::new(&doc.accounts).unwrap();
        let first = &doc.accounts[0].id;
        let second = &doc.accounts[1].id;
        let mut value = serde_json::to_value(&registry).unwrap();
        value["bindings"][second]["account_id"] = first.clone().into();
        let invalid: Registry = serde_json::from_value(value).unwrap();
        assert!(invalid.validate(&doc.accounts).is_err());
        let mut registry = registry;
        assert!(
            registry
                .observe(
                    first,
                    &VerifiedIdentity {
                        subject: "".into(),
                        tenant: None
                    }
                )
                .is_err()
        );
    }
}
