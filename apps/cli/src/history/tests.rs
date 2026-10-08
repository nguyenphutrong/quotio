use super::*;
fn at() -> OffsetDateTime {
    time::macros::datetime!(2026-10-05 12:00 UTC)
}
fn account() -> Account {
    Account {
        host_id: "host".into(),
        id: "account".into(),
        epoch: "epoch".into(),
        redirects: vec![],
        metrics: vec![Metric {
            id: "session".into(),
            display_name: "Session".into(),
            group: None,
            current: true,
            has_percentage: true,
        }],
    }
}
fn point(account: Account, at: OffsetDateTime, remaining: f64) -> Point {
    Point {
        metric: account.metrics[0].clone(),
        account,
        basis: "basis".into(),
        observation: Observation {
            series_id: String::new(),
            basis_id: String::new(),
            fetched_at: at,
            expires_at: Some(at + time::Duration::minutes(5)),
            quota: Quota::from_remaining(Some(remaining)),
            amounts: None,
            resets_at: None,
            reset_description: None,
            provenance: Provenance {
                source: "provider_api".into(),
                confidence: crate::domain::Confidence::Exact,
            },
        },
    }
}
async fn fixture() -> (History, PathBuf) {
    let dir = std::env::temp_dir().join(format!(
        "quotio-history-{}",
        crate::accounts::random_string().unwrap()
    ));
    let history = History::open(dir.join("quota.sqlite"), at()).await.unwrap();
    (history, dir)
}

