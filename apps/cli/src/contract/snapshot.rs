//! Provider-neutral projection of collected observations onto resolved accounts.
use super::*;
use crate::domain::{AccountRef, ProviderUsage, UsageReport};
use crate::error::ProviderError;

pub(crate) fn external_id(provider: &str, reference: Option<&AccountRef>) -> String {
    format!(
        "external-{}",
        crate::cache::fingerprint(&[provider, reference.map_or("local", |r| r.id.as_str())])
    )
}

pub(crate) fn external_refresh_source<'a>(
    report: &'a UsageReport,
    provider: &str,
    id: &str,
) -> Option<&'a str> {
    report
        .providers
        .iter()
        .map(|usage| (&usage.provider, usage.account_ref.as_ref()))
        .chain(
            report
                .failures
                .iter()
                .map(|failure| (&failure.provider, failure.account_ref.as_ref())),
        )
        .find_map(|(provider_id, reference)| {
            (provider_id.0 == provider
                && reference.is_none_or(|r| {
                    r.id == "local" || r.origin == Some(AccountOrigin::BorrowedProxy)
                })
                && external_id(provider, reference) == id)
                .then(|| reference.map_or("local", |r| r.id.as_str()))
        })
}

fn reference_matches(provider: &str, reference: Option<&AccountRef>, source: &str) -> bool {
    reference.is_some_and(|reference| reference.id == source)
        || external_id(provider, reference) == source
}

fn same_provider_account(left: &ProviderUsage, right: &ProviderUsage) -> bool {
    if left.provider != right.provider {
        return false;
    }
    match (&left.account.verified, &right.account.verified) {
        (Some(left), Some(right)) => left == right,
        _ => false,
    }
}

fn external_source(id: String, reference: Option<&AccountRef>) -> Source {
    let borrowed_proxy = reference.is_some_and(|r| r.origin == Some(AccountOrigin::BorrowedProxy));
    Source {
        id,
        origin: reference
            .and_then(|reference| reference.origin)
            .unwrap_or(AccountOrigin::BorrowedNative),
        kind: if borrowed_proxy {
            "cli_proxy_auth_file"
        } else {
            "external_observation"
        }
        .into(),
        location: None,
        keychain_account: None,
        directory: None,
        enabled: true,
        selected: false,
        state: ConnectionState::NotChecked,
        refresh_owner: if borrowed_proxy {
            RefreshOwner::ProviderTool
        } else {
            RefreshOwner::None
        },
        issue: None,
        actions: Vec::new(),
    }
}

fn include_external(accounts: &mut Vec<Account>, report: &UsageReport) {
    for value in &report.providers {
        let provider = value.provider.0.as_str();
        let reference = value.account_ref.as_ref();
        if accounts.iter().any(|account| {
            account.provider_id == provider
                && account
                    .sources
                    .iter()
                    .any(|source| reference_matches(provider, reference, &source.id))
        }) {
            continue;
        }
        let registered = report.providers.iter().find_map(|candidate| {
            let reference = candidate.account_ref.as_ref()?;
            if reference.id == "local"
                || reference.origin == Some(AccountOrigin::BorrowedProxy)
                || !same_provider_account(value, candidate)
            {
                return None;
            }
            accounts.iter().position(|account| {
                account.provider_id == provider
                    && account
                        .sources
                        .iter()
                        .any(|source| reference_matches(provider, Some(reference), &source.id))
            })
        });
        let id = external_id(provider, reference);
        if let Some(index) = registered {
            accounts[index].sources.push(external_source(id, reference));
            continue;
        }
        // Registered source IDs absent from the current vault were unlinked. A late report
        // must not turn them back into unregistered accounts.
        if reference.is_some_and(|reference| {
            reference.id != "local" && reference.origin != Some(AccountOrigin::BorrowedProxy)
        }) {
            continue;
        }
        accounts.push(Account {
            id: id.clone(),
            provider_id: provider.into(),
            display_name: Some(value.account.label.as_str())
                .filter(|label| !label.trim().is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| format!("{provider} account")),
            user_label: None,
            identity: Identity {
                evidence: IdentityEvidence::Unknown,
                username: None,
                email: None,
            },
            enabled: true,
            active: false,
            state: ConnectionState::NotChecked,
            sources: vec![external_source(id, reference)],
            actions: Vec::new(),
        });
    }
    // These references came from discovered files/keys, not failed native login probes.
    for failure in &report.failures {
        let Some(reference) = failure
            .account_ref
            .as_ref()
            .filter(|reference| reference.origin == Some(AccountOrigin::BorrowedProxy))
        else {
            continue;
        };
        if accounts.iter().any(|account| {
            account.provider_id == failure.provider.0
                && account.sources.iter().any(|source| {
                    reference_matches(&failure.provider.0, Some(reference), &source.id)
                })
        }) {
            continue;
        }
        let id = external_id(&failure.provider.0, Some(reference));
        let enabled = failure.code != ProviderError::SourceDisabled;
        let mut source = external_source(id.clone(), Some(reference));
        source.enabled = enabled;
        accounts.push(Account {
            id,
            provider_id: failure.provider.0.clone(),
            display_name: reference.label.clone(),
            user_label: None,
            identity: Identity {
                evidence: IdentityEvidence::Unknown,
                username: None,
                email: None,
            },
            enabled,
            active: false,
            state: ConnectionState::NotChecked,
            sources: vec![source],
            actions: Vec::new(),
        });
    }
}

