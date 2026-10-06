# Account quota timeline implementation plan

## Context

Implemented [PRODUCT.md](PRODUCT.md) in the SwiftUI macOS app and Rust host. The sections below preserve the agreed design; the implementation and verification record follows the frozen transport contract.

Research baseline: `71f427f7488e592406104d98936ff142000383d7`. References describe this checkout; re-read the relevant sections before implementation if the branch changes.

- [`apps/cli/src/domain.rs:44-157`](https://github.com/nguyenphutrong/quotio/blob/71f427f7488e592406104d98936ff142000383d7/apps/cli/src/domain.rs#L44-L157) defines percentage/unknown/unlimited/disabled/limit states and quota windows with metric IDs, reset information, provenance, and fetch timestamps.
- [`apps/cli/src/cache.rs:63-121`](https://github.com/nguyenphutrong/quotio/blob/71f427f7488e592406104d98936ff142000383d7/apps/cli/src/cache.rs#L63-L121) stores the latest normalized observation, not a time series. Cache identity is credential-sensitive, so its filename fingerprint is not a durable account history key.
- [`apps/cli/src/server.rs:739-943`](https://github.com/nguyenphutrong/quotio/blob/71f427f7488e592406104d98936ff142000383d7/apps/cli/src/server.rs#L739-L943) collects usage, rejects changed generations under the account mutation guard, and merges the requested scope. Record from this accepted observation path, not from an HTTP snapshot GET or SwiftUI update.
- [`apps/cli/src/contract/snapshot.rs:234-311`](https://github.com/nguyenphutrong/quotio/blob/71f427f7488e592406104d98936ff142000383d7/apps/cli/src/contract/snapshot.rs#L234-L311) derives metric IDs and projects observations. [`apps/cli/src/contract.rs`](https://github.com/nguyenphutrong/quotio/blob/71f427f7488e592406104d98936ff142000383d7/apps/cli/src/contract.rs) already carries resolved account IDs and redirects. Reuse these contracts.
- [`apps/cli/src/server.rs:470-557`](https://github.com/nguyenphutrong/quotio/blob/71f427f7488e592406104d98936ff142000383d7/apps/cli/src/server.rs#L470-L557) uses a session-scoped host identity in `--no-saved-accounts` mode. Do not pretend this mode has stable persistent history.
- [`apps/cli/src/server/security.rs:303-311`](https://github.com/nguyenphutrong/quotio/blob/71f427f7488e592406104d98936ff142000383d7/apps/cli/src/server/security.rs#L303-L311) restricts delegated reads and rejects query strings. New history routes must not bypass either rule.
- [`Packages/QuotioHostClient/Sources/QuotioHostClient/QuotioHostHTTPClient.swift:107-149`](https://github.com/nguyenphutrong/quotio/blob/71f427f7488e592406104d98936ff142000383d7/Packages/QuotioHostClient/Sources/QuotioHostClient/QuotioHostHTTPClient.swift#L107-L149) handles authenticated requests and currently builds URLs with `appendingPathComponent`. Range parameters will live in route paths, so no general query-support cutover is necessary.
- [`Packages/QuotioCore/Sources/QuotioInfrastructure/QuotioCLI/QuotioHostPresentationMapper.swift:14-108`](https://github.com/nguyenphutrong/quotio/blob/71f427f7488e592406104d98936ff142000383d7/Packages/QuotioCore/Sources/QuotioInfrastructure/QuotioCLI/QuotioHostPresentationMapper.swift#L14-L108) maps canonical host IDs and account redirects into app quota state.
- [`Packages/QuotioCore/Sources/QuotioPresentation/Quota/ProviderQuotaView.swift:38-81`](https://github.com/nguyenphutrong/quotio/blob/71f427f7488e592406104d98936ff142000383d7/Packages/QuotioCore/Sources/QuotioPresentation/Quota/ProviderQuotaView.swift#L38-L81) renders per-account cards. Its `AccountQuotaCardV2` is the history sheet entry point.

The researched Rust package had no SQLite crate. The implementation adds bundled `rusqlite` 0.37 and its locked SQLite dependency without updating unrelated locked packages. `apps/gpui` was empty at the research baseline; this feature does not depend on the previous GPUI handoff.

## Proposed changes

### 1. Agree the data contract and series identity

Add a small `history` module under `apps/cli/src` for history values, persistence, and time-bin queries. Keep account resolution in the existing account modules; do not add a second account registry.

A series key comprises the persisted host identity, provider ID, resolved account ID, metric ID, and an opaque identity/basis epoch. A point contains the metric's actual `fetched_at`, typed quota state, optional normalized amount/limit/unit, reset timestamp or description, provenance, observation validity deadline, and a basis fingerprint. Never use localized labels, email, access tokens, credential-derived cache filenames, or array positions as series identity.

- Reuse `contract::snapshot::metric_id`. The existing fallback hashes a raw provider label when no provider metric ID exists. Treat a fallback label change as a separate metric; do not introduce fuzzy matching. If a provider's ID embeds a changing reset date, stabilize that adapter's semantic ID and migrate every affected caller before recording its history.
- Reuse canonical resolved account IDs and verified tenant-aware identity. Apply only resolver-confirmed redirects. A different verified identity gets a different epoch. For unverified sources, a changed credential/source identity starts an isolated epoch unless the resolver proves continuity. Use credential-sensitive checks transiently; never persist their credential-derived digest. Ordinary token refresh with confirmed verified identity preserves history.
- If the plan, limit, unit, or interpretation changes, close the comparable basis interval. Source/provenance changes are retained and treated conservatively when they alter comparability. History remains visible for the same authorized identity, with a boundary marker.
- Deduplicate by series epoch and actual observation timestamp. An identical repeated point is ignored. Conflicting data with the same timestamp is a typed recording error, not silent replacement. Unknown/disabled/unlimited states are retained as nonnumeric observations.
- Store raw observations first. Infer reset intervals and quota increases from adjacent observations at query time. A passed reset timestamp alone is not evidence of a reset. Preserve before/after points for events even when both fall into one visual bin.

### 2. Persist on the Rust host

Use `rusqlite` with bundled SQLite, pinned in `Cargo.lock`, subject to Rust 1.88 compatibility. A local indexed database fits range reads, pruning, and transactional account clearing. JSON cache overwrites cannot provide those guarantees; a second Swift database would split history ownership.

Create a private database in persistent application data, scoped to the existing account-storage namespace and persisted host identity. Do not place it in `usage-v1`, the credential vault, a provider source directory, or a user-selected cache directory.

Proposed tables:

- `history_series`: opaque series ID, host/provider/account/metric IDs, identity epoch, sanitized metric display metadata, active basis metadata, and creation time.
- `history_observations`: series ID, UTC fetch timestamp, typed quota payload fields, optional amount/limit/unit, resets-at/reset-description, provenance, validity deadline, and basis fingerprint. Unique index on series ID plus fetch timestamp; range index on the same ordered keys. Foreign-key deletion removes dependent observations.
- `history_recording_state`: durable recording/clear revision, sanitized last recording error, and clear cutoffs needed to reject cached pre-clear observations after a restart.

Use prepared statements and one transaction per accepted refresh batch. Put synchronous SQLite work on a dedicated bounded blocking worker, not a Tokio runtime thread or the Swift main actor. Enable foreign keys, WAL, and bounded busy handling. Protect the database directory and files with the repository's private-file conventions, including sidecar files and symlink checks. Database migrations use `user_version` and transactions; do not migrate the latest cache into invented history.

Retain raw observations for 30 days without introducing a rollup database. Prune on startup and at most once per day using the time index and bounded batches. Query only the requested account/metric/range. Storage volume depends on existing fetch cadence and account count, so validate the database with a representative high-account fixture before shipping.

### 3. Record only accepted observations

Integrate with `server::collect_usage` after its generation check and canonical account resolution. Capture the new request's observation scope before merging, so the recorder never re-stamps retained observations from unrelated providers.

- Cache restoration never writes history. An existing cached point delivered during a refresh can only be deduplicated at its original timestamp, not stamped with `generated_at`.
- Failed fetches and stale fallback observations do not produce new numeric points. A successful fresh metric in a partial response may be recorded if that metric is independently valid. Provider-supplied estimates remain estimates.
- Preserve the existing refresh schedule and cache TTL. No chart-driven provider requests.
- Resolve identity and decide recording eligibility under the existing account mutation guard. The recording batch carries the account generation and history revision. Clear, pause, and account-removal operations use the same ordering and prevent older queued batches from committing afterward.
- A clear stores a durable cutoff so cache restoration or a pre-clear cached observation cannot repopulate deleted history after restart. A new observation must postdate the cutoff. Account removal purges the relevant series and prevents late completion from recreating them.
- If quota refresh succeeds but history persistence fails, publish the live quota normally and expose a history recording error. Do not report current quota refresh as failed merely because its history could not be stored. Clearing history, however, must report failure if persistence is uncertain.
- With `--no-saved-accounts`, expose history as unavailable and do not initialize a persistent history database.

### 4. Add owner-only HTTP routes and settings

Add `quota_history` and `quota_history_write` availability capabilities with explicit reasons. History reads require an authenticated owner. Writes also require existing management permission. Do not add these routes to the paired client's `public_read` allowlist or permit anonymous history reads.

Proposed routes use fixed path values rather than query strings:

| Route | Contract |
| --- | --- |
| `GET /v2/accounts/{account_id}/quota-history` | Metric catalog for the current identity, recording state, retained range, and sanitized recording error. Include historical-only metrics. |
| `GET /v2/accounts/{account_id}/quota-history/{metric_id}/{range}` | `range` is `24h`, `7d`, or `30d`; returns bins, events, and observed summaries. |
| `GET /v2/accounts/{account_id}/quota-history/{metric_id}/{range}/events/{cursor}` | Read the next page of events using an opaque cursor bound to the identity epoch and fixed range endpoints. |
| `DELETE /v2/accounts/{account_id}/quota-history` | Atomically clear the current account's retained history, advance the recording revision, and set its cutoff. |
| `DELETE /v2/quota-history` | Clear host history with the same ordering guarantees. |

Responses are versioned and include host/account/metric IDs, series/basis boundaries, UTC range endpoints, history revision, and actual observation timestamps. Validate identifiers, reject unsupported ranges, and resolve authorized account redirects. Unknown or removed account IDs must not reveal retained records for a previous identity.

Return at most 360 regular time bins per selected metric. Bin widths are 4 minutes for 24h, 28 minutes for 7d, and 2 hours for 30d. Anchor bins at the query end minus the range duration. Each nonempty bin carries first/last observation times, latest value, numeric min/max, count, observed states, and boundary/event summaries. A bin is not a claim of complete coverage. Return at most 128 detailed events per page, with a next cursor when additional events exist. Event pagination keeps the initial range endpoints fixed and rejects a cursor after an identity change or history clear. Do not silently truncate events or average across a basis boundary.

Use UTC for storage, comparisons, and elapsed ranges. The client uses the user's timezone for tick/tooltip labels. DST changes cannot duplicate observations or change the duration of a range. On clock rollback or future-dated observations, mark a clock discontinuity and refuse cross-boundary reset inference.

Add `quota_history_enabled` to the existing Config, SettingsPatch, and native bootstrap preference flow, default true. Keep config migration additive and preserve existing supported setting values and defaults. Pausing advances the history recording revision without stopping current quota monitoring. Retention remains 30 days even while paused. Keep snapshot schema version 2 and existing usage output unchanged; update OpenAPI, client validators, fixtures, capability handling, `apps/cli/docs/host-contract-v2.md`, and `apps/cli/docs/local-http-api.md` together.

### 5. Connect the Swift app and render the sheet

- `Packages/QuotioHostClient`: add versioned history DTOs, validated response decoding, range enum, and typed request methods. Build history paths from validated opaque IDs. Keep TLS pinning, no-redirect behavior, and authorization unchanged.
- `QuotioDomain/Quota`: add Sendable history values for bins, observation states, confidence, and boundary events. Use the existing account and metric IDs, without coupling to SwiftUI or HTTP.
- `QuotioApplication/Quota`: add a `QuotaHistoryReading` port and history/recording management use cases. Derive capabilities from the active host, not from assumptions about provider support.
- `QuotioInfrastructure/QuotioCLI`: implement the port through the existing host connection and map transport DTOs to domain values. No SQLite or file persistence in Swift.
- `QuotioPresentation/Quota`: add an observable `QuotaHistoryScreenModel` and `QuotaHistorySheet`. Keep request IDs and host/selection identity so out-of-order responses cannot overwrite a newer selection. Cancel reads when dismissed or when hosts change. Reload history after relevant accepted quota updates, without adding a provider refresh or a permanent view-owned timer.
- `ProviderQuotaView.swift`: add the account history action and pass its canonical host account ID. Keep the existing account controls intact.
- `QuotioPresentation/Settings/QuotaDisplaySettingsSection.swift`: add recording toggle, clear-all confirmation, and storage error state alongside the existing quota preferences. The detail sheet owns clear-account confirmation. Compose the concrete reader/use cases in `apps/macos/Quotio/App/CompositionRoot.swift`.
- Use Swift Charts `RectangleMark` with explicit time bounds and yStart:0/yEnd:quota for baseline-anchored vertical columns, plus a visible 0% `PointMark` and a distinct unknown-state square. Scale x by time, not sample index. Use a stable chart height, percentage y-axis, native pickers, keyboard selection, and VoiceOver descriptions. Do not use smoothing or decorative chart animation across gaps.
- Reuse the existing display preference and quota color policy. Extract the current file-private policy only if the chart cannot reuse it directly; avoid another set of thresholds. Put all copy in `apps/macos/Quotio/Localizable.xcstrings`, keeping en/fr/vi/zh-Hans aligned. Respect sensitive-information masking.

## Testing and validation

Keep deterministic tests for consumer-visible invariants. Do not test source text, DTO copies, or view wiring.

| Product behavior | Verification |
| --- | --- |
| 2-5, 11-13, 17-18 | Domain/query cases for separate metrics, known 0%/100%, unknown states, confidence, latest-not-average bins, remaining/used conversion, and observed-only extrema. |
| 6-10, 22, 25 | Host/store tests for duplicate cache delivery, stale/error rejection, recording with no UI, restart durability, 30-day pruning, empty bins, and live quota surviving a storage failure. |
| 14-16 | Reset inference cases for scheduled passage without refill, rolling refill without reset evidence, advancing reset with refill, estimated/reset-description-only data, multiple events per bin, plan changes, and clock rollback. |
| 23-24 | Presentation request-order tests for range/metric/host changes and capability/error transitions. Manually exercise disconnect and reconnect. |
| 26-29 | Persistence/concurrency cases for pause/resume, alias rename, verified redirect, tenant separation, unverified identity replacement, clear during fetch, clear then restart/cache delivery, and account removal during fetch. |
| 30-31 | HTTP tests denying anonymous/delegated history access and removed IDs; capability test for no-saved mode; inspect persisted fixture records for absence of credential and identity payloads. |
| 1, 9, 19-21, 27 | Actual macOS UI inspection for sheet open/close, hover/click/keyboard selection, 0% mark, empty/error states, clear confirmation, VoiceOver, masking, light/dark, contrast, and narrow layout. |

Smoke proof must exercise the real host and app, not only tests. Start an isolated host with the existing mock provider and a temporary configuration/data namespace, fetch a known observation, read its history endpoint, refresh from cache, and verify the count has not increased. Restart and verify persistence. Clear while a deliberately delayed fixture fetch is pending and verify that the deleted interval stays empty. Use a throwaway varying fixture to exercise decrease, recovery, reset evidence, and gaps; remove that fixture after verification.

Build and run the macOS app against that isolated host. Capture remaining-mode and used-mode screenshots with the same known data, plus a gap and 0% example. Then inspect at least one real supported account if available. Lack of provider credentials does not block fixture acceptance but must be reported as a live-provider verification limit. Do not expose real account labels in screenshots.

Run changed Rust behavior tests, then `cargo test --manifest-path apps/cli/Cargo.toml --locked --all-features`. Run `swift test --package-path Packages/QuotioHostClient` and `swift test --package-path Packages/QuotioCore`, architecture checks, and the relevant Xcode integration tests for composition/lifecycle changes. Documentation-only planning does not require these builds. Implementation must finish the smoke proof, localization, contract docs, and removal of throwaway fixtures before delivery.

## Implementation sequence and parallelization

1. Establish series identity, basis boundaries, route DTOs, capability rules, and clear/pause ordering first. This shared contract is a sequential prerequisite.
2. Implement host persistence/recording and the Swift consumer in parallel once the contract is frozen. Swift work must use the agreed fixtures until the real host is ready, then switch to the actual host for smoke proof.
3. Integrate owner permissions, settings/bootstrap, macOS composition, and account lifecycle handling. The integration owner resolves any cross-layer contract change and updates both implementations together.
4. Run the behavior tests and real host/app scenarios above. Update existing contract documentation and localized copy as part of the same implementation.

For a parallel implementation, use two local agents in separate worktrees from the same agreed contract commit:

| Agent | Branch and worktree | Ownership |
| --- | --- | --- |
| Host history | `feat/quota-timeline-host`, `../quotio-quota-timeline-host` | Rust history module, recording/settings/account integration, Rust API schemas/fixtures, and host contract docs. Local mode supports the actual binary and filesystem tests. |
| macOS timeline | `feat/quota-timeline-macos`, `../quotio-quota-timeline-macos` | QuotioHostClient DTOs, Swift ports/adapter/model/sheet, macOS composition/settings/localizations, and Swift tests. Local mode is required for Xcode and native UI inspection. |

The coordinating agent owns these specs and the final integration on the current branch. Agents exchange contract changes before altering DTOs or permission rules. Land both branches as one feature PR after host-to-app smoke proof; do not ship a UI backed only by fixtures or a storage-only feature without the sheet.

## Risks and decisions

- Sampling is incomplete by design. The chart represents provider observations, not a billing ledger or a reconstruction of usage while offline.
- History is sensitive even without tokens. Owner-only routes avoid exposing old activity through the existing paired snapshot permission. An iPhone history feature requires its own access review and UI plan.
- Credential cache identity is not account identity. Reusing it would fragment history on token rotation or join different logins under a filename. Canonical identity plus conservative epochs prevents that shortcut.
- Clear/delete concurrency crosses SQLite and account-storage boundaries. Persist cutoffs and revisions, use the existing mutation ordering, and report uncertain clearing instead of returning false success.
- Retention does not guarantee a fixed database size. Measure range-read latency and disk usage with 100 accounts, multiple metrics, and the repository's supported refresh cadence. If raw storage is unsuitable, revise the product retention/aggregation contract explicitly before introducing rollups.
- The chart is observation-based, so no exhaustion forecast, new quota alerts, account ranking, or token/cost accounting is part of this implementation.

## Frozen transport contract

The implementation uses snake_case JSON with `schema_version: 2`. Dates are RFC3339 UTC; nullable values are null or omitted and arrays are present even when empty. IDs use the existing valid-id policy. The owner-only routes above are unchanged.

- Catalog: `host_id`, `account_id`, `history_revision` as UInt64, `recording_enabled`, nullable `recording_error` as a sanitized code, nullable `first_observed_at` and `last_observed_at`, and `metrics`.
- Catalog metric: `id`, `display_name`, nullable `group`, `current` as Bool, and `has_percentage` as Bool.
- Observation: `series_id`, `basis_id`, `fetched_at`, nullable `expires_at`, `quota` using the existing tagged Rust Quota object, nullable `amounts`, nullable `resets_at`, nullable `reset_description`, and `provenance` with `source` and `confidence`.
- Chart response: `host_id`, `account_id`, `metric_id`, `history_revision`, `range`, `start_at`, `end_at`, `bin_seconds`, `recording_enabled`, nullable `recording_error`, `bins`, `events`, nullable `next_cursor`, nullable `latest`, and nullable `lowest_remaining_percent`.
- Bin: integer `id`, `start_at`, `end_at`, `first_observed_at`, `last_observed_at`, `sample_count`, `latest` observation, nullable `min_remaining_percent` and `max_remaining_percent`, and `states` as quota-state strings. Only nonempty bins are transmitted; id and time preserve gaps.
- Event: opaque `id`, `kind` as `reset_inferred`, `quota_increased`, `basis_changed`, or `clock_changed`, `from_at`, `to_at`, and nullable `before_remaining_percent` and `after_remaining_percent`.
- Events page: `host_id`, `account_id`, `metric_id`, `history_revision`, `events`, and nullable `next_cursor`.
- Successful DELETE returns HTTP 204. Settings GET/PATCH gains `quota_history_enabled`; native bootstrap accepts the same Bool with default true, preserving explicitly persisted host preferences.

Two implementation agents operate in the current checkout with disjoint ownership: all Rust/Cargo/API docs belong to the host agent; all Swift/Xcode/localization files belong to the macOS agent. No agent switches branches or commits. The coordinator owns this spec and final integrated smoke proof. This replaces the optional worktree arrangement above for this execution.

## Implementation and verification record

### Implemented

- Rust: `apps/cli/src/history.rs`, its store tests, and `server/history.rs` own private SQLite persistence, UTC bins, evidence-based events, replayable identity-bound cursors, owner permissions, retention, clear fences, and account/source lifecycle. Collector marks fresh observations transiently; cache deserialization never marks an observation fresh. Settings/native bootstrap carry `quota_history_enabled`. Existing host API docs and closed OpenAPI schemas include the routes.
- Swift: QuotioHostClient validates history DTOs; Core domain/application ports feed the existing backend, `QuotaHistoryScreenModel`, `QuotaHistorySheet`, and quota-settings service. Account cards open the sheet; settings pause recording or clear host history. All four locale catalogs are updated. The client preserves storage/authorization capability failures rather than mislabeling them as unsupported hosts.
- Verified identities retain their epoch across host restarts. Unverified borrowed sources conservatively start a new epoch on restart if continuity cannot be proved without persisting credential-derived identity. Old observations remain retained until expiry but are inaccessible through that new epoch. Ordinary alias changes preserve identity; unlinking one verified source preserves history when another source remains.

### Observed proof

- Actual loopback HTTP host, Collector/cache and SQLite: 13 controlled Session observations with gaps, real 0%, unknown/estimated state, increase/reset/basis/clock evidence. Owner access, invalid input, cache deduplication, all three ranges, pause/resume, account/host clearing, current-snapshot preservation and post-clear cached refresh passed. Historical fixture points were test-only normalized observations; no production provider hook or backfill was added.
- Native production sheet with the real HTTP backend passed remaining/used, range/metric changes, zero/unknown, offline and narrow-layout scenarios. Actual in-process AppKit mouse/key events focused the chart and changed observed-bin selection with Left arrow. Own-window compositor images confirmed baseline columns, light/dark/high-contrast appearance and existing account-name blur. Raw NSView bitmap capture omitted compositor blur and was not used as masking proof.
- Native frame sequence was recorded at a 15fps capture ceiling using monotonic timestamps, encoded as VFR H.264 and inspected as a contact sheet. This is not a display-frame-rate animation claim. Range/metric changes were driven through production screen-model actions. External VoiceOver, Escape-to-opener focus restoration and a live provider account were not exercised. No global accessibility or screen-recording permission was changed.
- Scale smoke used the production store at the default 300-second fresh-observation cadence: 100 accounts × 3 metrics × 30 days = 2,592,000 observations. Every 30-day query returned 360 bins and 8,640 samples with the actual latest value. SQLite plus sidecars occupied 1,592,928,808 bytes. The final query-only pass after reopening measured p50/p95/max 394.656/553.155/1899.917ms in a debug-linked driver on this arm64 Mac; these are store timings, not end-to-end UI latency or a fixed size guarantee.
- Rust final complete suite: 607 passed, 2 existing ignored, using `--locked --all-features -- --test-threads=1`. An earlier default-concurrency run failed the existing Cursor WAL lock-recovery fixture; its code/assertion remained unchanged. The retained-percentage regression failed before the fix and passed afterward: a current unknown value no longer hides older numeric observations, and percentage support disappears when those observations expire.
- Swift: HostClient 11 tests with one optional TLS skip; Core broad run 519 tests with three opt-in skips and the existing TunnelLifecycleControllerTests excluded after its wall-time assertion failed in the initial unfiltered run. Final focused history/capability suites passed 15 tests. Xcode app tests passed with the Rust helper staged in an isolated bundle identity. Architecture checks passed. Do not describe the initial unfiltered Core suite as green.
- The final CLI binary passed the actual Foundation native-parent pipe handshake, authenticated v2 snapshot, explicit no-saved history capability/rejection and clean EOF shutdown. The final Xcode app tests staged that same binary in the app: both helper SHA-256 hashes were `e67f033fef50ef00f6465a81fc93a4e78ed9075c97cce47c971ccd98cc7f363b`, avoiding an older shared Cargo target.

Evidence is retained outside the repository under `/Volumes/Avocado/quotio-timeline-smoke.9Jizx2/evidence/`; temporary drivers, private connection tokens, fixture databases and task-only build directories were removed after verification. The final macOS app bundle remains under `/tmp/QuotioQuotaTimelineDerived/Build/Products/Debug/Quotio.app`.
