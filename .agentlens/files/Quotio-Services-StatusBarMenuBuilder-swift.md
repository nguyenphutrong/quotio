# Quotio/Services/StatusBarMenuBuilder.swift

[← Back to Module](../modules/Quotio-Services/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1407
- **Language:** Swift
- **Symbols:** 44
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 18 | class | StatusBarMenuBuilder | (internal) | `class StatusBarMenuBuilder` |
| 27 | method | init | (internal) | `init(viewModel: QuotaViewModel)` |
| 33 | fn | buildMenu | (internal) | `func buildMenu() -> NSMenu` |
| 110 | fn | resolveSelectedProvider | (private) | `private func resolveSelectedProvider(from provi...` |
| 119 | fn | accountsForProvider | (private) | `private func accountsForProvider(_ provider: AI...` |
| 126 | fn | buildHeaderItem | (private) | `private func buildHeaderItem() -> NSMenuItem` |
| 133 | fn | buildNetworkInfoItem | (private) | `private func buildNetworkInfoItem() -> NSMenuItem` |
| 160 | fn | buildAccountCardItem | (private) | `private func buildAccountCardItem(     email: S...` |
| 191 | fn | buildAntigravitySubmenu | (private) | `private func buildAntigravitySubmenu(data: Prov...` |
| 207 | fn | showSwitchConfirmation | (private) | `private static func showSwitchConfirmation(emai...` |
| 236 | fn | buildEmptyStateItem | (private) | `private func buildEmptyStateItem() -> NSMenuItem` |
| 243 | fn | buildActionItems | (private) | `private func buildActionItems() -> [NSMenuItem]` |
| 267 | class | MenuActionHandler | (internal) | `class MenuActionHandler` |
| 276 | fn | refresh | (internal) | `@objc func refresh()` |
| 282 | fn | openApp | (internal) | `@objc func openApp()` |
| 286 | fn | quit | (internal) | `@objc func quit()` |
| 290 | fn | openMainWindow | (internal) | `static func openMainWindow()` |
| 315 | struct | MenuHeaderView | (private) | `struct MenuHeaderView` |
| 340 | struct | MenuProviderSectionHeader | (private) | `struct MenuProviderSectionHeader` |
| 358 | struct | MenuProviderPickerView | (private) | `struct MenuProviderPickerView` |
| 393 | struct | ProviderFilterButton | (private) | `struct ProviderFilterButton` |
| 425 | struct | ProviderIconMono | (private) | `struct ProviderIconMono` |
| 449 | struct | MenuNetworkInfoView | (private) | `struct MenuNetworkInfoView` |
| 557 | fn | triggerCopyState | (private) | `private func triggerCopyState(_ target: CopyTar...` |
| 568 | fn | setCopied | (private) | `private func setCopied(_ target: CopyTarget, va...` |
| 579 | fn | copyButton | (private) | `@ViewBuilder   private func copyButton(isCopied...` |
| 596 | struct | MenuAccountCardView | (private) | `struct MenuAccountCardView` |
| 635 | fn | planConfig | (private) | `private func planConfig(for planName: String) -...` |
| 867 | fn | formatLocalTime | (private) | `private func formatLocalTime(_ isoString: Strin...` |
| 886 | struct | ModelBadgeData | (private) | `struct ModelBadgeData` |
| 925 | struct | AntigravityDisplayGroup | (private) | `struct AntigravityDisplayGroup` |
| 932 | fn | menuDisplayPercent | (private) | `private func menuDisplayPercent(remainingPercen...` |
| 936 | fn | menuStatusColor | (private) | `private func menuStatusColor(remainingPercent: ...` |
| 954 | struct | LowestBarLayout | (private) | `struct LowestBarLayout` |
| 1034 | struct | RingGridLayout | (private) | `struct RingGridLayout` |
| 1078 | struct | CardGridLayout | (private) | `struct CardGridLayout` |
| 1127 | struct | ModernProgressBar | (private) | `struct ModernProgressBar` |
| 1162 | struct | PercentageBadge | (private) | `struct PercentageBadge` |
| 1198 | struct | MenuModelDetailView | (private) | `struct MenuModelDetailView` |
| 1250 | struct | MenuEmptyStateView | (private) | `struct MenuEmptyStateView` |
| 1265 | struct | MenuViewMoreAccountsView | (private) | `struct MenuViewMoreAccountsView` |
| 1313 | mod | extension AIProvider | (private) | - |
| 1335 | struct | MenuActionsView | (private) | `struct MenuActionsView` |
| 1373 | struct | MenuBarActionButton | (private) | `struct MenuBarActionButton` |