fn issue(code: ProviderError) -> Issue {
    let action = match code {
        ProviderError::Authentication => Some("sign_in"),
        ProviderError::OwnerRefreshRequired => Some("refresh_in_source_app"),
        ProviderError::CredentialStorage | ProviderError::LocalCredentialStorage => {
            Some("authorize")
        }
        ProviderError::Timeout
        | ProviderError::Transient
        | ProviderError::RateLimited
        | ProviderError::Cancelled => Some("retry"),
        _ => None,
    };
    Issue {
        code: serde_json::to_value(code)
            .expect("error code")
            .as_str()
            .expect("string code")
            .into(),
        retryable: matches!(
            code,
            ProviderError::Timeout
                | ProviderError::Transient
                | ProviderError::RateLimited
                | ProviderError::Cancelled
        ),
        action: action.map(|kind| Action {
            kind: kind.into(),
            available: true,
            reason: None,
            interaction: if kind == "retry" {
                InteractionLocation::Host
            } else {
                InteractionLocation::HostUser
            },
        }),
    }
}

fn state(code: ProviderError) -> ConnectionState {
    match code {
        ProviderError::Authentication | ProviderError::OwnerRefreshRequired => {
            ConnectionState::NeedsLogin
        }
        ProviderError::CredentialStorage | ProviderError::LocalCredentialStorage => {
            ConnectionState::NeedsAuthorization
        }
        ProviderError::SourceDisabled => ConnectionState::Disabled,
        _ => ConnectionState::Unavailable,
    }
}

pub(crate) fn metric_id(window: &crate::domain::QuotaWindow) -> String {
    window
        .metric_id
        .as_ref()
        .filter(|id| valid_id(id))
        .cloned()
        .unwrap_or_else(|| {
            crate::cache::fingerprint(&[
                "metric",
                window.metric_id.as_deref().unwrap_or(&window.label),
            ])
        })
}

fn plan_display_name(provider: &str, raw: &str) -> String {
    let normalized = raw.to_ascii_lowercase();
    let label = match (provider, normalized.as_str()) {
        ("codex", "pro") => "Pro 20x",
        ("codex", "prolite" | "pro_lite" | "pro-lite" | "pro lite") => "Pro 5x",
        ("openrouter", "openrouter-free") => "Free Tier",
        ("openrouter", "openrouter-pay-as-you-go") => "Pay as You Go",
        (_, "guest") => "Guest",
        (_, "free") => "Free",
        (_, "go") => "Go",
        (_, "plus") => "Plus",
        (_, "pro") => "Pro",
        (_, "free_workspace") => "Free Workspace",
        (_, "team") => "Team",
        (_, "business") => "Business",
        (_, "education") => "Education",
        (_, "quorum") => "Quorum",
        (_, "k12") => "K-12",
        (_, "enterprise") => "Enterprise",
        (_, "edu") => "Edu",
        _ => raw,
    };
    label.into()
}

