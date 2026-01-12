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

## Quotio/Views/Screens/QuotaScreen.swift (1584 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 8 | struct | QuotaScreen | (internal) |
| 37 | fn | accountCount | (private) |
| 56 | fn | lowestQuotaPercent | (private) |
| 215 | struct | QuotaDisplayHelper | (private) |
| 217 | fn | statusColor | (internal) |
| 233 | fn | displayPercent | (internal) |
| 242 | struct | ProviderSegmentButton | (private) |
| 320 | struct | QuotaStatusDot | (private) |
| 339 | struct | ProviderQuotaView | (private) |
| 421 | struct | AccountInfo | (private) |
| 433 | struct | AccountQuotaCardV2 | (private) |
| 803 | fn | standardContentByStyle | (private) |
| 830 | struct | PlanBadgeV2Compact | (private) |
| 884 | struct | PlanBadgeV2 | (private) |
| 939 | struct | SubscriptionBadgeV2 | (private) |
| 980 | struct | AntigravityDisplayGroup | (private) |
| 990 | struct | AntigravityGroupRow | (private) |
| 1067 | struct | AntigravityLowestBarLayout | (private) |
| 1086 | fn | displayPercent | (private) |
| 1148 | struct | AntigravityRingLayout | (private) |
| 1160 | fn | displayPercent | (private) |
| 1189 | struct | StandardLowestBarLayout | (private) |
| 1208 | fn | displayPercent | (private) |
| 1281 | struct | StandardRingLayout | (private) |
| 1293 | fn | displayPercent | (private) |
| 1328 | struct | AntigravityModelsDetailSheet | (private) |
| 1397 | struct | ModelDetailCard | (private) |
| 1464 | struct | UsageRowV2 | (private) |
| 1550 | struct | QuotaLoadingView | (private) |

## Quotio/Views/Screens/SettingsScreen.swift (2787 lines)

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
| 726 | struct | NetworkAccessSection | (internal) |
| 760 | struct | LocalPathsSection | (internal) |
| 784 | struct | PathLabel | (internal) |
| 808 | struct | NotificationSettingsSection | (internal) |
| 878 | struct | QuotaDisplaySettingsSection | (internal) |
| 920 | struct | RefreshCadenceSettingsSection | (internal) |
| 959 | struct | UpdateSettingsSection | (internal) |
| 1001 | struct | ProxyUpdateSettingsSection | (internal) |
| 1131 | fn | checkForUpdate | (private) |
| 1141 | fn | performUpgrade | (private) |
| 1160 | struct | ProxyVersionManagerSheet | (internal) |
| 1319 | fn | sectionHeader | (private) |
| 1334 | fn | isVersionInstalled | (private) |
| 1338 | fn | refreshInstalledVersions | (private) |
| 1342 | fn | loadReleases | (private) |
| 1356 | fn | installVersion | (private) |
| 1374 | fn | performInstall | (private) |
| 1395 | fn | activateVersion | (private) |
| 1413 | fn | deleteVersion | (private) |
| 1426 | struct | InstalledVersionRow | (private) |
| 1484 | struct | AvailableVersionRow | (private) |
| 1570 | fn | formatDate | (private) |
| 1588 | struct | MenuBarSettingsSection | (internal) |
| 1670 | struct | AppearanceSettingsSection | (internal) |
| 1699 | struct | PrivacySettingsSection | (internal) |
| 1721 | struct | GeneralSettingsTab | (internal) |
| 1760 | struct | AboutTab | (internal) |
| 1787 | struct | AboutScreen | (internal) |
| 2002 | struct | AboutUpdateSection | (internal) |
| 2058 | struct | AboutProxyUpdateSection | (internal) |
| 2194 | fn | checkForUpdate | (private) |
| 2204 | fn | performUpgrade | (private) |
| 2223 | struct | VersionBadge | (internal) |
| 2275 | struct | AboutUpdateCard | (internal) |
| 2366 | struct | AboutProxyUpdateCard | (internal) |
| 2523 | fn | checkForUpdate | (private) |
| 2533 | fn | performUpgrade | (private) |
| 2552 | struct | LinkCard | (internal) |
| 2639 | struct | ManagementKeyRow | (internal) |
| 2733 | struct | LaunchAtLoginToggle | (internal) |

