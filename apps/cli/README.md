# Quotio CLI

A standalone Rust CLI for provider quota and usage reports. The current registry
contains 46 real providers: 8 original routes and 38 catalog `Definition`s. `mock`
is a separate deterministic fixture, not a real provider. No TUI yet.

| Group | Providers | Credential path | Verification boundary |
| --- | --- | --- | --- |
| Original routes (8) | Codex, Amp, Antigravity, Factory, Synthetic, OpenRouter, Z.ai, MiniMax | Provider-specific OAuth, API-key, CLI, or native-service route | Route-specific automated coverage; live acceptance varies by provider |
| Catalog API-key routes (30) | ai&, Alibaba Coding Plan, Chutes, ClawRouter, ClinePass, Codebuff, Crof, Deepgram, DeepInfra, DeepSeek, Devin, Doubao Coding Plan, ElevenLabs, Fireworks, Groq, IBM Bob, Kilo, Kimi Code, LiteLLM, LLM Proxy, Moonshot, NeuralWatt, OpenAI organization usage, OpenCode Go, Poe, sub2api, Venice, Warp, xAI, ZenMux | Hidden key prompt, `--token-stdin`, or the named environment variable | Offline tests passed; no live credential acceptance |
| Catalog OAuth routes (8) | Azure OpenAI, Claude, Gemini, GitHub Copilot, Cursor, Grok, Kiro, Vertex AI | Explicit access token, supported native source, or provider CLI fallback | Offline tests passed; no standalone Quotio sign-in |
| Mock | Mock | No credential | Fixed offline fixture |

Azure OpenAI cost and Doubao Coding Plan are registered catalog providers. Azure
uses an Entra bearer or noninteractive Azure CLI fallback with a required ARM
`resource_id`; Doubao uses a hidden Volcengine SecretAccessKey with a required
nonsecret AccessKey ID. Their automated coverage does not establish live account
access, IAM authorization, or subscription entitlement. Ollama Cloud and OpenCode
Zen remain absent because the reviewed sources do not provide an API-key quota or
balance route without browser state. OpenCode Go is a separate, implemented provider.

Antigravity can use the running app's local service when direct API quota is unavailable.

## Local REST API

```sh
cargo run -- serve --provider codex --provider amp
curl http://127.0.0.1:6767/v1/usage
```

`serve` refreshes usage in the background and exposes read-only snapshots on
loopback. It shares the CLI's provider adapters, saved accounts, and JSON report
schema. Add `--manage` with `QUOTIO_SERVER_TOKEN` to enable managed account, Codex OAuth relay/loopback, settings, and refresh operations. `--public-url` records an HTTPS reverse-proxy origin and `--allow-origin` enables exact CORS origins; neither provisions TLS or changes the loopback listener. See [local REST API](docs/local-http-api.md) for routes, authentication, refresh behavior, and startup options. The complete contract is [OpenAPI 3.1](docs/openapi.json). Managed writes use idempotency keys, with up to 128 running operations. The most recent 128 refresh results are retained for up to 15 minutes; up to 4096 account write results and retry keys are retained until restart. Linux supports an encrypted account vault with a separately supplied master key. Adding a provider still requires its supported login or credential path.

Native parents may also pass `--cli-proxy-auth-dir` with `--manage --parent-pipe`.
Quotio reads supported Codex, Claude, GitHub Copilot, Antigravity, Kiro, and Vertex
JSON auth files from that directory for usage collection without importing, refreshing,
editing, or deleting them.

## Run

Use Rust stable with edition 2024 support. The package declares Rust 1.88 or newer;
this revision was verified with Rust 1.92.0. `Cargo.lock` pins dependencies.

```sh
cargo run -- --help
cargo run -- providers
cargo run -- usage
cargo run -- usage --provider mock --format text
cargo run -- usage --provider mock --format json
cargo run -- usage --provider mock --provider mock --timeout 5 --no-color --verbose
cargo run -- usage --config ./config.toml
cargo run -- usage --provider codex --provider amp --timeout 30
cargo run -- usage --provider antigravity --provider factory --format json
```

Repeated provider IDs are deduplicated, keeping the first occurrence. Timeout is
an integer from 1 to 3600 seconds, default 10, applied separately to each provider.
Text output is always plain, so `--no-color` is accepted without changing it.
`--verbose` sends logs to stderr. Reports go to stdout.

## Developer-signed macOS builds

On macOS, `cargo run` now signs the Quotio binary before launching it. The runner
uses a fixed identifier, `dev.quotio.cli`, and a developer certificate from the
login Keychain. It never falls back to ad-hoc signing. Run Cargo from this repository
so its `.cargo/config.toml` is loaded.

```sh
cargo run -- usage --provider codex --format text
./scripts/build-signed.sh --offline
./scripts/build-signed.sh --release --offline
```

