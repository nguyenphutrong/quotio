# Resolved host contract v2

Rust owns account resolution, provider discovery, OAuth, quota collection, cache and monitoring settings. CLI JSON and HTTP use the v2 contract by default; the macOS frontend reads `/v2/snapshot` and submits commands through `/v2` routes. There is no schema-selection flag or v1 API mode. Definitions live in `openapi.json` and `src/contract.rs`.

## Resource ownership

Rust supplies final account display names, stable opaque account IDs, separate source IDs, source selection, identity evidence, action availability and usage freshness. A frontend must not select names or merge accounts based on provider, email, username or credential location. A source's `location` is a semantic code, never a host path.

`user_label` is an explicit override, not a generated name. Identity evidence is `unknown`, `local` or `verified`. Local names may be displayed but are not sufficient proof to merge sources. Provider and tenant scoping belongs to Rust resolution, not client-side matching.

Each usage entry references one account. Source IDs are unique across a host snapshot; at most one enabled source is selected for an enabled account. A host's persisted revision must increase as its state changes; comparing revisions across different host IDs is invalid. Clients store selections by `(host.id, account.id)`, never display name.

## JSON and compatibility

- `schema_version` is exactly 2. Unsupported major versions must be rejected before changing frontend state.
- Every documented field is present. Optional values are explicit `null`; collections are empty arrays/maps, not null. Timestamps use RFC 3339.
- Server output is checked against closed schemas to detect accidental or sensitive fields. Clients tolerate additional fields introduced compatibly, but must not infer meaning for unknown action/state/metric kinds.
- `display_name` is render-ready public metadata; localization of semantic actions, units and dates remains a client concern.
- Rust projects Antigravity metric names in this order: `Session`, `Weekly`, `Claude Session`, `Claude Weekly`. Codex uses `Session`, `Weekly`, `Spark Session`, `Spark Weekly`. Missing windows are omitted except for the Antigravity exhaustion rule below; exhausted windows remain present. Unknown windows retain their labels and follow recognized windows. Existing metric IDs, quota values and reset timestamps are unchanged; clients render host names and order without parsing provider bucket labels.
- For Antigravity only, an exhausted `Weekly` or `Claude Weekly` implies a missing `Session` or `Claude Session` at 0%. Existing Session metrics take precedence. Inferred metrics use `antigravity_weekly_limit` provenance and the weekly observation timestamp, with no invented session reset time, amount or consumption.
- `not_loaded`, `fresh`, `stale` and `unavailable` are distinct. Empty metrics with a valid plan are supported. Unknown, disabled, unlimited and measured quota must not be collapsed into zero.
- Action `interaction` distinguishes work on the client, work on the host, and a person required at the host. This is not permission to bypass OS approval. Credentials never occur in these response types.
- A snapshot contains resolved accounts and usage atomically. It is not a request to rescan credentials or call provider APIs. Account lists must remain available without network refresh.
- The resolved model is the default contract. Existing credentials and source IDs are retained during data migration; old API shapes and schema-selection flags are not supported. Remote clients use an HTTPS reverse proxy with the configured `--public-url`; the host listener remains loopback.

## Checks

`cargo test --locked --test contract` validates real serializers against JSON Schema, rejects bad types/states, checks cross-resource references, and compares the shared fixtures. `tests/fixtures/contracts/snapshot-v2.json` covers a plan-only Copilot account and one Devin account with two sources. These fixtures are synthetic, not exported user data.

## Persisted naming provenance

New account creation records whether its label is user-supplied or generated. Successful managed refreshes cache the provider's name in the protected account document. CLI account listing, HTTP account serialization and managed usage share Rust's `Account::display_name` policy: explicit user label wins; generated labels may use the last observed provider name. A rename becomes an explicit user label and invalidates the old usage-cache key. Replacing a credential with a different identity clears its previously observed name.

Documents without naming provenance retain their stored labels. Reading naming metadata alone does not rewrite it, and existing sources are not guessed to be user-named/generated from string patterns. This preserves ambiguous legacy customization until explicit migration. Imported legacy account metadata likewise keeps unknown provenance.

Naming-aware writes require protected vault format 9. Readers reject naming metadata in older format numbers, and older binaries that only accept formats 1–8 must refuse format 9 rather than silently drop the new policy. Credential contents, account IDs, enabled state and refresh ownership are unchanged by naming observations. Later vault formats add the registry and host controls described below.

