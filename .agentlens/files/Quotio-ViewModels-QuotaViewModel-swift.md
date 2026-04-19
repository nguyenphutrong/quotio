# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1968
- **Language:** Swift
- **Symbols:** 93
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 11 | class | QuotaViewModel | (internal) | `class QuotaViewModel` |
| 140 | fn | loadDisabledAuthFiles | (private) | `private func loadDisabledAuthFiles() -> Set<Str...` |
| 146 | fn | saveDisabledAuthFiles | (private) | `private func saveDisabledAuthFiles(_ names: Set...` |
| 151 | fn | syncDisabledStatesToBackend | (private) | `private func syncDisabledStatesToBackend() async` |
| 170 | fn | notifyQuotaDataChanged | (private) | `private func notifyQuotaDataChanged()` |
| 173 | method | init | (internal) | `init()` |
| 183 | fn | setupProxyURLObserver | (private) | `private func setupProxyURLObserver()` |
| 199 | fn | normalizedProxyURL | (private) | `private func normalizedProxyURL(_ rawValue: Str...` |
| 211 | fn | updateProxyConfiguration | (internal) | `func updateProxyConfiguration() async` |
| 224 | fn | setupRefreshCadenceCallback | (private) | `private func setupRefreshCadenceCallback()` |
| 232 | fn | setupWarmupCallback | (private) | `private func setupWarmupCallback()` |
| 250 | fn | restartAutoRefresh | (private) | `private func restartAutoRefresh()` |
| 262 | fn | initialize | (internal) | `func initialize() async` |
| 272 | fn | initializeFullMode | (private) | `private func initializeFullMode() async` |
| 288 | fn | checkForProxyUpgrade | (private) | `private func checkForProxyUpgrade() async` |
| 293 | fn | initializeQuotaOnlyMode | (private) | `private func initializeQuotaOnlyMode() async` |
| 303 | fn | initializeRemoteMode | (private) | `private func initializeRemoteMode() async` |
| 331 | fn | setupRemoteAPIClient | (private) | `private func setupRemoteAPIClient(config: Remot...` |
| 339 | fn | reconnectRemote | (internal) | `func reconnectRemote() async` |
| 348 | fn | loadDirectAuthFiles | (internal) | `func loadDirectAuthFiles() async` |
| 354 | fn | refreshQuotasDirectly | (internal) | `func refreshQuotasDirectly() async` |
| 382 | fn | autoSelectMenuBarItems | (private) | `private func autoSelectMenuBarItems()` |
| 416 | fn | syncMenuBarSelection | (internal) | `func syncMenuBarSelection()` |
| 423 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 444 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 455 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 471 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 489 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 499 | fn | refreshWarpQuotasInternal | (private) | `private func refreshWarpQuotasInternal() async` |
| 523 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 533 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 539 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 587 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 605 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 624 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 628 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 633 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 638 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 647 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 659 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 670 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 703 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 766 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 811 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 872 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 896 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 909 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 931 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 945 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 974 | fn | startProxy | (internal) | `func startProxy() async` |
| 1018 | fn | stopProxy | (internal) | `func stopProxy()` |
| 1046 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 1054 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 1061 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 1098 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 1114 | fn | refreshData | (internal) | `func refreshData() async` |
| 1172 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1183 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1213 | fn | localProxyMigrationBaseURLs | (private) | `private func localProxyMigrationBaseURLs() -> [...` |
| 1239 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1273 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1293 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1310 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1315 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1325 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1330 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1335 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1338 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1343 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1348 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1383 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1390 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1435 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1452 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1492 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1509 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1532 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1560 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1564 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1600 | fn | toggleAuthFileDisabled | (internal) | `func toggleAuthFileDisabled(_ file: AuthFile) a...` |
| 1631 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1667 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1691 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1701 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1713 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1725 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1738 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1759 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1791 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1861 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1884 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1946 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1958 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 280)

> checkForProxyUpgrade() is now called inside startProxy()

### 🟢 `NOTE` (line 353)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 361)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1193)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1238)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1248)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1303)

> Don't call detectActiveAccount() here - already set by switch operation