The build script produces `target/debug/quotio` or `target/release/quotio`. Plain
`cargo build` alone has no post-link signing hook; use the script for a guaranteed
signed build, or let `cargo run` sign the result. Cargo test harnesses are passed
through unchanged and do not acquire the product's signing identity.

The scripts select the sole installed Developer ID Application identity. If none
exists, they accept a sole Apple Development/Mac Developer identity for local use.
If selection is ambiguous, set `QUOTIO_SIGNING_IDENTITY` to the full certificate
name or SHA-1 listed by `security find-identity -v -p codesigning`.
No Team ID, certificate name or fingerprint is committed as a project default.
Each fork uses its builder's installed identity; the Team ID in the signed binary
is derived from that certificate.

Signing happens on a temporary copy, verifies strictly, then atomically replaces
the binary. A signing failure prevents execution. No private key is exported.
This workflow uses hardened runtime with no added entitlements and no timestamp
server request. It is for local use; notarization/distribution is a separate step.

Existing vault authorization may need one explicit update because the identity
changed from the previous signing identifier or an ad-hoc binary. Run `cargo run -- accounts list` and authorize
the developer-signed build when macOS asks. The new designated requirement stays
stable across builds under the same identifier and developer team. The workflow
does not rewrite or weaken the vault's ACL.

## Usage cache

`usage` and `serve` share the persistent `UsageCache` service. Each provider/account
is checked independently. Usage is reused while every window's `fetched_at` is less
than `cache_ttl_seconds` old. At exactly 300 seconds with the default setting, the
entry is expired. Missing, invalid and future-dated entries are fetched again.

```sh
quotio usage --force
quotio usage --provider codex --force
quotio usage --provider codex --account ACCOUNT_ID --force
```

`--force` refreshes every selected account even when its cache is fresh. It does not
refresh unselected providers or accounts. Set `cache_ttl_seconds = 0` to refresh on
every invocation while still retaining the last good snapshot for failures.

A successful fetch saves only normalized `ProviderUsage` JSON. A failed refresh
keeps the last good snapshot for the verified login and includes the new error in
`failures` and CLI stderr. Its `fetched_at` stays unchanged. A report with retained
usage and failures exits with code 1. `generated_at` is the report creation time,
not the time every account was fetched. JSON schema version 1 is unchanged.

The default directory is `ProjectDirs::cache_dir()/usage-v1`, typically
`~/Library/Caches/quotio/usage-v1` on macOS or
`${XDG_CACHE_HOME:-~/.cache}/quotio/usage-v1` on Linux. `QUOTIO_CACHE_DIR` can select
another directory, including an isolated directory for tests. CLI and server must
use the same directory to share entries. Cache JSON contains public account labels
and usage, but no credentials, API keys, access tokens or refresh tokens. Opaque
filenames hash the provider, account reference and login/scope identity; credential
material used for that hash stays in memory.

Account identity is checked before reuse and after a fetch. Managed accounts use
their vault ID and login scope. Local sources reuse their existing credential
resolvers; region, organization, project and profile settings also separate entries.
Changing login or removing an account prevents its old entry from being returned.
Old files remain on disk until the cache directory is cleared.

When identity cannot be verified, Quotio fetches directly and does not return an
unverified old snapshot. In particular, local Codex identifies personal accounts
through `account/read`, but its current protocol does not expose a workspace ID.
Local Codex workspace usage, Amp CLI-only fallback and Antigravity local-service
fallback therefore bypass usage caching. Save a Codex workspace through Quotio to
cache it by its managed account ID. The demo `mock` provider keeps its fixed fixture
timestamps, so old demo windows are fetched again.

Cache read/write errors produce fixed diagnostics on stderr and do not replace
provider results. On macOS/Linux, each entry has an OS file lock covering read,
fetch and write. Waiters recheck freshness after acquiring it. Writes use a synced
temporary file and atomic rename; crashes release the lock. Different accounts
can refresh concurrently. Newly created cache directories and files use private
permissions. Platforms without the implemented OS lock bypass disk caching.

Identity/lock preparation shares the provider timeout budget. A final login check
has a separate bounded timeout so a timed-out quota request can still return a
verified stale snapshot. Cancellation interrupts identity checks and provider work.

## Config

```toml
# config.toml
disabled_providers = ["amp"] # optional; excluded from automatic CLI discovery
enabled_providers = ["mock"] # server selection; mock always requires explicit CLI selection
cache_ttl_seconds = 300 # optional; default is 5 minutes
```

`--config` chooses an explicit file. Otherwise `directories::ProjectDirs` locates
`quotio/config.toml` under the platform config directory. Typical locations are:

- macOS: `~/Library/Application Support/quotio/config.toml`
- Linux: `$XDG_CONFIG_HOME/quotio/config.toml`, or `~/.config/quotio/config.toml`
- Windows: the application config directory returned by `ProjectDirs`.

