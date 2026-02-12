# Quotio/Services/Proxy/CLIProxyManager.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1979
- **Language:** Swift
- **Symbols:** 64
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 9 | class | CLIProxyManager | (internal) | `class CLIProxyManager` |
| 193 | method | init | (internal) | `init()` |
| 234 | fn | restartProxyIfRunning | (private) | `private func restartProxyIfRunning()` |
| 252 | fn | updateConfigValue | (private) | `private func updateConfigValue(pattern: String,...` |
| 272 | fn | updateConfigPort | (private) | `private func updateConfigPort(_ newPort: UInt16)` |
| 276 | fn | updateConfigHost | (private) | `private func updateConfigHost(_ host: String)` |
| 280 | fn | ensureApiKeyExistsInConfig | (private) | `private func ensureApiKeyExistsInConfig()` |
| 329 | fn | updateConfigAllowRemote | (internal) | `func updateConfigAllowRemote(_ enabled: Bool)` |
| 333 | fn | updateConfigLogging | (internal) | `func updateConfigLogging(enabled: Bool)` |
| 341 | fn | updateConfigRoutingStrategy | (internal) | `func updateConfigRoutingStrategy(_ strategy: St...` |
| 346 | fn | updateConfigProxyURL | (internal) | `func updateConfigProxyURL(_ url: String?)` |
| 374 | fn | applyBaseURLWorkaround | (internal) | `func applyBaseURLWorkaround()` |
| 403 | fn | removeBaseURLWorkaround | (internal) | `func removeBaseURLWorkaround()` |
| 445 | fn | ensureConfigExists | (private) | `private func ensureConfigExists()` |
| 479 | fn | syncSecretKeyInConfig | (private) | `private func syncSecretKeyInConfig()` |
| 495 | fn | regenerateManagementKey | (internal) | `func regenerateManagementKey() async throws` |
| 537 | fn | syncProxyURLInConfig | (private) | `private func syncProxyURLInConfig()` |
| 554 | fn | syncCustomProvidersToConfig | (private) | `private func syncCustomProvidersToConfig()` |
| 571 | fn | downloadAndInstallBinary | (internal) | `func downloadAndInstallBinary() async throws` |
| 632 | fn | fetchLatestRelease | (private) | `private func fetchLatestRelease() async throws ...` |
| 653 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(in release: Re...` |
| 678 | fn | downloadAsset | (private) | `private func downloadAsset(url: String) async t...` |
| 697 | fn | extractAndInstall | (private) | `private func extractAndInstall(data: Data, asse...` |
| 759 | fn | findBinaryInDirectory | (private) | `private func findBinaryInDirectory(_ directory:...` |
| 792 | fn | start | (internal) | `func start() async throws` |
| 924 | fn | stop | (internal) | `func stop()` |
| 976 | fn | startHealthMonitor | (private) | `private func startHealthMonitor()` |
| 990 | fn | stopHealthMonitor | (private) | `private func stopHealthMonitor()` |
| 995 | fn | performHealthCheck | (private) | `private func performHealthCheck() async` |
| 1058 | fn | cleanupOrphanProcesses | (private) | `private func cleanupOrphanProcesses() async` |
| 1121 | fn | terminateAuthProcess | (internal) | `func terminateAuthProcess()` |
| 1127 | fn | toggle | (internal) | `func toggle() async throws` |
| 1135 | fn | copyEndpointToClipboard | (internal) | `func copyEndpointToClipboard()` |
| 1140 | fn | revealInFinder | (internal) | `func revealInFinder()` |
| 1147 | enum | ProxyError | (internal) | `enum ProxyError` |
| 1178 | enum | AuthCommand | (internal) | `enum AuthCommand` |
| 1216 | struct | AuthCommandResult | (internal) | `struct AuthCommandResult` |
| 1222 | mod | extension CLIProxyManager | (internal) | - |
| 1223 | fn | runAuthCommand | (internal) | `func runAuthCommand(_ command: AuthCommand) asy...` |
| 1255 | fn | appendOutput | (internal) | `func appendOutput(_ str: String)` |
| 1259 | fn | tryResume | (internal) | `func tryResume() -> Bool` |
| 1270 | fn | safeResume | (internal) | `@Sendable func safeResume(_ result: AuthCommand...` |
| 1370 | mod | extension CLIProxyManager | (internal) | - |
| 1400 | fn | checkForUpgrade | (internal) | `func checkForUpgrade() async` |
| 1451 | fn | saveInstalledVersion | (private) | `private func saveInstalledVersion(_ version: St...` |
| 1459 | fn | fetchAvailableReleases | (internal) | `func fetchAvailableReleases(limit: Int = 10) as...` |
| 1481 | fn | versionInfo | (internal) | `func versionInfo(from release: GitHubRelease) -...` |
| 1487 | fn | fetchGitHubRelease | (private) | `private func fetchGitHubRelease(tag: String) as...` |
| 1509 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(from release: ...` |
| 1542 | fn | performManagedUpgrade | (internal) | `func performManagedUpgrade(to version: ProxyVer...` |
| 1600 | fn | downloadAndInstallVersion | (private) | `private func downloadAndInstallVersion(_ versio...` |
| 1647 | fn | startDryRun | (private) | `private func startDryRun(version: String) async...` |
| 1718 | fn | promote | (private) | `private func promote(version: String) async throws` |
| 1753 | fn | rollback | (internal) | `func rollback() async throws` |
| 1786 | fn | stopTestProxy | (private) | `private func stopTestProxy() async` |
| 1815 | fn | stopTestProxySync | (private) | `private func stopTestProxySync()` |
| 1841 | fn | findUnusedPort | (private) | `private func findUnusedPort() throws -> UInt16` |
| 1851 | fn | isPortInUse | (private) | `private func isPortInUse(_ port: UInt16) -> Bool` |
| 1870 | fn | createTestConfig | (private) | `private func createTestConfig(port: UInt16) -> ...` |
| 1898 | fn | cleanupTestConfig | (private) | `private func cleanupTestConfig(_ configPath: St...` |
| 1906 | fn | isNewerVersion | (private) | `private func isNewerVersion(_ newer: String, th...` |
| 1909 | fn | parseVersion | (internal) | `func parseVersion(_ version: String) -> [Int]` |
| 1941 | fn | findPreviousVersion | (private) | `private func findPreviousVersion() -> String?` |
| 1954 | fn | migrateToVersionedStorage | (internal) | `func migrateToVersionedStorage() async throws` |

## Memory Markers

### 🟢 `NOTE` (line 224)

> Bridge mode default is registered in AppDelegate.applicationDidFinishLaunching()

### 🟢 `NOTE` (line 340)

> Changes take effect after proxy restart (CLIProxyAPI does not support live routing API)

### 🟢 `NOTE` (line 1434)

> Notification is handled by AtomFeedUpdateService polling

