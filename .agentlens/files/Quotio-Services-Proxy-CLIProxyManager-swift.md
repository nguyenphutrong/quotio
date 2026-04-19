# Quotio/Services/Proxy/CLIProxyManager.swift

[← Back to Module](../modules/Quotio-Services-Proxy/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 2105
- **Language:** Swift
- **Symbols:** 68
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 9 | class | CLIProxyManager | (internal) | `class CLIProxyManager` |
| 243 | method | init | (internal) | `init()` |
| 284 | fn | restartProxyIfRunning | (private) | `private func restartProxyIfRunning()` |
| 302 | fn | updateConfigValue | (private) | `private func updateConfigValue(pattern: String,...` |
| 322 | fn | updateConfigPort | (private) | `private func updateConfigPort(_ newPort: UInt16)` |
| 326 | fn | updateConfigHost | (private) | `private func updateConfigHost(_ host: String)` |
| 330 | fn | ensureApiKeyExistsInConfig | (private) | `private func ensureApiKeyExistsInConfig()` |
| 379 | fn | updateConfigAllowRemote | (internal) | `func updateConfigAllowRemote(_ enabled: Bool)` |
| 383 | fn | updateConfigLogging | (internal) | `func updateConfigLogging(enabled: Bool)` |
| 391 | fn | updateConfigRoutingStrategy | (internal) | `func updateConfigRoutingStrategy(_ strategy: St...` |
| 396 | fn | updateConfigProxyURL | (internal) | `func updateConfigProxyURL(_ url: String?)` |
| 424 | fn | applyBaseURLWorkaround | (internal) | `func applyBaseURLWorkaround()` |
| 453 | fn | removeBaseURLWorkaround | (internal) | `func removeBaseURLWorkaround()` |
| 495 | fn | ensureConfigExists | (private) | `private func ensureConfigExists()` |
| 529 | fn | syncSecretKeyInConfig | (private) | `private func syncSecretKeyInConfig()` |
| 545 | fn | regenerateManagementKey | (internal) | `func regenerateManagementKey() async throws` |
| 587 | fn | syncProxyURLInConfig | (private) | `private func syncProxyURLInConfig()` |
| 604 | fn | syncCustomProvidersToConfig | (private) | `private func syncCustomProvidersToConfig()` |
| 621 | fn | downloadAndInstallBinary | (internal) | `func downloadAndInstallBinary() async throws` |
| 682 | fn | fetchLatestRelease | (private) | `private func fetchLatestRelease() async throws ...` |
| 703 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(in release: Re...` |
| 728 | fn | downloadAsset | (private) | `private func downloadAsset(url: String) async t...` |
| 747 | fn | extractAndInstall | (private) | `private func extractAndInstall(data: Data, asse...` |
| 809 | fn | findBinaryInDirectory | (private) | `private func findBinaryInDirectory(_ directory:...` |
| 842 | fn | start | (internal) | `func start() async throws` |
| 974 | fn | waitForBackendReadiness | (private) | `private func waitForBackendReadiness(process: P...` |
| 991 | fn | waitForBridgeReadiness | (private) | `private func waitForBridgeReadiness(process: Pr...` |
| 1008 | fn | bridgeAcceptsConnections | (private) | `private func bridgeAcceptsConnections(on port: ...` |
| 1035 | fn | terminateProcessIfNeeded | (private) | `private func terminateProcessIfNeeded(_ process...` |
| 1050 | fn | stop | (internal) | `func stop()` |
| 1102 | fn | startHealthMonitor | (private) | `private func startHealthMonitor()` |
| 1116 | fn | stopHealthMonitor | (private) | `private func stopHealthMonitor()` |
| 1121 | fn | performHealthCheck | (private) | `private func performHealthCheck() async` |
| 1184 | fn | cleanupOrphanProcesses | (private) | `private func cleanupOrphanProcesses() async` |
| 1247 | fn | terminateAuthProcess | (internal) | `func terminateAuthProcess()` |
| 1253 | fn | toggle | (internal) | `func toggle() async throws` |
| 1261 | fn | copyEndpointToClipboard | (internal) | `func copyEndpointToClipboard()` |
| 1266 | fn | revealInFinder | (internal) | `func revealInFinder()` |
| 1273 | enum | ProxyError | (internal) | `enum ProxyError` |
| 1304 | enum | AuthCommand | (internal) | `enum AuthCommand` |
| 1342 | struct | AuthCommandResult | (internal) | `struct AuthCommandResult` |
| 1348 | mod | extension CLIProxyManager | (internal) | - |
| 1349 | fn | runAuthCommand | (internal) | `func runAuthCommand(_ command: AuthCommand) asy...` |
| 1381 | fn | appendOutput | (internal) | `func appendOutput(_ str: String)` |
| 1385 | fn | tryResume | (internal) | `func tryResume() -> Bool` |
| 1396 | fn | safeResume | (internal) | `@Sendable func safeResume(_ result: AuthCommand...` |
| 1496 | mod | extension CLIProxyManager | (internal) | - |
| 1526 | fn | checkForUpgrade | (internal) | `func checkForUpgrade() async` |
| 1577 | fn | saveInstalledVersion | (private) | `private func saveInstalledVersion(_ version: St...` |
| 1585 | fn | fetchAvailableReleases | (internal) | `func fetchAvailableReleases(limit: Int = 10) as...` |
| 1607 | fn | versionInfo | (internal) | `func versionInfo(from release: GitHubRelease) -...` |
| 1613 | fn | fetchGitHubRelease | (private) | `private func fetchGitHubRelease(tag: String) as...` |
| 1635 | fn | findCompatibleAsset | (private) | `private func findCompatibleAsset(from release: ...` |
| 1668 | fn | performManagedUpgrade | (internal) | `func performManagedUpgrade(to version: ProxyVer...` |
| 1726 | fn | downloadAndInstallVersion | (private) | `private func downloadAndInstallVersion(_ versio...` |
| 1773 | fn | startDryRun | (private) | `private func startDryRun(version: String) async...` |
| 1844 | fn | promote | (private) | `private func promote(version: String) async throws` |
| 1879 | fn | rollback | (internal) | `func rollback() async throws` |
| 1912 | fn | stopTestProxy | (private) | `private func stopTestProxy() async` |
| 1941 | fn | stopTestProxySync | (private) | `private func stopTestProxySync()` |
| 1967 | fn | findUnusedPort | (private) | `private func findUnusedPort() throws -> UInt16` |
| 1977 | fn | isPortInUse | (private) | `private func isPortInUse(_ port: UInt16) -> Bool` |
| 1996 | fn | createTestConfig | (private) | `private func createTestConfig(port: UInt16) -> ...` |
| 2024 | fn | cleanupTestConfig | (private) | `private func cleanupTestConfig(_ configPath: St...` |
| 2032 | fn | isNewerVersion | (private) | `private func isNewerVersion(_ newer: String, th...` |
| 2035 | fn | parseVersion | (internal) | `func parseVersion(_ version: String) -> [Int]` |
| 2067 | fn | findPreviousVersion | (private) | `private func findPreviousVersion() -> String?` |
| 2080 | fn | migrateToVersionedStorage | (internal) | `func migrateToVersionedStorage() async throws` |

## Memory Markers

### 🟢 `NOTE` (line 274)

> Bridge mode default is registered in AppDelegate.applicationDidFinishLaunching()

### 🟢 `NOTE` (line 390)

> Changes take effect after proxy restart (CLIProxyAPI does not support live routing API)

### 🟢 `NOTE` (line 1560)

> Notification is handled by AtomFeedUpdateService polling