Without `--provider`, `quotio usage` automatically selects enabled saved accounts and
detectable local sources, including supported environment credentials and installed
Codex/Amp CLIs. Providers in `disabled_providers` are excluded. Disabled saved
accounts and the `mock` fixture are never auto-selected. An explicit `--provider`
overrides automatic discovery and the disabled list.

`enabled_providers` remains the server's configured selection. A missing default
config is valid; if CLI discovery finds nothing, `usage` exits with code 3. A missing
explicit config, invalid TOML, unknown fields or unsupported provider is a config
error, code 2. The CLI does not create a config file. It creates the usage cache
directory when needed.

Do not put credentials in config. Unknown fields, including token fields, are
rejected. Parse errors show a line and column without echoing input. Argument
errors also omit input values; use `quotio usage --help` for valid syntax.
`CredentialStore` reads environment variables, but mock never requests a secret.
Credentials are persisted only by explicit account commands in the protected vault; they are
never printed or logged.

## Add and manage accounts on macOS and Linux

```sh
# Codex opens the official sign-in page. No Codex CLI is required.
cargo run -- accounts add --provider codex

# Amp and Factory prompt for a hidden API key in a terminal.
cargo run -- accounts add --provider amp
cargo run -- accounts add --provider factory

# Scripts can pipe keys from an existing secret-manager environment.
printenv AMP_API_KEY | cargo run -- accounts add --provider amp --token-stdin
printenv FACTORY_API_KEY | cargo run -- accounts add --provider factory --token-stdin

cargo run -- accounts list
cargo run -- accounts list --format json
cargo run -- accounts use <account-id>
cargo run -- accounts remove <account-id>
cargo run -- usage --provider codex --provider amp --provider factory
```

`--label` is optional. Codex defaults to the authenticated email. API-key accounts
default to `API key ****ABCD`, showing only the last four ASCII characters of keys
longer than eight characters; shorter or non-ASCII keys are fully masked. An explicit
label takes precedence. If a label already exists, supply a different `--label`.

For Codex, `--no-browser` prints the login URL without opening it. Callback binds to
`localhost:1455/auth/callback`; close another login process if that port is busy.
Login uses PKCE, state and nonce validation, then reads quota before saving. It has
a 180-second budget and supports Ctrl-C. No browser cookies are read.

For Factory, `--region global|eu` and `--organization <id>` may be supplied during
Add account. Amp/Factory prompt for a hidden key when stdin is a terminal. Press
Enter to submit or Ctrl-C to cancel. Terminal echo is restored on completion,
cancellation or timeout. Scripts must pass `--token-stdin` to read one key line
from a pipe. Keys are never accepted as command arguments. A failed validation or
save does not create an account.

The first saved account for each provider becomes active. Additional accounts are
saved without changing the selection; use `accounts use` to select them. Removing
an active account selects the next account for that provider. Removal affects only
Quotio's saved record; it does not revoke remote tokens or log other apps out.

On macOS, all account metadata and tokens live in one protected Keychain item:
service `app.quotio.cli.accounts.v1`, account `vault`. This existing storage key is
independent of signing identifier `dev.quotio.cli` and is retained for account
compatibility. No plaintext credential files
are created. Empty local lock files coordinate short vault transactions and per-account refresh. Writes that fail before replacement preserve the previous document. If directory
sync fails after replacement, `credential_commit_uncertain` reports that the change
may already be present. Inspect accounts before attempting a new mutation. Listing
prints metadata only.

On Linux, the same account commands and REST service use AES-256-GCM storage at
`${XDG_DATA_HOME:-~/.local/share}/quotio/vault/accounts.enc`. The binary envelope
has a version and authenticated header; each write uses a new random nonce.
The existing document format and transaction locks are shared with macOS.

Supply exactly one master-key source before starting the CLI or service:

- `QUOTIO_VAULT_KEY_FILE`: path to a file containing exactly 32 random bytes. It
  must belong to the current user, have no group/other permissions, have one
  hard link, and be a regular file, not a symlink. Store it outside the vault
  directory. Quotio does not generate or save the master key.
- `QUOTIO_VAULT_KEY_FD`: an inherited file descriptor numbered 3 or above,
  containing exactly 32 bytes followed by EOF. Pipes must close within five
  seconds. A regular-file descriptor has the same ownership, permission and
  location restrictions as a key file. The descriptor is marked close-on-exec.

Keep a protected backup of the key separately from the encrypted vault; losing
it makes saved accounts unreadable. The key itself never belongs in command
arguments, configuration, logs, or API requests. Missing/invalid keys and damaged
ciphertext report storage unavailable; they do not produce an empty account list
or overwrite an existing vault. Restart the service after correcting key access.
Use `--no-saved-accounts` explicitly to run usage without opening saved accounts.

