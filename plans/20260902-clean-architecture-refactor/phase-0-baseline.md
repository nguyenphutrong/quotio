# Phase 0 Baseline and Compatibility Record

Captured on 2026-09-03 before module extraction. The baseline commit was
`13fd478c` on `chore/clean-architecture-refactor`.

## Environment

- macOS 26.6 (25G72), arm64, Apple M4 Pro
- Xcode 26.6 (17F113), Swift 6 project mode
- Debug configuration, `platform=macOS`

## Automated Baseline

| Gate | Command | Result |
| --- | --- | --- |
| App tests | `xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' test` | Pass |
| Debug build | `xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' build` | Pass |
| Build, launch, process check | `./scripts/build_and_run.sh --verify` | Pass |

The initial full test run produced
`Test-Quotio-2026.09.03_02-16-04-+0700.xcresult`. Local command transcripts were
captured under `/tmp/quotio-phase0-*.log`; these paths are diagnostic evidence and are
not repository artifacts.

## Runtime Baseline

The Debug app was built and launched with `./scripts/build_and_run.sh --verify`.
Measurements are local development measurements, not release benchmarks.

| Measurement | Baseline | Method and limitation |
| --- | --- | --- |
| Build and verified launch | 4.44 s | Wall time for an incremental Debug build, termination, launch, and process verification |
| Menu bar usable | approximately 0.82 s after launch | Difference between the first application-launch log at 02:18:41.967 and status-item/control-center connection at 02:18:42.788 |
| Idle resident memory | 115,072 KB RSS | `ps` after approximately two minutes |
| Idle physical footprint | 54 MB | `/usr/bin/footprint` after approximately two minutes |
| Proxy startup | Not observed | The active operating mode/session did not start a proxy; do not infer a value |
| First quota refresh completion | Not observable in current logs | Network activity began approximately 0.95 s after launch, but no stable completion marker exists |

Phase 11 must use the same Debug command and measurement definitions. Proxy startup and
first-refresh timing require explicit instrumentation in their owning slices before a
meaningful comparison can be made.

## Phase 11 Final Evidence

The final comparison was captured on 2026-09-03 on the same development machine and
with the same Debug configuration as the baseline.

### Automated gates

| Gate | Command | Result |
| --- | --- | --- |
| Package tests | `swift test --package-path Packages/QuotioCore` | Pass: 488 tests, 0 failures |
| App integration tests | `xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' test` | Pass |
| Debug build | `xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' build` | Pass |
| Architecture boundaries | `./scripts/check_architecture.sh` | Pass |
| Build, launch, process check | `./scripts/build_and_run.sh --verify` | Pass |

### Runtime comparison

| Measurement | Phase 0 | Phase 11 | Result and limitation |
| --- | --- | --- | --- |
| Build and verified launch | 4.44 s | 5.01 s | 0.57 s slower; this wrapper includes incremental Xcode build and is not an app-only startup benchmark |
| Menu bar usable | approximately 0.82 s | approximately 0.47 s | No regression; measured from the first launch log to the Control Center status-item connection |
| Idle resident memory | 115,072 KB RSS | 114,288 KB RSS | 784 KB lower after approximately two minutes |
| Idle physical footprint | 54 MB | 52 MB | 2 MB lower after approximately two minutes |
| Proxy startup | Not observed | Not observed | The active operating mode/session did not start a proxy |
| First quota refresh completion | Not observable | Not observable | Network activity is visible, but there is still no stable completion marker |

No meaningful startup or idle-memory regression was observed. Proxy startup and first
quota-refresh timing remain unmeasurable without changing production instrumentation,
which is outside this behavior-preserving phase.

### Release-path validation

- `./scripts/build_dmg.sh` completed and produced universal x86_64/arm64
  `Quotio-0.31.0.dmg` and `Quotio-0.31.0.zip` artifacts targeting macOS 14.0.
- The ad-hoc app signature passes `codesign --verify --deep --strict`; the bundle keeps
  identifier `app.bytrong.quotio`, version `0.31.0`, the four localization bundles,
  AppIcon, and Sparkle.
- The ZIP is scoped to `Quotio.app` apart from `ditto` metadata. The DMG mounts
  read-only with `Quotio.app` and `Applications -> /Applications`, and its embedded app
  passes code-signature verification.
- `actionlint -shellcheck='' .github/workflows/*.yml`, `bash -n scripts/*.sh`,
  `plutil -lint Quotio/Info.plist`, and String Catalog JSON parsing pass.
- The published appcast parses as XML and contains 53 items with 53 EdDSA signatures.

