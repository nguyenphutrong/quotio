# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1708
- **Language:** Swift
- **Symbols:** 82
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 11 | class | QuotaViewModel | (internal) | `class QuotaViewModel` |
| 116 | method | init | (internal) | `init()` |
| 124 | fn | setupRefreshCadenceCallback | (private) | `private func setupRefreshCadenceCallback()` |
| 132 | fn | setupWarmupCallback | (private) | `private func setupWarmupCallback()` |
| 150 | fn | restartAutoRefresh | (private) | `private func restartAutoRefresh()` |
| 162 | fn | initialize | (internal) | `func initialize() async` |
| 172 | fn | initializeFullMode | (private) | `private func initializeFullMode() async` |
| 190 | fn | checkForProxyUpgrade | (private) | `private func checkForProxyUpgrade() async` |
| 195 | fn | initializeQuotaOnlyMode | (private) | `private func initializeQuotaOnlyMode() async` |
| 205 | fn | initializeRemoteMode | (private) | `private func initializeRemoteMode() async` |
| 233 | fn | setupRemoteAPIClient | (private) | `private func setupRemoteAPIClient(config: Remot...` |
| 241 | fn | reconnectRemote | (internal) | `func reconnectRemote() async` |
| 250 | fn | loadDirectAuthFiles | (internal) | `func loadDirectAuthFiles() async` |
| 256 | fn | refreshQuotasDirectly | (internal) | `func refreshQuotasDirectly() async` |
| 281 | fn | autoSelectMenuBarItems | (private) | `private func autoSelectMenuBarItems()` |
| 318 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 339 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 350 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 370 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 388 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 398 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 408 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 414 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 464 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 481 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 499 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 503 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 508 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 513 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 522 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 534 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 545 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 578 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 641 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 686 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 747 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 771 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 784 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 806 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 820 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 849 | fn | startProxy | (internal) | `func startProxy() async` |
| 876 | fn | stopProxy | (internal) | `func stopProxy()` |
| 898 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 906 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 913 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 950 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 966 | fn | refreshData | (internal) | `func refreshData() async` |
| 999 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1010 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1038 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1068 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1086 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1101 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1106 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1118 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1123 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1128 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1131 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1136 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1141 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1172 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1179 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1221 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1238 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1272 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1289 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1307 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1335 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1339 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1367 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1411 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1435 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1445 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1457 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1469 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1482 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1503 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1535 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1602 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1625 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1687 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1699 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 255)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 263)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1017)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1037)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1046)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1094)

> Don't call detectActiveAccount() here - already set by switch operation