/// Period length implied by labels that name it outright, for sources that
/// never state one. "Session" is not a period: its length varies by provider.
fn labeled_window_seconds(label: &str, resets_at: Option<OffsetDateTime>) -> Option<u64> {
    const HOUR: u64 = 60 * 60;
    let label = label.to_ascii_lowercase();
    let words: Vec<&str> = label
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|word| !word.is_empty())
        .collect();
    let has = |word: &str| words.contains(&word);
    if label.contains("5-hour") || label.contains("5 hour") || has("5h") {
        Some(5 * HOUR)
    } else if has("weekly") || label.contains("7-day") || label.contains("7 day") {
        Some(7 * 24 * HOUR)
    } else if has("daily") || has("1d") {
        Some(24 * HOUR)
    } else if has("monthly") {
        // A calendar month ends at the reset, so its length depends on which month it is.
        let reset = resets_at?;
        let (year, month) = match reset.month().previous() {
            time::Month::December => (reset.year() - 1, time::Month::December),
            previous => (reset.year(), previous),
        };
        let start = reset
            .replace_day(1)
            .ok()?
            .replace_year(year)
            .ok()?
            .replace_month(month)
            .ok()?;
        let start = start
            .replace_day(reset.day().min(month.length(year)))
            .ok()?;
        u64::try_from((reset - start).whole_seconds()).ok()
    } else {
        None
    }
}

fn observation(
    account_id: &str,
    value: &ProviderUsage,
    report: &UsageReport,
    now: OffsetDateTime,
    ttl: time::Duration,
    failure: Option<ProviderError>,
) -> Usage {
    // Plan-only successes are never cached. Their collection timestamp is the observation time.
    let fetched = value
        .windows
        .iter()
        .map(|window| window.fetched_at)
        .min()
        .unwrap_or(report.generated_at);
    let expires = fetched.checked_add(ttl);
    let stale = failure.is_some() || now < fetched || expires.is_none_or(|at| now >= at);
    let mut metrics: Vec<Metric> = value
        .windows
        .iter()
        .map(|window| {
            let group = metric_group(&value.provider.0, window);
            Metric {
                id: metric_id(window),
                group: group.map(|(group, _)| group.into()),
                display_name: group.map_or_else(
                    || metric_display_name(&value.provider.0, &window.label).into(),
                    |(_, name)| name.into(),
                ),
                note: window.note.clone(),
                quota: window.quota.clone(),
                amounts: window.amounts.clone(),
                consumption: window.consumption.clone(),
                resets_at: window.resets_at,
                reset_description: window.reset_description.clone(),
                window_seconds: window
                    .window_seconds
                    .or_else(|| labeled_window_seconds(&window.label, window.resets_at)),
                reset_precision: window.reset_precision,
                fetched_at: window.fetched_at,
                provenance: window.provenance.clone(),
            }
        })
        .collect();
    if value.provider.0 == "antigravity" {
        for (weekly_name, session_name) in
            [("Weekly", "Session"), ("Claude Weekly", "Claude Session")]
        {
            if metrics
                .iter()
                .any(|metric| metric.display_name == session_name)
            {
                continue;
            }
            if let Some(weekly) = metrics.iter().find(|metric| {
                metric.display_name == weekly_name
                    && matches!(metric.quota, Quota::Exhausted { .. })
            }) {
                let session = Metric {
                    id: crate::cache::fingerprint(&["antigravity_weekly_limit", &weekly.id]),
                    group: weekly.group.clone(),
                    display_name: session_name.into(),
                    note: None,
                    quota: Quota::from_remaining(Some(0.0)),
                    amounts: None,
                    consumption: None,
                    resets_at: None,
                    reset_description: None,
                    window_seconds: None,
                    reset_precision: None,
                    fetched_at: weekly.fetched_at,
                    provenance: Provenance {
                        source: "antigravity_weekly_limit".into(),
                        confidence: crate::domain::Confidence::Exact,
                    },
                };
                metrics.push(session);
            }
        }
    }
    if matches!(value.provider.0.as_str(), "antigravity" | "codex") {
        metrics.sort_by_key(|metric| match metric.display_name.as_str() {
            "Session" => 0,
            "Weekly" => 1,
            "Claude Session" | "Spark Session" => 2,
            "Claude Weekly" | "Spark Weekly" => 3,
            _ => 4,
        });
    }
    Usage {
        account_id: account_id.into(),
        freshness: if stale {
            Freshness::Stale
        } else {
            Freshness::Fresh
        },
        fetched_at: Some(fetched),
        expires_at: expires,
        plan: value
            .account
            .plan
            .as_deref()
            .map(|plan| plan_display_name(&value.provider.0, plan)),
        subscription_status: value.account.subscription_status.clone(),
        reset_credits: value
            .reset_credits
            .clone()
            .filter(|credits| !stale && credits.valid_at(now)),
        antigravity_subscription: value.antigravity_subscription.clone(),
        codex_profile: value.codex_profile.clone(),
        codex_reset_credits: value.codex_reset_credits.clone().filter(|_| !stale),
        summary: Some(super::summary::project(value)),
        metrics,
        issue: failure
            .or_else(|| value.diagnostics.first().map(|diagnostic| diagnostic.code))
            .map(issue),
    }
}