For Codex and Amp, `usage --provider <provider>` reads the available local account
and all saved accounts, including inactive ones. Synthetic, OpenRouter, Z.ai and
MiniMax likewise read all saved keys plus an explicit environment key when present.
Factory retains its active-account
selection. Use `--account local` or `--account <saved-account-id>` to select one:

```sh
cargo run -- usage --provider codex --account local
cargo run -- usage --provider amp --account local
cargo run -- accounts list
cargo run -- usage --provider codex --account <saved-account-id>
```

`--account` requires exactly one explicit provider and conflicts with
`--no-saved-accounts`. An unknown or wrong-provider account ID is an argument error.
When Codex is not installed, saved accounts still work without a local failure.
With no installed or saved account, the requested provider reports unavailable.

Duplicate successful Codex results prefer the saved account. Matching uses provider
account ID, or a unique personal-plan email when the local API has no account ID.
Business/workspace or unknown plans are never merged by email alone; ambiguous
identities stay separate. Amp removes a duplicate local result only when its
reported identity and quota windows, balances and reset values match a saved
result. Different scopes or balances remain separate. Failures are not hidden by
deduplication.

JSON successes and failures may include `account_ref` with the selector ID and
label. The authenticated provider identity remains in `account`; optional `plan`
is supplied when known. Text output shows the selector alongside each account.
Timeout/cancellation applies to each account, and refresh locks are per account.

Use `usage --no-saved-accounts` to explicitly skip the vault. A locked/denied vault
is reported separately; available local Codex and Amp data is preserved.
`usage` requests noninteractive Keychain access. If macOS requires authorization,
the saved-account read fails with `credential_storage` instead of repeatedly asking
for permission. Run `accounts list` explicitly to authorize access for this build.
Choosing Allow can authorize only the current request. Use the developer-signed
workflow above for stable application identity across builds. No ACLs are weakened
by the CLI.
Native Keychain calls cannot be cancelled at the OS boundary; command exit no longer
waits indefinitely after a timeout. If an account write times out, inspect the saved
accounts before retrying because the OS write outcome may be uncertain.

Managed storage supports macOS Keychain and the encrypted Linux vault described
above. Other platforms retain the previous environment/CLI usage routes. There is
no plaintext storage fallback.

Saved Codex accounts use `source: codex_api`. Refresh occurs near expiry or after
authentication failure, and all rotated tokens are saved before a quota retry.
Refresh is serialized and never automatically replayed after an uncertain failure.
Amp API accounts use `source: amp_api` and require no Amp binary. Factory uses
`source: factory_billing_limits` with account/organization validation.

Without saved accounts, Codex retains its installed-CLI route. Amp first uses
`AMP_API_KEY`, then the public-host key in `~/.local/share/amp/secrets.json`, and
calls the quota API directly. That existing file is read-only and size-bounded;
symlinks are rejected on Unix. If no key exists, or AMP_URL selects a custom host,
Amp retains its CLI route. Quotio submits no prompts and never starts login/logout
through those fallback CLIs.
Those CLIs may perform their usual internal auth maintenance or update checks.
Missing executables or unsupported output become per-provider failures.

## Catalog API-key accounts

Run `cargo run -- providers` to see each catalog credential and every allowed
setting. For a catalog API-key provider, `accounts add` asks for the key with
terminal echo disabled. The key is never accepted as a command argument. Scripts
may provide one key on stdin with `--token-stdin`.

```sh
cargo run -- accounts add --provider fireworks --setting account_id=acct_123
cargo run -- accounts add --provider devin --setting organization_id=org_123
cargo run -- accounts add --provider doubao --setting access_key_id=AKLTEXAMPLE
cargo run -- accounts add --provider litellm --setting base_url=https://proxy.example
```

`--setting NAME=VALUE` stores only allowlisted, nonsecret metadata with the key.
Repeat it for multiple settings. A required setting can also come from its
documented environment variable. Unknown, duplicate, empty, and control-character
settings are rejected. Do not put a token, secret, or password in `--setting`.

| Provider | `--setting` metadata | Requirement |
| --- | --- | --- |
| Moonshot / Kimi | `region` | Optional; `MOONSHOT_REGION` |
| xAI | `team_id` | Required; `XAI_TEAM_ID` |
| Alibaba Coding Plan | `region` | Required; `ALIBABA_CODING_PLAN_REGION` |
| Kilo | `organization_id` | Optional; `KILO_ORGANIZATION_ID` |
| Fireworks | `account_id` | Required; `FIREWORKS_ACCOUNT_ID` |
| Deepgram | `project_id` | Required; `DEEPGRAM_PROJECT_ID` |
| Devin | `organization_id` | Required; `DEVIN_ORG_ID` |
| Doubao Coding Plan | `access_key_id` | Required; `DOUBAO_ACCESS_KEY_ID` |
| ClawRouter | `base_url` | Optional; `CLAWROUTER_BASE_URL` |
| LiteLLM | `base_url` | Required; `LITELLM_BASE_URL` |
| LLM Proxy | `base_url` | Required; `LLM_PROXY_BASE_URL` |
| sub2api | `base_url` | Required; `SUB2API_BASE_URL` |
| OpenAI organization usage | `project_id` | Optional; `OPENAI_PROJECT_ID` |

