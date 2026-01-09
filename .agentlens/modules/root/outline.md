# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 4 large files in this module.

## Quotio/QuotioApp.swift (526 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 13 | struct | QuotioApp | (internal) |
| 100 | fn | updateStatusBar | (private) |
| 114 | fn | initializeApp | (private) |
| 212 | class | AppDelegate | (internal) |
| 215 | fn | applicationDidFinishLaunching | (internal) |
| 247 | fn | applicationShouldTerminateAfterLastWindowClosed | (internal) |
| 251 | fn | applicationShouldHandleReopen | (internal) |
| 269 | fn | applicationWillTerminate | (internal) |
| 273 | fn | handleWindowDidBecomeKey | (private) |
| 277 | fn | handleWindowWillClose | (private) |
| 294 | struct | ContentView | (internal) |
| 424 | struct | RemoteStatusRow | (internal) |
| 467 | struct | ProxyStatusRow | (internal) |
| 498 | struct | QuotaRefreshStatusRow | (internal) |

## Quotio/Services/Proxy/CLIProxyManager.swift (1776 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 9 | class | CLIProxyManager | (internal) |
| 160 | method | init | (internal) |
| 193 | fn | updateConfigPort | (private) |
| 203 | fn | updateConfigLogging | (internal) |
| 216 | fn | updateConfigRoutingStrategy | (internal) |
| 226 | fn | updateConfigProxyURL | (internal) |
| 246 | fn | ensureConfigExists | (private) |
| 280 | fn | syncSecretKeyInConfig | (private) |
| 296 | fn | regenerateManagementKey | (internal) |
| 327 | fn | syncProxyURLInConfig | (private) |
| 340 | fn | syncCustomProvidersToConfig | (private) |
| 357 | fn | downloadAndInstallBinary | (internal) |
| 418 | fn | fetchLatestRelease | (private) |
| 437 | fn | findCompatibleAsset | (private) |
| 462 | fn | downloadAsset | (private) |
| 479 | fn | extractAndInstall | (private) |
| 541 | fn | findBinaryInDirectory | (private) |
| 574 | fn | start | (internal) |
| 706 | fn | stop | (internal) |
| 762 | fn | startHealthMonitor | (private) |
| 776 | fn | stopHealthMonitor | (private) |
| 781 | fn | performHealthCheck | (private) |
| 844 | fn | cleanupOrphanProcesses | (private) |
| 898 | fn | terminateAuthProcess | (internal) |
| 904 | fn | toggle | (internal) |
| 912 | fn | copyEndpointToClipboard | (internal) |
| 917 | fn | revealInFinder | (internal) |
| 923 | enum | ProxyError | (internal) |
| 954 | enum | AuthCommand | (internal) |
| 992 | struct | AuthCommandResult | (internal) |
| 998 | mod | extension CLIProxyManager | (internal) |
| 999 | fn | runAuthCommand | (internal) |
| 1031 | fn | appendOutput | (internal) |
| 1035 | fn | tryResume | (internal) |
| 1046 | fn | safeResume | (internal) |
| 1146 | mod | extension CLIProxyManager | (internal) |
| 1175 | fn | checkForUpgrade | (internal) |
| 1256 | fn | saveInstalledVersion | (private) |
| 1264 | fn | fetchAvailableReleases | (internal) |
| 1284 | fn | versionInfo | (internal) |
| 1290 | fn | fetchGitHubRelease | (private) |
| 1310 | fn | findCompatibleAsset | (private) |
| 1343 | fn | performManagedUpgrade | (internal) |
| 1397 | fn | downloadAndInstallVersion | (private) |
| 1444 | fn | startDryRun | (private) |
| 1515 | fn | promote | (private) |
| 1550 | fn | rollback | (internal) |
| 1583 | fn | stopTestProxy | (private) |
| 1612 | fn | stopTestProxySync | (private) |
| 1638 | fn | findUnusedPort | (private) |
| 1648 | fn | isPortInUse | (private) |
| 1667 | fn | createTestConfig | (private) |
| 1695 | fn | cleanupTestConfig | (private) |
| 1703 | fn | isNewerVersion | (private) |
| 1706 | fn | parseVersion | (internal) |
| 1738 | fn | findPreviousVersion | (private) |
| 1751 | fn | migrateToVersionedStorage | (internal) |

## Quotio/Services/Proxy/ProxyBridge.swift (900 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 22 | struct | FallbackContext | (internal) |
| 61 | class | ProxyBridge | (internal) |
| 116 | method | init | (internal) |
| 125 | fn | configure | (internal) |
| 148 | fn | start | (internal) |
| 188 | fn | stop | (internal) |
| 198 | fn | handleListenerState | (private) |
| 214 | fn | handleNewConnection | (private) |
| 431 | fn | createFallbackContext | (private) |

