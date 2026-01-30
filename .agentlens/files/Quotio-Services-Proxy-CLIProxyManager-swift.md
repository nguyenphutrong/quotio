# Quotio/Services/Proxy/CLIProxyManager.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1829
- **Language:** Swift
- **Symbols:** 60
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 9 | class | CLIProxyManager | (internal) | `class CLIProxyManager` |
| 181 | method | init | (internal) | `init()` |
| 214 | fn | updateConfigValue | (private) | `private func updateConfigValue(pattern: String,...` |
| 234 | fn | updateConfigPort | (private) | `private func updateConfigPort(_ newPort: UInt16)` |
| 238 | fn | updateConfigHost | (private) | `private func updateConfigHost(_ host: String)` |
| 242 | fn | ensureApiKeyExistsInConfig | (private) | `private func ensureApiKeyExistsInConfig()` |
| 291 | fn | updateConfigLogging | (internal) | `func updateConfigLogging(enabled: Bool)` |
| 298 | fn | updateConfigRoutingStrategy | (internal) | `func updateConfigRoutingStrategy(_ strategy: St...` |
| 302 | fn | updateConfigProxyURL | (internal) | `func updateConfigProxyURL(_ url: String?)` |
| 322 | fn | ensureConfigExists | (private) | `private func ensureConfigExists()` |
| 356 | fn | syncSecretKeyInConfig | (private) | `private func syncSecretKeyInConfig()` |
| 372 | fn | regenerateManagementKey | (internal) | `func regenerateManagementKey() async throws` |
| 403 | fn | syncProxyURLInConfig | (private) | `private func syncProxyURLInConfig()` |
| 416 | fn | syncCustomProvidersToConfig | (private) | `private func syncCustomProvidersToConfig()` |
| 433 | fn | downloadAndInstallBinary | (internal) | `func downloadAndInstallBinary() async throws` |
| 494 | fn | fetchLatestRelease | (private) | `private func fetchLatestRelease() async throws ...` |
| 515 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(in release: Re...` |
| 540 | fn | downloadAsset | (private) | `private func downloadAsset(url: String) async t...` |
| 559 | fn | extractAndInstall | (private) | `private func extractAndInstall(data: Data, asse...` |
| 621 | fn | findBinaryInDirectory | (private) | `private func findBinaryInDirectory(_ directory:...` |
| 654 | fn | start | (internal) | `func start() async throws` |
| 786 | fn | stop | (internal) | `func stop()` |
| 842 | fn | startHealthMonitor | (private) | `private func startHealthMonitor()` |
| 856 | fn | stopHealthMonitor | (private) | `private func stopHealthMonitor()` |
| 861 | fn | performHealthCheck | (private) | `private func performHealthCheck() async` |
| 924 | fn | cleanupOrphanProcesses | (private) | `private func cleanupOrphanProcesses() async` |
| 978 | fn | terminateAuthProcess | (internal) | `func terminateAuthProcess()` |
| 984 | fn | toggle | (internal) | `func toggle() async throws` |
| 992 | fn | copyEndpointToClipboard | (internal) | `func copyEndpointToClipboard()` |
| 997 | fn | revealInFinder | (internal) | `func revealInFinder()` |
| 1004 | enum | ProxyError | (internal) | `enum ProxyError` |
| 1035 | enum | AuthCommand | (internal) | `enum AuthCommand` |
| 1073 | struct | AuthCommandResult | (internal) | `struct AuthCommandResult` |
| 1079 | mod | extension CLIProxyManager | (internal) | - |
| 1080 | fn | runAuthCommand | (internal) | `func runAuthCommand(_ command: AuthCommand) asy...` |
| 1112 | fn | appendOutput | (internal) | `func appendOutput(_ str: String)` |
| 1116 | fn | tryResume | (internal) | `func tryResume() -> Bool` |
| 1127 | fn | safeResume | (internal) | `@Sendable func safeResume(_ result: AuthCommand...` |
| 1227 | mod | extension CLIProxyManager | (internal) | - |
| 1257 | fn | checkForUpgrade | (internal) | `func checkForUpgrade() async` |
| 1305 | fn | saveInstalledVersion | (private) | `private func saveInstalledVersion(_ version: St...` |
| 1313 | fn | fetchAvailableReleases | (internal) | `func fetchAvailableReleases(limit: Int = 10) as...` |
| 1335 | fn | versionInfo | (internal) | `func versionInfo(from release: GitHubRelease) -...` |
| 1341 | fn | fetchGitHubRelease | (private) | `private func fetchGitHubRelease(tag: String) as...` |
| 1363 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(from release: ...` |
| 1396 | fn | performManagedUpgrade | (internal) | `func performManagedUpgrade(to version: ProxyVer...` |
| 1450 | fn | downloadAndInstallVersion | (private) | `private func downloadAndInstallVersion(_ versio...` |
| 1497 | fn | startDryRun | (private) | `private func startDryRun(version: String) async...` |
| 1568 | fn | promote | (private) | `private func promote(version: String) async throws` |
| 1603 | fn | rollback | (internal) | `func rollback() async throws` |
| 1636 | fn | stopTestProxy | (private) | `private func stopTestProxy() async` |
| 1665 | fn | stopTestProxySync | (private) | `private func stopTestProxySync()` |
| 1691 | fn | findUnusedPort | (private) | `private func findUnusedPort() throws -> UInt16` |
| 1701 | fn | isPortInUse | (private) | `private func isPortInUse(_ port: UInt16) -> Bool` |
| 1720 | fn | createTestConfig | (private) | `private func createTestConfig(port: UInt16) -> ...` |
| 1748 | fn | cleanupTestConfig | (private) | `private func cleanupTestConfig(_ configPath: St...` |
| 1756 | fn | isNewerVersion | (private) | `private func isNewerVersion(_ newer: String, th...` |
| 1759 | fn | parseVersion | (internal) | `func parseVersion(_ version: String) -> [Int]` |
| 1791 | fn | findPreviousVersion | (private) | `private func findPreviousVersion() -> String?` |
| 1804 | fn | migrateToVersionedStorage | (internal) | `func migrateToVersionedStorage() async throws` |

## Memory Markers

### 🟢 `NOTE` (line 207)

> Bridge mode default is registered in AppDelegate.applicationDidFinishLaunching()

### 🟢 `NOTE` (line 297)

> Changes take effect after proxy restart (CLIProxyAPI does not support live routing API)

### 🟢 `NOTE` (line 1288)

> Notification is handled by AtomFeedUpdateService polling