#[tokio::test]
async fn percentage_history_remains_graphable_until_numeric_observations_expire() {
    let (history, directory) = fixture().await;
    let now = at();
    history
        .record(
            vec![point(account(), now - time::Duration::minutes(5), 70.0)],
            history.revision(),
            now,
        )
        .await
        .unwrap();
    let mut current = account();
    current.metrics[0].has_percentage = false;
    let mut unknown = point(current.clone(), now + time::Duration::minutes(1), 0.0);
    unknown.observation.quota = Quota::Unknown;
    unknown.basis = "nonnumeric".into();
    history
        .record(
            vec![unknown],
            history.revision(),
            now + time::Duration::minutes(1),
        )
        .await
        .unwrap();
    let catalog = history
        .catalog(current.clone(), true, now + time::Duration::minutes(2))
        .await
        .unwrap();
    assert!(
        catalog.metrics[0].has_percentage,
        "a current unknown value must not hide retained numeric history"
    );
    let chart = history
        .chart(
            current.clone(),
            "session".into(),
            "24h".into(),
            true,
            now + time::Duration::minutes(2),
        )
        .await
        .unwrap();
    assert_eq!(chart.lowest_remaining_percent, Some(70.0));
    assert!(matches!(chart.latest.unwrap().quota, Quota::Unknown));
    let expired = history
        .catalog(current, true, now + time::Duration::days(30))
        .await
        .unwrap();
    assert!(
        !expired.metrics[0].has_percentage,
        "unknown-only retained history must not invent percentage support"
    );
    drop(history);
    std::fs::remove_dir_all(directory).unwrap();
}
#[tokio::test]
async fn duplicates_keep_actual_time_conflicts_are_atomic_and_zero_is_not_gap() {
    let (h, dir) = fixture().await;
    let now = at();
    h.record(
        vec![point(account(), now - time::Duration::minutes(12), 0.0)],
        h.revision(),
        now,
    )
    .await
    .unwrap();
    h.record(
        vec![point(account(), now - time::Duration::minutes(12), 0.0)],
        h.revision(),
        now,
    )
    .await
    .unwrap();
    let error = h
        .record(
            vec![
                point(account(), now - time::Duration::minutes(4), 50.0),
                point(account(), now - time::Duration::minutes(12), 10.0),
            ],
            h.revision(),
            now,
        )
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Conflict));
    let chart = h
        .chart(account(), "session".into(), "24h".into(), true, now)
        .await
        .unwrap();
    assert_eq!(chart.bins.len(), 1);
    assert_eq!(chart.bins[0].sample_count, 1);
    assert_eq!(chart.bins[0].id, 357);
    assert_eq!(chart.lowest_remaining_percent, Some(0.0));
    assert!(chart.recording_error.is_some());
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn clear_rejects_inflight_and_cached_points_after_restart() {
    let (h, dir) = fixture().await;
    let now = at();
    let old = h.revision();
    h.record(
        vec![point(account(), now - time::Duration::seconds(1), 20.0)],
        old,
        now,
    )
    .await
    .unwrap();
    h.clear(Some(account()), now).await.unwrap();
    h.record(
        vec![point(account(), now + time::Duration::seconds(1), 80.0)],
        old,
        now + time::Duration::seconds(2),
    )
    .await
    .unwrap();
    drop(h);
    let h = History::open(dir.join("quota.sqlite"), now + time::Duration::seconds(2))
        .await
        .unwrap();
    h.record(
        vec![point(account(), now - time::Duration::seconds(1), 20.0)],
        h.revision(),
        now + time::Duration::seconds(2),
    )
    .await
    .unwrap();
    assert!(
        h.chart(
            account(),
            "session".into(),
            "24h".into(),
            true,
            now + time::Duration::seconds(2)
        )
        .await
        .unwrap()
        .bins
        .is_empty()
    );
    h.record(
        vec![point(account(), now + time::Duration::seconds(3), 70.0)],
        h.revision(),
        now + time::Duration::seconds(3),
    )
    .await
    .unwrap();
    assert_eq!(
        h.catalog(account(), true, now + time::Duration::seconds(3))
            .await
            .unwrap()
            .last_observed_at,
        Some(now + time::Duration::seconds(3))
    );
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn epochs_isolate_identity_and_confirmed_redirect_preserves_it() {
    let (h, dir) = fixture().await;
    let now = at();
    h.record(vec![point(account(), now, 50.0)], h.revision(), now)
        .await
        .unwrap();
    let mut other = account();
    other.epoch = "different-tenant".into();
    assert!(
        h.chart(other, "session".into(), "24h".into(), true, now)
            .await
            .unwrap()
            .bins
            .is_empty()
    );
    let mut redirected = account();
    redirected.id = "canonical".into();
    redirected.redirects = vec!["account".into()];
    h.record(
        vec![point(
            redirected.clone(),
            now + time::Duration::seconds(1),
            49.0,
        )],
        h.revision(),
        now + time::Duration::seconds(1),
    )
    .await
    .unwrap();
    assert_eq!(
        h.chart(
            redirected,
            "session".into(),
            "24h".into(),
            true,
            now + time::Duration::seconds(1)
        )
        .await
        .unwrap()
        .bins[0]
            .sample_count,
        2
    );
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn unknown_breaks_reset_inference_and_basis_events_preserve_points() {
    let (h, dir) = fixture().await;
    let now = at();
    let mut a = point(account(), now - time::Duration::minutes(3), 20.0);
    a.observation.resets_at = Some(now - time::Duration::minutes(2));
    let mut b = point(account(), now - time::Duration::minutes(1), 90.0);
    b.observation.resets_at = Some(now + time::Duration::days(1));
    h.record(vec![a, b], h.revision(), now).await.unwrap();
    let chart = h
        .chart(account(), "session".into(), "24h".into(), true, now)
        .await
        .unwrap();
    assert_eq!(chart.events[0].kind, "reset_inferred");
    assert_eq!(chart.bins.len(), 1);
    assert_eq!(chart.bins[0].min_remaining_percent, Some(20.0));
    let mut unknown = point(account(), now, 0.0);
    unknown.observation.quota = Quota::Unknown;
    let mut next = point(account(), now + time::Duration::seconds(1), 100.0);
    next.basis = "plan-changed".into();
    h.record(
        vec![unknown, next],
        h.revision(),
        now + time::Duration::seconds(1),
    )
    .await
    .unwrap();
    let chart = h
        .chart(
            account(),
            "session".into(),
            "24h".into(),
            true,
            now + time::Duration::seconds(1),
        )
        .await
        .unwrap();
    assert_eq!(chart.events.len(), 2);
    assert_eq!(chart.events[1].kind, "basis_changed");
    assert!(chart.bins[0].states.contains(&"unknown".into()));
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn event_pagination_freezes_endpoints_and_clear_invalidates_cursor() {
    let (h, dir) = fixture().await;
    let now = at();
    let points = (0..260)
        .map(|i| {
            let mut p = point(account(), now - time::Duration::seconds(300 - i), 50.0);
            p.basis = format!("basis-{i}");
            p
        })
        .collect();
    h.record(points, h.revision(), now).await.unwrap();
    let chart = h
        .chart(account(), "session".into(), "24h".into(), true, now)
        .await
        .unwrap();
    assert_eq!(chart.events.len(), 128);
    let first = chart.next_cursor.unwrap();
    let mut late = point(account(), now - time::Duration::seconds(500), 20.0);
    late.basis = "later-accepted-earlier-dated".into();
    h.record(vec![late], h.revision(), now).await.unwrap();
    let page = h
        .events(
            account(),
            "session".into(),
            "24h".into(),
            first,
            now + time::Duration::hours(1),
        )
        .await
        .unwrap();
    assert_eq!(page.events.len(), 128);
    let last = page.next_cursor.unwrap();
    let page = h
        .events(
            account(),
            "session".into(),
            "24h".into(),
            last,
            now + time::Duration::hours(1),
        )
        .await
        .unwrap();
    assert_eq!(page.events.len(), 3);
    assert!(page.next_cursor.is_none());
    let cursor = h
        .chart(account(), "session".into(), "24h".into(), true, now)
        .await
        .unwrap()
        .next_cursor
        .unwrap();
    h.clear(None, now).await.unwrap();
    assert!(matches!(
        h.events(account(), "session".into(), "24h".into(), cursor, now)
            .await,
        Err(Error::Cursor)
    ));
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn retention_runs_while_paused_and_histories_survive_restart() {
    let (h, dir) = fixture().await;
    let now = at();
    h.record(vec![point(account(), now, 40.0)], h.revision(), now)
        .await
        .unwrap();
    h.pause(now + time::Duration::seconds(1)).await.unwrap();
    drop(h);
    let h = History::open(dir.join("quota.sqlite"), now + time::Duration::days(1))
        .await
        .unwrap();
    assert_eq!(
        h.chart(
            account(),
            "session".into(),
            "30d".into(),
            false,
            now + time::Duration::days(1)
        )
        .await
        .unwrap()
        .bins
        .len(),
        1
    );
    drop(h);
    let h = History::open(dir.join("quota.sqlite"), now + time::Duration::days(31))
        .await
        .unwrap();
    assert!(
        h.catalog(account(), false, now + time::Duration::days(31))
            .await
            .unwrap()
            .first_observed_at
            .is_none()
    );
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}
#[tokio::test]
async fn clock_rollback_prevents_cross_boundary_reset() {
    let (h, dir) = fixture().await;
    let now = at();
    h.record(
        vec![
            point(account(), now, 20.0),
            point(account(), now - time::Duration::minutes(1), 90.0),
        ],
        h.revision(),
        now,
    )
    .await
    .unwrap();
    let chart = h
        .chart(account(), "session".into(), "24h".into(), true, now)
        .await
        .unwrap();
    assert_eq!(chart.events[0].kind, "clock_changed");
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}
#[cfg(unix)]
#[tokio::test]
async fn rejects_symlinks_and_uses_private_sidecars() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let (h, dir) = fixture().await;
    for name in ["quota.sqlite", "quota.sqlite-wal", "quota.sqlite-shm"] {
        assert_eq!(
            std::fs::metadata(dir.join(name))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    drop(h);
    symlink(dir.join("quota.sqlite"), dir.join("link.sqlite")).unwrap();
    assert!(History::open(dir.join("link.sqlite"), at()).await.is_err());
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn future_timestamp_marks_clock_without_numeric_bin_and_blocks_reset() {
    let (h, dir) = fixture().await;
    let now = at();
    let mut before = point(account(), now - time::Duration::minutes(2), 20.0);
    before.observation.resets_at = Some(now - time::Duration::minutes(1));
    h.record(vec![before], h.revision(), now - time::Duration::minutes(2))
        .await
        .unwrap();
    h.record(
        vec![point(account(), now + time::Duration::hours(1), 90.0)],
        h.revision(),
        now,
    )
    .await
    .unwrap();
    let mut after = point(account(), now + time::Duration::seconds(1), 100.0);
    after.observation.resets_at = Some(now + time::Duration::days(1));
    h.record(vec![after], h.revision(), now + time::Duration::seconds(1))
        .await
        .unwrap();
    let chart = h
        .chart(
            account(),
            "session".into(),
            "24h".into(),
            true,
            now + time::Duration::seconds(1),
        )
        .await
        .unwrap();
    assert_eq!(chart.bins.iter().map(|b| b.sample_count).sum::<u64>(), 2);
    assert_eq!(chart.events.len(), 1);
    assert_eq!(chart.events[0].kind, "clock_changed");
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn inferred_reset_can_cross_range_start_without_backfilling_a_bin() {
    let (h, dir) = fixture().await;
    let now = at();
    let mut before = point(
        account(),
        now - time::Duration::hours(24) - time::Duration::seconds(1),
        20.0,
    );
    before.observation.resets_at = Some(now - time::Duration::hours(24));
    let mut after = point(
        account(),
        now - time::Duration::hours(24) + time::Duration::seconds(1),
        100.0,
    );
    after.observation.resets_at = Some(now + time::Duration::days(1));
    h.record(vec![before, after], h.revision(), now)
        .await
        .unwrap();
    let chart = h
        .chart(account(), "session".into(), "24h".into(), true, now)
        .await
        .unwrap();
    assert_eq!(chart.bins.len(), 1);
    assert_eq!(chart.bins[0].sample_count, 1);
    assert_eq!(chart.events[0].kind, "reset_inferred");
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn future_duplicates_conflict_and_clock_only_metrics_remain_selectable() {
    let (h, dir) = fixture().await;
    let now = at();
    let future = now + time::Duration::hours(1);
    h.record(vec![point(account(), future, 20.0)], h.revision(), now)
        .await
        .unwrap();
    h.record(
        vec![point(account(), future, 20.0)],
        h.revision(),
        now + time::Duration::seconds(1),
    )
    .await
    .unwrap();
    assert!(matches!(
        h.record(
            vec![point(account(), future, 25.0)],
            h.revision(),
            now + time::Duration::seconds(1)
        )
        .await,
        Err(Error::Conflict)
    ));
    let mut historical = account();
    historical.metrics.clear();
    let chart = h
        .chart(
            historical,
            "session".into(),
            "24h".into(),
            true,
            now + time::Duration::seconds(1),
        )
        .await
        .unwrap();
    assert!(chart.bins.is_empty());
    assert_eq!(chart.events.len(), 1);
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn amount_only_disabled_unlimited_and_unknown_never_invent_percentage() {
    let (h, dir) = fixture().await;
    let now = at();
    let points = [
        Quota::Limit {
            amount: 12.0,
            unit: "credits".into(),
        },
        Quota::Disabled,
        Quota::Unlimited,
        Quota::Unknown,
    ]
    .into_iter()
    .enumerate()
    .map(|(i, quota)| {
        let mut point = point(account(), now - time::Duration::seconds(i as i64), 0.0);
        point.observation.quota = quota;
        point
    })
    .collect();
    h.record(points, h.revision(), now).await.unwrap();
    let chart = h
        .chart(account(), "session".into(), "24h".into(), true, now)
        .await
        .unwrap();
    assert_eq!(chart.lowest_remaining_percent, None);
    assert_eq!(chart.bins[0].min_remaining_percent, None);
    assert_eq!(chart.bins[0].max_remaining_percent, None);
    assert_eq!(chart.bins[0].states.len(), 4);
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn representative_account_volume_keeps_transport_bounded_and_isolated() {
    let (h, dir) = fixture().await;
    let now = at();
    let mut points = Vec::new();
    for id in 0..64 {
        let mut account = account();
        account.id = format!("account-{id}");
        for sample in 0..120 {
            points.push(point(
                account.clone(),
                now - time::Duration::minutes(sample * 10),
                id as f64,
            ));
        }
    }
    h.record(points, h.revision(), now).await.unwrap();
    let mut account = account();
    account.id = "account-63".into();
    let chart = h
        .chart(account, "session".into(), "24h".into(), true, now)
        .await
        .unwrap();
    assert!(chart.bins.len() <= 360);
    assert!(chart.events.len() <= 128);
    assert_eq!(chart.bins.iter().map(|b| b.sample_count).sum::<u64>(), 120);
    assert_eq!(chart.lowest_remaining_percent, Some(63.0));
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn pagination_get_is_replayable_and_wrong_identity_cannot_consume_cursor() {
    let (h, dir) = fixture().await;
    let now = at();
    let points = (0..260)
        .map(|i| {
            let mut p = point(account(), now - time::Duration::seconds(300 - i), 50.0);
            p.basis = format!("basis-{i}");
            p
        })
        .collect();
    h.record(points, h.revision(), now).await.unwrap();
    let cursor = h
        .chart(account(), "session".into(), "24h".into(), true, now)
        .await
        .unwrap()
        .next_cursor
        .unwrap();
    let mut wrong_host = account();
    wrong_host.host_id = "another-host".into();
    assert!(matches!(
        h.events(
            wrong_host,
            "session".into(),
            "24h".into(),
            cursor.clone(),
            now
        )
        .await,
        Err(Error::Cursor)
    ));
    let mut wrong = account();
    wrong.epoch = "wrong-epoch".into();
    assert!(matches!(
        h.events(wrong, "session".into(), "24h".into(), cursor.clone(), now)
            .await,
        Err(Error::Cursor)
    ));
    let first = h
        .events(
            account(),
            "session".into(),
            "24h".into(),
            cursor.clone(),
            now,
        )
        .await
        .unwrap();
    let mut late = point(account(), now - time::Duration::seconds(500), 10.0);
    late.basis = "new-basis".into();
    h.record(vec![late], h.revision(), now).await.unwrap();
    let replay = h
        .events(
            account(),
            "session".into(),
            "24h".into(),
            cursor.clone(),
            now + time::Duration::seconds(1),
        )
        .await
        .unwrap();
    assert_eq!(
        first.events.iter().map(|e| &e.id).collect::<Vec<_>>(),
        replay.events.iter().map(|e| &e.id).collect::<Vec<_>>()
    );
    assert_eq!(first.history_revision, replay.history_revision);
    h.clear(None, now).await.unwrap();
    assert!(matches!(
        h.events(account(), "session".into(), "24h".into(), cursor, now)
            .await,
        Err(Error::Cursor)
    ));
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn recording_error_survives_empty_or_rejected_batches_until_fresh_success() {
    let (h, dir) = fixture().await;
    let now = at();
    let fetched = now - time::Duration::seconds(2);
    h.record(vec![point(account(), fetched, 20.0)], h.revision(), now)
        .await
        .unwrap();
    assert!(matches!(
        h.record(vec![point(account(), fetched, 25.0)], h.revision(), now)
            .await,
        Err(Error::Conflict)
    ));
    let error = h
        .catalog(account(), true, now)
        .await
        .unwrap()
        .recording_error;
    assert!(error.is_some());
    h.record(vec![], h.revision(), now).await.unwrap();
    assert_eq!(
        h.catalog(account(), true, now)
            .await
            .unwrap()
            .recording_error,
        error
    );
    let old = h.revision();
    h.pause(now).await.unwrap();
    h.record(
        vec![point(account(), now + time::Duration::seconds(1), 30.0)],
        old,
        now + time::Duration::seconds(1),
    )
    .await
    .unwrap();
    assert_eq!(
        h.catalog(account(), false, now + time::Duration::seconds(1))
            .await
            .unwrap()
            .recording_error,
        error
    );
    drop(h);
    let h = History::open(dir.join("quota.sqlite"), now + time::Duration::seconds(1))
        .await
        .unwrap();
    h.record(vec![], h.revision(), now + time::Duration::seconds(1))
        .await
        .unwrap();
    assert_eq!(
        h.catalog(account(), true, now + time::Duration::seconds(1))
            .await
            .unwrap()
            .recording_error,
        error
    );
    let fresh = now + time::Duration::seconds(2);
    h.record(vec![point(account(), fresh, 30.0)], h.revision(), fresh)
        .await
        .unwrap();
    let catalog = h.catalog(account(), true, fresh).await.unwrap();
    assert!(catalog.recording_error.is_none());
    assert_eq!(catalog.last_observed_at, Some(fresh));
    drop(h);
    std::fs::remove_dir_all(dir).unwrap();
}
