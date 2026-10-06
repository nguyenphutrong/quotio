use crate::{domain::*, error::ProviderError, providers::*};
use std::{sync::Arc, time::Duration};
use tokio::{sync::watch, task::JoinSet};

#[derive(Clone)]
pub struct Cancellation(watch::Sender<bool>);
impl Default for Cancellation {
    fn default() -> Self {
        Self(watch::channel(false).0)
    }
}
impl Cancellation {
    pub fn cancel(&self) {
        self.0.send_replace(true);
    }
    pub(crate) async fn cancelled(&self) {
        let mut receiver = self.0.subscribe();
        let _ = receiver.wait_for(|value| *value).await;
    }
}
pub struct CollectRequest {
    pub providers: Vec<Arc<dyn ProviderAdapter>>,
    /// Total budget per provider, including retries and backoff.
    pub timeout: Duration,
    pub cancellation: Cancellation,
}
pub struct Collector {
    pub context: ProviderContext,
}
impl Collector {
    pub async fn collect(&self, request: CollectRequest) -> UsageReport {
        let mut tasks = JoinSet::new();
        let mut ids = Vec::new();
        let mut accounts = Vec::new();
        let mut task_order = std::collections::HashMap::new();
        for (index, adapter) in request.providers.into_iter().enumerate() {
            ids.push(adapter.id());
            accounts.push(adapter.account_ref());
            let context = self.context.clone();
            let cancellation = request.cancellation.clone();
            let timeout = request.timeout;
            let handle = tasks.spawn(async move {
                let deadline = tokio::time::Instant::now() + timeout;
                let work = async {
                    for attempt in 0..3 {
                        match adapter.fetch(&context).await {
                            Err(ProviderError::Transient) if adapter.idempotent() && attempt < 2 => {
                                tracing::debug!(attempt, "retry temporary provider failure");
                                tokio::time::sleep(Duration::from_millis(100 * (attempt + 1))).await;
                            }
                            result => return result,
                        }
                    }
                    unreachable!()
                };
                let work = FETCH_DEADLINE.scope(deadline, work);
                tokio::select! {
                    biased;
                    _ = cancellation.cancelled() => Err(ProviderError::Cancelled),
                    result = tokio::time::timeout_at(deadline, work) => result.unwrap_or(Err(ProviderError::Timeout)),
                }
            });
            // Preserve request order and associate even a panicking task with its provider.
            task_order.insert(handle.id(), index);
        }
        let mut results = Vec::new();
        while let Some(result) = tasks.join_next_with_id().await {
            let (task_id, value) = match result {
                Ok((id, value)) => (id, value),
                Err(error) => (error.id(), Err(ProviderError::Internal)),
            };
            results.push((task_order[&task_id], value));
        }
        results.sort_by_key(|(index, _)| *index);
        let mut report = UsageReport {
            schema_version: 1,
            generated_at: self.context.clock.now(),
            providers: vec![],
            failures: vec![],
        };
        for (index, result) in results {
            let result = result.and_then(|usage| {
                if usage.provider != ids[index] || !valid_usage(&usage) {
                    Err(ProviderError::InvalidData)
                } else {
                    Ok(usage)
                }
            });
            match result {
                Ok(mut usage) => {
                    usage.fresh_observation = true;
                    usage.account_ref = accounts[index].clone();
                    report.providers.push(usage);
                }
                Err(code) => report.failures.push(ProviderFailure {
                    account_ref: accounts[index].clone(),
                    provider: ids[index].clone(),
                    code,
                    message: code.to_string(),
                }),
            }
        }
        report.include_diagnostics();
        report
    }
}

pub(crate) fn valid_usage(usage: &ProviderUsage) -> bool {
    let mut metrics = std::collections::HashSet::new();
    let mut dates = std::collections::HashSet::new();
    usage.has_observations()
        && usage
            .account
            .verified
            .as_ref()
            .is_none_or(VerifiedIdentity::is_valid)
        && usage.codex_profile.as_ref().is_none_or(|profile| {
            profile
                .daily_usage
                .iter()
                .all(|day| dates.insert(&day.date))
        })
        && usage.windows.iter().all(|window| {
            metrics.insert(crate::contract::snapshot::metric_id(window))
                && window.quota.is_valid()
                && window.consumption.as_ref().is_none_or(|value| {
                    value.used.is_finite() && value.used >= 0.0 && !value.unit.trim().is_empty()
                })
                && window.amounts.as_ref().is_none_or(|value| {
                    value.remaining.is_finite() && value.limit.is_none_or(f64::is_finite)
                })
        })
}

// Prefer a managed snapshot only when it identifies the same account. Email-only
// local identity is sufficient for a unique personal account, never a workspace.
