use super::*;
use crate::domain::*;
pub struct MockProvider;
impl ProviderAdapter for MockProvider {
    fn id(&self) -> ProviderId {
        ProviderId("mock".into())
    }
    fn idempotent(&self) -> bool {
        true
    }
    fn fetch<'a>(&'a self, context: &'a ProviderContext) -> FetchFuture<'a> {
        Box::pin(async move {
            let fetched_at = context.clock.now();
            Ok(ProviderUsage {
                reset_credits: None,
                antigravity_subscription: None,
                codex_profile: None,
                codex_reset_credits: None,
                diagnostics: vec![],
                account_ref: None,
                provider: self.id(),
                account: AccountIdentity {
                    verified: None,
                    subscription_status: None,
                    plan: None,
                    id: "mock-account".into(),
                    label: "Demo account".into(),
                },
                windows: [
                    ("Session", Some(25.0)),
                    ("Weekly", Some(100.0)),
                    ("Monthly", None),
                ]
                .into_iter()
                .map(|(label, used)| QuotaWindow {
                    note: None,
                    metric_id: None,
                    consumption: None,
                    reset_description: None,
                    amounts: None,
                    label: label.into(),
                    quota: Quota::from_used(used),
                    resets_at: used.map(|_| fetched_at + time::Duration::days(7)),
                    provenance: Provenance {
                        source: "mock_fixture".into(),
                        confidence: Confidence::Exact,
                    },
                    fetched_at,
                })
                .collect(),
            })
        })
    }
}