## Verified identity registry

Vault format 10 stores the resolved-account registry. Enabling it preserves every credential record and original source ID, starts logical account IDs from those stable IDs, and assigns a persistent host ID. Successful commits advance a checked monotonic revision. Reading the resolved account view initializes the registry if absent, then returns its committed revision.

Only `VerifiedIdentity { subject, tenant }` supplied by a fresh authenticated provider fetch can merge sources of the same provider. Labels, emails, local metadata, token fingerprints and cached/client-supplied reports are not identity proof. Devin Desktop emits evidence from `GetUserStatus.userId` and `teamId`; Copilot uses the authenticated GitHub profile numeric ID; Factory API-key usage uses verified user and organization IDs. Other source types remain distinct unless a fresh adapter response supplies verified evidence. Missing evidence does not invalidate a working login; its source stays distinct.

Merging an unverified source into a confirmed account retains a durable redirect for its earlier logical ID. Switching a source to a different verified identity or explicitly replacing its credential never redirects an old account bookmark to the new person. Deleting one source retains the logical ID while another source remains. Corrupt cross-provider or unverified shared bindings are rejected on read.

Data migration preserves current credentials, source IDs, names and enabled state. A failed write must leave the previous document intact. Downgrading to old API/storage behavior is not part of this migration.

## Default account read API

- CLI: `quotio accounts list --format json` emits the resolved account envelope; no `--schema-version` or initialization command is required. Text output formats the same Rust account projection.
- HTTP: `GET /v2/accounts` uses the same service. First access atomically initializes protected metadata, preserving original source IDs and credentials. Repeated reads keep the host ID and revision stable.
- CLI `use` and `remove` accept logical account IDs, including a group whose original source was removed. Removing a logical account unlinks all its registered sources, never external provider login files.
- The standalone CLI's default vault is not the macOS app's isolated vault. Use the appropriate host connection; never merge namespaces implicitly.
- Account-list reads report `not_checked`; use `/v2/snapshot` for source health and quota state. It advertises the supported logical-account and source actions. Discovery and authentication are host commands.

## Logical account and source mutations

- `POST /v2/accounts` accepts the typed credential intake already documented for account creation. It returns an idempotent operation; no credential is returned.
- `GET/PATCH/DELETE /v2/accounts/{id}` resolves a logical account or a persisted redirect. PATCH supports `user_label` (null resets, omission preserves), `enabled` for every source in the group, and `active: true` to select an enabled source. DELETE unlinks the entire group.
- `PATCH/DELETE /v2/sources/{id}` targets exactly one physical source record. PATCH accepts boolean `enabled` and replacement `api_key` for owned API-key sources. Replacement validates with the provider before committing; omitted settings/region/organization are preserved and null resets them. Settings changes require a replacement key. A changed credential during validation rejects the write. A new identity detaches the source and returns its new logical account ID. DELETE leaves the logical account alive while another source remains. Neither operation edits the provider's external login.
- Writes require bearer authentication, management mode and an `Idempotency-Key`. They use the existing durable mutation ledger and operation polling. A conflicting body with the same key is rejected.
- Logical user labels live in the protected registry, independent of source labels, so deleting the original source does not drop the account name. Format 11 records this policy. Display precedence and action availability are decided in Rust; frontends forward the selected resource scope.

## Resolved snapshots

`GET /v2/snapshot` combines registered accounts with collected observations. Rust chooses one enabled source per account, preferring fresh results over stale results and a working source over a failed source. It preserves metric states, amounts, notes, reset descriptions and provider supplemental observations. A secondary source failure stays on that source instead of hiding another source's quota. A plan-only success has no invented metrics. Failed unregistered login probes appear in `provider_issues` and do not create account rows.

Snapshot reads use the current vault under its transaction lock. Deleted sources cannot reappear from an old report, and replacing an API-key identity discards that identity's old quota. Format 12 persists a digest of account/usage state: the revision increases when those values change, including freshness transitions, but not on an unchanged read. The response is published only after the revision commits.

With `--no-saved-accounts`, snapshots do not access the protected vault. Default/environment/mock observations remain visible with no account-write actions. This mode's host ID and revision are scoped to the server session; restarting it creates a new host ID. Normal account-backed hosts retain the vault's host ID across restarts.

