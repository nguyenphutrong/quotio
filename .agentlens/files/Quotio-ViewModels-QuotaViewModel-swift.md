# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1803
- **Language:** Swift
- **Symbols:** 87
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 11 | class | QuotaViewModel | (internal) | `class QuotaViewModel` |
| 121 | method | init | (internal) | `init()` |
| 131 | fn | setupProxyURLObserver | (private) | `private func setupProxyURLObserver()` |
| 147 | fn | normalizedProxyURL | (private) | `private func normalizedProxyURL(_ rawValue: Str...` |
| 159 | fn | updateProxyConfiguration | (internal) | `func updateProxyConfiguration() async` |
| 172 | fn | setupRefreshCadenceCallback | (private) | `private func setupRefreshCadenceCallback()` |
| 180 | fn | setupWarmupCallback | (private) | `private func setupWarmupCallback()` |
| 198 | fn | restartAutoRefresh | (private) | `private func restartAutoRefresh()` |
| 210 | fn | initialize | (internal) | `func initialize() async` |
| 220 | fn | initializeFullMode | (private) | `private func initializeFullMode() async` |
| 238 | fn | checkForProxyUpgrade | (private) | `private func checkForProxyUpgrade() async` |
| 243 | fn | initializeQuotaOnlyMode | (private) | `private func initializeQuotaOnlyMode() async` |
| 253 | fn | initializeRemoteMode | (private) | `private func initializeRemoteMode() async` |
| 281 | fn | setupRemoteAPIClient | (private) | `private func setupRemoteAPIClient(config: Remot...` |
| 289 | fn | reconnectRemote | (internal) | `func reconnectRemote() async` |
| 298 | fn | loadDirectAuthFiles | (internal) | `func loadDirectAuthFiles() async` |
| 304 | fn | refreshQuotasDirectly | (internal) | `func refreshQuotasDirectly() async` |
| 330 | fn | autoSelectMenuBarItems | (private) | `private func autoSelectMenuBarItems()` |
| 364 | fn | syncMenuBarSelection | (internal) | `func syncMenuBarSelection()` |
| 371 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 392 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 403 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 423 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 441 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 451 | fn | refreshWarpQuotasInternal | (private) | `private func refreshWarpQuotasInternal() async` |
| 475 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 485 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 491 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 541 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 559 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 578 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 582 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 587 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 592 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 601 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 613 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 624 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 657 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 720 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 765 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 826 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 850 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 863 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 885 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 899 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 928 | fn | startProxy | (internal) | `func startProxy() async` |
| 955 | fn | stopProxy | (internal) | `func stopProxy()` |
| 983 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 991 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 998 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 1035 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 1051 | fn | refreshData | (internal) | `func refreshData() async` |
| 1094 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1105 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1134 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1165 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1185 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1202 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1207 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1219 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1224 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1229 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1232 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1237 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1242 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1275 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1282 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1324 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1341 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1375 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1392 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1410 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1438 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1442 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1470 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1506 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1530 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1540 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1552 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1564 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1577 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1598 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1630 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1697 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1720 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1782 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1794 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 303)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 311)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1112)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1133)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1142)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1195)

> Don't call detectActiveAccount() here - already set by switch operation