## Quotio/ViewModels/QuotaViewModel.swift (1700 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 11 | class | QuotaViewModel | (internal) |
| 113 | method | init | (internal) |
| 121 | fn | setupRefreshCadenceCallback | (private) |
| 129 | fn | setupWarmupCallback | (private) |
| 147 | fn | restartAutoRefresh | (private) |
| 159 | fn | initialize | (internal) |
| 169 | fn | initializeFullMode | (private) |
| 187 | fn | checkForProxyUpgrade | (private) |
| 192 | fn | initializeQuotaOnlyMode | (private) |
| 202 | fn | initializeRemoteMode | (private) |
| 230 | fn | setupRemoteAPIClient | (private) |
| 238 | fn | reconnectRemote | (internal) |
| 247 | fn | loadDirectAuthFiles | (internal) |
| 253 | fn | refreshQuotasDirectly | (internal) |
| 278 | fn | autoSelectMenuBarItems | (private) |
| 315 | fn | refreshClaudeCodeQuotasInternal | (private) |
| 336 | fn | refreshCursorQuotasInternal | (private) |
| 347 | fn | refreshCodexCLIQuotasInternal | (private) |
| 367 | fn | refreshGeminiCLIQuotasInternal | (private) |
| 385 | fn | refreshGlmQuotasInternal | (private) |
| 395 | fn | refreshTraeQuotasInternal | (private) |
| 405 | fn | refreshKiroQuotasInternal | (private) |
| 411 | fn | cleanName | (internal) |
| 461 | fn | startQuotaOnlyAutoRefresh | (private) |
| 478 | fn | startQuotaAutoRefreshWithoutProxy | (private) |
| 496 | fn | isWarmupEnabled | (internal) |
| 500 | fn | warmupStatus | (internal) |
| 505 | fn | warmupNextRunDate | (internal) |
| 510 | fn | toggleWarmup | (internal) |
| 519 | fn | setWarmupEnabled | (internal) |
| 531 | fn | nextDailyRunDate | (private) |
| 542 | fn | restartWarmupScheduler | (private) |
| 575 | fn | runWarmupCycle | (private) |
| 638 | fn | warmupAccount | (private) |
| 683 | fn | warmupAccount | (private) |
| 744 | fn | fetchWarmupModels | (private) |
| 768 | fn | warmupAvailableModels | (internal) |
| 781 | fn | warmupAuthInfo | (private) |
| 803 | fn | warmupTargets | (private) |
| 817 | fn | updateWarmupStatus | (private) |
| 846 | fn | startProxy | (internal) |
| 868 | fn | stopProxy | (internal) |
| 890 | fn | toggleProxy | (internal) |
| 898 | fn | setupAPIClient | (private) |
| 905 | fn | startAutoRefresh | (private) |
| 942 | fn | attemptProxyRecovery | (private) |
| 958 | fn | refreshData | (internal) |
| 991 | fn | manualRefresh | (internal) |
| 1002 | fn | refreshAllQuotas | (internal) |
| 1030 | fn | refreshQuotasUnified | (internal) |
| 1060 | fn | refreshAntigravityQuotasInternal | (private) |
| 1078 | fn | refreshAntigravityQuotasWithoutDetect | (private) |
| 1093 | fn | isAntigravityAccountActive | (internal) |
| 1098 | fn | switchAntigravityAccount | (internal) |
| 1110 | fn | beginAntigravitySwitch | (internal) |
| 1115 | fn | cancelAntigravitySwitch | (internal) |
| 1120 | fn | dismissAntigravitySwitchResult | (internal) |
| 1123 | fn | refreshOpenAIQuotasInternal | (private) |
| 1128 | fn | refreshCopilotQuotasInternal | (private) |
| 1133 | fn | refreshQuotaForProvider | (internal) |
| 1164 | fn | refreshAutoDetectedProviders | (internal) |
| 1171 | fn | startOAuth | (internal) |
| 1213 | fn | startCopilotAuth | (private) |
| 1230 | fn | startKiroAuth | (private) |
| 1264 | fn | pollCopilotAuthCompletion | (private) |
| 1281 | fn | pollKiroAuthCompletion | (private) |
| 1299 | fn | pollOAuthStatus | (private) |
| 1327 | fn | cancelOAuth | (internal) |
| 1331 | fn | deleteAuthFile | (internal) |
| 1359 | fn | pruneMenuBarItems | (private) |
| 1403 | fn | importVertexServiceAccount | (internal) |
| 1427 | fn | fetchAPIKeys | (internal) |
| 1437 | fn | addAPIKey | (internal) |
| 1449 | fn | updateAPIKey | (internal) |
| 1461 | fn | deleteAPIKey | (internal) |
| 1474 | fn | checkAccountStatusChanges | (private) |
| 1495 | fn | checkQuotaNotifications | (internal) |
| 1527 | fn | scanIDEsWithConsent | (internal) |
| 1594 | fn | savePersistedIDEQuotas | (private) |
| 1617 | fn | loadPersistedIDEQuotas | (private) |
| 1679 | fn | shortenAccountKey | (private) |
| 1691 | struct | OAuthState | (internal) |

