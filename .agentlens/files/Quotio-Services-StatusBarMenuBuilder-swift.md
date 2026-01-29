# Quotio/Services/StatusBarMenuBuilder.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1415
- **Language:** Swift
- **Symbols:** 44
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 18 | class | StatusBarMenuBuilder | (internal) | `class StatusBarMenuBuilder` |
| 29 | method | init | (internal) | `init(viewModel: QuotaViewModel)` |
| 35 | fn | buildMenu | (internal) | `func buildMenu() -> NSMenu` |
| 127 | fn | resolveSelectedProvider | (private) | `private func resolveSelectedProvider(from provi...` |
| 136 | fn | accountsForProvider | (private) | `private func accountsForProvider(_ provider: AI...` |
| 143 | fn | buildHeaderItem | (private) | `private func buildHeaderItem() -> NSMenuItem` |
| 150 | fn | buildNetworkInfoItem | (private) | `private func buildNetworkInfoItem() -> NSMenuItem` |
| 177 | fn | buildAccountCardItem | (private) | `private func buildAccountCardItem(     email: S...` |
| 206 | fn | buildViewMoreAccountsItem | (private) | `private func buildViewMoreAccountsItem(remainin...` |
| 217 | fn | buildAntigravitySubmenu | (private) | `private func buildAntigravitySubmenu(data: Prov...` |
| 233 | fn | showSwitchConfirmation | (private) | `private static func showSwitchConfirmation(emai...` |
| 262 | fn | buildEmptyStateItem | (private) | `private func buildEmptyStateItem() -> NSMenuItem` |
| 269 | fn | buildActionItems | (private) | `private func buildActionItems() -> [NSMenuItem]` |
| 293 | class | MenuActionHandler | (internal) | `class MenuActionHandler` |
| 302 | fn | refresh | (internal) | `@objc func refresh()` |
| 308 | fn | openApp | (internal) | `@objc func openApp()` |
| 312 | fn | quit | (internal) | `@objc func quit()` |
| 316 | fn | openMainWindow | (internal) | `static func openMainWindow()` |
| 341 | struct | MenuHeaderView | (private) | `struct MenuHeaderView` |
| 366 | struct | MenuProviderPickerView | (private) | `struct MenuProviderPickerView` |
| 401 | struct | ProviderFilterButton | (private) | `struct ProviderFilterButton` |
| 433 | struct | ProviderIconMono | (private) | `struct ProviderIconMono` |
| 457 | struct | MenuNetworkInfoView | (private) | `struct MenuNetworkInfoView` |
| 565 | fn | triggerCopyState | (private) | `private func triggerCopyState(_ target: CopyTar...` |
| 576 | fn | setCopied | (private) | `private func setCopied(_ target: CopyTarget, va...` |
| 587 | fn | copyButton | (private) | `@ViewBuilder   private func copyButton(isCopied...` |
| 604 | struct | MenuAccountCardView | (private) | `struct MenuAccountCardView` |
| 643 | fn | planConfig | (private) | `private func planConfig(for planName: String) -...` |
| 875 | fn | formatLocalTime | (private) | `private func formatLocalTime(_ isoString: Strin...` |
| 894 | struct | ModelBadgeData | (private) | `struct ModelBadgeData` |
| 933 | struct | AntigravityDisplayGroup | (private) | `struct AntigravityDisplayGroup` |
| 940 | fn | menuDisplayPercent | (private) | `private func menuDisplayPercent(remainingPercen...` |
| 944 | fn | menuStatusColor | (private) | `private func menuStatusColor(remainingPercent: ...` |
| 962 | struct | LowestBarLayout | (private) | `struct LowestBarLayout` |
| 1042 | struct | RingGridLayout | (private) | `struct RingGridLayout` |
| 1086 | struct | CardGridLayout | (private) | `struct CardGridLayout` |
| 1135 | struct | ModernProgressBar | (private) | `struct ModernProgressBar` |
| 1170 | struct | PercentageBadge | (private) | `struct PercentageBadge` |
| 1206 | struct | MenuModelDetailView | (private) | `struct MenuModelDetailView` |
| 1258 | struct | MenuEmptyStateView | (private) | `struct MenuEmptyStateView` |
| 1273 | struct | MenuViewMoreAccountsView | (private) | `struct MenuViewMoreAccountsView` |
| 1321 | mod | extension AIProvider | (private) | - |
| 1343 | struct | MenuActionsView | (private) | `struct MenuActionsView` |
| 1381 | struct | MenuBarActionButton | (private) | `struct MenuBarActionButton` |

