# Local REST API

Start a read-only API for applications running on the same machine:

```sh
cargo run -- serve --provider codex --provider amp
```

For a fixture-only run with no account discovery or provider requests:

```sh
cargo run -- serve --provider mock --no-saved-accounts
curl http://127.0.0.1:6767/health
curl http://127.0.0.1:6767/v1/providers
curl http://127.0.0.1:6767/v1/usage
curl http://127.0.0.1:6767/v1/usage/mock
```

The listening address is printed to stderr. The process stays in the foreground;
Ctrl-C or SIGTERM on Unix stops it. An occupied port is a startup error, rather
than silently disabling the API. Use `--listen 127.0.0.1:0` to choose an available
port, or `--listen '[::1]:6767'` for IPv6 loopback.

## Configuration

| Option | Default | Meaning |
| --- | --- | --- |
| `--listen` | `127.0.0.1:6767` | Loopback IP address and port; non-loopback addresses are rejected |
| `--provider` | Config selection | Repeat to enable multiple providers; duplicates are removed |
| `--config` | Platform config path | Read `enabled_providers` and `cache_ttl_seconds` from this TOML file |
| `--refresh-interval` | Config, then `60` | Seconds to wait after each completed refresh, from 1 to 86400; `0` disables scheduled refreshes |
| `--timeout` | Config, then `10` | Per-provider collection deadline, including retries, from 1 to 3600 seconds |
| `--no-saved-accounts` | Off | Skip the Quotio account vault and use environment/local sources |
| `--manage` | Off | Enable account, OAuth, settings, and refresh writes; requires `QUOTIO_SERVER_TOKEN` |
| `--public-url` | None | External HTTPS origin supplied by a reverse proxy or tunnel; requires the server token |
| `--allow-origin` | None | Exact browser origin allowed for CORS preflight and responses; repeat for multiple origins |

Without `--provider`, the server uses `enabled_providers` from the existing CLI configuration. An empty selection is allowed and serves an empty report until providers are enabled. Startup loads the configuration, while `GET /v1/settings` rechecks the file and applies external changes safely; effective changes invalidate the usage snapshot. Saved accounts are discovered again each cycle.

The same adapters and collector used by `quotio usage` fetch data. Existing provider
credential refresh behavior still applies, including managed OAuth token rotation.
The read-only default has no account or settings write routes. `--manage` adds the managed API described in [the OpenAPI contract](openapi.json): account mutations, Codex/Claude/Copilot OAuth sessions, settings updates, and asynchronous refresh. Quota collection can still refresh separately owned credentials. Borrowed native logins never refresh or write their source.

## Routes

| Request | Response |
| --- | --- |
| `GET /health` | `{"status":"ok","ready":true}`; `ready` means the first refresh has completed, even if providers failed |
| `GET /v1/providers` | `schema_version: 1` and a `providers` array with `id`, `description`, `enabled`, and `capabilities` |
| `GET /v1/usage` | Latest report for all enabled providers and their accounts |
| `GET /v1/usage/{provider}` | The same report shape filtered to one enabled, canonical provider ID |
| `GET /openapi.json` | OpenAPI 3.1 contract for all routes |
| `GET /v1/status` | Refresh state and current settings revision |
| `GET /v1/accounts` and `/v1/accounts/{id}` | Managed account metadata; available in read-only mode when account storage is enabled |
| `POST/PATCH/DELETE /v1/accounts...` | Asynchronous managed account mutations; require `Idempotency-Key` (1–128 visible ASCII characters) |
| `POST /v1/auth/sessions` and callback routes | Managed Codex, Claude and Copilot sessions (requires `--manage`) |
| `GET /v1/settings` | Current settings and revision; available in read-only mode |
| `PATCH /v1/settings` | Optimistic revision patch; requires `--manage` |
| `POST /v1/refresh` | Asynchronous refresh request (requires `--manage`); `include_owned: false` limits collection to borrowed sources and native-parent Warp mirrors; `disabled_proxy_auth_files` excludes the named CLIProxyAPI files from that request |
| `GET /v1/operations/{id}` | Operation status; recent refresh results expire after 15 minutes; account write results persist until restart |