These local artifacts are packaging evidence, not a release candidate: this host has
no `NOTARYTOOL_KEYCHAIN_PROFILE` or `SPARKLE_PRIVATE_KEY`. Developer ID distribution
signing, Apple notarization, generation of a release-candidate appcast, and the
Homebrew dispatch were therefore not run. Triggering the release or Homebrew workflow
would also mutate shared external state and requires explicit approval.

### Manual acceptance limits

This machine runs macOS 26.6 and has no macOS 14 host. The full macOS 14/current-macOS
manual matrix across both operating modes, light/dark appearance, all providers, and
all four locales was not run. Automated contracts and the current-macOS launch smoke
pass, but the deferred manual matrix and signed/notarized release-candidate validation
remain external acceptance gates.

## Persisted Identifier Compatibility Contract

The refactor must continue reading and writing these existing identifiers and layouts.
Changing one requires an explicit, idempotent migration with legacy and current fixtures.

### UserDefaults keys

- App identity/mode/onboarding: `migratedToByTrongAppIdentity`, `appMode`,
  `connectionMode`, `operatingMode`, `migratedToOperatingMode`,
  `hasCompletedOnboarding`.
- Proxy/network: `managementKey`, `warpTokens`, `installedProxyVersion_upstream`,
  `allowNetworkAccess`, `proxyPort`, `lastProxyUpdateCheckDate`, `proxyURL`,
  `autoStartProxy`, `autoStartTunnel`, `autoRestartTunnel`, `loggingToFile`.
- App/UI: `showInDock`, `hideGettingStarted`, `autoCheckUpdates`, `updateChannel`,
  `appLanguage`, `appearanceMode`, `refreshCadence`, `hideSensitiveInfo`,
  `totalUsageMode`, `modelAggregationMode`, `hasUserModifiedMenuBar`.
- Menu bar: `menuBarSelectedProvider`, `menuBarSelectedQuotaItems`,
  `menuBarColorMode`, `showMenuBarIcon`, `menuBarShowQuota`, `menuBarMaxItems`,
  `quotaDisplayMode`, `quotaDisplayStyle`, `menuBarStackClaudeQuotaWindows`.
- Notifications: `notificationsEnabled`, `quotaAlertThreshold`, `notifyOnQuotaLow`,
  `notifyOnCooling`, `notifyOnProxyCrash`, `notifyOnUpgradeAvailable`.
- Providers and warmup: `customProviders`, `KiroMachineId`,
  `warmupEnabledAccounts`, `warmupCadence`, `warmupScheduleMode`,
  `warmupDailyMinutes`, `warmupSelectedModels`, and the three existing
  `warmup*ByAccount` keys.
- Persisted feature data: `persisted.ideQuotas`, `persisted.disabledAuthFiles`,
  `quotio.authFiles.lastChanged`, `atomFeedCache_cliproxy`,
  `atomFeedCache_quotio`, `notifiedCLIProxyVersion`, `yubikeyPIVVaultFingerprint`.
- Telemetry: `shareAnonymousUsage`, `anonymousInstallID`,
  `telemetry.hasSentFirstOptInLaunch`.
- Dynamic agent keys: `agent.<agent>.configured` and
  `agent.<agent>.lastConfigured`.

### Keychain services and accounts

- Production bundle identifier: `app.bytrong.quotio`.
- `<bundle>.local-management` / `local-management-key`.
- `<bundle>.warp` / `warp-tokens`.
- `<bundle>.monitor-auth` / dynamic account identifier.
- Legacy bundle prefixes: `dev.quotio.desktop`, `proseek.io.vn.Quotio`, and
  `com.quotio.<suffix>`.
- Read-only external credentials: service `Codex Auth`; service
  `Claude Code-credentials`; service `Claude Safe Storage`, account `Claude Key`;
  service `Factory CLI`, accounts `auth-encryption-key-security-cli` and
  `auth-encryption-key`.

### Filesystem layouts

- `~/Library/Application Support/Quotio/CLIProxyAPI` and `config.yaml`.
- Version store `~/Library/Application Support/Quotio/proxy/upstream/v*/CLIProxyAPI`
  with the `current` symbolic link.
- Monitor data under `~/Library/Application Support/Quotio/Monitor/`:
  `accounts-v1.json`, `snapshots-v1.json`, and `antigravity-shadow-v1.json`.
- YubiKey envelopes under
  `~/Library/Application Support/Quotio/YubiKeyVault/*.qsv`.
- CLIProxy auth directory `~/.cli-proxy-api`.
- Agent-owned locations under `~/.codex`, `~/.config/codex`, `~/.claude` (or
  `CLAUDE_CONFIG_DIR`), `~/.config/amp`, `~/.local/share/amp`,
  `~/.config/opencode`, and `~/.factory`.
