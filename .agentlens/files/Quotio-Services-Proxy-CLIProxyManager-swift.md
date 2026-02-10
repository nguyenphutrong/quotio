# Quotio/Services/Proxy/CLIProxyManager.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1968
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
| 530 | fn | syncProxyURLInConfig | (private) | `private func syncProxyURLInConfig()` |
| 543 | fn | syncCustomProvidersToConfig | (private) | `private func syncCustomProvidersToConfig()` |
| 560 | fn | downloadAndInstallBinary | (internal) | `func downloadAndInstallBinary() async throws` |
| 621 | fn | fetchLatestRelease | (private) | `private func fetchLatestRelease() async throws ...` |
| 642 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(in release: Re...` |
| 667 | fn | downloadAsset | (private) | `private func downloadAsset(url: String) async t...` |
| 686 | fn | extractAndInstall | (private) | `private func extractAndInstall(data: Data, asse...` |
| 748 | fn | findBinaryInDirectory | (private) | `private func findBinaryInDirectory(_ directory:...` |
| 781 | fn | start | (internal) | `func start() async throws` |
| 913 | fn | stop | (internal) | `func stop()` |
| 965 | fn | startHealthMonitor | (private) | `private func startHealthMonitor()` |
| 979 | fn | stopHealthMonitor | (private) | `private func stopHealthMonitor()` |
| 984 | fn | performHealthCheck | (private) | `private func performHealthCheck() async` |
| 1047 | fn | cleanupOrphanProcesses | (private) | `private func cleanupOrphanProcesses() async` |
| 1110 | fn | terminateAuthProcess | (internal) | `func terminateAuthProcess()` |
| 1116 | fn | toggle | (internal) | `func toggle() async throws` |
| 1124 | fn | copyEndpointToClipboard | (internal) | `func copyEndpointToClipboard()` |
| 1129 | fn | revealInFinder | (internal) | `func revealInFinder()` |
| 1136 | enum | ProxyError | (internal) | `enum ProxyError` |
| 1167 | enum | AuthCommand | (internal) | `enum AuthCommand` |
| 1205 | struct | AuthCommandResult | (internal) | `struct AuthCommandResult` |
| 1211 | mod | extension CLIProxyManager | (internal) | - |
| 1212 | fn | runAuthCommand | (internal) | `func runAuthCommand(_ command: AuthCommand) asy...` |
| 1244 | fn | appendOutput | (internal) | `func appendOutput(_ str: String)` |
| 1248 | fn | tryResume | (internal) | `func tryResume() -> Bool` |
| 1259 | fn | safeResume | (internal) | `@Sendable func safeResume(_ result: AuthCommand...` |
| 1359 | mod | extension CLIProxyManager | (internal) | - |
| 1389 | fn | checkForUpgrade | (internal) | `func checkForUpgrade() async` |
| 1440 | fn | saveInstalledVersion | (private) | `private func saveInstalledVersion(_ version: St...` |
| 1448 | fn | fetchAvailableReleases | (internal) | `func fetchAvailableReleases(limit: Int = 10) as...` |
| 1470 | fn | versionInfo | (internal) | `func versionInfo(from release: GitHubRelease) -...` |
| 1476 | fn | fetchGitHubRelease | (private) | `private func fetchGitHubRelease(tag: String) as...` |
| 1498 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(from release: ...` |
| 1531 | fn | performManagedUpgrade | (internal) | `func performManagedUpgrade(to version: ProxyVer...` |
| 1589 | fn | downloadAndInstallVersion | (private) | `private func downloadAndInstallVersion(_ versio...` |
| 1636 | fn | startDryRun | (private) | `private func startDryRun(version: String) async...` |
| 1707 | fn | promote | (private) | `private func promote(version: String) async throws` |
| 1742 | fn | rollback | (internal) | `func rollback() async throws` |
| 1775 | fn | stopTestProxy | (private) | `private func stopTestProxy() async` |
| 1804 | fn | stopTestProxySync | (private) | `private func stopTestProxySync()` |
| 1830 | fn | findUnusedPort | (private) | `private func findUnusedPort() throws -> UInt16` |
| 1840 | fn | isPortInUse | (private) | `private func isPortInUse(_ port: UInt16) -> Bool` |
| 1859 | fn | createTestConfig | (private) | `private func createTestConfig(port: UInt16) -> ...` |
| 1887 | fn | cleanupTestConfig | (private) | `private func cleanupTestConfig(_ configPath: St...` |
| 1895 | fn | isNewerVersion | (private) | `private func isNewerVersion(_ newer: String, th...` |
| 1898 | fn | parseVersion | (internal) | `func parseVersion(_ version: String) -> [Int]` |
| 1930 | fn | findPreviousVersion | (private) | `private func findPreviousVersion() -> String?` |
| 1943 | fn | migrateToVersionedStorage | (internal) | `func migrateToVersionedStorage() async throws` |

## Memory Markers

### 🟢 `NOTE` (line 224)

> Bridge mode default is registered in AppDelegate.applicationDidFinishLaunching()

### 🟢 `NOTE` (line 340)

> Changes take effect after proxy restart (CLIProxyAPI does not support live routing API)

### 🟢 `NOTE` (line 1423)

> Notification is handled by AtomFeedUpdateService polling