fn metric_display_name<'a>(provider: &str, label: &'a str) -> &'a str {
    match provider {
        "antigravity" => {
            let bucket = label.rsplit_once(' ').map_or(label, |(_, bucket)| bucket);
            match bucket {
                "gemini-5h" | "gemini-session" => "Session",
                "gemini-weekly" => "Weekly",
                "3p-5h" | "3p-session" => "Claude Session",
                "3p-weekly" => "Claude Weekly",
                "gemini-argon-weekly" | "gemini-argon-wtu-weekly" => "Argon Weekly",
                _ if bucket.eq_ignore_ascii_case("session") => {
                    if label.starts_with("Claude") {
                        "Claude Session"
                    } else if label.starts_with("Gemini") {
                        "Session"
                    } else {
                        label
                    }
                }
                _ if bucket.eq_ignore_ascii_case("weekly") => {
                    if label.starts_with("Claude") {
                        "Claude Weekly"
                    } else if label.starts_with("Gemini") {
                        "Weekly"
                    } else {
                        label
                    }
                }
                _ => label,
            }
        }
        "codex" => match label {
            "Codex Spark Session" => "Spark Session",
            "Codex Spark Weekly" => "Spark Weekly",
            _ => label,
        },
        _ => label,
    }
}

fn metric_group(
    provider: &str,
    window: &crate::domain::QuotaWindow,
) -> Option<(&'static str, &'static str)> {
    if provider != "factory" {
        return None;
    }
    let id = window.metric_id.as_deref()?;
    let (group, period) = if let Some(period) = id.strip_prefix("factory-standard-") {
        ("Standard", period)
    } else {
        ("Core", id.strip_prefix("factory-core-")?)
    };
    let name = match period {
        "five-hour" => "5 hours",
        "weekly" => "Weekly",
        "monthly" => "Monthly",
        _ => return None,
    };
    Some((group, name))
}

