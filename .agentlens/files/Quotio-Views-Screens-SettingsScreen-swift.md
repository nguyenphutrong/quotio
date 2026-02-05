# Quotio/Views/Screens/SettingsScreen.swift

[← Back to Module](../modules/Quotio-Views-Screens/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 3013
- **Language:** Swift
- **Symbols:** 60
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 9 | struct | SettingsScreen | (internal) | `struct SettingsScreen` |
| 108 | struct | OperatingModeSection | (internal) | `struct OperatingModeSection` |
| 173 | fn | handleModeSelection | (private) | `private func handleModeSelection(_ mode: Operat...` |
| 192 | fn | switchToMode | (private) | `private func switchToMode(_ mode: OperatingMode)` |
| 207 | struct | RemoteServerSection | (internal) | `struct RemoteServerSection` |
| 328 | fn | saveRemoteConfig | (private) | `private func saveRemoteConfig(_ config: RemoteC...` |
| 336 | fn | reconnect | (private) | `private func reconnect()` |
| 351 | struct | UnifiedProxySettingsSection | (internal) | `struct UnifiedProxySettingsSection` |
| 571 | fn | loadConfig | (private) | `private func loadConfig() async` |
| 612 | fn | saveProxyURL | (private) | `private func saveProxyURL() async` |
| 625 | fn | saveRoutingStrategy | (private) | `private func saveRoutingStrategy(_ strategy: St...` |
| 634 | fn | saveSwitchProject | (private) | `private func saveSwitchProject(_ enabled: Bool)...` |
| 643 | fn | saveSwitchPreviewModel | (private) | `private func saveSwitchPreviewModel(_ enabled: ...` |
| 652 | fn | saveRequestRetry | (private) | `private func saveRequestRetry(_ count: Int) async` |
| 661 | fn | saveMaxRetryInterval | (private) | `private func saveMaxRetryInterval(_ seconds: In...` |
| 670 | fn | saveLoggingToFile | (private) | `private func saveLoggingToFile(_ enabled: Bool)...` |
| 679 | fn | saveRequestLog | (private) | `private func saveRequestLog(_ enabled: Bool) async` |
| 688 | fn | saveDebugMode | (private) | `private func saveDebugMode(_ enabled: Bool) async` |
| 701 | struct | LocalProxyServerSection | (internal) | `struct LocalProxyServerSection` |
| 763 | struct | NetworkAccessSection | (internal) | `struct NetworkAccessSection` |
| 797 | struct | LocalPathsSection | (internal) | `struct LocalPathsSection` |
| 821 | struct | PathLabel | (internal) | `struct PathLabel` |
| 845 | struct | NotificationSettingsSection | (internal) | `struct NotificationSettingsSection` |
| 915 | struct | QuotaDisplaySettingsSection | (internal) | `struct QuotaDisplaySettingsSection` |
| 957 | struct | RefreshCadenceSettingsSection | (internal) | `struct RefreshCadenceSettingsSection` |
| 996 | struct | UpdateSettingsSection | (internal) | `struct UpdateSettingsSection` |
| 1038 | struct | ProxyUpdateSettingsSection | (internal) | `struct ProxyUpdateSettingsSection` |
| 1185 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 1199 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 1218 | struct | ProxyVersionManagerSheet | (internal) | `struct ProxyVersionManagerSheet` |
| 1377 | fn | sectionHeader | (private) | `@ViewBuilder   private func sectionHeader(_ tit...` |
| 1392 | fn | isVersionInstalled | (private) | `private func isVersionInstalled(_ version: Stri...` |
| 1396 | fn | refreshInstalledVersions | (private) | `private func refreshInstalledVersions()` |
| 1400 | fn | loadReleases | (private) | `private func loadReleases() async` |
| 1414 | fn | installVersion | (private) | `private func installVersion(_ release: GitHubRe...` |
| 1432 | fn | performInstall | (private) | `private func performInstall(_ release: GitHubRe...` |
| 1453 | fn | activateVersion | (private) | `private func activateVersion(_ version: String)` |
| 1471 | fn | deleteVersion | (private) | `private func deleteVersion(_ version: String)` |
| 1484 | struct | InstalledVersionRow | (private) | `struct InstalledVersionRow` |
| 1542 | struct | AvailableVersionRow | (private) | `struct AvailableVersionRow` |
| 1628 | fn | formatDate | (private) | `private func formatDate(_ isoString: String) ->...` |
| 1646 | struct | MenuBarSettingsSection | (internal) | `struct MenuBarSettingsSection` |
| 1787 | struct | AppearanceSettingsSection | (internal) | `struct AppearanceSettingsSection` |
| 1816 | struct | PrivacySettingsSection | (internal) | `struct PrivacySettingsSection` |
| 1838 | struct | GeneralSettingsTab | (internal) | `struct GeneralSettingsTab` |
| 1877 | struct | AboutTab | (internal) | `struct AboutTab` |
| 1904 | struct | AboutScreen | (internal) | `struct AboutScreen` |
| 2119 | struct | AboutUpdateSection | (internal) | `struct AboutUpdateSection` |
| 2175 | struct | AboutProxyUpdateSection | (internal) | `struct AboutProxyUpdateSection` |
| 2328 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2342 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2361 | struct | VersionBadge | (internal) | `struct VersionBadge` |
| 2413 | struct | AboutUpdateCard | (internal) | `struct AboutUpdateCard` |
| 2504 | struct | AboutProxyUpdateCard | (internal) | `struct AboutProxyUpdateCard` |
| 2678 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2692 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2711 | struct | LinkCard | (internal) | `struct LinkCard` |
| 2798 | struct | ManagementKeyRow | (internal) | `struct ManagementKeyRow` |
| 2892 | struct | LaunchAtLoginToggle | (internal) | `struct LaunchAtLoginToggle` |
| 2950 | struct | UsageDisplaySettingsSection | (internal) | `struct UsageDisplaySettingsSection` |

