# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 2 large files in this module.

## Quotio/Services/Proxy/CLIProxyManager.swift (2029 lines)

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
| 974 | fn | stop | (internal) |
| 1026 | fn | startHealthMonitor | (private) |
| 1040 | fn | stopHealthMonitor | (private) |
| 1045 | fn | performHealthCheck | (private) |
| 1108 | fn | cleanupOrphanProcesses | (private) |
| 1171 | fn | terminateAuthProcess | (internal) |
| 1177 | fn | toggle | (internal) |
| 1185 | fn | copyEndpointToClipboard | (internal) |
| 1190 | fn | revealInFinder | (internal) |
| 1197 | enum | ProxyError | (internal) |
| 1228 | enum | AuthCommand | (internal) |
| 1266 | struct | AuthCommandResult | (internal) |
| 1272 | mod | extension CLIProxyManager | (internal) |
| 1273 | fn | runAuthCommand | (internal) |
| 1305 | fn | appendOutput | (internal) |
| 1309 | fn | tryResume | (internal) |
| 1320 | fn | safeResume | (internal) |
| 1420 | mod | extension CLIProxyManager | (internal) |
| 1450 | fn | checkForUpgrade | (internal) |
| 1501 | fn | saveInstalledVersion | (private) |
| 1509 | fn | fetchAvailableReleases | (internal) |
| 1531 | fn | versionInfo | (internal) |
| 1537 | fn | fetchGitHubRelease | (private) |
| 1559 | fn | findCompatibleAsset | (private) |
| 1592 | fn | performManagedUpgrade | (internal) |
| 1650 | fn | downloadAndInstallVersion | (private) |
| 1697 | fn | startDryRun | (private) |
| 1768 | fn | promote | (private) |
| 1803 | fn | rollback | (internal) |
| 1836 | fn | stopTestProxy | (private) |
| 1865 | fn | stopTestProxySync | (private) |
| 1891 | fn | findUnusedPort | (private) |
| 1901 | fn | isPortInUse | (private) |
| 1920 | fn | createTestConfig | (private) |
| 1948 | fn | cleanupTestConfig | (private) |
| 1956 | fn | isNewerVersion | (private) |
| 1959 | fn | parseVersion | (internal) |
| 1991 | fn | findPreviousVersion | (private) |
| 2004 | fn | migrateToVersionedStorage | (internal) |

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

