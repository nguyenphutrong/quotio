# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 2 large files in this module.

## Quotio/Services/Proxy/CLIProxyManager.swift (1979 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 9 | class | CLIProxyManager | (internal) |
| 193 | method | init | (internal) |
| 234 | fn | restartProxyIfRunning | (private) |
| 252 | fn | updateConfigValue | (private) |
| 272 | fn | updateConfigPort | (private) |
| 276 | fn | updateConfigHost | (private) |
| 280 | fn | ensureApiKeyExistsInConfig | (private) |
| 329 | fn | updateConfigAllowRemote | (internal) |
| 333 | fn | updateConfigLogging | (internal) |
| 341 | fn | updateConfigRoutingStrategy | (internal) |
| 346 | fn | updateConfigProxyURL | (internal) |
| 374 | fn | applyBaseURLWorkaround | (internal) |
| 403 | fn | removeBaseURLWorkaround | (internal) |
| 445 | fn | ensureConfigExists | (private) |
| 479 | fn | syncSecretKeyInConfig | (private) |
| 495 | fn | regenerateManagementKey | (internal) |
| 537 | fn | syncProxyURLInConfig | (private) |
| 554 | fn | syncCustomProvidersToConfig | (private) |
| 571 | fn | downloadAndInstallBinary | (internal) |
| 632 | fn | fetchLatestRelease | (private) |
| 653 | fn | findCompatibleAsset | (private) |
| 678 | fn | downloadAsset | (private) |
| 697 | fn | extractAndInstall | (private) |
| 759 | fn | findBinaryInDirectory | (private) |
| 792 | fn | start | (internal) |
| 924 | fn | stop | (internal) |
| 976 | fn | startHealthMonitor | (private) |
| 990 | fn | stopHealthMonitor | (private) |
| 995 | fn | performHealthCheck | (private) |
| 1058 | fn | cleanupOrphanProcesses | (private) |
| 1121 | fn | terminateAuthProcess | (internal) |
| 1127 | fn | toggle | (internal) |
| 1135 | fn | copyEndpointToClipboard | (internal) |
| 1140 | fn | revealInFinder | (internal) |
| 1147 | enum | ProxyError | (internal) |
| 1178 | enum | AuthCommand | (internal) |
| 1216 | struct | AuthCommandResult | (internal) |
| 1222 | mod | extension CLIProxyManager | (internal) |
| 1223 | fn | runAuthCommand | (internal) |
| 1255 | fn | appendOutput | (internal) |
| 1259 | fn | tryResume | (internal) |
| 1270 | fn | safeResume | (internal) |
| 1370 | mod | extension CLIProxyManager | (internal) |
| 1400 | fn | checkForUpgrade | (internal) |
| 1451 | fn | saveInstalledVersion | (private) |
| 1459 | fn | fetchAvailableReleases | (internal) |
| 1481 | fn | versionInfo | (internal) |
| 1487 | fn | fetchGitHubRelease | (private) |
| 1509 | fn | findCompatibleAsset | (private) |
| 1542 | fn | performManagedUpgrade | (internal) |
| 1600 | fn | downloadAndInstallVersion | (private) |
| 1647 | fn | startDryRun | (private) |
| 1718 | fn | promote | (private) |
| 1753 | fn | rollback | (internal) |
| 1786 | fn | stopTestProxy | (private) |
| 1815 | fn | stopTestProxySync | (private) |
| 1841 | fn | findUnusedPort | (private) |
| 1851 | fn | isPortInUse | (private) |
| 1870 | fn | createTestConfig | (private) |
| 1898 | fn | cleanupTestConfig | (private) |
| 1906 | fn | isNewerVersion | (private) |
| 1909 | fn | parseVersion | (internal) |
| 1941 | fn | findPreviousVersion | (private) |
| 1954 | fn | migrateToVersionedStorage | (internal) |

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

