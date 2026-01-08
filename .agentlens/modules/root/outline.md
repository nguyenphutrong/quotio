# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 4 large files in this module.

## Quotio/QuotioApp.swift (611 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 13 | struct | QuotioApp | (internal) |
| 99 | fn | updateStatusBar | (private) |
| 113 | fn | initializeApp | (private) |
| 205 | class | AppDelegate | (internal) |
| 208 | fn | applicationDidFinishLaunching | (internal) |
| 240 | fn | applicationShouldTerminateAfterLastWindowClosed | (internal) |
| 244 | fn | applicationWillTerminate | (internal) |
| 248 | fn | handleWindowDidBecomeKey | (private) |
| 261 | fn | handleWindowWillClose | (private) |
| 288 | struct | ContentView | (internal) |
| 409 | struct | ModeSwitcherRow | (internal) |
| 462 | fn | handleModeSelection | (private) |
| 474 | fn | switchToMode | (private) |
| 489 | struct | ModeButton | (private) |
| 552 | struct | ProxyStatusRow | (internal) |
| 583 | struct | QuotaRefreshStatusRow | (internal) |

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

## Quotio/Services/Proxy/ProxyBridge.swift (716 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 18 | class | ProxyBridge | (internal) |
| 73 | method | init | (internal) |
| 82 | fn | configure | (internal) |
| 105 | fn | start | (internal) |
| 148 | fn | stop | (internal) |
| 159 | fn | handleListenerState | (private) |
| 178 | fn | handleNewConnection | (private) |

## Quotio/ViewModels/QuotaViewModel.swift (1657 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 11 | class | QuotaViewModel | (internal) |
| 111 | method | init | (internal) |
| 119 | fn | setupRefreshCadenceCallback | (private) |
| 127 | fn | setupWarmupCallback | (private) |
| 145 | fn | restartAutoRefresh | (private) |
| 159 | fn | initialize | (internal) |
| 168 | fn | initializeFullMode | (private) |
| 185 | fn | checkForProxyUpgrade | (private) |
| 190 | fn | initializeQuotaOnlyMode | (private) |
| 204 | fn | loadDirectAuthFiles | (internal) |
| 210 | fn | refreshQuotasDirectly | (internal) |
| 235 | fn | autoSelectMenuBarItems | (private) |
| 272 | fn | refreshClaudeCodeQuotasInternal | (private) |
| 293 | fn | refreshCursorQuotasInternal | (private) |
| 304 | fn | refreshCodexCLIQuotasInternal | (private) |
| 324 | fn | refreshGeminiCLIQuotasInternal | (private) |
| 342 | fn | refreshGlmQuotasInternal | (private) |
| 352 | fn | refreshTraeQuotasInternal | (private) |
| 362 | fn | refreshKiroQuotasInternal | (private) |
| 368 | fn | cleanName | (internal) |
| 418 | fn | startQuotaOnlyAutoRefresh | (private) |
| 435 | fn | startQuotaAutoRefreshWithoutProxy | (private) |
| 453 | fn | isWarmupEnabled | (internal) |
| 457 | fn | warmupStatus | (internal) |
| 462 | fn | warmupNextRunDate | (internal) |
| 467 | fn | toggleWarmup | (internal) |
| 476 | fn | setWarmupEnabled | (internal) |
| 488 | fn | nextDailyRunDate | (private) |
| 499 | fn | restartWarmupScheduler | (private) |
| 532 | fn | runWarmupCycle | (private) |
| 595 | fn | warmupAccount | (private) |
| 640 | fn | warmupAccount | (private) |
| 701 | fn | fetchWarmupModels | (private) |
| 725 | fn | warmupAvailableModels | (internal) |
| 738 | fn | warmupAuthInfo | (private) |
| 760 | fn | warmupTargets | (private) |
| 774 | fn | updateWarmupStatus | (private) |
| 803 | fn | startProxy | (internal) |
| 825 | fn | stopProxy | (internal) |
| 847 | fn | toggleProxy | (internal) |
| 855 | fn | setupAPIClient | (private) |
| 862 | fn | startAutoRefresh | (private) |
| 899 | fn | attemptProxyRecovery | (private) |
| 915 | fn | refreshData | (internal) |
| 948 | fn | manualRefresh | (internal) |
| 959 | fn | refreshAllQuotas | (internal) |
| 987 | fn | refreshQuotasUnified | (internal) |
| 1017 | fn | refreshAntigravityQuotasInternal | (private) |
| 1035 | fn | refreshAntigravityQuotasWithoutDetect | (private) |
| 1050 | fn | isAntigravityAccountActive | (internal) |
| 1055 | fn | switchAntigravityAccount | (internal) |
| 1067 | fn | beginAntigravitySwitch | (internal) |
| 1072 | fn | cancelAntigravitySwitch | (internal) |
| 1077 | fn | dismissAntigravitySwitchResult | (internal) |
| 1080 | fn | refreshOpenAIQuotasInternal | (private) |
| 1085 | fn | refreshCopilotQuotasInternal | (private) |
| 1090 | fn | refreshQuotaForProvider | (internal) |
| 1121 | fn | refreshAutoDetectedProviders | (internal) |
| 1128 | fn | startOAuth | (internal) |
| 1170 | fn | startCopilotAuth | (private) |
| 1187 | fn | startKiroAuth | (private) |
| 1221 | fn | pollCopilotAuthCompletion | (private) |
| 1238 | fn | pollKiroAuthCompletion | (private) |
| 1256 | fn | pollOAuthStatus | (private) |
| 1284 | fn | cancelOAuth | (internal) |
| 1288 | fn | deleteAuthFile | (internal) |
| 1316 | fn | pruneMenuBarItems | (private) |
| 1360 | fn | importVertexServiceAccount | (internal) |
| 1384 | fn | fetchAPIKeys | (internal) |
| 1394 | fn | addAPIKey | (internal) |
| 1406 | fn | updateAPIKey | (internal) |
| 1418 | fn | deleteAPIKey | (internal) |
| 1431 | fn | checkAccountStatusChanges | (private) |
| 1452 | fn | checkQuotaNotifications | (internal) |
| 1484 | fn | scanIDEsWithConsent | (internal) |
| 1551 | fn | savePersistedIDEQuotas | (private) |
| 1574 | fn | loadPersistedIDEQuotas | (private) |
| 1636 | fn | shortenAccountKey | (private) |
| 1648 | struct | OAuthState | (internal) |

