# Quotio/ViewModels/QuotaViewModel.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1936
- **Language:** Swift
- **Symbols:** 92
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 11 | class | QuotaViewModel | (internal) | `class QuotaViewModel` |
| 139 | fn | loadDisabledAuthFiles | (private) | `private func loadDisabledAuthFiles() -> Set<Str...` |
| 145 | fn | saveDisabledAuthFiles | (private) | `private func saveDisabledAuthFiles(_ names: Set...` |
| 150 | fn | syncDisabledStatesToBackend | (private) | `private func syncDisabledStatesToBackend() async` |
| 169 | fn | notifyQuotaDataChanged | (private) | `private func notifyQuotaDataChanged()` |
| 172 | method | init | (internal) | `init()` |
| 182 | fn | setupProxyURLObserver | (private) | `private func setupProxyURLObserver()` |
| 198 | fn | normalizedProxyURL | (private) | `private func normalizedProxyURL(_ rawValue: Str...` |
| 210 | fn | updateProxyConfiguration | (internal) | `func updateProxyConfiguration() async` |
| 223 | fn | setupRefreshCadenceCallback | (private) | `private func setupRefreshCadenceCallback()` |
| 231 | fn | setupWarmupCallback | (private) | `private func setupWarmupCallback()` |
| 249 | fn | restartAutoRefresh | (private) | `private func restartAutoRefresh()` |
| 261 | fn | initialize | (internal) | `func initialize() async` |
| 271 | fn | initializeFullMode | (private) | `private func initializeFullMode() async` |
| 287 | fn | checkForProxyUpgrade | (private) | `private func checkForProxyUpgrade() async` |
| 292 | fn | initializeQuotaOnlyMode | (private) | `private func initializeQuotaOnlyMode() async` |
| 302 | fn | initializeRemoteMode | (private) | `private func initializeRemoteMode() async` |
| 330 | fn | setupRemoteAPIClient | (private) | `private func setupRemoteAPIClient(config: Remot...` |
| 338 | fn | reconnectRemote | (internal) | `func reconnectRemote() async` |
| 347 | fn | loadDirectAuthFiles | (internal) | `func loadDirectAuthFiles() async` |
| 353 | fn | refreshQuotasDirectly | (internal) | `func refreshQuotasDirectly() async` |
| 381 | fn | autoSelectMenuBarItems | (private) | `private func autoSelectMenuBarItems()` |
| 415 | fn | syncMenuBarSelection | (internal) | `func syncMenuBarSelection()` |
| 422 | fn | refreshClaudeCodeQuotasInternal | (private) | `private func refreshClaudeCodeQuotasInternal() ...` |
| 443 | fn | refreshCursorQuotasInternal | (private) | `private func refreshCursorQuotasInternal() async` |
| 454 | fn | refreshCodexCLIQuotasInternal | (private) | `private func refreshCodexCLIQuotasInternal() async` |
| 470 | fn | refreshGeminiCLIQuotasInternal | (private) | `private func refreshGeminiCLIQuotasInternal() a...` |
| 488 | fn | refreshGlmQuotasInternal | (private) | `private func refreshGlmQuotasInternal() async` |
| 498 | fn | refreshWarpQuotasInternal | (private) | `private func refreshWarpQuotasInternal() async` |
| 522 | fn | refreshTraeQuotasInternal | (private) | `private func refreshTraeQuotasInternal() async` |
| 532 | fn | refreshKiroQuotasInternal | (private) | `private func refreshKiroQuotasInternal() async` |
| 538 | fn | cleanName | (internal) | `func cleanName(_ name: String) -> String` |
| 586 | fn | startQuotaOnlyAutoRefresh | (private) | `private func startQuotaOnlyAutoRefresh()` |
| 604 | fn | startQuotaAutoRefreshWithoutProxy | (private) | `private func startQuotaAutoRefreshWithoutProxy()` |
| 623 | fn | isWarmupEnabled | (internal) | `func isWarmupEnabled(for provider: AIProvider, ...` |
| 627 | fn | warmupStatus | (internal) | `func warmupStatus(provider: AIProvider, account...` |
| 632 | fn | warmupNextRunDate | (internal) | `func warmupNextRunDate(provider: AIProvider, ac...` |
| 637 | fn | toggleWarmup | (internal) | `func toggleWarmup(for provider: AIProvider, acc...` |
| 646 | fn | setWarmupEnabled | (internal) | `func setWarmupEnabled(_ enabled: Bool, provider...` |
| 658 | fn | nextDailyRunDate | (private) | `private func nextDailyRunDate(minutes: Int, now...` |
| 669 | fn | restartWarmupScheduler | (private) | `private func restartWarmupScheduler()` |
| 702 | fn | runWarmupCycle | (private) | `private func runWarmupCycle() async` |
| 765 | fn | warmupAccount | (private) | `private func warmupAccount(provider: AIProvider...` |
| 810 | fn | warmupAccount | (private) | `private func warmupAccount(     provider: AIPro...` |
| 871 | fn | fetchWarmupModels | (private) | `private func fetchWarmupModels(     provider: A...` |
| 895 | fn | warmupAvailableModels | (internal) | `func warmupAvailableModels(provider: AIProvider...` |
| 908 | fn | warmupAuthInfo | (private) | `private func warmupAuthInfo(provider: AIProvide...` |
| 930 | fn | warmupTargets | (private) | `private func warmupTargets() -> [WarmupAccountKey]` |
| 944 | fn | updateWarmupStatus | (private) | `private func updateWarmupStatus(for key: Warmup...` |
| 973 | fn | startProxy | (internal) | `func startProxy() async` |
| 1017 | fn | stopProxy | (internal) | `func stopProxy()` |
| 1045 | fn | toggleProxy | (internal) | `func toggleProxy() async` |
| 1053 | fn | setupAPIClient | (private) | `private func setupAPIClient()` |
| 1060 | fn | startAutoRefresh | (private) | `private func startAutoRefresh()` |
| 1097 | fn | attemptProxyRecovery | (private) | `private func attemptProxyRecovery() async` |
| 1113 | fn | refreshData | (internal) | `func refreshData() async` |
| 1160 | fn | manualRefresh | (internal) | `func manualRefresh() async` |
| 1171 | fn | refreshAllQuotas | (internal) | `func refreshAllQuotas() async` |
| 1207 | fn | refreshQuotasUnified | (internal) | `func refreshQuotasUnified() async` |
| 1241 | fn | refreshAntigravityQuotasInternal | (private) | `private func refreshAntigravityQuotasInternal()...` |
| 1261 | fn | refreshAntigravityQuotasWithoutDetect | (private) | `private func refreshAntigravityQuotasWithoutDet...` |
| 1278 | fn | isAntigravityAccountActive | (internal) | `func isAntigravityAccountActive(email: String) ...` |
| 1283 | fn | switchAntigravityAccount | (internal) | `func switchAntigravityAccount(email: String) async` |
| 1293 | fn | beginAntigravitySwitch | (internal) | `func beginAntigravitySwitch(accountId: String, ...` |
| 1298 | fn | cancelAntigravitySwitch | (internal) | `func cancelAntigravitySwitch()` |
| 1303 | fn | dismissAntigravitySwitchResult | (internal) | `func dismissAntigravitySwitchResult()` |
| 1306 | fn | refreshOpenAIQuotasInternal | (private) | `private func refreshOpenAIQuotasInternal() async` |
| 1311 | fn | refreshCopilotQuotasInternal | (private) | `private func refreshCopilotQuotasInternal() async` |
| 1316 | fn | refreshQuotaForProvider | (internal) | `func refreshQuotaForProvider(_ provider: AIProv...` |
| 1351 | fn | refreshAutoDetectedProviders | (internal) | `func refreshAutoDetectedProviders() async` |
| 1358 | fn | startOAuth | (internal) | `func startOAuth(for provider: AIProvider, proje...` |
| 1403 | fn | startCopilotAuth | (private) | `private func startCopilotAuth() async` |
| 1420 | fn | startKiroAuth | (private) | `private func startKiroAuth(method: AuthCommand)...` |
| 1460 | fn | pollCopilotAuthCompletion | (private) | `private func pollCopilotAuthCompletion() async` |
| 1477 | fn | pollKiroAuthCompletion | (private) | `private func pollKiroAuthCompletion() async` |
| 1500 | fn | pollOAuthStatus | (private) | `private func pollOAuthStatus(state: String, pro...` |
| 1528 | fn | cancelOAuth | (internal) | `func cancelOAuth()` |
| 1532 | fn | deleteAuthFile | (internal) | `func deleteAuthFile(_ file: AuthFile) async` |
| 1568 | fn | toggleAuthFileDisabled | (internal) | `func toggleAuthFileDisabled(_ file: AuthFile) a...` |
| 1599 | fn | pruneMenuBarItems | (private) | `private func pruneMenuBarItems()` |
| 1635 | fn | importVertexServiceAccount | (internal) | `func importVertexServiceAccount(url: URL) async` |
| 1659 | fn | fetchAPIKeys | (internal) | `func fetchAPIKeys() async` |
| 1669 | fn | addAPIKey | (internal) | `func addAPIKey(_ key: String) async` |
| 1681 | fn | updateAPIKey | (internal) | `func updateAPIKey(old: String, new: String) async` |
| 1693 | fn | deleteAPIKey | (internal) | `func deleteAPIKey(_ key: String) async` |
| 1706 | fn | checkAccountStatusChanges | (private) | `private func checkAccountStatusChanges()` |
| 1727 | fn | checkQuotaNotifications | (internal) | `func checkQuotaNotifications()` |
| 1759 | fn | scanIDEsWithConsent | (internal) | `func scanIDEsWithConsent(options: IDEScanOption...` |
| 1829 | fn | savePersistedIDEQuotas | (private) | `private func savePersistedIDEQuotas()` |
| 1852 | fn | loadPersistedIDEQuotas | (private) | `private func loadPersistedIDEQuotas()` |
| 1914 | fn | shortenAccountKey | (private) | `private func shortenAccountKey(_ key: String) -...` |
| 1926 | struct | OAuthState | (internal) | `struct OAuthState` |

## Memory Markers

### 🟢 `NOTE` (line 279)

> checkForProxyUpgrade() is now called inside startProxy()

### 🟢 `NOTE` (line 352)

> Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)

### 🟢 `NOTE` (line 360)

> Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)

### 🟢 `NOTE` (line 1181)

> Cursor and Trae removed from auto-refresh (issue #29)

### 🟢 `NOTE` (line 1206)

> Cursor and Trae require explicit user scan (issue #29)

### 🟢 `NOTE` (line 1216)

> Cursor and Trae removed - require explicit scan (issue #29)

### 🟢 `NOTE` (line 1271)

> Don't call detectActiveAccount() here - already set by switch operation