- IDE stores under the existing Cursor, Trae, Devin, and Antigravity Application
  Support paths; Antigravity profiles remain under `~/.quotio/antigravity-profiles`.

## Characterization Coverage

| Invariant | Evidence |
| --- | --- |
| Active proxy version is retained | `ProxyInfrastructureTests.testVersionRepositoryRefusesToDeleteCurrentVersion` and `testCleanupAlwaysKeepsCurrentVersion` |
| Management endpoint is loopback-only | `ProxyModelsTests.testEndpointUsesIPv4LoopbackForManagementAndLocalhostForClients` |
| Port cleanup excludes Quotio's PID | `ProxyInfrastructureTests.testProcessControllerUsesConfigArgumentAndExcludesOwnProcessID` |
| Auth names, JSON shape, symlinks, and private permissions | `AccountPersistenceTests.testAuthFileUploadValidatesNameAndJSONObject` and `testAuthFileUploadIsPrivateAndRefusesSymbolicLinkDestination` |
| Atomic writer rejects symbolic-link destinations | `AccountPersistenceTests.testAtomicWriterRefusesSymbolicLinkDestination` |
| Agent merge preserves native/unknown content | `CodexConfigurationCodecTests`, `CodexAgentConfigurationAdapterTests`, and `AgentConfigurationAdaptersTests` |
| Repeated agent writes retain collision-safe backups | `CodexAgentConfigurationAdapterTests.testAutomaticApplyPreservesAuthSetsPermissionsInspectsAndListsCollisionSafeBackups` |
| Monitor credential compare-and-swap rejects stale replacement | `CredentialVaultServiceTests.testCompareAndSwapDoesNotOverwriteNewerCredential` |
| Cancelled refresh cannot publish a stale result | `QuotaRefreshCoordinatorTests.testCancelledRefreshCannotPublishLateResult` and related stale-result tests |
| Headless and window startup share one runtime | `AppRuntimeTests.testHeadlessAndWindowInitializationShareOneRuntimeAndInitializeServicesOnce` |
| OAuth callbacks from stale attempts are ignored | `OAuthFlowControllerTests` cancellation and stale-callback coverage |
| Tunnel callbacks and automatic restart reject stale work | `TunnelLifecycleControllerTests` cancellation, stale-callback, timeout, and retry-cap coverage |

The package owns domain, application, infrastructure, and presentation regression
tests. `QuotioTests` now contains only executable identity, localization-bundle, and
runtime/lifecycle integration coverage.

## Manual Regression Matrix

Legend: **Pass** was exercised during this baseline; **Deferred** requires credentials,
installed tools, a running proxy, or a second supported macOS host and is mandatory in
the owning phase and Phase 11; **N/A** is not offered in that operating mode.

| Flow | Local proxy | Quota-only | Baseline note |
| --- | --- | --- | --- |
| Upgrade with existing preferences/keychain/app support | Pass | Pass | Existing development profile launched without migration or data reset |
| Fresh install/onboarding | Deferred | Deferred | Requires isolated user fixture |
| Login/headless launch and menu creation | Pass | Pass | Shared bootstrap path observed; identity test belongs to Phase 2 |
| Open/close main window | Pass | Pass | Debug launch smoke |
| Proxy install/start/stop/restart | Deferred | N/A | Phase 5 |
| Proxy update/rollback/unexpected exit | Deferred | N/A | Phase 5 |
| OAuth strategies and account add/disable/delete | Deferred | Deferred | Phase 6; do not exercise real credentials during automated baseline |
| Auth import/export | Deferred | Deferred | Phase 6; filesystem contracts covered automatically |
| Full and scoped quota refresh | Deferred | Deferred | Phase 7; baseline environment lacked deterministic completion marker |
| Warmup and custom provider | Deferred | Deferred | Phase 7 |
| Agent preview/apply/test/backup/restore | Deferred | Deferred | Phase 8; fixtures cover preservation/backups |
| Tunnel start/stop/error/auto-restart | Deferred | N/A | Phase 9 |
| Menu rendering/actions and accessibility | Pass | Pass | Menu bar became usable; full provider/locale matrix is Phase 9/11 |
| Updates, notifications, telemetry consent | Deferred | Deferred | Phase 10 |
| Light and dark appearance | Deferred | Deferred | Phase 11 visual matrix |
| English, French, Vietnamese, Simplified Chinese | Deferred | Deferred | Phase 11 localization matrix |
| macOS 14 availability paths | Deferred | Deferred | Requires macOS 14 host in Phase 11 |

No destructive credential, proxy-version, agent-file, signing, notarization, or release
operation was performed while establishing this baseline.
