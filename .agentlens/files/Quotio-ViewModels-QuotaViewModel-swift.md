# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1913
- **Language:** Swift
- **Symbols:** 92
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 11 | class | QuotaViewModel | (internal) | `class QuotaViewModel` |
| 131 | fn | loadDisabledAuthFiles | (private) | `private func loadDisabledAuthFiles() -> Set<Str...` |
| 137 | fn | saveDisabledAuthFiles | (private) | `private func saveDisabledAuthFiles(_ names: Set...` |
| 142 | fn | syncDisabledStatesToBackend | (private) | `private func syncDisabledStatesToBackend() async` |
| 161 | fn | notifyQuotaDataChanged | (private) | `private func notifyQuotaDataChanged()` |
| 164 | method | init | (internal) | `init()` |
| 174 | fn | setupProxyURLObserver | (private) | `private func setupProxyURLObserver()` |
| 190 | fn | normalizedProxyURL | (private) | `private func normalizedProxyURL(_ rawValue: Str...` |
| 202 | fn | updateProxyConfiguration | (internal) | `func updateProxyConfiguration() async` |
| 215 | fn | setupRefreshCadenceCallback | (private) | `private func setupRefreshCadenceCallback()` |
| 223 | fn | setupWarmupCallback | (private) | `private func setupWarmupCallback()` |
| 241 | fn | restartAutoRefresh | (private) | `private func restartAutoRefresh()` |
| 253 | fn | initialize | (internal) | `func initialize() async` |
| 263 | fn | initializeFullMode | (private) | `private func initializeFullMode() async` |
| 279 | fn | checkForProxyUpgrade | (private) | `private func checkForProxyUpgrade() async` |
| 284 | fn | initializeQuotaOnlyMode | (private) | `private func initializeQuotaOnlyMode() async` |
| 294 | fn | initializeRemoteMode | (private) | `private func initializeRemoteMode() async` |
| 322 | fn | setupRemoteAPIClient | (private) | `private func setupRemoteAPIClient(config: Remot...` |
| 330 | fn | reconnectRemote | (internal) | `func reconnectRemote() async` |
| 339 | fn | loadDirectAuthFiles | (internal) | `func loadDirectAuthFiles() async` |
| 345 | fn | refreshQuotasDirectly | (internal) | `func refreshQuotasDirectly() async` |
| 372 | fn | autoSelectMenuBarItems | (private) | `private func autoSelectMenuBarItems()` |
| 406 | fn | syncMenuBarSelection | (internal) | `func syncMenuBarSelection()` |
| 413 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 434 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 445 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 461 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 479 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 489 | fn | refreshWarpQuotasInternal | (private) | `private func refreshWarpQuotasInternal() async` |
| 513 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 523 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 529 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 579 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 597 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 616 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 620 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 625 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 630 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 639 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 651 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 662 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 695 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 758 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 803 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 864 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 888 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 901 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 923 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 937 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 966 | fn | startProxy | (internal) | `func startProxy() async` |
| 1010 | fn | stopProxy | (internal) | `func stopProxy()` |
| 1038 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 1046 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 1053 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 1090 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 1106 | fn | refreshData | (internal) | `func refreshData() async` |
| 1153 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1164 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1199 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1232 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1252 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1269 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1274 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1286 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1291 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1296 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1299 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1304 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1309 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1344 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1351 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1393 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1410 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1444 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1461 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1479 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1507 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1511 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1547 | fn | toggleAuthFileDisabled | (internal) | `func toggleAuthFileDisabled(_ file: AuthFile) a...` |
| 1578 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1614 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1638 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1648 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1660 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1672 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1685 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1706 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1738 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1807 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1830 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1892 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1904 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 271)

> checkForProxyUpgrade() is now called inside startProxy()

### 🟢 `NOTE` (line 344)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 352)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1174)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1198)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1208)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1262)

> Don't call detectActiveAccount() here - already set by switch operation