Usage responses use Quotio's existing `schema_version: 1` JSON contract, matching
`quotio usage --format json`: `generated_at`, `providers`, and `failures`. Each usage
entry includes its provider, account identity, optional account reference, and quota
windows. Each window retains its own `fetched_at`, reset time, and provenance.
Unknown usage stays unknown; it is never replaced with zero.

Codex entries may also contain the optional `reset_credits` snapshot described in
the [output contract](../README.md#output-contract): `available_count`, nullable
`earliest_expires_at`, `fetched_at`, and `source`. These are banked quota resets,
not monetary credits. Omission is unknown, not zero. Credit failures retain quota
and add `codex_reset_credits` diagnostics. All usage GET routes expose this field
in read-only mode, without `--manage`; there is no redeem/consume route. Use the
credit observation timestamp for freshness, not report generation time. Known
expired balances are omitted even between background refreshes. API/schema v1
is unchanged under the additive-field policy.

A provider route returns all accounts for that provider, including local and saved
accounts after the collector's normal deduplication. Disabled and unknown providers
return 404. Route IDs are canonical IDs from `/v1/providers`; CLI aliases are not
accepted in HTTP paths. Query parameters are not supported.

`HEAD` is supported with no response body. `OPTIONS` returns 204 for an allowed CORS preflight when `--allow-origin` matches; unsupported methods return 405. Read routes remain available without `--manage`; write routes are rejected as read-only unless management mode is enabled.

## Managed request examples

Create an API-key account with a synthetic credential and poll the returned operation:

```sh
curl -X POST http://127.0.0.1:6767/v1/accounts \
  -H "Authorization: Bearer $QUOTIO_SERVER_TOKEN" \
  -H "Idempotency-Key: demo-account-1" -H 'Content-Type: application/json' \
  -d '{"provider":"synthetic","api_key":"synthetic-example-key","settings":{},"region":null,"organization":null}'
curl -H "Authorization: Bearer $QUOTIO_SERVER_TOKEN" http://127.0.0.1:6767/v1/operations/OPERATION_ID
```

Settings patches include the current `revision`; a stale revision returns 409
`revision_conflict`, so read `GET /v1/settings` and retry. `POST /v1/refresh` returns
202 with an operation ID. A request with `account_id` may refresh that enabled
account even when its provider is not enabled for scheduled collection. The
provider must match the account, and account-scoped requests must name exactly
one provider. Requests without `account_id` remain limited to enabled providers.

### Managed OAuth sessions

Start with `POST /v1/auth/sessions`, supplying `provider` and an optional `label`.
The response adds `provider`, `workflow`, and optional `user_code` to the existing
`id`, `url`, `expires_at`, `status`, `account_id`, and `error_code` fields.
Provider capabilities also expose `oauth_workflow` and `start_oauth`.

| Provider | Workflow | User action |
| --- | --- | --- |
| `codex` | `browser_callback` | Open `url`. For `callback_mode: relay`, send `{"callback_url":"..."}` to `POST /v1/auth/sessions/{id}/callback`. `loopback` remains supported. |
| `claude` | `manual_code` | Open `url`, then send `{"code":"..."}` to the callback route. A code with `#state` must match the backend's state. |
| `copilot` | `device_code` | Open `url` and enter `user_code`. Do not call the callback route. The backend polls GitHub. |

Claude and Copilot accept only the default `callback_mode: relay`; this field is
retained for Codex compatibility. Submit exactly one callback field. Never include
codes in a URL query or log them. The backend owns proof-key generation, state,
exchange, provider polling and credential storage. Swift only retains the session
ID, renders the user action, submits the Claude code, and polls the local session.

Poll `GET /v1/auth/sessions/{id}`. `waiting` permits cancellation with `DELETE` on
the same route. `processing` means exchange or persistence has been claimed;
cancellation then returns `account_busy`, and the client must keep polling.
Terminal states are `completed`, `failed`, `cancelled`, and `expired`. A completed
session returns the saved account ID. No response contains access, refresh or
private device tokens. An uncertain storage result requires inspecting accounts
before starting another login.

Codex and Claude wait up to 180 seconds for user input. Copilot uses GitHub's
expiry, waits at least five seconds between polls, and adds five seconds after
each `slow_down`. Pending responses do not create accounts. Cancellation or expiry
stops polling and discards late tokens before persistence. Sessions live in memory;
a backend restart requires a new session, not reuse of an authorization code.

Claude saves the account identity from the token exchange before any quota request,
matching the native authorizer. A quota outage does not discard a successful login.
Claude refresh uses a durable marker written before the token request. A timeout,
invalid response, or uncertain write leaves that marker in place, preventing replay.
Current and past refresh-token fingerprints remain reserved after account deletion.
These reservations require vault format 6, which older backends reject. Recovery
requires a fresh login, not copying the same refresh token into another account.
Copilot stores the GitHub token only after `/user` identifies the account. It has no
refresh-token grant; a rejected token requires a new login. Copilot login does not
require a paid quota response.

The terminal also supports `quotio accounts add --provider claude` and
`quotio accounts add --provider copilot`. Both print the user action without opening a browser.
Claude reads its code from a hidden terminal prompt. `--token-stdin` is not an OAuth
code input mode. No native provider file or Keychain item is imported by these flows.

Provider capabilities include `auth`, supported operations, native-login instructions,
and field metadata. Use each setting's `field_path` to place its value in an account
request: core fields such as `region` are top-level; catalog fields use paths such
as `settings.project_id`. Frontends do not need a separate provider-to-form mapping.

## Refresh and failures

The first refresh starts when the server starts. HTTP reads use memory snapshots
and never trigger another provider fetch. Refreshes run one cycle at a time, with
the configured wait after completion. Each cycle publishes its report atomically.
The shared `UsageCache` service reads
persistent entries also used by `quotio usage`. Only missing or expired accounts
are fetched; the default TTL is 300 seconds, configurable as `cache_ttl_seconds` in
TOML. `--refresh-interval` controls how often the server checks, independently of
that TTL. REST GET requests do not provide a force-refresh option.

Until the first cycle finishes, usage routes return 503 with `not_ready`. Afterwards,
a valid usage report returns 200 even if some or all providers failed. Inspect the
`failures` array to determine provider health; HTTP success only means a report is
available.

A failed account refresh keeps that verified login's last successful snapshot
alongside the new failure. Its original window `fetched_at` values remain unchanged. `generated_at`
is the latest report time, not proof that every account was just fetched. Clients
should display the failure and use each window's `fetched_at` to assess age. Old
snapshots may remain available through repeated failures even after their TTL expires.
A successful refresh replaces them. Removed accounts disappear on the next discovery
cycle. If login identity cannot be verified, no old snapshot is restored. The HTTP
transport does not perform its own stale-data merge.

Disk entries survive server restarts. CLI and REST share the same cache directory;
`QUOTIO_CACHE_DIR` overrides its platform default. See the README's usage cache
section for storage, concurrency, diagnostics and native identity limitations.

This follows OpenUsage's local snapshot approach, but uses Quotio's own report schema.
It is not an implementation of OpenUsage's `/v1/limits` or legacy UI response format.

## Local access and optional authentication

Only loopback listening is supported. The server accepts a Host header matching its
bound address and port, or `localhost` with that port. It rejects requests carrying
an Origin header and does not emit CORS permission headers. Browser pages on other
origins cannot read the API through CORS; this version targets local CLI/native
clients rather than a browser dashboard.

By default, other processes running on the same machine can read the snapshots.
To require authentication, set `QUOTIO_SERVER_TOKEN` before starting the server. It
must contain 32 to 4096 visible ASCII characters. Clients must then send
`Authorization: Bearer <token>` on every route, including `/health`. Keep the token
in the client's secret storage and send it only as a header, never in a URL. There
is no token command-line flag. An empty or malformed configured token prevents startup.

Responses include `Cache-Control: no-store` and `X-Content-Type-Options: nosniff`.
Account labels, email addresses, usage, and balances can appear just as in CLI JSON;
provider credentials and server tokens are not serialized. There is no request/header
logging. Up to 16 HTTP handlers can run at once; this is a handler limit, not a TCP
connection limit. `--public-url` declares the HTTPS origin of a separately operated reverse proxy; it does not provision TLS or open a remote listener. Quotio itself remains loopback-only.

## Error codes

API errors use `{"error":"code"}`. Provider failures remain inside a usage report.

| Status | Codes |
| --- | --- |
| 400 | `unsupported_query` |
| 401 | `unauthorized` |
| 403 | `origin_not_allowed`, `host_not_allowed` |
| 404 | `not_found`, `provider_not_enabled` |
| 405 | `method_not_allowed` |
| 503 | `not_ready`, `server_busy` |
| 500 | `encoding_failed` |

Managed routes also use `idempotency_key_required`, `invalid_idempotency_key`, `idempotency_conflict`, `operations_full`, `account_storage_disabled`, and account or OAuth-specific errors. A settings patch with a stale `revision` returns 409 `revision_conflict`; read `GET /v1/settings` and retry against the returned revision.

Malformed HTTP is rejected by the HTTP stack before these API handlers. Startup
argument/config errors exit with code 2; initialization or bind errors use code 3.

### Account operation deadlines

Vault reads and waits for the shared mutation lock stop after 10 seconds. A busy
vault produces `account_busy`; settings lock contention produces `settings_busy`
(409). Usage reads return 503 `account_busy` while a write holds the lock too long.
OAuth token exchange and quota validation each have a 30-second deadline.

Once a native credential write starts, Quotio waits for its actual result instead
of reporting a timeout that might hide a successful write. A stalled write remains
running; other requests stop waiting for its lock after 10 seconds. After an
interruption or restart, inspect the account list before submitting another write.

### Operation capacity and retries

Up to 128 operations may run at once. Completed refreshes do not consume running
slots. The latest 128 refresh results are available for up to 15 minutes; older
results return 404. Account write results and their idempotency keys remain until
restart, so retrying a key cannot repeat a write after refresh history is pruned.
The server accepts at most 4096 distinct account write keys per lifetime; further
new keys return 503 `idempotency_full`. Existing keys still replay their result,
and refresh remains available. Complete pending writes and restart to clear this
in-memory operation ledger; this does not clear successful vault receipts. Operation IDs cannot be recovered across restart. Successful account writes now
commit a receipt atomically inside the protected vault. Retrying the same key and
body after restart returns a new operation with the original result, without
revalidating credentials or applying the mutation again. A changed body or target
fails with `idempotency_conflict`. Receipts do not resurrect deleted accounts.
Failed writes do not persist receipts. Vault receipts are bounded at 4096 and are
not cleared by restart; reaching that bound returns `idempotency_full`. No receipt
is evicted silently because doing so could repeat a mutation.

The first successful managed HTTP account write upgrades the vault document from
version 1 to 2 while preserving accounts and credentials in the same atomic write.
CLI 0.2.0 reads both formats. Earlier CLI binaries reject version 2; do not downgrade
after that write. CLI-only account operations preserve existing version-2 receipts.
This is retry infrastructure, not an implementation of the Swift legacy import API.

### Refresh schedule

`next_refresh_at` describes the periodic scheduler's actual timer. Manual refresh
updates `last_completed_at` but does not postpone that timer. The next time is null
while the scheduler is refreshing or waiting for another refresh to finish.
Settings and account changes wake the scheduler and replace its pending timer.

## Native parent pipe, bootstrap version 1

`serve --manage --parent-pipe --listen 127.0.0.1:0` is the native app transport.
The parent supplies one 32–4096 byte visible-ASCII token followed by LF over an
inherited stdin pipe within five seconds. Do not also set `QUOTIO_SERVER_TOKEN`.
The process emits one JSON line on stdout after binding and initialization:

```json
{"bootstrap_version":1,"api_version":1,"server_version":"0.1.1","pid":123,"host":"127.0.0.1","port":49152}
```

The example port and PID are illustrative. Use the actual record, then authenticate
`GET /v1/status` and verify version/access mode and readiness. The record means the
listener is bound, not that the initial provider refresh is complete. Logs stay on
stderr. Tokens never appear in the record. Keep stdin open for the process lifetime;
EOF, input failure or extra bytes terminate the session using normal graceful
shutdown. This mode requires a Unix pipe, not a terminal or regular file. A native
parent must close unused pipe endpoints, keep the token private and stop only its
owned child. The normal CLI stderr announcement is unchanged without this flag.

The native parent may pass an absolute `--cli-proxy-auth-dir`. The helper reads
supported Codex, Claude, GitHub Copilot, Antigravity, Kiro, and Vertex JSON auth
files from that directory as borrowed credentials. It does not import, refresh,
edit, or delete those files; their owner remains responsible for token rotation.

## Native migration scope

The native migration covers quota/usage and Quotio-managed provider accounts. The
macOS app also imports the legacy `Codex Auth` Keychain credential once into the
CLI's owned Codex account format. After a successful import, the helper owns token
refresh; the original Keychain item is left untouched and is no longer read by
migration. Failed imports remain retryable. Claude discovery supports Claude Code
only; Claude Desktop credential discovery is intentionally not supported.

Agent configuration, CLIProxyAPI auth-file management, proxy lifecycle, proxy keys, tunnels,
and proxy notification policy remain in the existing Swift app.
The unreleased notification endpoint has been removed. An existing `notifications`
config table is retained on settings writes for compatibility but does not control
behavior. No migration step edits or stops a separately running CLIProxyAPI engine.

## Partial provider endpoints

A usage entry may include `diagnostics` with fixed error codes and an endpoint
identifier when some provider endpoints succeed and others fail. The report's
`failures` array also includes these account-scoped failures. Cached responses
preserve the diagnostics and original window timestamps. OpenRouter now combines
account credits/balance with key limits and spend using its existing API-key source.
No new credential input endpoint or native credential discovery is included.


## Explicit read-only OpenRouter queries

`POST /v1/usage/queries` requires management mode and accepts `provider: openrouter`,
`client_account_id`, `label`, `access_token` and `force`. The token is an explicit
input from the native client's existing authorized store, held only for the query.
The operation returns `result.report` with normalized usage and failures. It does
not create/update accounts, refresh credentials, read native credential files, or
change CLIProxyAPI. Unknown fields and unsupported providers fail before provider I/O.

Queries reuse UsageCache with client-account and credential identity isolation.
Force bypasses freshness; key rotation cannot reuse another login's snapshot. The
provider token is not persisted, returned, logged or passed through arguments/URLs.
Operation history is bounded like refresh history; disconnecting a client does not
claim a provider operation completed, and backend shutdown cancels tracked jobs.

## Borrowed ClinePass source references

On macOS, `POST /v1/account-sources` registers one existing ClinePass group from
Quotio's custom-provider preferences. It requires management authentication and an
`Idempotency-Key`, and returns an operation whose result contains the new account
ID. The request contains references only:

```json
{
  "kind": "quotio_custom_provider",
  "source": {
    "domain": "production",
    "record_id": "01234567-89ab-cdef-0123-456789abcdef"
  }
}
```

`production` addresses `app.bytrong.quotio`; `development` addresses
`app.bytrong.quotio.dev`. An effective app bundle identifier (for example,
`com.example.quotio`) is also accepted: up to 255 ASCII alphanumeric, hyphen,
and dot characters, with nonempty dot-separated components. File paths, credentials and ownership
flags are rejected. This operation does not discover groups, copy their keys,
change the proxy configuration, or refresh their credentials. The group must exist,
be enabled and contain a usable key. As in the Swift implementation, quota uses the
first key. Linux can use owned ClinePass API keys, but cannot read macOS preferences.
Provider capabilities expose this distinction in `source_references`.

The account has `origin: borrowed_proxy`; accounts created through the owned-key or
OAuth APIs have `origin: owned`. Ownership cannot be patched. The opaque account ID
and duplicate detection bind to the source domain and group UUID, not its label.
Use the existing account endpoints to rename or remove the reference, and refresh
by account ID. Removing a reference never removes the source group or its key.

Source keys are resolved on the backend for usage and cache identity checks. Disabled
sources report `source_disabled`. Source changes during a fetch reject that result;
credential replacement or account deletion also rejects an in-flight result.
Registration receipts and references use vault document format 3, which older
binaries reject. Documents in formats 1 and 2 remain readable. Registration is
explicit and is not run automatically by the current Swift production composition.

Automated source tests use a JSON fixture encoded by Swift's `CustomProvider` model,
a separate macOS test preferences domain for cross-process visibility, and an
in-memory vault for retry and deletion races. These do not establish live ClinePass
account acceptance or a completed Swift migration.

## Uncertain storage commits

A Linux vault write can replace the document successfully and then fail while
syncing the parent directory. Such a result uses `credential_commit_uncertain`,
not a rollback or completed-login claim. The new account state may already be
visible; snapshots are invalidated even when this error occurs. Inspect accounts
before starting another mutation. After a service restart, retrying with the same
Idempotency-Key checks the durable receipt if the replacement survived. Do not
start a new OAuth flow merely because storage durability could not be confirmed.

## Quota presentation and refresh results

Completed refresh operations include `result.report`, containing the exact requested
scope from that refresh, alongside the existing provider/failure counts. Clients
can render that result without reading a later, potentially changed snapshot.

Quota windows can include `metric_id`. ClinePass supplies `clinepass-five-hour`,
`clinepass-weekly`, and `clinepass-monthly` in that order when the corresponding
windows exist. Missing percentages and duplicate windows produce unknown quota
with a scoped diagnostic. A malformed reset drops only that reset timestamp;
valid percentages and other windows remain available. An absent reset stays
absent, and a past source timestamp is retained. This does not add upstream proxy
support or enable the Swift production backend.

## Amp presentation parity

Amp normalization supports Free percentages or dollar balances, named subscription
agent/orb percentages or amounts, individual credits and workspace balances. It
returns plan metadata, stable `amp-free`, `amp-agent-usage`, `amp-orb-usage`,
`amp-individual-credits` and hashed workspace metric IDs. Amount windows include
consumption when their limit is known. Credits without a limit retain unknown
percentage, including a zero balance.

Daily, renewal, billing-period and replenishment information remains a reset
description. No exact reset timestamp is inferred from that text. Native public-host
key aliases follow the Swift selection order without modifying the file. Amp native
reference registration is described below. Full frontend composition remains pending.
This parser work does not activate Swift production or establish live-provider
acceptance.

## Amp native account reference

Register the current node's standard Amp source with authenticated management
`POST /v1/account-sources`, an `Idempotency-Key`, and `{"kind":"amp_native"}`.
The backend resolves `~/.local/share/amp/secrets.json` on macOS/Linux. The request
cannot supply a path, token or ownership override. The vault stores a reference,
not a second copy of the native key. Registration confirms that the source is
readable; it does not claim the provider accepted the key.

The account reports `origin: borrowed_native` and `enabled`. For this source,
`PATCH /v1/accounts/{id}` accepts `enabled: false` or `true` using the usual
idempotent mutation API. Disabled references return `source_disabled`, and native
credential rejection returns `owner_refresh_required`; the backend never refreshes
or writes the native key and never falls back to running `amp usage` for a reference.
It checks the source again after provider I/O and separates cache identity by its
current key. Removing the account removes only the binding.

Once this public native source is registered, use its opaque account ID instead of
the legacy `local` alias. The duplicate implicit native adapter is suppressed;
independently configured AMP_API_KEY or custom AMP_URL local sources retain their
existing behavior. This does not introduce automatic registration or migrate Swift
credentials. The app's current binary pin predates this implementation.

## Z.ai quota metadata

Z.ai usage now includes subscription names when the subscription endpoint succeeds.
A subscription failure is a scoped diagnostic and does not discard valid quota.
Known quota periods expose the existing Swift metric IDs. TIME_LIMIT uses its
reported counters; a zero limit remains unknown rather than invented exhaustion.
The quota endpoint's business error code is validated before accepting its data.

## Z.ai custom-provider source

The `quotio_custom_provider` source also accepts an enabled `glm-api-key` record.
Only HTTPS api.z.ai on its standard port is accepted for these Swift-derived
references. Configured custom origins and the China origin are unsupported for
this source; the existing independent CLI region option is unchanged.

Keys stay in the owner's configuration. Backend refresh tries them in configuration
order and retains the last valid quota, while preserving failed-key diagnostics.
Changing the key list invalidates its cache identity. Per-key work shares the
Collector deadline, so a later key timeout does not erase an earlier successful
result. Optional subscription metadata uses part of that same budget.

## Unlimited quota and Warp grants

Quota can have `state: unlimited`, distinct from unknown and a finite 100 percent
balance. Warp keeps reported usage alongside that state. Grant notes are returned
in window `note`; grant IDs include their scope and stable allocation metadata,
not remaining usage. Distinct grants are retained when the response provides no
reliable unique ID to prove duplication. Invalid grant data or partial GraphQL
errors retain valid request quota with diagnostics. Request context names the
current node platform. These changes do not migrate or read Swift's Warp vault.

### Account quota selection

`PATCH /v1/accounts/{id}` accepts `enabled` for owned accounts and borrowed
references. Disabling an account prevents new quota requests and credential refresh,
removes its cache identity, and discards a quota result that finishes after disabling.
It does not change the provider login or the source owner's configuration. A token
rotation already accepted by the provider is still persisted to avoid losing the
replacement credential; its quota result is discarded while disabled.

Writing this flag upgrades the vault document to format 4 atomically. Existing
accounts default to enabled; the prior Amp reference flag remains respected. Older
binaries reject format 4 instead of ignoring disabled accounts. Adding another
source or recording a mutation receipt preserves the newer format version.

### Factory refresh ownership and vault format 5

Owned Factory OAuth refresh tokens remain reserved to one account, regardless of
organization. The vault keeps fingerprints of current and previous refresh tokens
after rotation and account removal. Deleting an account does not release these
reservations or allow a failed refresh to be retried under a new account. Recover
with fresh, separately owned credentials, not a previously registered refresh token.
If `organization_id` is supplied, the access token must contain the same WorkOS
`org_id` claim. A missing or mismatched claim blocks the quota request.

Writing refresh reservations upgrades the vault document to format 5 in the same
atomic write. Current readers accept formats 1–5. A write to an existing older-format
document containing reservations also upgrades it, even for an unrelated account
rename. Later writes preserve format 5 and the reservations, including removal of
the last account and receipt recovery after an uncertain commit. Binaries that only
support formats 1–4 reject format 5 rather than silently dropping the reservations.
Do not downgrade after this write or manually lower the document version. This is
an internal account-storage change, not an HTTP API schema version change or a
migration of the Swift application's vault.

### Cursor quota endpoints

Cursor collection combines `auth/usage-summary` with the existing current-period
RPC using one token snapshot. Summary metrics keep the Swift IDs `plan-usage` and
`on-demand`, the provider's unscaled amounts, membership plan, and exact supplied
billing-cycle reset. On-demand does not inherit the plan reset. RPC metrics retain
the current-period and model percentages with separate stable IDs.

Missing counters and zero limits remain unknown. Unlimited is reported only when
explicitly supplied by the summary. A malformed metric or failed endpoint adds a
scoped diagnostic without deleting valid sibling data; endpoint deadlines leave
time to return partial results within the collector budget.

### Cursor native source

Managed servers accept `POST /v1/account-sources` with
`{"kind":"cursor_native"}` and an `Idempotency-Key`. On macOS, the backend resolves
Cursor's standard state database and saves an opaque borrowed-native reference.
The request cannot supply a path, token or ownership flag. Registration reads the
local login only and does not validate it against a remote endpoint or trigger OAuth.

Account-ID refresh resolves the token on the node, carries available email, plan
and `account.subscription_status`, and rechecks the source after HTTP. Changes to
token or metadata invalidate the shared cache identity. Source metadata may be
missing without suppressing usable quota. A rejected token requires the native
owner to log in; the backend never refreshes or writes Cursor's login. A disabled
reference blocks the equivalent native `local` alias; an explicit environment
token remains an independent legacy source.

The reader copies the database and its committed WAL frames into a bounded private
snapshot before opening SQLite. It never copies the owner's SHM file; SQLite may
rebuild SHM only inside the private directory. Symlinks, unsafe database files,
malformed WAL data, source changes during capture or refresh, and unsafe schemas
are rejected. Native source registration is macOS-only; Linux retains
explicit-token usage and encrypted account storage. Live acceptance with Cursor
open and an active WAL remains pending.

### Grok plan and extra usage

Grok usage reads billing and settings with the same token snapshot. The settings
response supplies the subscription display name; errors remain scoped diagnostics
and do not discard billing data. Weekly/monthly credit metrics have stable IDs,
and reset timestamps are kept exactly as supplied, including elapsed periods.
Missing percentages remain unknown.

`grok-extra-usage` reports a supplied zero cap as `quota.state: disabled`, a positive
cap as `quota.state: limit` with `amount` and unscaled `unit: units`, and a missing
cap as unknown. This is a configured spending limit, not remaining credit. No
balance, reset or usage amount is invented. Malformed sibling fields retain valid
quota with diagnostics. Multi-account native source registration and owned OAuth
refresh remain pending; this change does not refresh or write native Grok files.