/// Resolve source health and choose one usable observation without combining quota balances.
/// Callers must fence the report against concurrent mutations before invoking this projection.
pub fn project(
    accounts: AccountList,
    report: &UsageReport,
    now: OffsetDateTime,
    ttl: time::Duration,
) -> Result<Snapshot, &'static str> {
    let mut snapshot = Snapshot {
        schema_version: 2,
        host: accounts.host,
        revision: accounts.revision,
        generated_at: now,
        accounts: accounts.accounts,
        usage: Vec::new(),
        provider_issues: BTreeMap::new(),
        account_redirects: accounts.account_redirects,
    };
    include_external(&mut snapshot.accounts, report);
    for failure in &report.failures {
        let reference = failure.account_ref.as_ref();
        if reference.is_none_or(|reference| {
            reference.id == "local" || reference.origin == Some(AccountOrigin::BorrowedProxy)
        }) && !snapshot.accounts.iter().any(|account| {
            account.provider_id == failure.provider.0
                && account
                    .sources
                    .iter()
                    .any(|source| reference_matches(&failure.provider.0, reference, &source.id))
        }) {
            snapshot
                .provider_issues
                .entry(failure.provider.0.clone())
                .or_insert_with(|| issue(failure.code));
        }
    }
    for account in &mut snapshot.accounts {
        let mut choices = Vec::new();
        for source in &mut account.sources {
            source.selected = false;
            if !account.enabled || !source.enabled {
                source.state = ConnectionState::Disabled;
                source.issue = None;
                continue;
            }
            let value = report.providers.iter().find(|value| {
                value.provider.0 == account.provider_id
                    && reference_matches(
                        &account.provider_id,
                        value.account_ref.as_ref(),
                        &source.id,
                    )
            });
            let failure = report
                .failures
                .iter()
                .find(|failure| {
                    failure.provider.0 == account.provider_id
                        && reference_matches(
                            &account.provider_id,
                            failure.account_ref.as_ref(),
                            &source.id,
                        )
                        && !value.is_some_and(|value| {
                            value
                                .diagnostics
                                .iter()
                                .any(|diagnostic| diagnostic.code == failure.code)
                        })
                })
                .map(|failure| failure.code);
            source.issue = failure
                .or_else(|| {
                    value.and_then(|value| {
                        value.diagnostics.first().map(|diagnostic| diagnostic.code)
                    })
                })
                .map(issue);
            source.state = failure.map(state).unwrap_or(if value.is_some() {
                ConnectionState::Ready
            } else {
                ConnectionState::NotChecked
            });
            if let Some(value) = value {
                choices.push((
                    source.id.clone(),
                    source.origin,
                    observation(&account.id, value, report, now, ttl, failure),
                ));
            }
        }
        choices.sort_by(|a, b| {
            let rank = |entry: &(String, AccountOrigin, Usage)| {
                (
                    entry.2.freshness != Freshness::Fresh,
                    entry.2.issue.is_some(),
                    entry.1 != AccountOrigin::Owned,
                )
            };
            rank(a)
                .cmp(&rank(b))
                .then_with(|| b.2.fetched_at.cmp(&a.2.fetched_at))
                .then_with(|| a.0.cmp(&b.0))
        });
        if let Some((selected, _, usage)) = choices.into_iter().next() {
            let source = account
                .sources
                .iter_mut()
                .find(|source| source.id == selected)
                .expect("projected source");
            source.selected = true;
            account.state = source.state;
            snapshot.usage.push(usage);
        } else {
            account.state = if !account.enabled {
                ConnectionState::Disabled
            } else {
                account
                    .sources
                    .iter()
                    .filter(|source| source.enabled)
                    .find(|source| source.issue.is_some())
                    .map_or(ConnectionState::NotChecked, |source| source.state)
            };
            let source_issue = account
                .sources
                .iter()
                .filter(|source| source.enabled)
                .find_map(|source| source.issue.clone());
            snapshot.usage.push(Usage {
                account_id: account.id.clone(),
                freshness: if source_issue.is_some() {
                    Freshness::Unavailable
                } else {
                    Freshness::NotLoaded
                },
                fetched_at: None,
                expires_at: None,
                plan: None,
                subscription_status: None,
                reset_credits: None,
                antigravity_subscription: None,
                codex_profile: None,
                codex_reset_credits: None,
                metrics: Vec::new(),
                summary: None,
                issue: source_issue,
            });
        }
    }
    snapshot.validate()?;
    Ok(snapshot)
}