## CLI quota output

`quotio usage --format json` emits the same `Snapshot` shape as `/v2/snapshot`; text output formats its resolved names, IDs and selected metrics. Provider/account filters limit the returned accounts. `--account` resolves a logical account and collects its enabled sources, including after the original source was unlinked. The no-saved-account path performs no protected-vault read. Internal per-source cache records are not a public output format.

`account_redirects` contains persisted logical-account redirects. Source IDs are a separate scope and must never be inferred as redirects; a reassigned source must not retarget an old account bookmark. Loaded usage requires a fetch timestamp. Duplicate metric IDs, invalid graph references and duplicate profile dates are rejected before rendering. Malformed collected data reports `invalid_snapshot`, not a credential-storage permission error.

## Host-owned OAuth callbacks

When `callback_mode` is omitted, Rust selects it from the provider workflow. Browser-callback flows use the host's loopback listener; device and manual-code flows remain session-driven. The frontend opens the supplied HTTPS URL, displays a supplied user code or manual-code form, and polls the session. Only the host declares expiry or completion. Cancelling an attempt requests host cancellation, including when the frontend task itself was cancelled. Completed accounts are read by logical ID; the frontend never synthesizes a name or account when that read fails.

## Native discovery

`POST /v2/discovery` starts a host discovery operation for the requested provider IDs, or the configured providers when omitted. Rust selects supported native source kinds, inspects metadata without prompting, registers readable sources, and reports permission requests separately. `GET /v2/discovery` returns the complete current report, including per-provider scan times, known sources and failures. A scoped scan preserves other providers' discovery results.

Repeated registration of an existing source is a no-op: it preserves disabled state, does not rewrite the borrowed login and does not append another mutation receipt. The frontend submits scan/authorization commands and renders one discovery snapshot; it no longer loops over source kinds or persists discovery decisions in UserDefaults. Rust schedules discovery and refresh from persisted settings without depending on an open frontend window.

## Removed native sources

Vault format 13 records suppression for removed native source identities and their permission locations. Automatic scans do not recreate those references or repeat their permission prompts. Explicit `restore_removed: true` discovery clears suppression only for the selected providers; existing disabled sources remain disabled. The app's Scan Again action sends this explicit restore intent. Discovery reads recheck current registered/suppressed sources so a removed source is not kept in permission state solely by an older scan report. External login files and Keychain items remain unchanged.

## Monitoring settings and restart

Rust persists provider tracking, automatic discovery, refresh cadence and
`disabled_proxy_auth_files`. The native parent sends old preferences once through
the private startup pipe; existing host settings take precedence. Both manual and
scheduled refreshes honor disabled borrowed files. Requests may add exclusions,
but cannot override the host's exclusions. External login files remain read-only.

Startup restores matching cached observations without contacting providers. Failed
refresh state survives restart; stale quota stays marked stale. A successful
plan-only response supersedes old metrics. Account mutations preserve unrelated
observations, and the frontend reloads the host snapshot after CRUD.

The host resolves Codex/Amp executables using PATH and common installation
locations. The native frontend does not detect or choose provider executables.

## Client permissions

The owner can issue host-bound, expiring, revocable **read** client credentials.
Only their digests are stored; the token is returned once. Read clients cannot
mutate accounts/settings, refresh, start OAuth or view private operation/session
state. Delegated `manage` issuance is not enabled. Owner management remains
available when the server is started with `--manage`.

Operations, discovery references and OAuth sessions are bound to the requesting
client. Revocation is rechecked before durable writes and OAuth credential
persistence. Native OS authorization and legacy credential migration remain
host-owner actions; a public-host connection cannot approve an OS prompt.

## Frontend boundary and validation limits

`Packages/QuotioHostClient` is the portable Foundation transport/DTO package.
Swift renders host names, metrics, actions and freshness; selections use exact
host/account IDs or explicit redirects. UI formatting, accessibility, locale,
notifications, app updates and OS integration remain frontend responsibilities.

The production graph has no provider fetchers, credential-file reader, proxy
management, tunnel, warmup, agent configuration or account-switching service.
Historical modules remain in the package but are not constructed by the app.
Explicit legacy account migration is the exception: it reads the old app-owned
credential store and sends it through the owner-only migration endpoint. Bootstrap
also imports old preferences and supplies the read-only external auth directory.
Neither is an ongoing second owner of account state.

