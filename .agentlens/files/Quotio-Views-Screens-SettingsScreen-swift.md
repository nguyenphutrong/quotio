# Quotio/Views/Screens/SettingsScreen.swift

[← Back to Module](../modules/Quotio-Views-Screens/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 2876
- **Language:** Swift
- **Symbols:** 60
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 9 | struct | SettingsScreen | (internal) | `struct SettingsScreen` |
| 93 | struct | OperatingModeSection | (internal) | `struct OperatingModeSection` |
| 158 | fn | handleModeSelection | (private) | `private func handleModeSelection(_ mode: Operat...` |
| 177 | fn | switchToMode | (private) | `private func switchToMode(_ mode: OperatingMode)` |
| 192 | struct | RemoteServerSection | (internal) | `struct RemoteServerSection` |
| 313 | fn | saveRemoteConfig | (private) | `private func saveRemoteConfig(_ config: RemoteC...` |
| 321 | fn | reconnect | (private) | `private func reconnect()` |
| 336 | struct | UnifiedProxySettingsSection | (internal) | `struct UnifiedProxySettingsSection` |
| 556 | fn | loadConfig | (private) | `private func loadConfig() async` |
| 597 | fn | saveProxyURL | (private) | `private func saveProxyURL() async` |
| 610 | fn | saveRoutingStrategy | (private) | `private func saveRoutingStrategy(_ strategy: St...` |
| 619 | fn | saveSwitchProject | (private) | `private func saveSwitchProject(_ enabled: Bool)...` |
| 628 | fn | saveSwitchPreviewModel | (private) | `private func saveSwitchPreviewModel(_ enabled: ...` |
| 637 | fn | saveRequestRetry | (private) | `private func saveRequestRetry(_ count: Int) async` |
| 646 | fn | saveMaxRetryInterval | (private) | `private func saveMaxRetryInterval(_ seconds: In...` |
| 655 | fn | saveLoggingToFile | (private) | `private func saveLoggingToFile(_ enabled: Bool)...` |
| 664 | fn | saveRequestLog | (private) | `private func saveRequestLog(_ enabled: Bool) async` |
| 673 | fn | saveDebugMode | (private) | `private func saveDebugMode(_ enabled: Bool) async` |
| 686 | struct | LocalProxyServerSection | (internal) | `struct LocalProxyServerSection` |
| 748 | struct | NetworkAccessSection | (internal) | `struct NetworkAccessSection` |
| 782 | struct | LocalPathsSection | (internal) | `struct LocalPathsSection` |
| 806 | struct | PathLabel | (internal) | `struct PathLabel` |
| 830 | struct | NotificationSettingsSection | (internal) | `struct NotificationSettingsSection` |
| 900 | struct | QuotaDisplaySettingsSection | (internal) | `struct QuotaDisplaySettingsSection` |
| 942 | struct | RefreshCadenceSettingsSection | (internal) | `struct RefreshCadenceSettingsSection` |
| 981 | struct | UpdateSettingsSection | (internal) | `struct UpdateSettingsSection` |
| 1023 | struct | ProxyUpdateSettingsSection | (internal) | `struct ProxyUpdateSettingsSection` |
| 1153 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 1163 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 1182 | struct | ProxyVersionManagerSheet | (internal) | `struct ProxyVersionManagerSheet` |
| 1341 | fn | sectionHeader | (private) | `@ViewBuilder   private func sectionHeader(_ tit...` |
| 1356 | fn | isVersionInstalled | (private) | `private func isVersionInstalled(_ version: Stri...` |
| 1360 | fn | refreshInstalledVersions | (private) | `private func refreshInstalledVersions()` |
| 1364 | fn | loadReleases | (private) | `private func loadReleases() async` |
| 1378 | fn | installVersion | (private) | `private func installVersion(_ release: GitHubRe...` |
| 1396 | fn | performInstall | (private) | `private func performInstall(_ release: GitHubRe...` |
| 1417 | fn | activateVersion | (private) | `private func activateVersion(_ version: String)` |
| 1435 | fn | deleteVersion | (private) | `private func deleteVersion(_ version: String)` |
| 1448 | struct | InstalledVersionRow | (private) | `struct InstalledVersionRow` |
| 1506 | struct | AvailableVersionRow | (private) | `struct AvailableVersionRow` |
| 1592 | fn | formatDate | (private) | `private func formatDate(_ isoString: String) ->...` |
| 1610 | struct | MenuBarSettingsSection | (internal) | `struct MenuBarSettingsSection` |
| 1692 | struct | AppearanceSettingsSection | (internal) | `struct AppearanceSettingsSection` |
| 1721 | struct | PrivacySettingsSection | (internal) | `struct PrivacySettingsSection` |
| 1743 | struct | GeneralSettingsTab | (internal) | `struct GeneralSettingsTab` |
| 1782 | struct | AboutTab | (internal) | `struct AboutTab` |
| 1809 | struct | AboutScreen | (internal) | `struct AboutScreen` |
| 2024 | struct | AboutUpdateSection | (internal) | `struct AboutUpdateSection` |
| 2080 | struct | AboutProxyUpdateSection | (internal) | `struct AboutProxyUpdateSection` |
| 2216 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2226 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2245 | struct | VersionBadge | (internal) | `struct VersionBadge` |
| 2297 | struct | AboutUpdateCard | (internal) | `struct AboutUpdateCard` |
| 2388 | struct | AboutProxyUpdateCard | (internal) | `struct AboutProxyUpdateCard` |
| 2545 | fn | checkForUpdate | (private) | `private func checkForUpdate()` |
| 2555 | fn | performUpgrade | (private) | `private func performUpgrade(to version: ProxyVe...` |
| 2574 | struct | LinkCard | (internal) | `struct LinkCard` |
| 2661 | struct | ManagementKeyRow | (internal) | `struct ManagementKeyRow` |
| 2755 | struct | LaunchAtLoginToggle | (internal) | `struct LaunchAtLoginToggle` |
| 2813 | struct | UsageDisplaySettingsSection | (internal) | `struct UsageDisplaySettingsSection` |

