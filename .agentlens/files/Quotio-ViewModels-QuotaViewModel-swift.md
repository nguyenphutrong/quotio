# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1903
- **Language:** Swift
- **Symbols:** 92
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 11 | class | QuotaViewModel | (internal) | `class QuotaViewModel` |
| 130 | fn | loadDisabledAuthFiles | (private) | `private func loadDisabledAuthFiles() -> Set<Str...` |
| 136 | fn | saveDisabledAuthFiles | (private) | `private func saveDisabledAuthFiles(_ names: Set...` |
| 141 | fn | syncDisabledStatesToBackend | (private) | `private func syncDisabledStatesToBackend() async` |
| 160 | fn | notifyQuotaDataChanged | (private) | `private func notifyQuotaDataChanged()` |
| 163 | method | init | (internal) | `init()` |
| 173 | fn | setupProxyURLObserver | (private) | `private func setupProxyURLObserver()` |
| 189 | fn | normalizedProxyURL | (private) | `private func normalizedProxyURL(_ rawValue: Str...` |
| 201 | fn | updateProxyConfiguration | (internal) | `func updateProxyConfiguration() async` |
| 214 | fn | setupRefreshCadenceCallback | (private) | `private func setupRefreshCadenceCallback()` |
| 222 | fn | setupWarmupCallback | (private) | `private func setupWarmupCallback()` |
| 240 | fn | restartAutoRefresh | (private) | `private func restartAutoRefresh()` |
| 252 | fn | initialize | (internal) | `func initialize() async` |
| 262 | fn | initializeFullMode | (private) | `private func initializeFullMode() async` |
| 278 | fn | checkForProxyUpgrade | (private) | `private func checkForProxyUpgrade() async` |
| 283 | fn | initializeQuotaOnlyMode | (private) | `private func initializeQuotaOnlyMode() async` |
| 293 | fn | initializeRemoteMode | (private) | `private func initializeRemoteMode() async` |
| 321 | fn | setupRemoteAPIClient | (private) | `private func setupRemoteAPIClient(config: Remot...` |
| 329 | fn | reconnectRemote | (internal) | `func reconnectRemote() async` |
| 338 | fn | loadDirectAuthFiles | (internal) | `func loadDirectAuthFiles() async` |
| 344 | fn | refreshQuotasDirectly | (internal) | `func refreshQuotasDirectly() async` |
| 371 | fn | autoSelectMenuBarItems | (private) | `private func autoSelectMenuBarItems()` |
| 405 | fn | syncMenuBarSelection | (internal) | `func syncMenuBarSelection()` |
| 412 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 433 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 444 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 464 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 482 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 492 | fn | refreshWarpQuotasInternal | (private) | `private func refreshWarpQuotasInternal() async` |
| 516 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 526 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 532 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 582 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 600 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 619 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 623 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 628 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 633 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 642 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 654 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 665 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 698 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 761 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 806 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 867 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 891 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 904 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 926 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 940 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 969 | fn | startProxy | (internal) | `func startProxy() async` |
| 1006 | fn | stopProxy | (internal) | `func stopProxy()` |
| 1034 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 1042 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 1049 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 1086 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 1102 | fn | refreshData | (internal) | `func refreshData() async` |
| 1149 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1160 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1190 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1222 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1242 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1259 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1264 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1276 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1281 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1286 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1289 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1294 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1299 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1334 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1341 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1383 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1400 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1434 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1451 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1469 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1497 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1501 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1537 | fn | toggleAuthFileDisabled | (internal) | `func toggleAuthFileDisabled(_ file: AuthFile) a...` |
| 1568 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1604 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1628 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1638 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1650 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1662 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1675 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1696 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1728 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1797 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1820 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1882 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1894 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 270)

> checkForProxyUpgrade() is now called inside startProxy()

### 🟢 `NOTE` (line 343)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 351)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1167)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1189)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1198)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1252)

> Don't call detectActiveAccount() here - already set by switch operation

