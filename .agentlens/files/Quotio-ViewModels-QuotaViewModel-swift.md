# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1757
- **Language:** Swift
- **Symbols:** 85
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 11 | class | QuotaViewModel | (internal) | `class QuotaViewModel` |
| 117 | method | init | (internal) | `init()` |
| 127 | fn | setupProxyURLObserver | (private) | `private func setupProxyURLObserver()` |
| 143 | fn | normalizedProxyURL | (private) | `private func normalizedProxyURL(_ rawValue: Str...` |
| 155 | fn | updateProxyConfiguration | (internal) | `func updateProxyConfiguration() async` |
| 167 | fn | setupRefreshCadenceCallback | (private) | `private func setupRefreshCadenceCallback()` |
| 175 | fn | setupWarmupCallback | (private) | `private func setupWarmupCallback()` |
| 193 | fn | restartAutoRefresh | (private) | `private func restartAutoRefresh()` |
| 205 | fn | initialize | (internal) | `func initialize() async` |
| 215 | fn | initializeFullMode | (private) | `private func initializeFullMode() async` |
| 233 | fn | checkForProxyUpgrade | (private) | `private func checkForProxyUpgrade() async` |
| 238 | fn | initializeQuotaOnlyMode | (private) | `private func initializeQuotaOnlyMode() async` |
| 248 | fn | initializeRemoteMode | (private) | `private func initializeRemoteMode() async` |
| 276 | fn | setupRemoteAPIClient | (private) | `private func setupRemoteAPIClient(config: Remot...` |
| 284 | fn | reconnectRemote | (internal) | `func reconnectRemote() async` |
| 293 | fn | loadDirectAuthFiles | (internal) | `func loadDirectAuthFiles() async` |
| 299 | fn | refreshQuotasDirectly | (internal) | `func refreshQuotasDirectly() async` |
| 324 | fn | autoSelectMenuBarItems | (private) | `private func autoSelectMenuBarItems()` |
| 361 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 382 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 393 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 413 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 431 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 441 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 451 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 457 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 507 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 524 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 542 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 546 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 551 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 556 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 565 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 577 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 588 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 621 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 684 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 729 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 790 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 814 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 827 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 849 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 863 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 892 | fn | startProxy | (internal) | `func startProxy() async` |
| 919 | fn | stopProxy | (internal) | `func stopProxy()` |
| 947 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 955 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 962 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 999 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 1015 | fn | refreshData | (internal) | `func refreshData() async` |
| 1048 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1059 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1087 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1117 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1135 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1150 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1155 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1167 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1172 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1177 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1180 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1185 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1190 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1221 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1228 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1270 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1287 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1321 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1338 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1356 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1384 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1388 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1416 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1460 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1484 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1494 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1506 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1518 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1531 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1552 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1584 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1651 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1674 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1736 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1748 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 298)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 306)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1066)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1086)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1095)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1143)

> Don't call detectActiveAccount() here - already set by switch operation