The command saves validated metadata with the API key. Environment metadata is a
fallback for an omitted setting. `cargo run -- providers` shows the current
required/optional flag, so use it instead of copying an old table after upgrades.
Doubao's hidden API key is `DOUBAO_SECRET_ACCESS_KEY`; its `access_key_id` setting
is nonsecret metadata and must not contain the SecretAccessKey.

### Admin and Management keys

`openai` reads organization usage and costs with `OPENAI_ADMIN_KEY`; an ordinary
project key is not a substitute. `xai` and `zenmux` use `XAI_MANAGEMENT_API_KEY`
and `ZENMUX_MANAGEMENT_API_KEY`, respectively. These privileged keys are still
entered through the hidden prompt or `--token-stdin`, never as a command argument.

### Catalog OAuth routes

Azure OpenAI, Claude, Gemini, GitHub Copilot, Cursor, Grok, Kiro, and Vertex AI
are OAuth catalog providers. `accounts add` does not start or import a standalone
OAuth login for them. Supply the documented explicit access-token environment
variable: `AZURE_ACCESS_TOKEN`, `CLAUDE_OAUTH_ACCESS_TOKEN`,
`GEMINI_OAUTH_ACCESS_TOKEN`, `COPILOT_API_TOKEN`, `CURSOR_ACCESS_TOKEN`,
`GROK_OAUTH_TOKEN`, `KIRO_ACCESS_TOKEN`, or `VERTEXAI_ACCESS_TOKEN`.

Azure OpenAI also requires nonsecret `resource_id` metadata
(`AZURE_OPENAI_RESOURCE_ID`). Without an explicit token, it can request an Azure
Resource Manager token through noninteractive `az account get-access-token`; it
does not run `az login`, scan Azure credential files, or read browser state.

The adapters do not read browser cookies. Claude, Gemini, Copilot, Cursor, and
Grok reuse a valid native token without a Quotio login or refresh flow. Kiro and
Vertex AI can refresh recognized native credentials in memory, but they do not
start a login or write the owning application's credential files. Codex keeps its
separate Quotio-owned sign-in flow.

Catalog implementation means that a `Definition` and synthetic parser/local
HTTP-fixture coverage exist. It does not mean a real key, OAuth credential, IAM
role, or subscription has been accepted live. The full offline suite passed 143
library, 12 CLI, and 17 collection tests (172 total), with one opt-in test ignored.

## Additional API-key providers

```sh
cargo run -- accounts add --provider synthetic
cargo run -- accounts add --provider openrouter
cargo run -- accounts add --provider zai --region global
cargo run -- accounts add --provider minimax --region global
cargo run -- usage --provider synthetic --provider openrouter --provider zai --provider minimax
```

These commands use the hidden key prompt; scripts can pass `--token-stdin`.
Z.ai and MiniMax accept `--region global|cn`, defaulting to global. Factory still
accepts only global/eu. No key is automatically retried against another region.

| Provider | Environment credential | Optional region |
| --- | --- | --- |
| Synthetic | `SYNTHETIC_API_KEY` | — |
| OpenRouter | `OPENROUTER_API_KEY` | — |
| Z.ai | `ZAI_API_KEY` | `ZAI_REGION=global|cn` |
| MiniMax | `MINIMAX_API_KEY` | `MINIMAX_REGION=global|cn` |

MiniMax requires a Coding/Token Plan key. The global route follows the documented
`www.minimax.io/v1/token_plan/remains` endpoint. Z.ai uses its monitor API;
its schema is backed by reference implementations and may change.

OpenRouter reads `/api/v1/key`, not the management-key-only account credits API.
Daily/weekly/monthly amounts are USD spend. A spending cap uses `limit_remaining`,
not lifetime spend, to calculate the percentage. Uncapped keys show consumption
without an invented remaining balance. Synthetic's next replenishment is kept as
a description, not misrepresented as a full reset timestamp. MiniMax's
`usage_count` fields are interpreted as remaining counts; modern percentages take
precedence over legacy zero placeholders. MiniMax status3 lanes are omitted because
they can mean unavailable or unlimited rather than a metered quota; unknown status
codes are rejected until their semantics are verified.

