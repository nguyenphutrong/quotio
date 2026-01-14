# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1772
- **Language:** Swift
- **Symbols:** 85
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 11 | class | QuotaViewModel | (internal) | `class QuotaViewModel` |
| 120 | method | init | (internal) | `init()` |
| 130 | fn | setupProxyURLObserver | (private) | `private func setupProxyURLObserver()` |
| 146 | fn | normalizedProxyURL | (private) | `private func normalizedProxyURL(_ rawValue: Str...` |
| 158 | fn | updateProxyConfiguration | (internal) | `func updateProxyConfiguration() async` |
| 170 | fn | setupRefreshCadenceCallback | (private) | `private func setupRefreshCadenceCallback()` |
| 178 | fn | setupWarmupCallback | (private) | `private func setupWarmupCallback()` |
| 196 | fn | restartAutoRefresh | (private) | `private func restartAutoRefresh()` |
| 208 | fn | initialize | (internal) | `func initialize() async` |
| 218 | fn | initializeFullMode | (private) | `private func initializeFullMode() async` |
| 236 | fn | checkForProxyUpgrade | (private) | `private func checkForProxyUpgrade() async` |
| 241 | fn | initializeQuotaOnlyMode | (private) | `private func initializeQuotaOnlyMode() async` |
| 251 | fn | initializeRemoteMode | (private) | `private func initializeRemoteMode() async` |
| 279 | fn | setupRemoteAPIClient | (private) | `private func setupRemoteAPIClient(config: Remot...` |
| 287 | fn | reconnectRemote | (internal) | `func reconnectRemote() async` |
| 296 | fn | loadDirectAuthFiles | (internal) | `func loadDirectAuthFiles() async` |
| 302 | fn | refreshQuotasDirectly | (internal) | `func refreshQuotasDirectly() async` |
| 327 | fn | autoSelectMenuBarItems | (private) | `private func autoSelectMenuBarItems()` |
| 364 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 385 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 396 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 416 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 434 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 444 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 454 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 460 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 510 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 528 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 547 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 551 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 556 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 561 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 570 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 582 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 593 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 626 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 689 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 734 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 795 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 819 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 832 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 854 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 868 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 897 | fn | startProxy | (internal) | `func startProxy() async` |
| 924 | fn | stopProxy | (internal) | `func stopProxy()` |
| 952 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 960 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 967 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 1004 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 1020 | fn | refreshData | (internal) | `func refreshData() async` |
| 1063 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1074 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1102 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1132 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1150 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1165 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1170 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1182 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1187 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1192 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1195 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1200 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1205 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1236 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1243 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1285 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1302 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1336 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1353 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1371 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1399 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1403 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1431 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1475 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1499 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1509 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1521 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1533 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1546 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1567 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1599 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1666 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1689 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1751 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1763 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 301)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 309)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1081)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1101)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1110)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1158)

> Don't call detectActiveAccount() here - already set by switch operation

