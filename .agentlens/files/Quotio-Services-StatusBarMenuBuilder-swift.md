# Quotio/Services/StatusBarMenuBuilder.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1470
- **Language:** Swift
- **Symbols:** 46
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 18 | class | StatusBarMenuBuilder | (internal) | `class StatusBarMenuBuilder` |
| 33 | method | init | (internal) | `init(viewModel: QuotaViewModel)` |
| 39 | fn | buildMenu | (internal) | `func buildMenu() -> NSMenu` |
| 120 | fn | isCLIInstalled | (private) | `private func isCLIInstalled(_ agent: CLIAgent) ...` |
| 144 | fn | checkBinaryExists | (private) | `private func checkBinaryExists(names: [String])...` |
| 173 | fn | resolveSelectedProvider | (private) | `private func resolveSelectedProvider(from provi...` |
| 182 | fn | accountsForProvider | (private) | `private func accountsForProvider(_ provider: AI...` |
| 189 | fn | buildHeaderItem | (private) | `private func buildHeaderItem() -> NSMenuItem` |
| 196 | fn | buildNetworkInfoItem | (private) | `private func buildNetworkInfoItem() -> NSMenuItem` |
| 223 | fn | buildAccountCardItem | (private) | `private func buildAccountCardItem(     email: S...` |
| 254 | fn | buildAntigravitySubmenu | (private) | `private func buildAntigravitySubmenu(data: Prov...` |
| 270 | fn | showSwitchConfirmation | (private) | `private static func showSwitchConfirmation(emai...` |
| 299 | fn | buildEmptyStateItem | (private) | `private func buildEmptyStateItem() -> NSMenuItem` |
| 306 | fn | buildActionItems | (private) | `private func buildActionItems() -> [NSMenuItem]` |
| 330 | class | MenuActionHandler | (internal) | `class MenuActionHandler` |
| 339 | fn | refresh | (internal) | `@objc func refresh()` |
| 345 | fn | openApp | (internal) | `@objc func openApp()` |
| 349 | fn | quit | (internal) | `@objc func quit()` |
| 353 | fn | openMainWindow | (internal) | `static func openMainWindow()` |
| 378 | struct | MenuHeaderView | (private) | `struct MenuHeaderView` |
| 403 | struct | MenuProviderSectionHeader | (private) | `struct MenuProviderSectionHeader` |
| 421 | struct | MenuProviderPickerView | (private) | `struct MenuProviderPickerView` |
| 456 | struct | ProviderFilterButton | (private) | `struct ProviderFilterButton` |
| 488 | struct | ProviderIconMono | (private) | `struct ProviderIconMono` |
| 512 | struct | MenuNetworkInfoView | (private) | `struct MenuNetworkInfoView` |
| 620 | fn | triggerCopyState | (private) | `private func triggerCopyState(_ target: CopyTar...` |
| 631 | fn | setCopied | (private) | `private func setCopied(_ target: CopyTarget, va...` |
| 642 | fn | copyButton | (private) | `@ViewBuilder   private func copyButton(isCopied...` |
| 659 | struct | MenuAccountCardView | (private) | `struct MenuAccountCardView` |
| 698 | fn | planConfig | (private) | `private func planConfig(for planName: String) -...` |
| 930 | fn | formatLocalTime | (private) | `private func formatLocalTime(_ isoString: Strin...` |
| 949 | struct | ModelBadgeData | (private) | `struct ModelBadgeData` |
| 988 | struct | AntigravityDisplayGroup | (private) | `struct AntigravityDisplayGroup` |
| 995 | fn | menuDisplayPercent | (private) | `private func menuDisplayPercent(remainingPercen...` |
| 999 | fn | menuStatusColor | (private) | `private func menuStatusColor(remainingPercent: ...` |
| 1017 | struct | LowestBarLayout | (private) | `struct LowestBarLayout` |
| 1097 | struct | RingGridLayout | (private) | `struct RingGridLayout` |
| 1141 | struct | CardGridLayout | (private) | `struct CardGridLayout` |
| 1190 | struct | ModernProgressBar | (private) | `struct ModernProgressBar` |
| 1225 | struct | PercentageBadge | (private) | `struct PercentageBadge` |
| 1261 | struct | MenuModelDetailView | (private) | `struct MenuModelDetailView` |
| 1313 | struct | MenuEmptyStateView | (private) | `struct MenuEmptyStateView` |
| 1328 | struct | MenuViewMoreAccountsView | (private) | `struct MenuViewMoreAccountsView` |
| 1376 | mod | extension AIProvider | (private) | - |
| 1398 | struct | MenuActionsView | (private) | `struct MenuActionsView` |
| 1436 | struct | MenuBarActionButton | (private) | `struct MenuBarActionButton` |