pub fn digest(snapshot: &Snapshot) -> Result<String, crate::accounts::AccountError> {
    let content = serde_json::to_string(&(
        &snapshot.host,
        &snapshot.accounts,
        &snapshot.usage,
        &snapshot.provider_issues,
        &snapshot.account_redirects,
    ))
    .map_err(|_| crate::accounts::AccountError::Snapshot)?;
    Ok(crate::cache::fingerprint(&[&content]))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn antigravity_exhausted_weekly_fills_only_missing_sessions() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../../tests/fixtures/contracts/usage-v1.json"))
                .unwrap();
        let mut report = UsageReport {
            schema_version: 1,
            generated_at: OffsetDateTime::UNIX_EPOCH,
            providers: vec![serde_json::from_value(fixture["providers"][0].clone()).unwrap()],
            failures: vec![],
        };
        report.providers[0].provider.0 = "antigravity".into();
        let original = report.providers[0].windows[0].clone();
        for (weekly_label, session_name) in [
            ("gemini-weekly", "Session"),
            ("3p-weekly", "Claude Session"),
        ] {
            for weekly_quota in [
                Quota::from_remaining(Some(0.0)),
                Quota::from_remaining(Some(0.1)),
                Quota::from_remaining(Some(100.0)),
                Quota::Unknown,
                Quota::Disabled,
                Quota::Unlimited,
            ] {
                let mut weekly = original.clone();
                weekly.label = weekly_label.into();
                weekly.quota = weekly_quota.clone();
                weekly.resets_at = Some(OffsetDateTime::UNIX_EPOCH + time::Duration::days(7));
                report.providers[0].windows = vec![weekly];
                let usage = observation(
                    "account",
                    &report.providers[0],
                    &report,
                    report.generated_at,
                    time::Duration::hours(1),
                    None,
                );
                let session = usage
                    .metrics
                    .iter()
                    .find(|metric| metric.display_name == session_name);
                if matches!(weekly_quota, Quota::Exhausted { .. }) {
                    let session = session.unwrap();
                    assert_eq!(session.quota, Quota::from_remaining(Some(0.0)));
                    assert!(session.resets_at.is_none());
                    assert!(session.reset_description.is_none());
                    assert!(session.amounts.is_none());
                    assert!(session.consumption.is_none());
                    assert_eq!(usage.metrics[0].display_name, session_name);
                    assert_eq!(usage.metrics[1].quota, weekly_quota);
                } else {
                    assert!(session.is_none());
                }
            }
        }
        report.providers[0].windows = ["gemini-weekly", "3p-weekly"]
            .iter()
            .map(|label| {
                let mut window = original.clone();
                window.label = (*label).into();
                window.quota = Quota::from_remaining(Some(0.0));
                window
            })
            .collect();
        let usage = observation(
            "account",
            &report.providers[0],
            &report,
            report.generated_at,
            time::Duration::hours(1),
            None,
        );
        assert_eq!(
            usage
                .metrics
                .iter()
                .map(|metric| metric.display_name.as_str())
                .collect::<Vec<_>>(),
            ["Session", "Weekly", "Claude Session", "Claude Weekly"]
        );
        let mut session = original;
        session.label = "3p-session".into();
        session.quota = Quota::from_remaining(Some(45.0));
        report.providers[0].windows.push(session.clone());
        let usage = observation(
            "account",
            &report.providers[0],
            &report,
            report.generated_at,
            time::Duration::hours(1),
            None,
        );
        let sessions: Vec<_> = usage
            .metrics
            .iter()
            .filter(|metric| metric.display_name == "Claude Session")
            .collect();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].id, metric_id(&session));
        assert_eq!(sessions[0].quota, session.quota);
        assert_eq!(sessions[0].resets_at, session.resets_at);
        report.providers[0].provider.0 = "codex".into();
        report.providers[0].windows.truncate(1);
        report.providers[0].windows[0].label = "Weekly".into();
        let usage = observation(
            "account",
            &report.providers[0],
            &report,
            report.generated_at,
            time::Duration::hours(1),
            None,
        );
        assert_eq!(
            usage
                .metrics
                .iter()
                .map(|metric| metric.display_name.as_str())
                .collect::<Vec<_>>(),
            ["Weekly"]
        );
    }

    #[test]
    fn quota_labels_are_projected_in_period_order_without_changing_observations() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../../tests/fixtures/contracts/usage-v1.json"))
                .unwrap();
        let report = UsageReport {
            schema_version: 1,
            generated_at: OffsetDateTime::UNIX_EPOCH,
            providers: vec![serde_json::from_value(fixture["providers"][0].clone()).unwrap()],
            failures: vec![],
        };
        for (provider, labels, expected) in [
            (
                "antigravity",
                vec![
                    "Claude and GPT models 3p-weekly",
                    "Gemini Models gemini-weekly",
                    "Gemini Models gemini-5h",
                    "Gemini 4 Argon gemini-argon-wtu-weekly",
                ],
                vec!["Session", "Weekly", "Claude Weekly", "Argon Weekly"],
            ),
            (
                "antigravity",
                vec!["3p-session", "gemini-weekly", "gemini-session", "3p-weekly"],
                vec!["Session", "Weekly", "Claude Session", "Claude Weekly"],
            ),
            (
                "codex",
                vec!["Codex Spark Weekly", "Weekly", "Codex Spark Session"],
                vec!["Weekly", "Spark Session", "Spark Weekly"],
            ),
        ] {
            let mut value = report.providers[0].clone();
            value.provider.0 = provider.into();
            let original = value.windows[0].clone();
            value.windows = labels
                .iter()
                .map(|label| {
                    let mut window = original.clone();
                    window.label = (*label).into();
                    window.quota =
                        crate::domain::Quota::from_remaining(Some(if label.contains("3p") {
                            20.0
                        } else {
                            99.0
                        }));
                    window
                })
                .collect();
            let usage = observation(
                "account",
                &value,
                &report,
                report.generated_at,
                time::Duration::hours(1),
                None,
            );
            assert_eq!(
                usage
                    .metrics
                    .iter()
                    .map(|metric| metric.display_name.as_str())
                    .collect::<Vec<_>>(),
                expected
            );
            for metric in &usage.metrics {
                let window = value
                    .windows
                    .iter()
                    .find(|window| metric_id(window) == metric.id)
                    .unwrap();
                assert_eq!(metric.quota, window.quota);
                assert_eq!(metric.resets_at, window.resets_at);
                assert_eq!(metric.provenance.source, window.provenance.source);
            }
            value.windows = vec![original.clone()];
            value.windows[0].label = "Future window".into();
            let usage = observation(
                "account",
                &value,
                &report,
                report.generated_at,
                time::Duration::hours(1),
                None,
            );
            assert_eq!(usage.metrics[0].display_name, "Future window");
            value.windows.clear();
            assert!(
                observation(
                    "account",
                    &value,
                    &report,
                    report.generated_at,
                    time::Duration::hours(1),
                    None
                )
                .metrics
                .is_empty()
            );
        }
    }

    #[test]
    fn factory_limits_have_host_groups_and_short_period_names() {
        let report: serde_json::Value =
            serde_json::from_str(include_str!("../../tests/fixtures/contracts/usage-v1.json"))
                .unwrap();
        let mut parsed: crate::domain::QuotaWindow =
            serde_json::from_value(report["providers"][0]["windows"][0].clone()).unwrap();
        let window = &mut parsed;
        for (pool, group) in [("standard", "Standard"), ("core", "Core")] {
            for (period, name) in [
                ("five-hour", "5 hours"),
                ("weekly", "Weekly"),
                ("monthly", "Monthly"),
            ] {
                window.metric_id = Some(format!("factory-{pool}-{period}"));
                assert_eq!(metric_group("factory", window), Some((group, name)));
                assert_eq!(metric_group("future", window), None);
            }
        }
        window.metric_id = Some("factory-extra-balance".into());
        assert_eq!(metric_group("factory", window), None);
    }
    #[test]
    fn plan_labels_preserve_provider_specific_and_unknown_names() {
        for (provider, raw, expected) in [
            ("codex", "pro", "Pro 20x"),
            ("codex", "pro_lite", "Pro 5x"),
            ("claude", "pro", "Pro"),
            ("openrouter", "openrouter-free", "Free Tier"),
            ("future", "Custom CBP Plan 2x", "Custom CBP Plan 2x"),
            ("factory", "standard", "standard"),
        ] {
            assert_eq!(plan_display_name(provider, raw), expected);
        }
    }
}