These providers identify each key with a provider/region-scoped fingerprint after
successful quota validation. This identifies a key, not an account email; different
keys can have different caps even when owned by the same person. Saved labels still
default to the masked key. No browser cookies, local app credential imports, proxy
credential directories, endpoint overrides or generation requests are used.

## Other credential sources

Antigravity uses `ANTIGRAVITY_ACCESS_TOKEN` first, then the `access_token` field
in the JSON file selected by `ANTIGRAVITY_AUTH_FILE`. On macOS, without either
explicit source, it reads the existing Antigravity login from Keychain
(service `gemini`, account `antigravity`) and calls Google's quota APIs directly.
The direct API route does not require a running app. If it cannot provide quota,
Quotio can fall back to the running Antigravity app's local language server.
This fallback does not run for explicitly supplied environment/file credentials,
so it cannot silently select a different account. No browser cookies are used.

If Keychain access is blocked, authorize it once from the signed CLI:

```sh
cargo run -- accounts authorize --provider antigravity
cargo run -- usage --provider antigravity --format text
```

The authorize command allows macOS to show its Keychain permission dialog. Choose
Always Allow if you want subsequent usage checks to read the login without asking.
Keep using the same signing identity. The `usage` command never opens that dialog;
it reports an actionable error when the credential store cannot be read.

Expired native access tokens are refreshed through Google OAuth using client
configuration discovered from the installed Antigravity app. An unrecognized or
ambiguous app layout stops refresh. Quotio stores only the derived access token
in its own Keychain item, bound to the current login. It checks the original login
before using cached tokens and before returning quota. Antigravity's credential
values are never rewritten. Explicit environment/file tokens are not refreshed.
A missing quota remains unknown; missing windows are not invented. If the models
endpoint reports every quota as full, Quotio requires confirmation from
`retrieveUserQuota` before displaying those limits. If confirmation is denied,
it reports `quota_unavailable`. This conservative check can also hide genuinely
unused or newly reset quotas. An all-full response alone does not prove that the
values are defaults. Both the daily and stable Google Cloud Code hosts are tried
when quota endpoints are unavailable. The native-session route then tries local
`RetrieveUserQuotaSummary`, with source `antigravity_local_service`. It verifies
the process and its IPv4 listening port, checks the local account before and after
reading quota, and matches the Google account when already known. Only returned
windows appear, using Session, Weekly, Claude Session and Claude Weekly labels.
The app must already be running; Quotio does not launch it or `agy`.

Without a saved account, Factory uses `FACTORY_API_KEY`. Optional `FACTORY_REGION` is `global`
or `eu`; `FACTORY_ORG_ID` selects the organization. The adapter validates user and
organization with Factory before and after reading quota. Local encrypted Droid
auth reuse is not implemented pending the requested explicit authorization.
The internal billing endpoint is verified from first-party code, but API-key
acceptance has not yet been validated live.

Set credentials through your existing environment/secret manager. Do not put them
in TOML, shell command arguments, fixture files or bug reports. See the contract
notes for the exact authenticated destinations. Remote HTTP uses normal TLS and
disables redirects. A separate Antigravity loopback client accepts the local service's
self-signed certificate only at a verified process-owned IPv4 port. That client
cannot follow redirects, use a proxy, or send OAuth tokens.

## Output contract

JSON has `schema_version: 1`, RFC 3339 `generated_at`, `providers`, and `failures`.
Arrays preserve request order within successes and failures. Each provider contains
`provider`, `account` with `id` and `label`, and an arbitrary number of `windows`.

Codex optionally includes `reset_credits`, an observation of banked **quota resets**,
not monetary credits, consumption, or a computed pool-restoration percentage:

```json
{"reset_credits":{"available_count":2,"earliest_expires_at":"2026-10-01T00:00:00Z","fetched_at":"2026-09-08T12:00:00Z","source":"codex_api"}}
```

Saved OAuth accounts read `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`
with their own access token and ChatGPT account ID. Native Codex reads optional
`rateLimitResetCredits` from `account/rateLimits/read`; older CLIs that omit it
remain unsupported (no credential-file scraping or invented count). The count is
the upstream authoritative `available_count` / `availableCount`, not the length
of the detail list (which Codex documents may be capped). Earliest expiry considers
only available Codex reset rows with future expiries, ignoring redeemed, expired,
unknown-status and other-reset-type rows. Native count-only summaries preserve
the upstream count with unknown expiry; native detail failures can be hidden by
Codex's own count-only fallback and cannot be diagnosed by Quotio.
`earliest_expires_at: null` means no expiry is known, not unlimited validity.

An omitted `reset_credits` means unknown/unsupported/failed lookup, **not zero**.
Lookup errors preserve subscription windows and add a sanitized diagnostic with
`source: codex_reset_credits` (also included in report failures, exit 1). Zero is
reported only after a successful lookup. No credit IDs, tokens or redemption API
are exposed. Read-only `serve` is sufficient; no `--manage` is needed.

