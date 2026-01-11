# Quotio/Views/Screens/SettingsScreen.swift

[← Back to Module](../modules/Quotio-Views-Screens/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 2733
- **Language:** Swift
- **Symbols:** 58
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 9 | struct | SettingsScreen | (internal) | `struct SettingsScreen` |
| 90 | struct | OperatingModeSection | (internal) | `struct OperatingModeSection` |
| 155 | fn | handleModeSelection | (private) | `private func handleModeSelection(_ mode: Operat...` |
| 174 | fn | switchToMode | (private) | `private func switchToMode(_ mode: OperatingMode)` |
| 189 | struct | RemoteServerSection | (internal) | `struct RemoteServerSection` |
| 310 | fn | saveRemoteConfig | (private) | `private func saveRemoteConfig(_ config: RemoteC...` |
| 318 | fn | reconnect | (private) | `private func reconnect()` |
| 333 | struct | UnifiedProxySettingsSection | (internal) | `struct UnifiedProxySettingsSection` |
| 544 | fn | loadConfig | (private) | `private func loadConfig() async` |
| 575 | fn | saveProxyURL | (private) | `private func saveProxyURL() async` |
| 588 | fn | saveRoutingStrategy | (private) | `private func saveRoutingStrategy(_ strategy: St...` |
| 597 | fn | saveSwitchProject | (private) | `private func saveSwitchProject(_ enabled: Bool)...` |
| 606 | fn | saveSwitchPreviewModel | (private) | `private func saveSwitchPreviewModel(_ enabled: ...` |
| 615 | fn | saveRequestRetry | (private) | `private func saveRequestRetry(_ count: Int) async` |
| 624 | fn | saveMaxRetryInterval | (private) | `private func saveMaxRetryInterval(_ seconds: In...` |
| 633 | fn | saveLoggingToFile | (private) | `private func saveLoggingToFile(_ enabled: Bool)...` |
| 642 | fn | saveRequestLog | (private) | `private func saveRequestLog(_ enabled: Bool) async` |
| 651 | fn | saveDebugMode | (private) | `private func saveDebugMode(_ enabled: Bool) async` |
| 664 | struct | LocalProxyServerSection | (internal) | `struct LocalProxyServerSection` |
| 720 | struct | LocalPathsSection | (internal) | `struct LocalPathsSection` |
| 744 | struct | PathLabel | (internal) | `struct PathLabel` |
| 768 | struct | NotificationSettingsSection | (internal) | `struct NotificationSettingsSection` |
| 838 | struct | QuotaDisplaySettingsSection | (internal) | `struct QuotaDisplaySettingsSection` |
| 866 | struct | RefreshCadenceSettingsSection | (internal) | `struct RefreshCadenceSettingsSection` |
| 905 | struct | UpdateSettingsSection | (internal) | `struct UpdateSettingsSection` |
| 947 | struct | ProxyUpdateSettingsSection | (internal) | `struct ProxyUpdateSettingsSection` |
| 1077 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 1087 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 1106 | struct | ProxyVersionManagerSheet | (internal) | `struct ProxyVersionManagerSheet` |
| 1265 | fn | sectionHeader | (private) | `@ViewBuilder   private func sectionHeader(_ tit...` |
| 1280 | fn | isVersionInstalled | (private) | `private func isVersionInstalled(_ version: Stri...` |
| 1284 | fn | refreshInstalledVersions | (private) | `private func refreshInstalledVersions()` |
| 1288 | fn | loadReleases | (private) | `private func loadReleases() async` |
| 1302 | fn | installVersion | (private) | `private func installVersion(_ release: GitHubRe...` |
| 1320 | fn | performInstall | (private) | `private func performInstall(_ release: GitHubRe...` |
| 1341 | fn | activateVersion | (private) | `private func activateVersion(_ version: String)` |
| 1359 | fn | deleteVersion | (private) | `private func deleteVersion(_ version: String)` |
| 1372 | struct | InstalledVersionRow | (private) | `struct InstalledVersionRow` |
| 1430 | struct | AvailableVersionRow | (private) | `struct AvailableVersionRow` |
| 1516 | fn | formatDate | (private) | `private func formatDate(_ isoString: String) ->...` |
| 1534 | struct | MenuBarSettingsSection | (internal) | `struct MenuBarSettingsSection` |
| 1616 | struct | AppearanceSettingsSection | (internal) | `struct AppearanceSettingsSection` |
| 1645 | struct | PrivacySettingsSection | (internal) | `struct PrivacySettingsSection` |
| 1667 | struct | GeneralSettingsTab | (internal) | `struct GeneralSettingsTab` |
| 1706 | struct | AboutTab | (internal) | `struct AboutTab` |
| 1733 | struct | AboutScreen | (internal) | `struct AboutScreen` |
| 1948 | struct | AboutUpdateSection | (internal) | `struct AboutUpdateSection` |
| 2004 | struct | AboutProxyUpdateSection | (internal) | `struct AboutProxyUpdateSection` |
| 2140 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2150 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2169 | struct | VersionBadge | (internal) | `struct VersionBadge` |
| 2221 | struct | AboutUpdateCard | (internal) | `struct AboutUpdateCard` |
| 2312 | struct | AboutProxyUpdateCard | (internal) | `struct AboutProxyUpdateCard` |
| 2469 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2479 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2498 | struct | LinkCard | (internal) | `struct LinkCard` |
| 2585 | struct | ManagementKeyRow | (internal) | `struct ManagementKeyRow` |
| 2679 | struct | LaunchAtLoginToggle | (internal) | `struct LaunchAtLoginToggle` |

