# GPUI cutover contract and milestone 0 evidence

Status: milestone 0 is partially verified, not accepted. Signed GPUI experiments
passed Sparkle update, notarization, and synthetic Keychain approval checks.
The native shared-vault fix is now integrated into this checkout. Swift-to-GPUI
update and rollback with shared-vault writes passed on macmini. Synthetic
adoption from a populated isolated store also passed in the actual GPUI host.
On 2026-11-08, the owner waived real OAuth refresh and rollback testing and
requested work on subsequent milestones. This is a waiver, not a passing test.
Migration acceptance remains in milestone 1. Desktop CI at `67a8aede` passed
on macOS 15, Ubuntu 24.04, and Windows 2025.
Milestones 1 and 2 now have local migration-choice, pin/proxy import, Sparkle,
and packaging implementations. They are not accepted: native GUI checks are
paused on the in-use MacBook, and Windows package runtime is untested.
No public release or update feed has changed.

Research date: 2026-11-07. Repository baseline:
`21af52d1d37a76ea76ac4abf5c4abf64ec33b33f`.
Synchronization update: 2026-11-08, incorporating native commit `ae02c70d`.
This contract records implementation defaults for the next milestones. It is not
approval to publish releases, change update feeds, or delete Swift.

## Scope and support boundary

Replace the macOS desktop app with `apps/desktop`. Keep `apps/cli`, `apps/ios`,
and `Packages/QuotioHostClient`. Retire `apps/macos` and `Packages/QuotioCore` only
after migration, native acceptance, distribution, and rollback pass.

The compatibility target is macOS 14 or newer on both Apple Silicon and Intel.
Windows x64 and Linux x64 match the existing desktop release targets. Ubuntu
24.04 is the initial Linux acceptance target. These are targets, not a claim
that GPUI release artifacts already pass native acceptance on each platform.
Keep English, Vietnamese, Simplified Chinese, and French for macOS cutover.

Two downloaded release archives establish the existing macOS artifact baseline:

| Archive | App identity | Build | Minimum macOS | Executable architectures | Bundled components |
| --- | --- | --- | --- | --- | --- |
| `Quotio-0.33.1.zip` | `app.bytrong.quotio` | 75 | 14.0 | x86_64, arm64 | Sparkle, no Rust helper |
| `Quotio-1.0.0-beta.11.zip` | `app.bytrong.quotio.beta` | 87 | 14.0 | x86_64, arm64 | Sparkle and Rust helper |

Their SHA256 values are respectively
`290f21086b0cd62d133259a701f20b4fb2491822c99d407d175b1ee6a047d9bd` and
`9fe6608d23fbd140d8f532ae106a920a13227a9111dc3eca9440c5cca20ebb1b`.
The archive hashes matched GitHub asset metadata at inspection. Python
`zipfile`, `plistlib`, and `struct` read the actual app Info.plist and Mach-O
headers. A nested Sparkle Updater.app is not the product app.
These checks do not verify code signatures, notarization, launch, or runtime
compatibility on macOS 14.

