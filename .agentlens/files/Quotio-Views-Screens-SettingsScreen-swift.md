# Quotio/Views/Screens/SettingsScreen.swift

[← Back to Module](../modules/Quotio-Views-Screens/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 3047
- **Language:** Swift
- **Symbols:** 60
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 9 | struct | SettingsScreen | (internal) | `struct SettingsScreen` |
| 111 | struct | OperatingModeSection | (internal) | `struct OperatingModeSection` |
| 176 | fn | handleModeSelection | (private) | `private func handleModeSelection(_ mode: Operat...` |
| 195 | fn | switchToMode | (private) | `private func switchToMode(_ mode: OperatingMode)` |
| 210 | struct | RemoteServerSection | (internal) | `struct RemoteServerSection` |
| 330 | fn | saveRemoteConfig | (private) | `private func saveRemoteConfig(_ config: RemoteC...` |
| 338 | fn | reconnect | (private) | `private func reconnect()` |
| 353 | struct | UnifiedProxySettingsSection | (internal) | `struct UnifiedProxySettingsSection` |
| 573 | fn | loadConfig | (private) | `private func loadConfig() async` |
| 620 | fn | saveProxyURL | (private) | `private func saveProxyURL() async` |
| 638 | fn | saveRoutingStrategy | (private) | `private func saveRoutingStrategy(_ strategy: St...` |
| 647 | fn | saveSwitchProject | (private) | `private func saveSwitchProject(_ enabled: Bool)...` |
| 656 | fn | saveSwitchPreviewModel | (private) | `private func saveSwitchPreviewModel(_ enabled: ...` |
| 665 | fn | saveRequestRetry | (private) | `private func saveRequestRetry(_ count: Int) async` |
| 674 | fn | saveMaxRetryInterval | (private) | `private func saveMaxRetryInterval(_ seconds: In...` |
| 683 | fn | saveLoggingToFile | (private) | `private func saveLoggingToFile(_ enabled: Bool)...` |
| 692 | fn | saveRequestLog | (private) | `private func saveRequestLog(_ enabled: Bool) async` |
| 701 | fn | saveDebugMode | (private) | `private func saveDebugMode(_ enabled: Bool) async` |
| 714 | struct | LocalProxyServerSection | (internal) | `struct LocalProxyServerSection` |
| 784 | struct | NetworkAccessSection | (internal) | `struct NetworkAccessSection` |
| 818 | struct | LocalPathsSection | (internal) | `struct LocalPathsSection` |
| 842 | struct | PathLabel | (internal) | `struct PathLabel` |
| 866 | struct | NotificationSettingsSection | (internal) | `struct NotificationSettingsSection` |
| 936 | struct | QuotaDisplaySettingsSection | (internal) | `struct QuotaDisplaySettingsSection` |
| 978 | struct | RefreshCadenceSettingsSection | (internal) | `struct RefreshCadenceSettingsSection` |
| 1017 | struct | UpdateSettingsSection | (internal) | `struct UpdateSettingsSection` |
| 1059 | struct | ProxyUpdateSettingsSection | (internal) | `struct ProxyUpdateSettingsSection` |
| 1219 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 1233 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 1252 | struct | ProxyVersionManagerSheet | (internal) | `struct ProxyVersionManagerSheet` |
| 1411 | fn | sectionHeader | (private) | `@ViewBuilder   private func sectionHeader(_ tit...` |
| 1426 | fn | isVersionInstalled | (private) | `private func isVersionInstalled(_ version: Stri...` |
| 1430 | fn | refreshInstalledVersions | (private) | `private func refreshInstalledVersions()` |
| 1434 | fn | loadReleases | (private) | `private func loadReleases() async` |
| 1448 | fn | installVersion | (private) | `private func installVersion(_ release: GitHubRe...` |
| 1466 | fn | performInstall | (private) | `private func performInstall(_ release: GitHubRe...` |
| 1487 | fn | activateVersion | (private) | `private func activateVersion(_ version: String)` |
| 1505 | fn | deleteVersion | (private) | `private func deleteVersion(_ version: String)` |
| 1518 | struct | InstalledVersionRow | (private) | `struct InstalledVersionRow` |
| 1576 | struct | AvailableVersionRow | (private) | `struct AvailableVersionRow` |
| 1662 | fn | formatDate | (private) | `private func formatDate(_ isoString: String) ->...` |
| 1680 | struct | MenuBarSettingsSection | (internal) | `struct MenuBarSettingsSection` |
| 1821 | struct | AppearanceSettingsSection | (internal) | `struct AppearanceSettingsSection` |
| 1850 | struct | PrivacySettingsSection | (internal) | `struct PrivacySettingsSection` |
| 1872 | struct | GeneralSettingsTab | (internal) | `struct GeneralSettingsTab` |
| 1911 | struct | AboutTab | (internal) | `struct AboutTab` |
| 1938 | struct | AboutScreen | (internal) | `struct AboutScreen` |
| 2153 | struct | AboutUpdateSection | (internal) | `struct AboutUpdateSection` |
| 2209 | struct | AboutProxyUpdateSection | (internal) | `struct AboutProxyUpdateSection` |
| 2362 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2376 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2395 | struct | VersionBadge | (internal) | `struct VersionBadge` |
| 2447 | struct | AboutUpdateCard | (internal) | `struct AboutUpdateCard` |
| 2538 | struct | AboutProxyUpdateCard | (internal) | `struct AboutProxyUpdateCard` |
| 2712 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2726 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2745 | struct | LinkCard | (internal) | `struct LinkCard` |
| 2832 | struct | ManagementKeyRow | (internal) | `struct ManagementKeyRow` |
| 2926 | struct | LaunchAtLoginToggle | (internal) | `struct LaunchAtLoginToggle` |
| 2984 | struct | UsageDisplaySettingsSection | (internal) | `struct UsageDisplaySettingsSection` |