Use `reset_credits.fetched_at`, never `generated_at`, for balance age. Fresh cache
hits retain this timestamp. Stale quota fallback drops the balance; reaching its
earliest known expiry triggers a cache refresh and suppresses the old balance,
including from HTTP snapshots between refreshes. Count-only observations cannot
predict expiry, and credits may be redeemed elsewhere after any observation.
Clients should show the observation age and apply their own freshness limit.
This is additive: schema/API version 1 is unchanged.

Upstream contracts: [Codex account protocol](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/account.rs)
and [WHAM reset-credit client](https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client/rate_limit_resets.rs).

Each window contains `label`, `quota`, nullable `resets_at`, `provenance` with
`source` and `confidence`, and RFC 3339 `fetched_at`. Timestamps include an offset.
Optional `consumption` records `used` and `unit` independently of any cap or balance,
for example OpenRouter USD spend. It is omitted from existing provider reports.
Optional `amounts` records a balance as `remaining`, nullable `limit`, and `unit`.
USD credit balances with no limit retain unknown percentage in JSON, including a
zero balance. Text renders those as balances rather than missing usage. Amp
subscription dollar/hour allowances are separate windows with used/remaining amounts.

Optional `reset_description` preserves source wording such as `daily` or
`upon renewal in 13 days` when an exact reset timestamp is unavailable. Text uses
that description instead of `reset unknown`; `resets_at` remains null. An exact
timestamp takes precedence when present. Date-only billing ends are labeled with
`timezone unspecified`. Relative descriptions refer to the observation time.

The mock's fixed observation date is January 1, 2026. It is demo data, not fresh
account usage. The report generation time uses the injected clock.

Quota examples:

```json
{"state":"available","used_percent":25.0,"remaining_percent":75.0}
{"state":"exhausted","used_percent":100.0,"remaining_percent":0.0}
{"state":"unknown"}
```

Missing or non-finite input becomes unknown. Finite input is clamped to 0–100.
Unknown usage has no numeric percentage fields and never means exhausted.
Collector rejects inconsistent numeric quota values returned by an adapter.
Confidence is `exact`, `estimated` or `unknown`. Consumers can calculate observation
age from `fetched_at`; cached failures preserve this observation time.

A failure contains `provider`, a fixed `code`, and a safe `message`. Codes are
`timeout`, `cancelled`, `transient`, `authentication`, `invalid_data`, `internal`,
`unavailable`, and `rate_limited`.
A failed provider does not remove successful results. Failures are included in
reports and summarized on stderr. Consumers should allow future additive fields;
incompatible changes require a new schema version.

| Exit | Meaning |
| --- | --- |
| 0 | Every selected provider returned valid data |
| 1 | Some providers succeeded and some failed |
| 2 | Invalid arguments or config |
| 3 | No provider returned data, no providers selected, or output/runtime setup failed |

Ctrl-C cancels pending providers and emits a report with completed results. It uses
the same success/partial/empty exit rules. Output write errors use code 3.

## Code and extension points

- `src/domain.rs`: renderer-independent identity, quota, provenance and report types.
- `src/providers/mod.rs`: `ProviderAdapter`, injected HTTP client, clock and credential store.
- `src/providers/mock.rs`: fixed fixture, with available, exhausted and unknown windows.
- `src/providers/{codex,amp,antigravity,factory}.rs`: independent provider adapters.
- `src/providers/http.rs`, `src/providers/process.rs`: bounded transport and child lifecycle.
- `src/fetch.rs`: `Collector::collect(CollectRequest) -> UsageReport`.
- `src/cli.rs`, `src/config.rs`, `src/main.rs`: arguments, config and executable wiring.
- `src/output/`: independent text and JSON renderers.
- `tests/`: offline collection and binary contract tests.
- `VALIDATION.md`: verification evidence.

The collector runs adapters concurrently with Tokio. Each provider gets a deadline
covering fetches and retry delays. Only an idempotent adapter returning `Transient`
is retried, up to three total attempts, with 100 ms then 200 ms backoff. Cancellation
and timeout drop the adapter future. Dropping collection aborts its owned tasks.
HTTP 429 honors Retry-After within the deadline. Missing/invalid delays or delays
over one hour return rate_limited without rapid retries.

Adapters must remain async and cancellation-safe, and must not detach work or block
the runtime. Completed results are ordered before rendering.

The HTTP client uses reqwest JSON and rustls TLS. Redirects are disabled in the
executable. Tokio supplies concurrency, deadlines, cancellation channels and signals;
no extra async trait or cancellation dependency is needed. Serde, JSON and TOML
handle data/config; time handles timestamp offsets; thiserror provides fixed typed
errors; tracing sends diagnostics; clap parses arguments; directories resolves the
config location. Account onboarding additionally uses ring for secure randomness and PKCE hashing,
base64 for protocol encoding, libc for native file locking and cancellable input,
and security-framework on macOS for Keychain access.

