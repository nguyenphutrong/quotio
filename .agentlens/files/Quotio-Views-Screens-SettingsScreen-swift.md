# Quotio/Views/Screens/SettingsScreen.swift

[← Back to Module](../modules/Quotio-Views-Screens/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 2691
- **Language:** Swift
- **Symbols:** 57
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 10 | struct | SettingsScreen | (internal) | `struct SettingsScreen` |
| 103 | struct | OperatingModeSection | (internal) | `struct OperatingModeSection` |
| 168 | fn | handleModeSelection | (private) | `private func handleModeSelection(_ mode: Operat...` |
| 187 | fn | switchToMode | (private) | `private func switchToMode(_ mode: OperatingMode)` |
| 202 | struct | RemoteServerSection | (internal) | `struct RemoteServerSection` |
| 320 | fn | saveRemoteConfig | (private) | `private func saveRemoteConfig(_ config: RemoteC...` |
| 328 | fn | reconnect | (private) | `private func reconnect()` |
| 343 | struct | UnifiedProxySettingsSection | (internal) | `struct UnifiedProxySettingsSection` |
| 554 | fn | loadConfig | (private) | `private func loadConfig() async` |
| 585 | fn | saveProxyURL | (private) | `private func saveProxyURL() async` |
| 598 | fn | saveRoutingStrategy | (private) | `private func saveRoutingStrategy(_ strategy: St...` |
| 607 | fn | saveSwitchProject | (private) | `private func saveSwitchProject(_ enabled: Bool)...` |
| 616 | fn | saveSwitchPreviewModel | (private) | `private func saveSwitchPreviewModel(_ enabled: ...` |
| 625 | fn | saveRequestRetry | (private) | `private func saveRequestRetry(_ count: Int) async` |
| 634 | fn | saveMaxRetryInterval | (private) | `private func saveMaxRetryInterval(_ seconds: In...` |
| 643 | fn | saveLoggingToFile | (private) | `private func saveLoggingToFile(_ enabled: Bool)...` |
| 652 | fn | saveRequestLog | (private) | `private func saveRequestLog(_ enabled: Bool) async` |
| 661 | fn | saveDebugMode | (private) | `private func saveDebugMode(_ enabled: Bool) async` |
| 674 | struct | LocalProxyServerSection | (internal) | `struct LocalProxyServerSection` |
| 726 | struct | LocalPathsSection | (internal) | `struct LocalPathsSection` |
| 750 | struct | PathLabel | (internal) | `struct PathLabel` |
| 774 | struct | NotificationSettingsSection | (internal) | `struct NotificationSettingsSection` |
| 844 | struct | QuotaDisplaySettingsSection | (internal) | `struct QuotaDisplaySettingsSection` |
| 872 | struct | RefreshCadenceSettingsSection | (internal) | `struct RefreshCadenceSettingsSection` |
| 911 | struct | UpdateSettingsSection | (internal) | `struct UpdateSettingsSection` |
| 953 | struct | ProxyUpdateSettingsSection | (internal) | `struct ProxyUpdateSettingsSection` |
| 1083 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 1093 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 1112 | struct | ProxyVersionManagerSheet | (internal) | `struct ProxyVersionManagerSheet` |
| 1271 | fn | sectionHeader | (private) | `@ViewBuilder   private func sectionHeader(_ tit...` |
| 1286 | fn | isVersionInstalled | (private) | `private func isVersionInstalled(_ version: Stri...` |
| 1290 | fn | refreshInstalledVersions | (private) | `private func refreshInstalledVersions()` |
| 1294 | fn | loadReleases | (private) | `private func loadReleases() async` |
| 1308 | fn | installVersion | (private) | `private func installVersion(_ release: GitHubRe...` |
| 1326 | fn | performInstall | (private) | `private func performInstall(_ release: GitHubRe...` |
| 1347 | fn | activateVersion | (private) | `private func activateVersion(_ version: String)` |
| 1365 | fn | deleteVersion | (private) | `private func deleteVersion(_ version: String)` |
| 1378 | struct | InstalledVersionRow | (private) | `struct InstalledVersionRow` |
| 1436 | struct | AvailableVersionRow | (private) | `struct AvailableVersionRow` |
| 1522 | fn | formatDate | (private) | `private func formatDate(_ isoString: String) ->...` |
| 1540 | struct | MenuBarSettingsSection | (internal) | `struct MenuBarSettingsSection` |
| 1622 | struct | AppearanceSettingsSection | (internal) | `struct AppearanceSettingsSection` |
| 1651 | struct | PrivacySettingsSection | (internal) | `struct PrivacySettingsSection` |
| 1673 | struct | GeneralSettingsTab | (internal) | `struct GeneralSettingsTab` |
| 1724 | struct | AboutTab | (internal) | `struct AboutTab` |
| 1751 | struct | AboutScreen | (internal) | `struct AboutScreen` |
| 1966 | struct | AboutUpdateSection | (internal) | `struct AboutUpdateSection` |
| 2022 | struct | AboutProxyUpdateSection | (internal) | `struct AboutProxyUpdateSection` |
| 2158 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2168 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2187 | struct | VersionBadge | (internal) | `struct VersionBadge` |
| 2239 | struct | AboutUpdateCard | (internal) | `struct AboutUpdateCard` |
| 2330 | struct | AboutProxyUpdateCard | (internal) | `struct AboutProxyUpdateCard` |
| 2487 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2497 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2516 | struct | LinkCard | (internal) | `struct LinkCard` |
| 2603 | struct | ManagementKeyRow | (internal) | `struct ManagementKeyRow` |

