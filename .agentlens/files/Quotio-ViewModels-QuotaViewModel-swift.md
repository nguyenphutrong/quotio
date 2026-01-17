# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1807
- **Language:** Swift
- **Symbols:** 86
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
| 367 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 388 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 399 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 419 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 437 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 447 | fn | refreshWarpQuotasInternal | (private) | `private func refreshWarpQuotasInternal() async` |
| 471 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 481 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 487 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 537 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 555 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 574 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 578 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 583 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 588 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 597 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 609 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 620 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 653 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 716 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 761 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 822 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 846 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 859 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 881 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 895 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 924 | fn | startProxy | (internal) | `func startProxy() async` |
| 951 | fn | stopProxy | (internal) | `func stopProxy()` |
| 979 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 987 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 994 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 1031 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 1047 | fn | refreshData | (internal) | `func refreshData() async` |
| 1090 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1101 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1130 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1161 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1181 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1198 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1203 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1215 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1220 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1225 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1228 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1233 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1238 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1271 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1278 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1320 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1337 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1371 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1388 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1406 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1434 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1438 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1466 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1510 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1534 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1544 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1556 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1568 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1581 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1602 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1634 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1701 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1724 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1786 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1798 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 303)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 311)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1108)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1129)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1138)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1191)

> Don't call detectActiveAccount() here - already set by switch operation