Run `apps/macos/scripts/check_architecture.sh` to guard these boundaries.
[Provider coverage](provider-coverage.md) is generated from the Rust registry and
checked by contract tests. Offline fixtures and macOS tests do not establish live
success for every provider. Windows/Linux runtime acceptance remains deferred
until test hosts are available.

## Quota observation history

The host records accepted fresh quota metrics in a private SQLite database beside its account-storage namespace, outside the credential vault and usage cache. Standalone `usage`, cached restoration, snapshot reads and failed fetch fallbacks never record observations. A successful quota refresh remains successful when history storage fails; the history catalog and chart expose a sanitized recording-error code. That error remains visible across empty cached or fenced batches and clears only after an accepted fresh batch or an explicit clear.

`quota_history` permits authenticated-owner reads. `quota_history_write` additionally requires management mode. Anonymous and delegated clients cannot read history, including delegated management grants. `--no-saved-accounts` advertises both capabilities as unavailable with `no_saved_accounts` and does not initialize a persistent database. Hosts without these capabilities do not support this feature.

History responses keep `schema_version: 2` and UTC RFC3339 timestamps. The catalog preserves current metric presentation order and appends retained historical-only metrics with `current: false`. The chart contains only nonempty bins. Missing bins are gaps, a measured zero remains an observation, and nonnumeric quota states remain typed rather than becoming percentages. Bin widths are 240 seconds for `24h`, 1680 for `7d` and 7200 for `30d`, anchored at the fixed query start. Numeric summaries are observed values, never consumption or estimates of missing samples.

Reset inference requires an increase across adjacent comparable numeric observations, a prior reset between their actual timestamps, and an advancing next reset. Other increases use `quota_increased`. Basis changes and clock discontinuities stop inference. Future-dated responses produce a `clock_changed` interval from host acceptance time to the claimed provider timestamp, without a numeric bin. Event endpoints can cross range boundaries or run backwards after clock rollback. Detailed events paginate in pages of at most 128; opaque cursors freeze endpoints and committed observation bounds and reject identity changes, pause revisions and clears. A valid event cursor can be read again after a lost response; an identity-mismatched request does not consume it.

Verified identity epochs are tenant-aware and stored as opaque history identifiers. Resolver-confirmed redirects preserve access only to that same epoch. Credential replacement creates a separate account epoch. Borrowed or external unverified identities conservatively isolate on host restart because the host cannot prove continuity without retaining credential material. Unchanged managed owned identity and verified identity preserve retained history. No token, cache-key digest, email, credential path, provider payload or prompt is stored in SQLite. Temporary source disappearance does not delete records.

`quota_history_enabled` defaults to true in configuration, Settings GET/PATCH and native bootstrap preferences. Explicit persisted host choices override bootstrap imports. A history-only pause/resume patch preserves the current snapshot and does not wake quota collection. Pausing leaves retained observations readable and follows the existing fetch cadence; startup, refresh and history-read maintenance prune the rolling 30-day retention in bounded batches. Clearing one account or the host advances a durable revision and cutoff under the account mutation guard. Old in-flight batches and cached pre-clear timestamps cannot repopulate cleared records, including after restart. Explicit account removal also purges history before the credential transaction proceeds.

Unlinking one source does not purge a logical account that still has other sources. Unlinking its final source removes the account and purges history before the mutation; identity continuity rules still apply when the selected source changes.

The closed `QuotaHistoryCatalog`, `QuotaHistoryChart`, `QuotaHistoryObservation`, `QuotaHistoryBin`, `QuotaHistoryEvent` and `QuotaHistoryEventsPage` schemas in `openapi.json` define the wire fields. `cargo test --locked --all-features` covers deduplication, conflict rollback, zero/gaps, nonnumeric boundaries, identity epochs, reset evidence, replayable pagination, private storage, retention, clear cutoffs and representative account volume. The `server::history_tests::live_host_history_smoke` test exercises actual loopback HTTP refresh, snapshot, history reads and clearing with an isolated vault and fixture clock. Test-only normalized store samples add gaps, zero, unknown and estimated states, an increase and an inferred reset; they do not add production hooks. Set `QUOTIO_HISTORY_SMOKE_SECONDS` to hold its seeded server before clearing for client inspection.