To add a live provider:

1. Choose the provider and confirm its documented endpoint and authentication flow.
2. Implement `ProviderAdapter` using the injected client, clock and credential store.
3. Normalize missing data explicitly. Return public account metadata and source names
   only; never copy raw response bodies, headers or credentials into errors or logs.
4. Add sanitized fixtures and offline tests for authentication, malformed responses,
   rate limits, account identity and retries. Add the provider to CLI/config selection.
5. Verify live behavior separately with authorized credentials. Mock tests cannot
   establish that live authentication or quota fetching works.

Antigravity tries quota summary with a project, then without a project when needed,
then model quota. Optional project discovery failures do not block this fallback;
authentication and rate-limit failures stop it. Every window records its source.

A future TUI can reuse `UsageCache::collect` with a `Collector`, display the domain
report and use `Cancellation` on refresh or exit. It must not parse the CLI text or require changes
to provider fetch logic. No UI framework is needed in this milestone.

## Verification

`tests/cache.rs` uses an injected clock and fake adapters for TTL boundaries,
force refresh, stale failures, login/scope changes, invalid files, cancellation and
concurrent threads/processes. `tests/usage_cache_cli.rs` uses a fake Codex executable
to verify CLI persistence and REST reuse without live credentials or provider APIs.


```sh
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
```

After dependencies are downloaded, use `CARGO_NET_OFFLINE=true` to enforce offline
Cargo resolution. Tests need no credentials and call no endpoints. If the host's
shared Cargo target path is invalid, set `CARGO_TARGET_DIR=target` for local builds.
See `VALIDATION.md` for the exact checked commands and results.

CodexBar was inspected read-only for modeling and test ideas. Relevant files were
`UsageFetcher.swift`, `ProviderIdentitySnapshot.swift`, `ProviderFetchPlan.swift`,
`UsageFormatter.swift`, and `CopilotUsageModelsTests.swift`. No implementation was
copied. This project contains no CodexBar imports, path dependencies, binaries,
symlinks or submodules. Build and runtime do not need the reference checkout.


## Limits of this milestone

- Live evidence covers the Codex CLI, Amp direct API/multi-account, and Antigravity
  native authentication/local-service routes on this macOS installation.
- Synthetic, OpenRouter, Z.ai, MiniMax and Factory still need live acceptance with
  appropriate keys. Offline tests do not prove account entitlements or API stability.
- Antigravity direct quota can be denied even with valid authentication; its local
  fallback requires the app to be running.
- Z.ai monitor and other internal endpoints may change. MiniMax uses the documented
  global host; compatibility with actual subscription keys remains unverified.
- Saved account storage uses Keychain on macOS and an encrypted file with an
  externally supplied master key on Linux. Factory selects the active saved
  account; the other managed providers support multiple saved accounts/keys.
- Usage cache and REST polling are implemented; no TUI is included. Native Antigravity
  also has an existing, separate access-token cache in Keychain. Usage cache files
  never contain those tokens.
- Dates without a timezone in Amp output have no invented reset instant.
- Factory windows whose end is in the past remain unknown until replaced by fresh data.
- Reference projects were consulted read-only. Build/runtime require none of their
  checkouts, binaries, or proxy credential directories.

## License

Quotio CLI is licensed under the [MIT License](LICENSE). Dependencies retain their
own licenses; binary distributions also need the applicable third-party notices.

## Security checks

The GitHub workflows run on pull requests and pushes to main, with manual dispatch
available. They use read-only repository permissions, pinned action commits and no
stored checkout credentials. No developer certificate or provider secret is needed.

- Gitleaks scans full Git history with redacted findings.
- `python3 scripts/check-advisories.py` checks Cargo.lock against OSV and fails on
  advisories or incomplete/unavailable results. Only crates.io package names and
  versions are sent; private registries require an explicit policy and are not sent.
- `python3 scripts/test-check-advisories.py` tests the checker without network access.
- zizmor audits GitHub Actions changes with code-scanning uploads disabled.

The patched date parser uses time 0.3.47 and bounds Retry-After header input. See
[security remediation evidence](SECURITY_REMEDIATION.md) for verified results.

## Backend operations and releases

See [backend operation and recovery](docs/operations.md) for startup, background
supervision and live acceptance, and [macOS release preparation](docs/releasing.md)
for distribution signing, dependency notices and notarization. Local builds and
offline tests do not establish live deployment or distribution acceptance.

Release automation for GitHub Releases, npm (`quotio`) and Homebrew is described in
[release channels](docs/release-channels.md). Configure signing, npm trust and tap
access before triggering publication; the presence of the workflows does not mean
packages have already been published.
