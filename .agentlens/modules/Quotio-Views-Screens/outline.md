# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 5 large files in this module.

## Quotio/Views/Screens/DashboardScreen.swift (1006 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 9 | struct | DashboardScreen | (internal) |
| 564 | fn | handleStepAction | (private) |
| 575 | fn | showProviderPicker | (private) |
| 599 | fn | showAgentPicker | (private) |
| 800 | struct | GettingStartedStep | (internal) |
| 809 | struct | GettingStartedStepRow | (internal) |
| 864 | struct | KPICard | (internal) |
| 892 | struct | ProviderChip | (internal) |
| 916 | struct | FlowLayout | (internal) |
| 930 | fn | layout | (private) |
| 958 | struct | QuotaProviderRow | (internal) |

## Quotio/Views/Screens/FallbackScreen.swift (531 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 8 | struct | FallbackScreen | (internal) |
| 103 | fn | loadModelsIfNeeded | (private) |
| 317 | struct | VirtualModelsEmptyState | (internal) |
| 359 | struct | VirtualModelRow | (internal) |
| 477 | struct | FallbackEntryRow | (internal) |

## Quotio/Views/Screens/ProvidersScreen.swift (916 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 16 | struct | ProvidersScreen | (internal) |
| 338 | fn | handleAddProvider | (private) |
| 353 | fn | deleteAccount | (private) |
| 374 | fn | handleEditGlmAccount | (private) |
| 382 | fn | syncCustomProvidersToConfig | (private) |
| 392 | struct | CustomProviderRow | (internal) |
| 493 | struct | MenuBarBadge | (internal) |
| 516 | class | TooltipWindow | (private) |
| 528 | method | init | (private) |
| 558 | fn | show | (internal) |
| 587 | fn | hide | (internal) |
| 593 | class | TooltipTrackingView | (private) |
| 595 | fn | updateTrackingAreas | (internal) |
| 606 | fn | mouseEntered | (internal) |
| 610 | fn | mouseExited | (internal) |
| 614 | fn | hitTest | (internal) |
| 620 | struct | NativeTooltipView | (private) |
| 622 | fn | makeNSView | (internal) |
| 628 | fn | updateNSView | (internal) |
| 634 | mod | extension View | (private) |
| 635 | fn | nativeTooltip | (internal) |
| 642 | struct | MenuBarHintView | (internal) |
| 657 | struct | OAuthSheet | (internal) |
| 783 | struct | OAuthStatusView | (private) |

## Quotio/Views/Screens/QuotaScreen.swift (1246 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 10 | struct | QuotaScreen | (internal) |
| 38 | fn | accountCount | (private) |
| 57 | fn | lowestQuotaPercent | (private) |
| 179 | struct | ProviderSegmentButton | (private) |
| 240 | struct | QuotaStatusDot | (private) |
| 259 | struct | ProviderQuotaView | (private) |
| 340 | struct | AccountInfo | (private) |
| 352 | struct | AccountQuotaCardV2 | (private) |
| 704 | struct | PlanBadgeV2Compact | (private) |
| 758 | struct | PlanBadgeV2 | (private) |
| 823 | struct | SubscriptionBadgeV2 | (private) |
| 864 | struct | AntigravityDisplayGroup | (private) |
| 874 | struct | AntigravityGroupRow | (private) |
| 971 | struct | AntigravityModelsDetailSheet | (private) |
| 1033 | struct | ModelDetailCard | (private) |
| 1103 | struct | UsageRowV2 | (private) |
| 1212 | struct | QuotaLoadingView | (private) |

## Quotio/Views/Screens/SettingsScreen.swift (2733 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 9 | struct | SettingsScreen | (internal) |
| 90 | struct | OperatingModeSection | (internal) |
| 155 | fn | handleModeSelection | (private) |
| 174 | fn | switchToMode | (private) |
| 189 | struct | RemoteServerSection | (internal) |
| 310 | fn | saveRemoteConfig | (private) |
| 318 | fn | reconnect | (private) |
| 333 | struct | UnifiedProxySettingsSection | (internal) |
| 544 | fn | loadConfig | (private) |
| 575 | fn | saveProxyURL | (private) |
| 588 | fn | saveRoutingStrategy | (private) |
| 597 | fn | saveSwitchProject | (private) |
| 606 | fn | saveSwitchPreviewModel | (private) |
| 615 | fn | saveRequestRetry | (private) |
| 624 | fn | saveMaxRetryInterval | (private) |
| 633 | fn | saveLoggingToFile | (private) |
| 642 | fn | saveRequestLog | (private) |
| 651 | fn | saveDebugMode | (private) |
| 664 | struct | LocalProxyServerSection | (internal) |
| 720 | struct | LocalPathsSection | (internal) |
| 744 | struct | PathLabel | (internal) |
| 768 | struct | NotificationSettingsSection | (internal) |
| 838 | struct | QuotaDisplaySettingsSection | (internal) |
| 866 | struct | RefreshCadenceSettingsSection | (internal) |
| 905 | struct | UpdateSettingsSection | (internal) |
| 947 | struct | ProxyUpdateSettingsSection | (internal) |
| 1077 | fn | checkForUpdate | (private) |
| 1087 | fn | performUpgrade | (private) |
| 1106 | struct | ProxyVersionManagerSheet | (internal) |
| 1265 | fn | sectionHeader | (private) |
| 1280 | fn | isVersionInstalled | (private) |
| 1284 | fn | refreshInstalledVersions | (private) |
| 1288 | fn | loadReleases | (private) |
| 1302 | fn | installVersion | (private) |
| 1320 | fn | performInstall | (private) |
| 1341 | fn | activateVersion | (private) |
| 1359 | fn | deleteVersion | (private) |
| 1372 | struct | InstalledVersionRow | (private) |
| 1430 | struct | AvailableVersionRow | (private) |
| 1516 | fn | formatDate | (private) |
| 1534 | struct | MenuBarSettingsSection | (internal) |
| 1616 | struct | AppearanceSettingsSection | (internal) |
| 1645 | struct | PrivacySettingsSection | (internal) |
| 1667 | struct | GeneralSettingsTab | (internal) |
| 1706 | struct | AboutTab | (internal) |
| 1733 | struct | AboutScreen | (internal) |
| 1948 | struct | AboutUpdateSection | (internal) |
| 2004 | struct | AboutProxyUpdateSection | (internal) |
| 2140 | fn | checkForUpdate | (private) |
| 2150 | fn | performUpgrade | (private) |
| 2169 | struct | VersionBadge | (internal) |
| 2221 | struct | AboutUpdateCard | (internal) |
| 2312 | struct | AboutProxyUpdateCard | (internal) |
| 2469 | fn | checkForUpdate | (private) |
| 2479 | fn | performUpgrade | (private) |
| 2498 | struct | LinkCard | (internal) |
| 2585 | struct | ManagementKeyRow | (internal) |
| 2679 | struct | LaunchAtLoginToggle | (internal) |

