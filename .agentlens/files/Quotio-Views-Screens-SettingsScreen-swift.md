# Quotio/Views/Screens/SettingsScreen.swift

[← Back to Module](../modules/Quotio-Views-Screens/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 2787
- **Language:** Swift
- **Symbols:** 59
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
| 726 | struct | NetworkAccessSection | (internal) | `struct NetworkAccessSection` |
| 760 | struct | LocalPathsSection | (internal) | `struct LocalPathsSection` |
| 784 | struct | PathLabel | (internal) | `struct PathLabel` |
| 808 | struct | NotificationSettingsSection | (internal) | `struct NotificationSettingsSection` |
| 878 | struct | QuotaDisplaySettingsSection | (internal) | `struct QuotaDisplaySettingsSection` |
| 920 | struct | RefreshCadenceSettingsSection | (internal) | `struct RefreshCadenceSettingsSection` |
| 959 | struct | UpdateSettingsSection | (internal) | `struct UpdateSettingsSection` |
| 1001 | struct | ProxyUpdateSettingsSection | (internal) | `struct ProxyUpdateSettingsSection` |
| 1131 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 1141 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 1160 | struct | ProxyVersionManagerSheet | (internal) | `struct ProxyVersionManagerSheet` |
| 1319 | fn | sectionHeader | (private) | `@ViewBuilder   private func sectionHeader(_ tit...` |
| 1334 | fn | isVersionInstalled | (private) | `private func isVersionInstalled(_ version: Stri...` |
| 1338 | fn | refreshInstalledVersions | (private) | `private func refreshInstalledVersions()` |
| 1342 | fn | loadReleases | (private) | `private func loadReleases() async` |
| 1356 | fn | installVersion | (private) | `private func installVersion(_ release: GitHubRe...` |
| 1374 | fn | performInstall | (private) | `private func performInstall(_ release: GitHubRe...` |
| 1395 | fn | activateVersion | (private) | `private func activateVersion(_ version: String)` |
| 1413 | fn | deleteVersion | (private) | `private func deleteVersion(_ version: String)` |
| 1426 | struct | InstalledVersionRow | (private) | `struct InstalledVersionRow` |
| 1484 | struct | AvailableVersionRow | (private) | `struct AvailableVersionRow` |
| 1570 | fn | formatDate | (private) | `private func formatDate(_ isoString: String) ->...` |
| 1588 | struct | MenuBarSettingsSection | (internal) | `struct MenuBarSettingsSection` |
| 1670 | struct | AppearanceSettingsSection | (internal) | `struct AppearanceSettingsSection` |
| 1699 | struct | PrivacySettingsSection | (internal) | `struct PrivacySettingsSection` |
| 1721 | struct | GeneralSettingsTab | (internal) | `struct GeneralSettingsTab` |
| 1760 | struct | AboutTab | (internal) | `struct AboutTab` |
| 1787 | struct | AboutScreen | (internal) | `struct AboutScreen` |
| 2002 | struct | AboutUpdateSection | (internal) | `struct AboutUpdateSection` |
| 2058 | struct | AboutProxyUpdateSection | (internal) | `struct AboutProxyUpdateSection` |
| 2194 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2204 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2223 | struct | VersionBadge | (internal) | `struct VersionBadge` |
| 2275 | struct | AboutUpdateCard | (internal) | `struct AboutUpdateCard` |
| 2366 | struct | AboutProxyUpdateCard | (internal) | `struct AboutProxyUpdateCard` |
| 2523 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2533 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2552 | struct | LinkCard | (internal) | `struct LinkCard` |
| 2639 | struct | ManagementKeyRow | (internal) | `struct ManagementKeyRow` |
| 2733 | struct | LaunchAtLoginToggle | (internal) | `struct LaunchAtLoginToggle` |

