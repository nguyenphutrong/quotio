# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 2 large files in this module.

## Quotio/Services/Proxy/CLIProxyManager.swift (2105 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 9 | class | CLIProxyManager | (internal) |
| 243 | method | init | (internal) |
| 284 | fn | restartProxyIfRunning | (private) |
| 302 | fn | updateConfigValue | (private) |
| 322 | fn | updateConfigPort | (private) |
| 326 | fn | updateConfigHost | (private) |
| 330 | fn | ensureApiKeyExistsInConfig | (private) |
| 379 | fn | updateConfigAllowRemote | (internal) |
| 383 | fn | updateConfigLogging | (internal) |
| 391 | fn | updateConfigRoutingStrategy | (internal) |
| 396 | fn | updateConfigProxyURL | (internal) |
| 424 | fn | applyBaseURLWorkaround | (internal) |
| 453 | fn | removeBaseURLWorkaround | (internal) |
| 495 | fn | ensureConfigExists | (private) |
| 529 | fn | syncSecretKeyInConfig | (private) |
| 545 | fn | regenerateManagementKey | (internal) |
| 587 | fn | syncProxyURLInConfig | (private) |
| 604 | fn | syncCustomProvidersToConfig | (private) |
| 621 | fn | downloadAndInstallBinary | (internal) |
| 682 | fn | fetchLatestRelease | (private) |
| 703 | fn | findCompatibleAsset | (private) |
| 728 | fn | downloadAsset | (private) |
| 747 | fn | extractAndInstall | (private) |
| 809 | fn | findBinaryInDirectory | (private) |
| 842 | fn | start | (internal) |
| 974 | fn | waitForBackendReadiness | (private) |
| 991 | fn | waitForBridgeReadiness | (private) |
| 1008 | fn | bridgeAcceptsConnections | (private) |
| 1035 | fn | terminateProcessIfNeeded | (private) |
| 1050 | fn | stop | (internal) |
| 1102 | fn | startHealthMonitor | (private) |
| 1116 | fn | stopHealthMonitor | (private) |
| 1121 | fn | performHealthCheck | (private) |
| 1184 | fn | cleanupOrphanProcesses | (private) |
| 1247 | fn | terminateAuthProcess | (internal) |
| 1253 | fn | toggle | (internal) |
| 1261 | fn | copyEndpointToClipboard | (internal) |
| 1266 | fn | revealInFinder | (internal) |
| 1273 | enum | ProxyError | (internal) |
| 1304 | enum | AuthCommand | (internal) |
| 1342 | struct | AuthCommandResult | (internal) |
| 1348 | mod | extension CLIProxyManager | (internal) |
| 1349 | fn | runAuthCommand | (internal) |
| 1381 | fn | appendOutput | (internal) |
| 1385 | fn | tryResume | (internal) |
| 1396 | fn | safeResume | (internal) |
| 1496 | mod | extension CLIProxyManager | (internal) |
| 1526 | fn | checkForUpgrade | (internal) |
| 1577 | fn | saveInstalledVersion | (private) |
| 1585 | fn | fetchAvailableReleases | (internal) |
| 1607 | fn | versionInfo | (internal) |
| 1613 | fn | fetchGitHubRelease | (private) |
| 1635 | fn | findCompatibleAsset | (private) |
| 1668 | fn | performManagedUpgrade | (internal) |
| 1726 | fn | downloadAndInstallVersion | (private) |
| 1773 | fn | startDryRun | (private) |
| 1844 | fn | promote | (private) |
| 1879 | fn | rollback | (internal) |
| 1912 | fn | stopTestProxy | (private) |
| 1941 | fn | stopTestProxySync | (private) |
| 1967 | fn | findUnusedPort | (private) |
| 1977 | fn | isPortInUse | (private) |
| 1996 | fn | createTestConfig | (private) |
| 2024 | fn | cleanupTestConfig | (private) |
| 2032 | fn | isNewerVersion | (private) |
| 2035 | fn | parseVersion | (internal) |
| 2067 | fn | findPreviousVersion | (private) |
| 2080 | fn | migrateToVersionedStorage | (internal) |

## Quotio/Services/Proxy/ProxyBridge.swift (1127 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 22 | struct | FallbackContext | (internal) |
| 96 | class | ProxyBridge | (internal) |
| 158 | method | init | (internal) |
| 167 | fn | configure | (internal) |
| 190 | fn | start | (internal) |
| 230 | fn | stop | (internal) |
| 240 | fn | handleListenerState | (private) |
| 256 | fn | handleNewConnection | (private) |
| 492 | fn | createFallbackContext | (private) |

