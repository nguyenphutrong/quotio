# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1700
- **Language:** Swift
- **Symbols:** 82
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 11 | class | QuotaViewModel | (internal) | `class QuotaViewModel` |
| 113 | method | init | (internal) | `init()` |
| 121 | fn | setupRefreshCadenceCallback | (private) | `private func setupRefreshCadenceCallback()` |
| 129 | fn | setupWarmupCallback | (private) | `private func setupWarmupCallback()` |
| 147 | fn | restartAutoRefresh | (private) | `private func restartAutoRefresh()` |
| 159 | fn | initialize | (internal) | `func initialize() async` |
| 169 | fn | initializeFullMode | (private) | `private func initializeFullMode() async` |
| 187 | fn | checkForProxyUpgrade | (private) | `private func checkForProxyUpgrade() async` |
| 192 | fn | initializeQuotaOnlyMode | (private) | `private func initializeQuotaOnlyMode() async` |
| 202 | fn | initializeRemoteMode | (private) | `private func initializeRemoteMode() async` |
| 230 | fn | setupRemoteAPIClient | (private) | `private func setupRemoteAPIClient(config: Remot...` |
| 238 | fn | reconnectRemote | (internal) | `func reconnectRemote() async` |
| 247 | fn | loadDirectAuthFiles | (internal) | `func loadDirectAuthFiles() async` |
| 253 | fn | refreshQuotasDirectly | (internal) | `func refreshQuotasDirectly() async` |
| 278 | fn | autoSelectMenuBarItems | (private) | `private func autoSelectMenuBarItems()` |
| 315 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 336 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 347 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 367 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 385 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 395 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 405 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 411 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 461 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 478 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 496 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 500 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 505 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 510 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 519 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 531 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 542 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 575 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 638 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 683 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 744 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 768 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 781 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 803 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 817 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 846 | fn | startProxy | (internal) | `func startProxy() async` |
| 868 | fn | stopProxy | (internal) | `func stopProxy()` |
| 890 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 898 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 905 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 942 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 958 | fn | refreshData | (internal) | `func refreshData() async` |
| 991 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1002 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1030 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1060 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1078 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1093 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1098 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1110 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1115 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1120 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1123 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1128 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1133 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1164 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1171 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1213 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1230 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1264 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1281 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1299 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1327 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1331 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1359 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1403 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1427 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1437 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1449 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1461 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1474 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1495 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1527 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1594 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1617 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1679 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1691 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 252)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 260)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1009)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1029)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1038)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1086)

> Don't call detectActiveAccount() here - already set by switch operation

