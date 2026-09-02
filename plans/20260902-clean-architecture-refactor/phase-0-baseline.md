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
| Active proxy version is retained | `ProxyCharacterizationTests` |
| Management endpoint is loopback-only | `ProxyCharacterizationTests` |
| Port cleanup excludes Quotio's PID | `ProxyCharacterizationTests` |
| Auth names, symlinks, private directory/file permissions, and round trip | `AuthFileTransferTests` |
| Atomic writer rejects symbolic-link destinations | `MonitorRuntimeTests.testAtomicWriterRefusesSymbolicLinkDestination` |
| Agent merge preserves native/unknown content | `CodexAuthConfigTests.testMergePreservesNativeFieldsAndSetsProxyKey` and `MonitorRuntimeTests.testAmpConfigurationMergePreservesNativeAndUnknownSecrets` |
| Repeated agent reverts retain collision-safe backups | `CodexAuthConfigTests.testRepeatedRevertsKeepEveryBackup` |
| Monitor credential compare-and-swap rejects stale replacement | `MonitorRuntimeTests.testMonitorCredentialCASDoesNotOverwriteNewerCredential` |
| Cancelled IDE refresh cannot publish a stale result | `IDEQuotaRefreshReentrancyTests.testCancelledGlobalRefreshDoesNotApplyStaleIDEQuota` |

Headless/window runtime identity is added in Phase 2 before lifecycle ownership moves.
OAuth attempt cancellation is added in Phase 6 before OAuth moves. Tunnel callback and
restart cancellation are added in Phase 9 before tunnel ownership moves. Those tests
need the injection seams introduced by their owning phase; the legacy singleton paths
cannot be isolated without prematurely introducing the target architecture.

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
