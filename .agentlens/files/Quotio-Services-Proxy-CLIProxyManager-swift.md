# Quotio/Services/Proxy/CLIProxyManager.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1935
- **Language:** Swift
- **Symbols:** 63
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 9 | class | CLIProxyManager | (internal) | `class CLIProxyManager` |
| 176 | method | init | (internal) | `init()` |
| 217 | fn | restartProxyIfRunning | (private) | `private func restartProxyIfRunning()` |
| 235 | fn | updateConfigValue | (private) | `private func updateConfigValue(pattern: String,...` |
| 255 | fn | updateConfigPort | (private) | `private func updateConfigPort(_ newPort: UInt16)` |
| 259 | fn | updateConfigHost | (private) | `private func updateConfigHost(_ host: String)` |
| 263 | fn | ensureApiKeyExistsInConfig | (private) | `private func ensureApiKeyExistsInConfig()` |
| 312 | fn | updateConfigLogging | (internal) | `func updateConfigLogging(enabled: Bool)` |
| 320 | fn | updateConfigRoutingStrategy | (internal) | `func updateConfigRoutingStrategy(_ strategy: St...` |
| 325 | fn | updateConfigProxyURL | (internal) | `func updateConfigProxyURL(_ url: String?)` |
| 353 | fn | applyBaseURLWorkaround | (internal) | `func applyBaseURLWorkaround()` |
| 382 | fn | removeBaseURLWorkaround | (internal) | `func removeBaseURLWorkaround()` |
| 424 | fn | ensureConfigExists | (private) | `private func ensureConfigExists()` |
| 458 | fn | syncSecretKeyInConfig | (private) | `private func syncSecretKeyInConfig()` |
| 474 | fn | regenerateManagementKey | (internal) | `func regenerateManagementKey() async throws` |
| 509 | fn | syncProxyURLInConfig | (private) | `private func syncProxyURLInConfig()` |
| 522 | fn | syncCustomProvidersToConfig | (private) | `private func syncCustomProvidersToConfig()` |
| 539 | fn | downloadAndInstallBinary | (internal) | `func downloadAndInstallBinary() async throws` |
| 600 | fn | fetchLatestRelease | (private) | `private func fetchLatestRelease() async throws ...` |
| 621 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(in release: Re...` |
| 646 | fn | downloadAsset | (private) | `private func downloadAsset(url: String) async t...` |
| 665 | fn | extractAndInstall | (private) | `private func extractAndInstall(data: Data, asse...` |
| 727 | fn | findBinaryInDirectory | (private) | `private func findBinaryInDirectory(_ directory:...` |
| 760 | fn | start | (internal) | `func start() async throws` |
| 892 | fn | stop | (internal) | `func stop()` |
| 948 | fn | startHealthMonitor | (private) | `private func startHealthMonitor()` |
| 962 | fn | stopHealthMonitor | (private) | `private func stopHealthMonitor()` |
| 967 | fn | performHealthCheck | (private) | `private func performHealthCheck() async` |
| 1030 | fn | cleanupOrphanProcesses | (private) | `private func cleanupOrphanProcesses() async` |
| 1084 | fn | terminateAuthProcess | (internal) | `func terminateAuthProcess()` |
| 1090 | fn | toggle | (internal) | `func toggle() async throws` |
| 1098 | fn | copyEndpointToClipboard | (internal) | `func copyEndpointToClipboard()` |
| 1103 | fn | revealInFinder | (internal) | `func revealInFinder()` |
| 1110 | enum | ProxyError | (internal) | `enum ProxyError` |
| 1141 | enum | AuthCommand | (internal) | `enum AuthCommand` |
| 1179 | struct | AuthCommandResult | (internal) | `struct AuthCommandResult` |
| 1185 | mod | extension CLIProxyManager | (internal) | - |
| 1186 | fn | runAuthCommand | (internal) | `func runAuthCommand(_ command: AuthCommand) asy...` |
| 1218 | fn | appendOutput | (internal) | `func appendOutput(_ str: String)` |
| 1222 | fn | tryResume | (internal) | `func tryResume() -> Bool` |
| 1233 | fn | safeResume | (internal) | `@Sendable func safeResume(_ result: AuthCommand...` |
| 1333 | mod | extension CLIProxyManager | (internal) | - |
| 1363 | fn | checkForUpgrade | (internal) | `func checkForUpgrade() async` |
| 1411 | fn | saveInstalledVersion | (private) | `private func saveInstalledVersion(_ version: St...` |
| 1419 | fn | fetchAvailableReleases | (internal) | `func fetchAvailableReleases(limit: Int = 10) as...` |
| 1441 | fn | versionInfo | (internal) | `func versionInfo(from release: GitHubRelease) -...` |
| 1447 | fn | fetchGitHubRelease | (private) | `private func fetchGitHubRelease(tag: String) as...` |
| 1469 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(from release: ...` |
| 1502 | fn | performManagedUpgrade | (internal) | `func performManagedUpgrade(to version: ProxyVer...` |
| 1556 | fn | downloadAndInstallVersion | (private) | `private func downloadAndInstallVersion(_ versio...` |
| 1603 | fn | startDryRun | (private) | `private func startDryRun(version: String) async...` |
| 1674 | fn | promote | (private) | `private func promote(version: String) async throws` |
| 1709 | fn | rollback | (internal) | `func rollback() async throws` |
| 1742 | fn | stopTestProxy | (private) | `private func stopTestProxy() async` |
| 1771 | fn | stopTestProxySync | (private) | `private func stopTestProxySync()` |
| 1797 | fn | findUnusedPort | (private) | `private func findUnusedPort() throws -> UInt16` |
| 1807 | fn | isPortInUse | (private) | `private func isPortInUse(_ port: UInt16) -> Bool` |
| 1826 | fn | createTestConfig | (private) | `private func createTestConfig(port: UInt16) -> ...` |
| 1854 | fn | cleanupTestConfig | (private) | `private func cleanupTestConfig(_ configPath: St...` |
| 1862 | fn | isNewerVersion | (private) | `private func isNewerVersion(_ newer: String, th...` |
| 1865 | fn | parseVersion | (internal) | `func parseVersion(_ version: String) -> [Int]` |
| 1897 | fn | findPreviousVersion | (private) | `private func findPreviousVersion() -> String?` |
| 1910 | fn | migrateToVersionedStorage | (internal) | `func migrateToVersionedStorage() async throws` |

## Memory Markers

### 🟢 `NOTE` (line 207)

> Bridge mode default is registered in AppDelegate.applicationDidFinishLaunching()

### 🟢 `NOTE` (line 319)

> Changes take effect after proxy restart (CLIProxyAPI does not support live routing API)

### 🟢 `NOTE` (line 1394)

> Notification is handled by AtomFeedUpdateService polling

