use crate::providers::{FetchFuture, ProviderContext};
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum AuthKind {
    ApiKey,
    OAuth,
}
pub struct Setting {
    pub name: &'static str,
    pub env: &'static str,
    pub required: bool,
}
pub struct Definition {
    pub id: &'static str,
    pub name: &'static str,
    pub key_env: &'static str,
    pub auth: AuthKind,
    pub settings: &'static [Setting],
    pub fetch: for<'a> fn(&'a ProviderContext) -> FetchFuture<'a>,
}
pub mod azure;
pub mod balances;
pub mod coding;
pub mod common;
pub mod devin_desktop;
pub mod doubao;
pub mod gateways;
pub mod infrastructure;
pub mod muse;
pub mod oauth_cloud;
pub mod oauth_editors;
pub mod oauth_primary;
pub mod tools;
pub fn definitions() -> impl Iterator<Item = &'static Definition> {
    [
        azure::DEFINITIONS,
        doubao::DEFINITIONS,
        balances::DEFINITIONS,
        infrastructure::DEFINITIONS,
        coding::DEFINITIONS,
        muse::DEFINITIONS,
        gateways::DEFINITIONS,
        tools::DEFINITIONS,
        devin_desktop::DEFINITIONS,
        oauth_primary::DEFINITIONS,
        oauth_editors::DEFINITIONS,
        oauth_cloud::DEFINITIONS,
    ]
    .into_iter()
    .flatten()
}
pub fn find(id: &str) -> Option<&'static Definition> {
    definitions().find(|d| d.id == id)
}

pub struct CatalogProvider(pub &'static str);
impl crate::providers::ProviderAdapter for CatalogProvider {
    fn cache_identity<'a>(
        &'a self,
        context: &'a ProviderContext,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Option<String>> + Send + 'a>> {
        Box::pin(async move {
            let definition = find(self.0)?;
            // Cloud project scope can come from native config even with an explicit token.
            if matches!(self.0, "kiro" | "vertexai") {
                return oauth_cloud::cache_identity(self.0, context).await;
            }
            if definition.auth == AuthKind::ApiKey
                || context.credentials.get(definition.key_env).is_some()
            {
                return crate::cache::environment_identity(self.0, context);
            }
            let token = match self.0 {
                "claude" | "gemini" | "copilot" => {
                    oauth_primary::cache_token(self.0, context).await
                }
                "cursor" | "grok" => oauth_editors::cache_token(self.0, context).await,
                "muse" => muse::cache_token(context).await,
                _ => None,
            }?;
            let mut parts = vec![self.0.to_owned(), token.0];
            for setting in definition.settings {
                parts.push(
                    context
                        .credentials
                        .get(setting.env)
                        .map(|v| v.0)
                        .unwrap_or_default(),
                );
            }
            Some(crate::cache::fingerprint(
                &parts.iter().map(String::as_str).collect::<Vec<_>>(),
            ))
        })
    }

    fn id(&self) -> crate::domain::ProviderId {
        crate::domain::ProviderId(self.0.into())
    }
    fn account_ref(&self) -> Option<crate::domain::AccountRef> {
        Some(crate::domain::AccountRef {
            origin: None,
            id: "local".into(),
            label: "Local or environment account".into(),
        })
    }
    fn idempotent(&self) -> bool {
        find(self.0).is_some_and(|d| d.auth == AuthKind::ApiKey)
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            let definition = find(self.0).ok_or(crate::error::ProviderError::Unavailable)?;
            (definition.fetch)(context).await
        })
    }
}

#[cfg(test)]
mod registry_tests {
    use super::*;
    use crate::cli::Provider;
    use clap::ValueEnum;
    #[test]
    fn registry_ids_settings_and_storage_roundtrip_are_consistent() {
        let mut ids = std::collections::HashSet::new();
        for provider in Provider::value_variants() {
            assert!(ids.insert(provider.id()));
            let json = serde_json::to_string(provider).unwrap();
            assert_eq!(serde_json::from_str::<Provider>(&json).unwrap(), *provider);
            assert_eq!(Provider::from_str(provider.id(), false).unwrap(), *provider);
        }
        for definition in definitions() {
            assert_eq!(
                Provider::from_str(definition.id, false).unwrap(),
                Provider::Catalog(definition.id)
            );
            assert!(
                definition
                    .id
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
            );
            assert!(
                definition
                    .key_env
                    .bytes()
                    .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
            );
            let mut names = std::collections::HashSet::new();
            let mut envs = std::collections::HashSet::new();
            for setting in definition.settings {
                assert!(
                    !setting.name.is_empty()
                        && setting
                            .name
                            .bytes()
                            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_'),
                    "{} has invalid setting identifier",
                    definition.id
                );
                assert!(names.insert(setting.name) && envs.insert(setting.env));
                assert_ne!(setting.env, definition.key_env);
            }
        }
        assert_eq!(Provider::from_str("glm", false).unwrap(), Provider::Zai);
        assert_eq!(
            Provider::from_str("factory-droid", false).unwrap(),
            Provider::Factory
        );
        assert!(
            !serde_json::from_str::<Provider>("\"unrecognized-secret-value\"")
                .unwrap_err()
                .to_string()
                .contains("unrecognized-secret-value")
        );
    }
}
