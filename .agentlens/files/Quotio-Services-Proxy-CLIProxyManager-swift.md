# Quotio/Services/Proxy/CLIProxyManager.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 2180
- **Language:** Swift
- **Symbols:** 75
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 9 | class | CLIProxyManager | (internal) | `class CLIProxyManager` |
| 192 | method | init | (internal) | `init()` |
| 235 | fn | restartProxyIfRunning | (private) | `private func restartProxyIfRunning()` |
| 253 | fn | updateConfigValue | (private) | `private func updateConfigValue(pattern: String,...` |
| 273 | fn | updateConfigPort | (private) | `private func updateConfigPort(_ newPort: UInt16)` |
| 277 | fn | updateConfigHost | (private) | `private func updateConfigHost(_ host: String)` |
| 281 | fn | ensureApiKeyExistsInConfig | (private) | `private func ensureApiKeyExistsInConfig()` |
| 330 | fn | updateConfigAllowRemote | (internal) | `func updateConfigAllowRemote(_ enabled: Bool)` |
| 334 | fn | updateConfigLogging | (internal) | `func updateConfigLogging(enabled: Bool)` |
| 342 | fn | updateConfigRoutingStrategy | (internal) | `func updateConfigRoutingStrategy(_ strategy: St...` |
| 347 | fn | updateConfigProxyURL | (internal) | `func updateConfigProxyURL(_ url: String?)` |
| 375 | fn | applyBaseURLWorkaround | (internal) | `func applyBaseURLWorkaround()` |
| 404 | fn | removeBaseURLWorkaround | (internal) | `func removeBaseURLWorkaround()` |
| 446 | fn | ensureConfigExists | (private) | `private func ensureConfigExists()` |
| 480 | fn | syncSecretKeyInConfig | (private) | `private func syncSecretKeyInConfig()` |
| 496 | fn | regenerateManagementKey | (internal) | `func regenerateManagementKey() async throws` |
| 538 | fn | syncProxyURLInConfig | (private) | `private func syncProxyURLInConfig()` |
| 555 | fn | syncCustomProvidersToConfig | (private) | `private func syncCustomProvidersToConfig()` |
| 568 | fn | downloadAndInstallBinary | (internal) | `func downloadAndInstallBinary() async throws` |
| 626 | fn | fetchLatestRelease | (private) | `private func fetchLatestRelease(source: ProxyBi...` |
| 651 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(in release: Re...` |
| 676 | fn | downloadAsset | (private) | `private func downloadAsset(url: String) async t...` |
| 695 | fn | extractAndInstall | (private) | `private func extractAndInstall(data: Data, asse...` |
| 757 | fn | findBinaryInDirectory | (private) | `private func findBinaryInDirectory(_ directory:...` |
| 790 | fn | start | (internal) | `func start() async throws` |
| 922 | fn | stop | (internal) | `func stop()` |
| 974 | fn | startHealthMonitor | (private) | `private func startHealthMonitor()` |
| 988 | fn | stopHealthMonitor | (private) | `private func stopHealthMonitor()` |
| 993 | fn | performHealthCheck | (private) | `private func performHealthCheck() async` |
| 1056 | fn | cleanupOrphanProcesses | (private) | `private func cleanupOrphanProcesses() async` |
| 1119 | fn | terminateAuthProcess | (internal) | `func terminateAuthProcess()` |
| 1125 | fn | toggle | (internal) | `func toggle() async throws` |
| 1133 | fn | copyEndpointToClipboard | (internal) | `func copyEndpointToClipboard()` |
| 1138 | fn | revealInFinder | (internal) | `func revealInFinder()` |
| 1145 | enum | ProxyError | (internal) | `enum ProxyError` |
| 1178 | enum | AuthCommand | (internal) | `enum AuthCommand` |
| 1216 | struct | AuthCommandResult | (internal) | `struct AuthCommandResult` |
| 1222 | mod | extension CLIProxyManager | (internal) | - |
| 1223 | fn | runAuthCommand | (internal) | `func runAuthCommand(_ command: AuthCommand) asy...` |
| 1255 | fn | appendOutput | (internal) | `func appendOutput(_ str: String)` |
| 1259 | fn | tryResume | (internal) | `func tryResume() -> Bool` |
| 1270 | fn | safeResume | (internal) | `@Sendable func safeResume(_ result: AuthCommand...` |
| 1370 | mod | extension CLIProxyManager | (internal) | - |
| 1403 | fn | isLegacyAuthWarningNeeded | (internal) | `func isLegacyAuthWarningNeeded(for provider: AI...` |
| 1408 | fn | sourceInstallHint | (internal) | `func sourceInstallHint(for source: ProxyBinaryS...` |
| 1412 | fn | confirmBinarySourceSelection | (internal) | `func confirmBinarySourceSelection(_ source: Pro...` |
| 1422 | fn | isSourceInstalled | (internal) | `func isSourceInstalled(_ source: ProxyBinarySou...` |
| 1466 | fn | checkForUpgrade | (internal) | `func checkForUpgrade() async` |
| 1523 | fn | saveInstalledVersion | (private) | `private func saveInstalledVersion(_ version: St...` |
| 1528 | fn | fetchAvailableVersions | (internal) | `func fetchAvailableVersions(limit: Int = 10) as...` |
| 1540 | fn | fetchAvailableUpstreamVersions | (private) | `private func fetchAvailableUpstreamVersions(lim...` |
| 1567 | fn | versionInfo | (internal) | `func versionInfo(from release: GitHubRelease) -...` |
| 1573 | fn | fetchGitHubRelease | (private) | `private func fetchGitHubRelease(tag: String, so...` |
| 1599 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(from release: ...` |
| 1632 | fn | performManagedUpgrade | (internal) | `func performManagedUpgrade(to version: ProxyVer...` |
| 1694 | fn | downloadAndInstallVersion | (private) | `private func downloadAndInstallVersion(_ versio...` |
| 1750 | fn | startDryRun | (private) | `private func startDryRun(version: String, sourc...` |
| 1821 | fn | promote | (private) | `private func promote(version: String, source: P...` |
| 1856 | fn | rollback | (internal) | `func rollback() async throws` |
| 1889 | fn | stopTestProxy | (private) | `private func stopTestProxy() async` |
| 1918 | fn | stopTestProxySync | (private) | `private func stopTestProxySync()` |
| 1944 | fn | findUnusedPort | (private) | `private func findUnusedPort() throws -> UInt16` |
| 1954 | fn | isPortInUse | (private) | `private func isPortInUse(_ port: UInt16) -> Bool` |
| 1973 | fn | createTestConfig | (private) | `private func createTestConfig(port: UInt16) -> ...` |
| 2001 | fn | cleanupTestConfig | (private) | `private func cleanupTestConfig(_ configPath: St...` |
| 2009 | fn | isNewerVersion | (private) | `private func isNewerVersion(_ newer: String, th...` |
| 2012 | fn | parseVersion | (internal) | `func parseVersion(_ version: String) -> [Int]` |
| 2044 | fn | plusLocalVersionInfo | (private) | `private func plusLocalVersionInfo() -> ProxyVer...` |
| 2058 | fn | installLocalPlusBinary | (private) | `private func installLocalPlusBinary() async thr...` |
| 2065 | fn | findPreviousVersion | (private) | `private func findPreviousVersion() -> String?` |
| 2078 | fn | migrateToVersionedStorage | (internal) | `func migrateToVersionedStorage() async throws` |
| 2104 | fn | initializeSelectedBinarySourceIfNeeded | (private) | `private func initializeSelectedBinarySourceIfNe...` |
| 2114 | fn | defaultBinarySource | (private) | `private func defaultBinarySource() -> ProxyBina...` |
| 2121 | fn | migrateLegacyVersionedStorageIfNeeded | (private) | `private func migrateLegacyVersionedStorageIfNee...` |
| 2149 | fn | resolveBundledPlusBinaryPath | (private) | `private func resolveBundledPlusBinaryPath() -> ...` |

## Memory Markers

### 🟢 `NOTE` (line 223)

> Bridge mode default is registered in AppDelegate.applicationDidFinishLaunching()

### 🟢 `NOTE` (line 341)

> Changes take effect after proxy restart (CLIProxyAPI does not support live routing API)

### 🟢 `NOTE` (line 1506)

> Notification is handled by AtomFeedUpdateService polling

