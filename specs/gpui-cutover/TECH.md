# GPUI cutover contract and milestone 0 evidence

Status: milestone 0 is partially verified, not accepted. Signed GPUI experiments
passed Sparkle update, notarization, and synthetic Keychain approval checks.
The native shared-vault fix is now integrated into this checkout. Swift-to-GPUI
update and rollback with shared-vault writes passed on macmini, but adoption
from a populated isolated store and rollback after OAuth refresh remain open.
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

## Native acceptance still blocks milestone 0

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
owner's active provider login as a substitute.

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
