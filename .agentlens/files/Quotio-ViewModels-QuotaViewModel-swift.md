# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1821
- **Language:** Swift
- **Symbols:** 88
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 11 | class | QuotaViewModel | (internal) | `class QuotaViewModel` |
| 126 | fn | notifyQuotaDataChanged | (private) | `private func notifyQuotaDataChanged()` |
| 129 | method | init | (internal) | `init()` |
| 139 | fn | setupProxyURLObserver | (private) | `private func setupProxyURLObserver()` |
| 155 | fn | normalizedProxyURL | (private) | `private func normalizedProxyURL(_ rawValue: Str...` |
| 167 | fn | updateProxyConfiguration | (internal) | `func updateProxyConfiguration() async` |
| 180 | fn | setupRefreshCadenceCallback | (private) | `private func setupRefreshCadenceCallback()` |
| 188 | fn | setupWarmupCallback | (private) | `private func setupWarmupCallback()` |
| 206 | fn | restartAutoRefresh | (private) | `private func restartAutoRefresh()` |
| 218 | fn | initialize | (internal) | `func initialize() async` |
| 228 | fn | initializeFullMode | (private) | `private func initializeFullMode() async` |
| 244 | fn | checkForProxyUpgrade | (private) | `private func checkForProxyUpgrade() async` |
| 249 | fn | initializeQuotaOnlyMode | (private) | `private func initializeQuotaOnlyMode() async` |
| 259 | fn | initializeRemoteMode | (private) | `private func initializeRemoteMode() async` |
| 287 | fn | setupRemoteAPIClient | (private) | `private func setupRemoteAPIClient(config: Remot...` |
| 295 | fn | reconnectRemote | (internal) | `func reconnectRemote() async` |
| 304 | fn | loadDirectAuthFiles | (internal) | `func loadDirectAuthFiles() async` |
| 310 | fn | refreshQuotasDirectly | (internal) | `func refreshQuotasDirectly() async` |
| 337 | fn | autoSelectMenuBarItems | (private) | `private func autoSelectMenuBarItems()` |
| 371 | fn | syncMenuBarSelection | (internal) | `func syncMenuBarSelection()` |
| 378 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 399 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 410 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 430 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 448 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 458 | fn | refreshWarpQuotasInternal | (private) | `private func refreshWarpQuotasInternal() async` |
| 482 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 492 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 498 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 548 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 566 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 585 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 589 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 594 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 599 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 608 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 620 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 631 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 664 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 727 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 772 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 833 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 857 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 870 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 892 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 906 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 935 | fn | startProxy | (internal) | `func startProxy() async` |
| 967 | fn | stopProxy | (internal) | `func stopProxy()` |
| 995 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 1003 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 1010 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 1047 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 1063 | fn | refreshData | (internal) | `func refreshData() async` |
| 1106 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1117 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1147 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1179 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1199 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1216 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1221 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1233 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1238 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1243 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1246 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1251 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1256 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1291 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1298 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1340 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1357 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1391 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1408 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1426 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1454 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1458 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1486 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1522 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1546 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1556 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1568 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1580 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1593 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1614 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1646 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1715 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1738 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1800 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1812 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 236)

> checkForProxyUpgrade() is now called inside startProxy()

### 🟢 `NOTE` (line 309)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 317)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1124)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1146)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1155)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1209)

> Don't call detectActiveAccount() here - already set by switch operation