Sources: [stable archive](https://github.com/nguyenphutrong/quotio/releases/download/v0.33.1/Quotio-0.33.1.zip),
[beta archive](https://github.com/nguyenphutrong/quotio/releases/download/v1.0.0-beta.11/Quotio-1.0.0-beta.11.zip),
[`desktop-release.yml`](../../.github/workflows/desktop-release.yml),
and [`Localization.swift`](../../Packages/QuotioCore/Sources/QuotioPresentation/Resources/Localization.swift).

## Identity remains separate during preview

Use `Quotio GPUI Preview` with proposed bundle identifier
`app.bytrong.quotio.gpui-preview`. A separate preview must keep isolated storage,
preferences, and autostart registration. The existing fallback vault namespace
is `quotio-desktop`; a dedicated preview namespace is not implemented. Do not
move an existing GPUI store silently when introducing a preview identity.

After acceptance, the replacement uses the existing stable or beta app identity,
respectively `app.bytrong.quotio` or `app.bytrong.quotio.beta`. Preserve the
existing `quotio` and `quotio-beta` URL schemes at cutover. The preview must not
claim these schemes or the Swift update feeds. There is no preview deep-link
scheme until a real flow needs one.

The proposed preview identity is not the production packaging configuration.
Today GPUI uses
`app.quotio.Quotio` in its app and autostart integration, while its Cargo runner
signs as `app.Quotio.desktop`. Reconcile those consumers with bundle metadata
before distributing a macOS preview.

The owner subsequently chose shared storage for the signed macOS replacement.
A bundled GPUI process whose signature satisfies the `dev.quotio.cli` Developer
ID requirement now uses the CLI's shared vault and default `config.toml`. It
also adopts the former Swift isolated store for its own bundle ID. Other builds
retain `quotio-desktop` and `host.toml`. This is a signature check, not a Debug
versus Release configuration check. A Debug binary re-signed with the qualifying
Developer ID also enters shared mode. A preview signed that way is not isolated,
even with a separate bundle ID.

The Rust self-signature check does not pin a Team ID; existing Keychain ACLs
still enforce their trusted designated requirements. Release signing must use
the expected Team. A common bundle ID alone grants no credential access.
Keep vault format 22 through the rollback window. Do not run competing OAuth
refreshes, proxies, or sharing listeners during transfer. Shared-vault operation
does not establish safety for concurrent app instances.

Sources: [`app.rs`](../../apps/desktop/src/app.rs),
[`autostart.rs`](../../apps/desktop/src/autostart.rs),
[`sign-and-run.sh`](../../apps/desktop/scripts/sign-and-run.sh), and
[`RuntimeIdentity.swift`](../../Packages/QuotioCore/Sources/QuotioDomain/Platform/RuntimeIdentity.swift).

## Storage sources must be identified before adoption

The following paths and selection rules come from source, not a scan of a real
Mac user's data. On macOS, `AS` below means `~/Library/Application Support`.

| Source | Accounts and host settings | Identity and other state |
| --- | --- | --- |
| Swift using an isolated helper | `AS/<support>/QuotioCLI`, with `AS/<support>/quotio-cli.toml`; support is `Quotio` for production, otherwise the bundle ID | Production namespace `quotio-macos`. Beta namespace is `quotio-macos-` followed by the first eight SHA256 bytes of its bundle ID, encoded as hex |
| Swift using a trusted standalone-compatible helper, or standalone CLI | `AS/quotio`, with `config.toml` | Shared CLI vault, not namespace `quotio-macos` |
| Legacy Swift production | `AS/Quotio/Monitor/accounts-v1.json` | Credential services derive from current and legacy bundle IDs. Some credentials require the Swift PIV reader |
| GPUI with a qualifying bundled Developer ID signature | Shared CLI vault and `config.toml`, adopting the same-bundle Swift isolated source above | UI preferences and proxy retain their desktop paths; this is not full preferences migration |
| GPUI without that signature or bundle metadata | `AS/app.Quotio.Quotio/accounts`, with sibling `host.toml` and `desktop.json` | Namespace `quotio-desktop`. Proxy lives at `AS/app.Quotio.Quotio/proxy/config.yaml` |

The shared macOS Keychain service is `app.quotio.cli.accounts.v1`, account
`vault`. An isolated service is `app.quotio.cli.accounts.<namespace>.v1`, account
`vault.<namespace>`. Swift selects shared storage only when the helper satisfies
the `dev.quotio.cli` Developer ID requirement for the app's Team ID. Check the
installed helper signature before selecting a source. Do not infer the storage
mode from the release name or point a debug build at a shared production vault.

`adopt::Source` currently requires an isolated namespace and its reader calls
`Vault::isolated_interactive`. It does not describe the unnamespaced shared CLI
source. Qualifying macOS builds now use that shared source directly rather than
importing it. Migration to a separate destination would still need explicit
support for shared storage. Do not substitute an isolated namespace for it.

For current GPUI on Linux, ProjectDirs uses `~/.config/quotio` for host and UI
settings, and `~/.local/share/quotio/accounts` for accounts, subject to XDG
overrides. The proxy uses `~/.local/share/quotio/proxy`. On Windows, settings use
`%APPDATA%/Quotio/Quotio/config`, accounts use
`%LOCALAPPDATA%/Quotio/Quotio/data/accounts`, and the proxy uses
`%APPDATA%/Quotio/Quotio/data/proxy`. These are source-derived platform defaults.
The Linux product root can overlap the CLI root even though account namespaces
and filenames differ.

Swift production proxy configuration is `AS/Quotio/config.yaml`, with auth in
`~/.cli-proxy-api`. Beta uses its own application support and auth directory.
GPUI has a different proxy layout. Do not copy an old proxy configuration or
enable its process without checking format and port ownership.

Migration includes host account IDs, labels, disabled state, history, supported
preferences, pinned-account references, proxy settings, host identity, and
device grants. UserDefaults are not `desktop.json`. Copying account credentials
alone does not preserve the user's setup. Preserve target data when newer or
conflicting, and require an explicit source choice rather than merging every
production, beta, and CLI store automatically.

Sources: [`CompositionRoot.swift`](../../apps/macos/Quotio/App/CompositionRoot.swift),
[`AppIdentity.swift`](../../apps/macos/Quotio/App/AppIdentity.swift),
[`QuotioCLIServerProcess.swift`](../../Packages/QuotioCore/Sources/QuotioInfrastructure/QuotioCLI/QuotioCLIServerProcess.swift),
[`QuotioCLIHelperSignature.swift`](../../Packages/QuotioCore/Sources/QuotioInfrastructure/QuotioCLI/QuotioCLIHelperSignature.swift),
[`vault.rs`](../../apps/cli/src/accounts/vault.rs),
[`host.rs`](../../apps/desktop/src/host.rs),
[`prefs.rs`](../../apps/desktop/src/prefs.rs), and
[`proxy.rs`](../../apps/desktop/src/proxy.rs).

## Migration findings from milestone 0

A temporary Rust example exercised public `adopt::vault` against encrypted Linux
vaults, with a generated scratch key and a synthetic OpenRouter API key. It ran
successfully twice with separate scratch directories. It observed:

```text
PASS: first adoption preserves ID, label and disabled state
PASS: same-target retry creates no duplicate
CONFIRMED BLOCKER: source completion marker skips a different empty target
CONTROL: removing only the scratch marker permits second-target adoption
```

The source account remained present. The marker is source-scoped
`accounts-<namespace>.adopted`. Adoption to target A creates it. A later adoption
to empty target B returns without copying the account. Removing only that marker
in the scratch source allows target B to receive it.

This is a blocker to reusing the current helper for a new destination, not
a demonstrated GPUI user-data incident. At the research baseline GPUI's adoption
arguments were all `None`. The integrated native fix now adopts into the same
shared destination as the signed Swift helper; its existing completion marker
does not prove adoption into another destination.
Do not delete existing users' markers as a workaround. Completion for the new
flow must distinguish destinations and permit retry until required account,
history, and configuration work completes. Keep original credentials and data.
The current helper writes a source marker, so it is not a read-only import.

Source inspection also shows that `Document::absorb` can drop source pairing
when both stores have different paired host identities. Migration must disclose
the chosen identity and any need to pair again. This conflict has not been
exercised with an actual iPhone in milestone 0.

Prefer the existing Swift legacy reader as a bridge instead of rewriting PIV
support solely for old data. Current beta identity does not enable legacy
account migration. A beta-only bridge is therefore insufficient without an
explicit change. The production bridge must cover the supported old providers
or document which accounts require login again. Keep a signed bridge available
for users who skip intermediate releases. No plaintext credential export.

Sources: [`adopt.rs`](../../apps/cli/src/accounts/adopt.rs),
[`accounts/mod.rs`](../../apps/cli/src/accounts/mod.rs),
[`QuotioCLILegacyAccountMigration.swift`](../../Packages/QuotioCore/Sources/QuotioInfrastructure/QuotioCLI/QuotioCLILegacyAccountMigration.swift), and
[`YubiKeySecretVault.swift`](../../Packages/QuotioCore/Sources/QuotioInfrastructure/Credentials/YubiKeySecretVault.swift).

## Sparkle is feasible, production update and rollback remain unproven

The downloaded stable app uses `releases/latest/download/appcast.xml`.
The beta uses `releases/download/macos-beta-appcast/appcast-beta.xml`.
Keep both feeds unchanged during preview. GPUI's current updater has assets only
for Windows and Linux x64. Its macOS asset is `None`.

Use Sparkle as the default for milestone 2 instead of building another macOS
updater. A native experiment established feasibility in the actual GPUI event
loop. A manual DMG preview remains an acceptable interim channel, but does not
pass stable cutover. The update unit must be the signed app bundle, not its raw
inner executable. Windows and Linux can retain their current Ed25519 update
channel while packaging is addressed in milestone 2. That signature is not OS
code signing.

### Native update experiment

With the owner's approval, the existing Quotio macOS thread ran the experiment
on macOS 27.2, build 26B123, arm64, at the same repository baseline. The thread
made no production source change. It used Sparkle 2.8.1 from the installed Swift
beta and a Developer ID Application identity with Team ID `C48F8UHK3M`.

The experiment first used a standalone Rust/objc2 harness, then an actual
`quotio-desktop` scratch build. The GPUI build linked Sparkle and started
`SPUUpdater` after `app::init`. Fixture mode disabled live account operations.
Its preferences pointed to a scratch `desktop.json` containing
`{"quota_style":"rings"}`. A and B were separate app bundles with versions 1 and
2 and identifier `app.bytrong.quotio.m0-gpui-sparkle-probe`. The local update feed
and archive used a throwaway Ed25519 key.

The GPUI log showed version 1 finding and installing version 2, then a different
process launching version 2. Reading the final installed Info.plist confirmed
build 2. `codesign --verify --deep --strict` passed on the updated bundle, which
kept the expected identifier and Team ID with hardened runtime enabled. The
scratch preference still contained `rings`. HTTP logs recorded the feed, B.zip,
and another feed request after restart.

This proves signed whole-bundle update and relaunch inside GPUI with one
preserved preference. It does not prove real account, history, or pairing
preservation. The probe used `--timestamp=none` and was not notarized. Its
Gatekeeper acceptance, downgrade rejection, and Team-ID mismatch rejection were
not tested. An initial read saw build 1 before the asynchronous update finished.
Only the later final-state read and relaunched build 2 count as completion.

The standalone harness rejected an invalid archive signature with Sparkle error
4005, leaving build 1 installed. That rejection was not repeated inside GPUI.
Do not combine these two experiments into a claim that every failure case
passed in the real app.

Native inspection separately verified the installed Swift Beta 1.0.0-beta.11,
build 87. Its app passed signature verification and `spctl` reported
`accepted`, `source=Notarized Developer ID`. Its helper has identifier
`dev.quotio.cli` and the same Team ID. This matches the shared-storage signature
requirement. This metadata alone does not prove credential access or
notarization of the GPUI probe.

The native thread retained sanitized logs, not a runnable reproduction bundle.
It removed scratch builds, app bundles, feeds, disposable signing keys, probe
preferences, caches, HTTP storage, and servers. The native checkout was clean.
Evidence was transferred back to the coordinating thread under
`.amp/in/artifacts/gpui-cutover/native-*`.

Source: [native experiment thread](https://ampcode.com/threads/T-01a1b158-c768-7336-a5f9-1a7c7e5399b1).

### Scoped Keychain experiment

A follow-up used scratch copies of `vault.rs` with a mandatory
`QUOTIO_M0_KEYCHAIN` path. Both normal options and the separate authorization
query added `kSecUseKeychain` and a single-keychain `kSecMatchSearchList`. Missing
scope failed before an unscoped query. The hook was not applied to production
source. Provider-native credential readers were not invoked.

A source-built helper signed as `dev.quotio.cli` wrote empty synthetic vault
documents into the disposable file Keychain. Both shared and `m0-test` isolated
vaults were readable from the actual GPUI process after `app::init` when that
process was also signed with code identifier `dev.quotio.cli` and the same Team
ID. The result was `shared=Ok(0) isolated=Ok(0)`. A control signed as
`app.bytrong.quotio.m0-gpui-preview` returned
`shared=Err(Storage) isolated=Err(Storage)`.

Both processes exited zero because the probes printed application-level errors
without returning a failing exit status. The error results, not process exit
codes, establish the control's denial. An earlier CLI stand-in recorded
Security status `-25293` on noninteractive foreign-identifier reads. No user
pressed Deny. Matching-identity authorization exercised an already-readable
early return, not a prompt approval.

The CLI stand-in retained access after a changed CDHash and executable path
under the same designated requirement. This was not an actual GPUI rebuild
test. ACL metadata retained the original helper's trusted requirement. Reading
real credentials from the unmodified installed helper, the login or
data-protection Keychain, and full embedded-host operation remain untested.
The GPUI experiment used fixture mode and did not start the host or proxy.

The GPUI bundle kept its preview CFBundleIdentifier while its code identifier
was `dev.quotio.cli`. Local strict signature verification accepted this probe.
Before notarization, Gatekeeper reported `rejected`,
`source=Unnotarized Developer ID`. The later experiment below established
notarization acceptance for that identifier combination. Do not treat those
two results as evidence for full production migration or update compatibility.

The native thread removed both disposable Keychains and scratch homes, sources,
builds, and bundles. A composite snapshot of the real default and search list,
security-preference hash, and Keychains directory listing stayed unchanged.
This was not a content audit of every real Keychain. Sanitized results and the
scratch patches remain in `native-05-*` and `native-06-*` evidence files.

### Apple accepted the preview bundle with the CLI code identifier

The owner separately authorized submitting one test bundle, without publishing
it. A fresh unmodified GPUI build from the same baseline was packaged with
CFBundleIdentifier `app.bytrong.quotio.m0-gpui-preview`, version 0.0.1, build 1,
and minimum macOS 14.0. It was a thin arm64 dev build, not a universal release.
Unlike the Keychain probe, it had no vault hook or probe. It also had no Sparkle,
nested code, or extra entitlements.

The Developer ID signature used hardened runtime, a secure timestamp, and code
identifier `dev.quotio.cli`, Team ID `C48F8UHK3M`. The designated requirement
included that identifier, the Apple anchor, and the Team ID. The executable
CDHash was `de238dd393369ef0340d66b855b0c56f3410b6aa`.

Using existing ASC credentials, `asc notarization submit --file
QuotioM0GPUIPreview.zip --wait` submitted once and returned exit 0 with status
`Accepted`. Submission ID: `7769e2a5-2122-468f-82b6-75376314b7b1`.
A status query for that same ID confirmed acceptance. Apple's developer log
reported `statusCode: 0`, `issues: null`, and the matching archive SHA256 and
executable CDHash.

The submitted ZIP SHA256 was
`7a293b51134021416ac21c80dc8cb20af271c709105ede9116f02622480c76cb`.
After stapling, the retained ZIP SHA256 is
`727069da9b9d946ed4caf32296421f94054d3df91cba340d5efebfe60cab9572`.
These are intentionally different archives. The original submitted ZIP was
removed with scratch. The retained stapled ZIP is 38,810,004 bytes.

After extracting the retained ZIP with `ditto`, each of the following commands
returned exit 0: `stapler validate`, `codesign --verify --deep --strict`, and
`spctl --assess --type execute`. Gatekeeper reported `accepted`,
`source=Notarized Developer ID`. After applying and reading back quarantine
metadata, both `spctl` and `syspolicy_check distribution` also returned exit 0.
The ticket validated again. The archive checksum stayed unchanged. This checks
the retained archive, not just a loose app before packaging.

No quarantined Finder or LaunchServices first launch was performed. A direct
nonquarantined fixture execution survived an eight-second bound and was then
terminated by the intentional alarm, exit 142, with no captured stderr. That
is not a normal exit or end-to-end application acceptance test.

Apple acceptance resolves the packaging question about these identifiers for
this artifact. It does not prove Intel support, release packaging, notarized
Sparkle updates, real credential migration, or OAuth rollback. Apple's
`Ready for distribution` log summary describes platform notarization, not the
product's cutover readiness.

Sanitized evidence is retained as `native-07-notarization-gatekeeper.txt`,
`native-07-apple-notary-log.json`, and `native-07b-retained-zip-check.txt` under
`.amp/in/artifacts/gpui-cutover/`, alongside
`native-07-QuotioM0GPUIPreview-stapled.zip`. The coordinating Linux orb verified
the transferred log, archive hash, and Info.plist, not native Gatekeeper again.
The native thread removed scratch sources, builds, homes, extraction copies,
and probe processes. Its source checkout remained clean. No release or update
feed changed.

### Interactive Keychain approval, denial, and retry

After explicit owner approval, the native thread used Accessibility automation
to observe and click the actual SecurityAgent buttons `Deny`, `Allow`, and
`Always Allow`. Each action required exactly one window naming the expected
synthetic caller and disposable Keychain. Only the generated test-Keychain
password was entered. No real login password or credential was used.

Sources came from `git archive` of the baseline, not the native working tree.
The mandatory scope hook covered every vault query, including authorization.
Tests used legacy file Keychains on macOS 27.2 arm64, not the data-protection
Keychain. Separate fresh Keychains prevented persistent ACL grants from leaking
between phases. No screenshots or recordings were captured. Retained evidence
contains Accessibility text, result logs, securityd prompt counts, and ACLs.

The first probe used an interactive backend. A signed native stand-in covered
shared and isolated vaults. Actual GPUI in fixture mode covered an isolated
interactive read, Deny, retry with Always Allow, and the next process's
noninteractive read. It did not run the embedded host. Synthetic document
fingerprints stayed unchanged and the creating helper retained access.

A second probe matched the production host's constructor choices:
`server.rs` uses `Vault::for_usage` or `isolated_for_usage`, followed by
`authorize_interactively` in `server/management.rs`. These backends keep reads
noninteractive. The second probe used a native signed stand-in, not GPUI.

| Host-shaped authorization, both shared and isolated | Observed result |
| --- | --- |
| Matching helper designated requirement | Success, zero prompts |
| Foreign caller, Deny | One prompt, `Err(Storage)`, source payload and helper access preserved |
| Retry after Deny, choose Allow | One prompt, interactive query succeeds, final noninteractive read fails, `Err(Storage)` |
| Next process after Allow | Noninteractive read still fails, ACL unchanged |
| Fresh source, Always Allow | One prompt, authorization succeeds, ACL gains the foreign requirement |
| Next process after Always Allow | Read and authorize succeed, zero prompts |
| Deny then retry Always Allow on the same source | One prompt per call, failure then success, next process succeeds without prompting |

The shared native stand-in retained persistent access after rebuilding at a new
path with a changed CDHash and the same designated requirement. Actual GPUI
rebuild access was not retested in this round. `Allow` proves a single approved
query without permission surviving into the next process. It does not establish
the exact lifetime of that grant within a process.

The first interactive-backend probe produced two prompts after Deny. The
host-shaped follow-up produced only one for both storage modes. Do not call the
two-prompt result a demonstrated host regression. The constructor difference
explains the observation: interactive preflight `read()` can prompt, whereas
the host's preflight cannot. Denial returned numeric Security status `-128`;
noninteractive failures recorded `-25293`. These are application-level errors,
not child-process exit statuses. The probes print errors without necessarily
exiting nonzero, and most child exit codes were not captured separately.

The owner chose to retain the host-shaped authorization behavior and document
that only **Always Allow** enables background monitoring.
The interactive authorization query succeeds, but the function then calls
`self.read()` on the noninteractive backend and returns a storage error.
Background monitoring still lacks persistent access. Removing that check merely
to report success would not establish that later reads can work. Distinguish
temporary consent from persistent access rather than promising that every
approval button enables monitoring. No production fix was made by these tests.

Evidence is retained as `native-13-*` and `native-13b-*` under
`.amp/in/artifacts/gpui-cutover/`, including driver sources, probe patches,
guarded click scripts, phase logs, and final ACL metadata. The initial 13b phase
was discarded after an incorrect prompt-name guard refused automation. Its
synthetic prompt and scratch were cleaned up before the valid phases ran.
Final checks found no probe process, SecurityAgent window, or probe preferences.
Disposable Keychains, password files, sources, and builds were removed. The
real-default/search-list metadata guard stayed unchanged. This is not an audit
of the contents of every real Keychain.

### Backend rotation checks do not prove rollback

Two existing backend tests passed, one test in each filtered invocation:

```sh
cargo test --locked --manifest-path apps/cli/Cargo.toml --lib factory_and_claude_rotation_and_uncertain_writes_never_replay -- --nocapture
cargo test --locked --manifest-path apps/cli/Cargo.toml --lib rotation_is_saved_before_failed_quota_and_storage_errors_fail_closed -- --nocapture
```

They verify synthetic token rotation and fail-closed persistence behavior. They
do not prove provider credentials remain usable after rolling back to Swift.
An initial invocation with a short filter and `--exact` ran zero tests and is
not counted. The successful invocations each reported `1 passed; 0 failed`.

A backup of an old vault can contain invalid refresh tokens after GPUI refreshes
them. Recovery must either transfer the valid newer credential securely or
require login again, while preserving metadata and history. Do not promise
rollback by restoring a directory alone. Do not allow both apps to refresh the
same rotating credential concurrently.

Sources: [`updater.rs`](../../apps/desktop/src/updater.rs),
[`build_dmg.sh`](../../apps/macos/scripts/build_dmg.sh), and
[`accounts/service.rs`](../../apps/cli/src/accounts/service.rs).

### Swift update and shared-vault rollback on macmini

The native thread subsequently tested a copy of Swift Beta 87 updating through
its actual Sparkle updater to GPUI 88, using a disposable local feed. The first
GPUI build still opened `quotio-desktop` and missed Swift's account. That finding
led to native commit `ae02c70d`, now integrated without changing its patch.

With the fix, the real GPUI embedded host opened the shared history database,
wrote the shared vault, and did not create a `quotio-desktop` Keychain item.
The vault revision progressed from 7 in Swift to 11 in GPUI and 14 after rollback
to Swift 87. The borrowed-native `amp` account remained present, with zero
Quotio Keychain prompts and no reported newer-format or corruption error.

This test used the macmini GUI session and its login Keychain under a separate
direct owner instruction recorded in the native thread. That authorization is
not permission to use the owner's active credentials in later experiments.
The account was not an owned OAuth credential and Quotio did not refresh it.
The isolated source already had an adoption marker, so adoption was a no-op.
History stayed at four observations because each run was shorter than its
600-second polling interval. The test used SIGTERM, not menu Quit. It does not
prove OAuth rotation, first adoption, new history writes, or pairing continuity.

Evidence: `native-11-macmini-swift-to-gpui-rollback.txt` and
`native-12-macmini-shared-vault-retest.txt` under
`.amp/in/artifacts/gpui-cutover/`. The temporary installation, feed, and test
materials were removed. No public feed changed.

### Synthetic adoption from a populated isolated store

The next probe used native commit `ae02c70d`, whose runtime patch is identical
to the synchronized `fe3f7998`. A scratch copy added the mandatory disposable
Keychain scope and a probe after `app::init`. A Developer ID signed GPUI bundle
ran the actual `EmbeddedHost` and `serve_args`, not a replacement host adapter.
It used a scratch HOME and bundle ID `app.bytrong.quotio.m0-adopt`.

The source contained one disabled Claude OAuth-shaped synthetic account, a
client read grant, a resolved host identity, and six mock-history observations.
The source config enabled only the mock provider. The shared destination started
empty. The first writer omitted refresh-ownership/schema metadata and produced
`Err(Corrupt)`. That attempt was discarded. The corrected scratch writer used
the document's ownership API, and a fresh HOME and disposable Keychain passed
the seed/read check before adoption.

| Scenario | Observed result |
| --- | --- |
| First GPUI adoption | `added=1 refreshed=0 skipped=0 rows=6`; seven config keys seeded; account ID, label, disabled state, client grant, and host identity retained |
| Normal process restart | No new adoption; one account, one grant, and six history observations retained; marker unchanged |
| Remove only the scratch marker, then restart | `added=0 refreshed=0 skipped=0 rows=0`, config `keys=0`; no duplicate account, grant, or history observation |
| Synthetic credential change in the shared store | Credential fingerprint changed, client grant retained; no real OAuth request |
| Rollback reader using Swift's shared/adopt arguments and parent-pipe protocol | Helper exit 0; accounts, clients, settings, snapshot, and history catalog returned HTTP 200; changed credential remained readable |
| Original isolated source after all steps | Document fingerprint and history hash unchanged; the adoption marker was added as expected |

The six history observations belong to the mock provider. The disabled Claude
account had no quota metrics. This proves database import and catalog access,
not live quota continuity for that provider. The preserved client read grant is
not an iPhone pairing, companion identity, TLS, or physical-device test. The
rollback reader was a source-built helper using Swift's protocol, not a launch
of the complete Swift application or its installed historical helper.
Merging into an already-populated shared vault was not exercised.

The isolated source still contains the pre-cutover credential. After a real
refresh rotates that credential, rollback must read the current shared vault,
not restore or reopen the stale isolated source. Preserving source data alone
does not make its old token usable again.

There were zero recorded Keychain prompts and no SecurityAgent windows at the
safety check. Default/search-list metadata matched the pre-test hash. The log
query found no non-loopback connection attempt; this is not a packet capture.
The synthetic preferences plist written outside scratch was removed, together
with the disposable Keychain, HOME, source, and binaries. No probe process
remained. GPUI notification authorization warnings were observed and do not
count as notification acceptance. No real credential was used.

Evidence: `native-14-adoption-rollback.txt`, `native-14-G1-after.txt.txt`,
`native-14-G2-G3-restart.txt.txt`,
`native-14-RB-rollback-reader.txt.txt`, and `native-14-Z-safety.txt.txt` under
`.amp/in/artifacts/gpui-cutover/`. Scratch probe sources and the diff are retained
there too. Sanitized paths and concatenated step arrays need reconstruction
before replay; this is not a ready-to-run test bundle. Real provider refresh
followed by Swift rollback was not tested and was subsequently waived by the
owner on 2026-11-08.

## Native acceptance and the OAuth waiver

Run the following on a dedicated macOS test user, using synthetic credentials
and a disposable test installation. Never change the real user's Keychain,
login items, proxy, sharing listener, or existing working tree for these probes.

1. Record OS, architecture, app and helper signing identifiers, Team ID, and
   designated requirements. Create a synthetic credential through the signed
   Swift helper. Read it from a Developer ID signed GPUI probe. Exercise approve,
   deny, retry, and rebuild. Confirm the target stays unchanged on denial and
   the source credential survives. Cover isolated and shared helper storage.
2. Build signed GPUI app bundles A and B with the chosen identity. Test Sparkle
   loading and an A-to-B bundle update from a local disposable feed. Check bundle
   signature, version ordering, restart, state preservation, and rejected update
   behavior. Check notarization and Gatekeeper with the distributable artifact
   once signing and notary access are available. Do not modify the public feeds.
3. Migrate a dedicated test account, refresh its OAuth credential once in GPUI,
   quit GPUI, then recover through the retained Swift bridge. Observe a fresh
   successful quota read, history continuity, and the expected pairing result.
   If re-login is necessary, record it as a product limitation before cutover.
   The owner waived this OAuth test on 2026-11-08. Do not count it as passed
   or block unrelated milestone work on obtaining a credential.

The Linux orb cannot run Security.framework, codesign, Sparkle, or a native Mac
app. The owner approved using the existing Quotio thread on `macbook`, without
creating a new thread. That route produced the update evidence above and
confirmed an available signing identity.

The native credential experiment initially stopped because `vault.rs` uses the
default Keychain search list for both shared and namespaced vaults. A namespace
does not isolate a test from the owner's login Keychain. There was no dedicated
test OS user. No native vault test ran against that default Keychain. A further
scratch-only experiment scoped queries to a disposable Keychain and established
the conditional access results above. Such a hook is not a production feature
and cannot prove an unmodified installed helper's behavior. Synthetic interactive
approve, deny, and retry are now verified within the limits above. Real-user
migration and end-to-end embedded-host authorization remain outstanding.

No dedicated OAuth test credential was identified in the limited inspection.
This is not evidence that none exists. Real provider refresh, rollback through
Swift, and subsequent quota, history, and pairing remain untested. Never use the
owner's active provider login as a substitute. The owner has accepted proceeding
without the real OAuth test, not waived other migration and distribution checks.

The authorized test submission passed notarization and Gatekeeper policy
assessment, including after extracting its retained ZIP and adding quarantine.
No publication was authorized or performed. Notarization does not replace the
missing OAuth rollback or real-user migration tests.

The initial coordinating change retained only this document. Its portable
example, encrypted scratch vaults, generated key, downloaded archives, and build
directory were removed after evidence capture. The prompt experiments used an
archived baseline, excluding the native shared-vault patch.

On 2026-11-08, the owner requested synchronization of that native work. Commit
`ae02c70d` was transferred as a verified Git bundle and integrated on top of the
previous documentation commit. It changes only `apps/desktop/src/host.rs`,
`Cargo.toml`, and `Cargo.lock`. The macmini retest above exercised that patch;
the older baseline prompt and full-suite checks do not validate it. No permanent
test, release dispatch, public-feed change, or Swift deletion was added.

## Milestone 1: populated destinations and preferences

The extended native phase 15 used actual GPUI `EmbeddedHost` from `67a8aede`
with the same fail-closed disposable-Keychain hook. Both source and destination
had accounts, history, and read-client grants. No real credential or provider
request was used.

For matching provider and account identity, the destination kept its label and
enabled state. An enabled source did not re-enable its disabled counterpart.
Only a newer source credential replaced the destination credential. A newly
added account with a duplicate label received suffix ` 2` and was not made
active over the existing account.

Making source history unreadable caused history adoption to fail after account
commit. No completion marker was written. After restoring only scratch-file
permissions, the next launch imported six observations without duplicating
accounts. Restart and removal of only the scratch marker were idempotent.
The resulting history had six series and nine observations. Marker counts
describe the final successful attempt, not all work across retries.

When the destination already held a read grant, it retained its host ID and
grants. The source phone token returned HTTP 401 after merge. The destination
token read the merged snapshot with HTTP 200 but received 403 for client-list
and settings writes. After owner revocation, that token returned 401 too.
These were real client requests over loopback HTTP, not iPhone, TLS, or
companion-identity tests. A source-paired phone must pair again in this case.
The backend currently logs `vault_adoption_pairing_dropped`; user-facing
migration disclosure remains required before cutover.

Phase 15 also reproduced a valid source and destination with different account
identities but the same storage and logical ID. Adoption failed with `Corrupt`,
made no writes, and left no marker. A Linux probe confirmed the cause:
`Document::absorb` remapped the storage ID, but `Registry::absorb` reused its
logical ID. Registry validation then rejected the unverified shared group.
The local fix allocates a fresh logical ID on collision unless authenticated
provider evidence permits a join. The same failing probe passes after the fix.
A matrix of 24 synthetic public-API cases checks independent storage and logical
collisions, absent/equal/different verified identities, same/different providers,
history rewrite IDs, and byte-identical retry state. All cases passed on Linux.
The actual native GPUI retest also passed: `added=1 refreshed=1 rows=12`.
The destination account retained its ID, label, and credential fingerprint.
The colliding source account received distinct storage and logical IDs. Its two
synthetic history observations moved to its new logical ID; the destination's
observation stayed under the original ID. Final history contained eight series
and twelve observations. Restart and lost-marker retry retained account and
credential fingerprints and the history checksum, with no duplicate data.
The source document and history checksums stayed unchanged. The native
destination document fingerprint varied across launches; do not describe it as
byte-identical. The rollback-protocol reader exposed both accounts separately.

The local desktop change imports supported Swift UserDefaults on macOS only
when `desktop.json` is missing and persistence is enabled. It reads only the
current bundle's persistent domain and requires a recognized Swift key.
AppKit creates its own domain key before preferences load, so domain existence
alone misidentified clean installs in v2. The v3 guard passed clean-install,
AppKit-only-domain, and appearance-only-domain tests in actual GPUI.
Existing files, including malformed JSON, are not replaced by import.
Fixture mode does not import or write. Theme,
masking, quota display and aggregation, tray settings, notification choices,
and automatic-update preference have direct mappings. It does not auto-enable
proxy, sharing, or autostart. Pinned-account references, language, and proxy
configuration are not migrated by this change. Fractional thresholds truncate
to the target's integer representation; hand-edited string values are ignored
rather than coerced as Swift would do.

Native C1-C8 tests, two extra domain controls, and boundary cases passed on v3.
Restart preserved the imported file despite changed Swift preferences. Source
Swift keys were unchanged; AppKit added only its own autofill key. Actual GPUI
renders were captured and inspected for dark/masked/used and light/unmasked/
remaining states, in both menu and Accounts settings. Captures contain synthetic
addresses only. The tray icon itself could not be captured; its preference was
checked in JSON, not visually. The fixture captures did not change preferences.

Linux and native desktop fmt, clippy all-targets with `-D warnings`, and two
desktop tests passed. Four existing Linux resolved-account tests and 210 native
account tests passed, with one native test ignored. Linux CLI all-features
`--no-fail-fast` ran every target: 634 passed, one failed, one ignored. The
failure `empty_and_invalid_config_exit_codes_and_redaction` returned 0 instead
of 3 and reproduced with the exact test on a clean detached `67a8aede` baseline.
This is not an all-green full suite. No permanent test was added.

Evidence: `native-16-phase15-paired-merge.txt` under
`.amp/in/artifacts/gpui-cutover/`; native fix results are in
`native-18-logical-id-collision-fix.txt` and
`native-18-logical-id-M1b-fixed.log.txt`. Final preferences results, safety,
and screenshots use the prefix `native-19-`. Linux logs and the synthetic
public-API reproducer are under `.amp/in/artifacts/milestone-1/`.
The verified patch SHA256 values are
`3f5e0e9998a2ef492c6d24bfa8c9b2d093c36931ec48df028e41b69b95868ca8`
for preferences v3 and
`67230965c6ed788772c552866a781284687189ee197e3b81f7ee91531eb0b0b9`
for the logical-ID fix.

Milestone 1 is not yet accepted. Pinned references, proxy migration, legacy
bridge coverage, user-facing source and pairing disclosures, and actual
iPhone/TLS/companion acceptance remain. Milestone 2 production packaging and
Sparkle integration have not been implemented by these changes.
All changes in this section remain local, uncommitted and unpushed. No Swift
deletion, public release, or feed change.

## Milestones 1 and 2: source choice and local packages

The next increment requires an explicit, persisted exact-bundle choice before
reading the isolated Swift vault. A qualifying Developer ID build still uses
the shared CLI vault. The Privacy page offers shared-only or isolated merge,
describes destination label/enabled-state precedence, retained source data,
and re-pairing when the destination already has device grants. Legacy
Monitor/PIV accounts require the retained signed Swift bridge or a new login.
This is a disclosed manual path, not newly implemented GPUI Monitor/PIV support.
If saving the choice fails, the in-memory choice is restored too.

Receipt schema 2 records source/target host IDs and unambiguous account-ID
mappings without credentials. Swift NSData pins restore only against the
chosen host and matching provider, preserving order and removing duplicates.
Remote, missing, ambiguous, and v1-receipt references are warned about rather
than guessed onto colliding IDs. Manual pin selection cancels pending import.
Native C1-C7 passed no-choice/no-source-read, shared-only, bundle mismatch,
merge, ID collision, retry, lost receipt, failed history, v1 receipt, V2 NSData,
and legacy alias cases. A save-failure UI check showed both choice buttons
still available and no disk choice; retry saved successfully.

That check found a real macOS restart bug: GPUI calls `terminate:` inside
`run()`, so the post-run executable spawn never executes. The final source
uses GPUI's `cx.restart()` after saving instead. The mechanism was checked in
the dependency source. Runtime acceptance of the new restart path is pending;
LaunchServices drops the synthetic test environment, so the original test
cannot safely be repeated without an adapted fail-closed setup.

Proxy import is explicit and requires a stopped proxy with auto-start off.
It copies only port, auth-directory reference, and client API keys from bounded
v7/v8 YAML into a new private v8 file. It forces loopback and remote management
off, imports no management credential, binary, routing, or provider overrides,
and refuses existing files and symlinks. Linux probes of the actual extracted
functions passed valid/invalid YAML, escaping, size limits, private mode, and
no-overwrite cases. A native no-GUI probe of the same function also passed
v7/v8, private mode, existing files, live/dangling symlinks, and invalid inputs.
The temporary probe was removed. The actual Privacy-button route and its
running/auto-start refusals have not been exercised on macOS.

### Packaging implementation and executed checks

[`PACKAGING.md`](../../apps/desktop/PACKAGING.md) documents the local-only
Python packager. It creates macOS universal ZIP/DMG, Linux tar.gz, and Windows
portable ZIP packages with a desktop-owned icon, license, notes, and checksums.
The Linux/Windows release workflow now creates archives alongside existing raw
updater assets. Manual dispatch still publishes a prerelease and was not used.
No macOS production release workflow or feed was switched.

macOS uses runtime-loaded Sparkle 2.8.1 for whole-bundle updates. The About
page routes manual checks and automatic-check preferences to Sparkle. Normal
Cargo builds need no framework. The packager requires an explicit verified
framework, checks both architectures in all nested Mach-O files, signs nested
components before the app, and optionally notarizes/staples the app and DMG.
It uses one `lipo -verify_arch` call per architecture because the local Xcode
tool rejected a combined invocation. A validly signed thin Sparkle helper was
correctly rejected. Native compilation also caught and corrected objc2 retained
return/allocated receiver typing; Linux compilation cannot check this module.

A native preview built both release slices with macOS 14.0 deployment targets.
Sparkle's SPM archive checksum matched its pinned 2.8.1 revision. All five
nested Mach-O components were universal. Apple accepted app ZIP submission
`eb4af25d-f579-474f-96f3-e90d7ce2e6ce` and DMG submission
`e53db8d4-8bb5-40df-8ec3-d1b46158fc75`. Stapling, strict signatures, and
Gatekeeper checks passed. A quarantined DMG mount/copy and extracted ZIP app
also passed CLI policy checks. There was no Finder copy or GUI first launch.
Both slices ran `--help`; x86_64 ran under Rosetta, not on Intel hardware.
macOS 14 support is a deployment target, not a runtime result on macOS 14.
The notarized preview predates the final `cx.restart()` change. It does not
certify the exact final source or a completed Sparkle A-to-B update.

The Linux release packager completed. Final archive validation checked hashes,
safe paths, executable permissions, byte-identical extraction, and `--help`
exit 0. `ldd` found all linked libraries in this orb. That is not a clean Linux
desktop install/runtime test. Windows ZIP composition passed with a synthetic
header only; no Windows runner was available. No claim of a Windows build or
runtime pass is made for these local changes. The portable Windows package has
no Authenticode signature and may show SmartScreen warnings.

Linux desktop fmt, clippy all-targets `-D warnings`, and both existing tests
passed on the final source. Final native desktop fmt, clippy, and both tests
also passed. Native CLI fmt/clippy passed, and the all-features full suite
exited 0 with 641 passed and 2 ignored across its suites. The native Keychain
smoke test was ignored, not run. Both final release slices rebuilt and packaged
successfully with strict bundle/DMG signatures. This exact final package was
not resubmitted to Apple; Gatekeeper rejected it as Unnotarized Developer ID,
as expected. Retained native packages distinguish `22-notarized` from
`23-final-unnotarized`.

The Linux full CLI suite ran every target but was not all-green: its existing
config exit-code failure reproduced on clean
`origin/HEAD` at `67a8aede`; a staging-conflict test also failed on that clean
baseline after passing once. Those failures were not hidden or fixed in this
increment. No permanent tests were added.

### Remaining acceptance and delivery

The owner stopped screenshots on the in-use MacBook. Further GUI work is
paused to avoid disrupting that machine. Pending checks include the final
restart, completed/retry migration states, proxy-button refusals, About controls, automatic-update
toggles, whole-bundle Sparkle A-to-B/relaunch, beta acceptance, bad-signature
rejection, and a quarantined Finder first launch. No finalized pointer clip
exists. Earlier Sparkle experiments do not prove this exact integration.
Actual iPhone/TLS/companion acceptance, legacy bridge coverage, and clean
Linux/Windows runtime checks also remain. OAuth remains waived, not passed.
Keep Swift until these acceptance and rollback gates are addressed.

Evidence is under `.amp/in/artifacts/gpui-cutover/native-21-*`, `native-22-*`, `native-23-*`,
`.amp/in/artifacts/milestone-1/choice-*`, and
`.amp/in/artifacts/milestone-2/`. The native summaries distinguish actual GPUI
checks from stand-ins and static package checks. Native scratch homes,
Keychains, test sources, builds, and private test key were cleaned; packages
and evidence were retained. Recorded real-Keychain state hash remained
unchanged with zero prompts. All new source and docs remain
local, uncommitted and unpushed on `master` based on `67a8aede`. No public
release, update-feed change, Swift deletion, or real credential test occurred.
