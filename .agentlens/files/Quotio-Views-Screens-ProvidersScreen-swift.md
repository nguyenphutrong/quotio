# Quotio/Views/Screens/ProvidersScreen.swift

[← Back to Module](../modules/Quotio-Views-Screens/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1008
- **Language:** Swift
- **Symbols:** 27
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 16 | struct | ProvidersScreen | (internal) | `struct ProvidersScreen` |
| 376 | fn | handleAddProvider | (private) | `private func handleAddProvider(_ provider: AIPr...` |
| 394 | fn | deleteAccount | (private) | `private func deleteAccount(_ account: AccountRo...` |
| 424 | fn | toggleAccountDisabled | (private) | `private func toggleAccountDisabled(_ account: A...` |
| 434 | fn | handleEditGlmAccount | (private) | `private func handleEditGlmAccount(_ account: Ac...` |
| 441 | fn | handleEditWarpAccount | (private) | `private func handleEditWarpAccount(_ account: A...` |
| 449 | fn | syncCustomProvidersToConfig | (private) | `private func syncCustomProvidersToConfig()` |
| 459 | struct | CustomProviderRow | (internal) | `struct CustomProviderRow` |
| 560 | struct | MenuBarBadge | (internal) | `struct MenuBarBadge` |
| 583 | class | TooltipWindow | (private) | `class TooltipWindow` |
| 595 | method | init | (private) | `private init()` |
| 625 | fn | show | (internal) | `func show(text: String, near view: NSView)` |
| 654 | fn | hide | (internal) | `func hide()` |
| 660 | class | TooltipTrackingView | (private) | `class TooltipTrackingView` |
| 662 | fn | updateTrackingAreas | (internal) | `override func updateTrackingAreas()` |
| 673 | fn | mouseEntered | (internal) | `override func mouseEntered(with event: NSEvent)` |
| 677 | fn | mouseExited | (internal) | `override func mouseExited(with event: NSEvent)` |
| 681 | fn | hitTest | (internal) | `override func hitTest(_ point: NSPoint) -> NSView?` |
| 687 | struct | NativeTooltipView | (private) | `struct NativeTooltipView` |
| 689 | fn | makeNSView | (internal) | `func makeNSView(context: Context) -> TooltipTra...` |
| 695 | fn | updateNSView | (internal) | `func updateNSView(_ nsView: TooltipTrackingView...` |
| 701 | mod | extension View | (private) | - |
| 702 | fn | nativeTooltip | (internal) | `func nativeTooltip(_ text: String) -> some View` |
| 709 | struct | MenuBarHintView | (internal) | `struct MenuBarHintView` |
| 724 | struct | OAuthSheet | (internal) | `struct OAuthSheet` |
| 850 | struct | OAuthStatusView | (private) | `struct OAuthStatusView` |
| 987 | enum | CustomProviderSheetMode | (internal) | `enum CustomProviderSheetMode` |

## Memory Markers

### 🟢 `NOTE` (line 64)

> GLM uses API key auth via CustomProviderService, so skip it here

