use super::*;
use crate::history::{self, Account, Metric, Observation, Point};

pub(super) fn restriction(
    state: &ApiState,
    principal: &security::Principal,
    write: bool,
) -> Option<&'static str> {
    if !principal.owner {
        Some("insufficient_scope")
    } else if state.no_saved_accounts {
        Some("no_saved_accounts")
    } else if state.history.is_none() {
        Some("history_storage_unavailable")
    } else if write {
        state.management_restriction(principal)
    } else {
        None
    }
}
fn authorize(
    state: &ApiState,
    principal: &security::Principal,
    write: bool,
) -> Result<history::History, ApiError> {
    if let Some(reason) = restriction(state, principal, write) {
        return Err(ApiError(
            if reason == "insufficient_scope" || reason == "management_disabled" {
                StatusCode::FORBIDDEN
            } else {
                StatusCode::SERVICE_UNAVAILABLE
            },
            reason,
        ));
    }
    Ok(state.history.as_ref().expect("authorized history").clone())
}
fn history_error(error: history::Error) -> ApiError {
    ApiError(
        match error {
            history::Error::Cursor => StatusCode::CONFLICT,
            history::Error::Metric => StatusCode::NOT_FOUND,
            _ => StatusCode::SERVICE_UNAVAILABLE,
        },
        match error {
            history::Error::Storage => "history_storage_unavailable",
            history::Error::Conflict => "history_observation_conflict",
            history::Error::Cursor => "history_cursor_invalid",
            history::Error::Metric => "history_metric_not_found",
        },
    )
}
fn safe_text(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()
        && value.len() <= 96
        && !value.contains(['@', '/', '\\'])
        && !value.chars().any(char::is_control)
        && value.split_whitespace().all(|word| word.len() <= 32))
    .then(|| value.to_owned())
}
fn metric(value: &crate::contract::Metric) -> Metric {
    Metric {
        id: value.id.clone(),
        display_name: safe_text(&value.display_name).unwrap_or_else(|| "Quota".into()),
        group: value.group.as_deref().and_then(safe_text),
        current: true,
        has_percentage: history::remaining(&value.quota).is_some(),
    }
}
pub(super) async fn snapshot(
    state: &ApiState,
    report: UsageReport,
) -> Result<crate::contract::Snapshot, ApiError> {
    let ttl = time::Duration::seconds(
        state
            .settings
            .read()
            .await
            .values
            .cache_ttl_seconds
            .min(i64::MAX as u64) as i64,
    );
    crate::accounts::api::resolved_snapshot(
        state.vault.clone().ok_or(ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "account_storage_disabled",
        ))?,
        report,
        state.context.clock.now(),
        ttl,
    )
    .await
    .map_err(|e| {
        ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            management::account_code(&e),
        )
    })
}
pub(super) async fn account_context(
    state: &ApiState,
    view: &crate::contract::Snapshot,
    report: &UsageReport,
    id: &str,
) -> Result<Account, ApiError> {
    if !crate::contract::valid_id(id) {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_id"));
    }
    let canonical = view.account_redirects.get(id).map_or(id, String::as_str);
    let account = view
        .accounts
        .iter()
        .find(|account| account.id == canonical)
        .ok_or(ApiError(StatusCode::NOT_FOUND, "account_not_found"))?;
    let raw = report.providers.iter().find(|value| {
        value.provider.0 == account.provider_id
            && value.account_ref.as_ref().is_some_and(|reference| {
                account
                    .sources
                    .iter()
                    .any(|source| source.id == reference.id)
            })
            || value.provider.0 == account.provider_id
                && crate::contract::snapshot::external_id(
                    &value.provider.0,
                    value.account_ref.as_ref(),
                ) == canonical
    });
    let verified = raw.and_then(|value| value.account.verified.clone());
    let allow_verified_fallback = raw.is_none();
    let vault = state.vault.clone().ok_or(ApiError(
        StatusCode::SERVICE_UNAVAILABLE,
        "account_storage_disabled",
    ))?;
    let account_id = canonical.to_owned();
    let provider = account.provider_id.clone();
    let durable_vault = vault.clone();
    let (durable, owned_epoch) = tokio::task::spawn_blocking(move || {
        let mut tx = vault.begin()?;
        tx.document.enable_resolved_accounts()?;
        let registry = tx.document.resolved.as_mut().expect("initialized");
        let identity = verified.or_else(|| {
            allow_verified_fallback
                .then(|| registry.verified_for_account(&account_id).cloned())
                .flatten()
        });
        let owned_epoch = registry.owned_history_epoch(&account_id);
        if let Some(identity) = identity {
            let (epoch, changed) = registry.history_epoch(&provider, &identity)?;
            if changed {
                tx.commit()?;
            }
            Ok((Some(epoch), owned_epoch))
        } else {
            Ok::<_, crate::accounts::AccountError>((None, owned_epoch))
        }
    })
    .await
    .map_err(|_| {
        ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            "account_storage_unavailable",
        )
    })?
    .map_err(|e| {
        ApiError(
            StatusCode::SERVICE_UNAVAILABLE,
            management::account_code(&e),
        )
    })?;
    let mut epochs = state.history_epochs.lock().await;
    let identity = raw.and_then(|value| value.history_identity.clone());
    let owned = account
        .sources
        .iter()
        .any(|source| source.origin == crate::domain::AccountOrigin::Owned);
    let entry = match epochs.entry(canonical.into()) {
        std::collections::hash_map::Entry::Occupied(entry) => entry.into_mut(),
        std::collections::hash_map::Entry::Vacant(entry) => {
            let initial = match durable.as_ref() {
                Some(epoch) => epoch.clone(),
                None if owned => owned_epoch,
                None => crate::accounts::random_string().map_err(|_| {
                    ApiError(StatusCode::SERVICE_UNAVAILABLE, "host_state_unavailable")
                })?,
            };
            entry.insert((identity.clone(), initial))
        }
    };
    if let Some(durable) = durable {
        entry.1 = durable;
        entry.0 = identity;
    } else if identity.is_some() && entry.0.is_some() && entry.0 != identity {
        entry.1 = crate::accounts::random_string()
            .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "host_state_unavailable"))?;
        entry.0 = identity;
        if owned {
            let account_id = canonical.to_owned();
            let epoch = entry.1.clone();
            tokio::task::spawn_blocking(move || {
                let mut tx = durable_vault.begin()?;
                tx.document
                    .resolved
                    .as_mut()
                    .ok_or(crate::accounts::AccountError::Corrupt)?
                    .set_owned_history_epoch(&account_id, epoch);
                tx.commit()
            })
            .await
            .map_err(|_| {
                ApiError(
                    StatusCode::SERVICE_UNAVAILABLE,
                    "account_storage_unavailable",
                )
            })?
            .map_err(|e| {
                ApiError(
                    StatusCode::SERVICE_UNAVAILABLE,
                    management::account_code(&e),
                )
            })?;
        }
    } else if identity.is_some() {
        entry.0 = identity;
    }
    Ok(Account {
        host_id: view.host.id.clone(),
        id: canonical.into(),
        epoch: entry.1.clone(),
        redirects: view
            .account_redirects
            .iter()
            .filter(|(_, target)| target.as_str() == canonical)
            .map(|(old, _)| old.clone())
            .collect(),
        metrics: view
            .usage
            .iter()
            .find(|usage| usage.account_id == canonical)
            .map_or_else(Vec::new, |usage| usage.metrics.iter().map(metric).collect()),
    })
}
async fn current(state: &ApiState, id: &str) -> Result<Account, ApiError> {
    let report = state
        .snapshot
        .read()
        .await
        .as_ref()
        .filter(|(generation, _)| *generation == state.generation.load(Ordering::SeqCst))
        .map(|(_, r)| r.clone())
        .unwrap_or(UsageReport {
            schema_version: 1,
            generated_at: state.context.clock.now(),
            providers: vec![],
            failures: vec![],
        });
    let view = snapshot(state, report.clone()).await?;
    account_context(state, &view, &report, id).await
}
pub(super) async fn record(
    state: &ApiState,
    report: &UsageReport,
    revision: u64,
    ttl: u64,
) -> Result<(), ApiError> {
    if state.no_saved_accounts {
        return Ok(());
    }
    let Some(history) = &state.history else {
        return Ok(());
    };
    if !state.settings.read().await.values.quota_history_enabled {
        return history
            .maintain(state.context.clock.now())
            .await
            .map_err(history_error);
    }
    let view = snapshot(state, report.clone()).await?;
    let now = state.context.clock.now();
    let mut points = vec![];
    for account in &view.accounts {
        let context = account_context(state, &view, report, &account.id).await?;
        for raw in report.providers.iter().filter(|value| {
            value.fresh_observation
                && value.provider.0 == account.provider_id
                && (value.account_ref.as_ref().is_some_and(|reference| {
                    account
                        .sources
                        .iter()
                        .any(|source| source.id == reference.id)
                }) || crate::contract::snapshot::external_id(
                    &value.provider.0,
                    value.account_ref.as_ref(),
                ) == account.id)
        }) {
            for window in &raw.windows {
                let expires = window
                    .fetched_at
                    .checked_add(time::Duration::seconds(ttl.min(i64::MAX as u64) as i64));
                if expires.is_none_or(|at| ttl > 0 && at <= now) {
                    continue;
                }
                let id = crate::contract::snapshot::metric_id(window);
                let Some(metadata) = context.metrics.iter().find(|metric| metric.id == id) else {
                    continue;
                };
                let mut quota = window.quota.clone();
                if let crate::domain::Quota::Limit { unit, .. } = &mut quota {
                    *unit = safe_text(unit).unwrap_or_else(|| "units".into());
                }
                let mut amounts = window.amounts.clone();
                if let Some(amounts) = &mut amounts {
                    amounts.unit = safe_text(&amounts.unit).unwrap_or_else(|| "units".into());
                }
                let source = window
                    .provenance
                    .source
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
                    .then(|| window.provenance.source.clone())
                    .filter(|s| !s.is_empty() && s.len() <= 64)
                    .unwrap_or_else(|| "provider".into());
                let interpretation = match quota {
                    crate::domain::Quota::Available { .. }
                    | crate::domain::Quota::Exhausted { .. } => "percentage",
                    crate::domain::Quota::Limit { .. } => "amount",
                    _ => "nonnumeric",
                };
                let limit_basis = match &quota {
                    crate::domain::Quota::Limit { amount, unit } => format!("{amount}:{unit}"),
                    _ => String::new(),
                };
                let basis = crate::cache::fingerprint(&[
                    raw.account.plan.as_deref().unwrap_or(""),
                    &serde_json::to_string(&amounts.as_ref().map(|a| (&a.limit, &a.unit)))
                        .unwrap_or_default(),
                    &limit_basis,
                    interpretation,
                    &source,
                ]);
                points.push(Point {
                    account: context.clone(),
                    metric: metadata.clone(),
                    basis,
                    observation: Observation {
                        series_id: String::new(),
                        basis_id: String::new(),
                        fetched_at: window.fetched_at.to_offset(time::UtcOffset::UTC),
                        expires_at: expires.map(|at| at.to_offset(time::UtcOffset::UTC)),
                        quota,
                        amounts,
                        resets_at: window
                            .resets_at
                            .map(|at| at.to_offset(time::UtcOffset::UTC)),
                        reset_description: window.reset_description.as_deref().and_then(safe_text),
                        provenance: crate::domain::Provenance {
                            source,
                            confidence: window.provenance.confidence.clone(),
                        },
                    },
                });
            }
        }
    }
    history
        .record(points, revision, now)
        .await
        .map_err(history_error)
}
pub(super) async fn catalog(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path(id): Path<String>,
) -> Result<Json<history::Catalog>, ApiError> {
    let history = authorize(&state, &principal, false)?;
    let _guard = crate::accounts::service::mutation_guard(&state.commit_guard)
        .await
        .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "account_busy"))?;
    let account = current(&state, &id).await?;
    let enabled = state.settings.read().await.values.quota_history_enabled;
    history
        .catalog(account, enabled, state.context.clock.now())
        .await
        .map(Json)
        .map_err(history_error)
}
pub(super) async fn chart(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path((id, metric, range)): Path<(String, String, String)>,
) -> Result<Json<history::Chart>, ApiError> {
    let history = authorize(&state, &principal, false)?;
    validate(&metric, &range)?;
    let _guard = crate::accounts::service::mutation_guard(&state.commit_guard)
        .await
        .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "account_busy"))?;
    let account = current(&state, &id).await?;
    let enabled = state.settings.read().await.values.quota_history_enabled;
    history
        .chart(account, metric, range, enabled, state.context.clock.now())
        .await
        .map(Json)
        .map_err(history_error)
}
fn validate(metric: &str, range: &str) -> Result<(), ApiError> {
    if !crate::contract::valid_id(metric) {
        Err(ApiError(StatusCode::BAD_REQUEST, "invalid_id"))
    } else if history::range_spec(range).is_none() {
        Err(ApiError(StatusCode::BAD_REQUEST, "invalid_history_range"))
    } else {
        Ok(())
    }
}
pub(super) async fn events(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path((id, metric, range, cursor)): Path<(String, String, String, String)>,
) -> Result<Json<history::EventsPage>, ApiError> {
    let history = authorize(&state, &principal, false)?;
    validate(&metric, &range)?;
    if !crate::contract::valid_id(&cursor) {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid_id"));
    }
    let _guard = crate::accounts::service::mutation_guard(&state.commit_guard)
        .await
        .map_err(|_| ApiError(StatusCode::SERVICE_UNAVAILABLE, "account_busy"))?;
    let account = current(&state, &id).await?;
    history
        .events(account, metric, range, cursor, state.context.clock.now())
        .await
        .map(Json)
        .map_err(history_error)
}
async fn clear(
    state: Arc<ApiState>,
    principal: security::Principal,
    id: Option<String>,
) -> Result<StatusCode, ApiError> {
    let history = authorize(&state, &principal, true)?;
    let (send, receive) = tokio::sync::oneshot::channel();
    let work = state.clone();
    state.spawn(async move {
        let result = async {
            let _guard = work
                .client_mutation_guard(&principal)
                .await
                .map_err(client_access_error)?;
            let account = if let Some(id) = id {
                Some(current(&work, &id).await?)
            } else {
                None
            };
            history
                .clear(account, work.context.clock.now())
                .await
                .map_err(history_error)?;
            Ok(StatusCode::NO_CONTENT)
        }
        .await;
        let _ = send.send(result);
    })?;
    receive
        .await
        .map_err(|_| ApiError(StatusCode::INTERNAL_SERVER_ERROR, "internal_error"))?
}
pub(super) async fn clear_account(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    clear(state, principal, Some(id)).await
}
pub(super) async fn clear_all(
    State(state): State<Arc<ApiState>>,
    Extension(principal): Extension<security::Principal>,
) -> Result<StatusCode, ApiError> {
    clear(state, principal, None).await
}
pub(super) async fn purge(
    state: &ApiState,
    id: &str,
    last_source_only: bool,
) -> Result<(), &'static str> {
    if let Some(history) = &state.history {
        let report = state
            .snapshot
            .read()
            .await
            .as_ref()
            .map(|(_, r)| r.clone())
            .unwrap_or(UsageReport {
                schema_version: 1,
                generated_at: state.context.clock.now(),
                providers: vec![],
                failures: vec![],
            });
        let view = snapshot(state, report.clone())
            .await
            .map_err(|_| "history_storage_unavailable")?;
        let resolved = view
            .accounts
            .iter()
            .find(|account| {
                account.id == id || account.sources.iter().any(|source| source.id == id)
            })
            .ok_or("account_not_found")?;
        if last_source_only && resolved.sources.len() > 1 {
            return Ok(());
        }
        let account = account_context(state, &view, &report, &resolved.id)
            .await
            .map_err(|_| "history_storage_unavailable")?;
        history
            .clear(Some(account), state.context.clock.now())
            .await
            .map_err(|_| "history_storage_unavailable")?;
    }
    Ok(())
}
