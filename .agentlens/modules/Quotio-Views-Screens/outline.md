# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 6 large files in this module.

## Quotio/Views/Screens/DashboardScreen.swift (1014 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 9 | struct | DashboardScreen | (internal) |
| 572 | fn | handleStepAction | (private) |
| 583 | fn | showProviderPicker | (private) |
| 607 | fn | showAgentPicker | (private) |
| 808 | struct | GettingStartedStep | (internal) |
| 817 | struct | GettingStartedStepRow | (internal) |
| 872 | struct | KPICard | (internal) |
| 900 | struct | ProviderChip | (internal) |
| 924 | struct | FlowLayout | (internal) |
| 938 | fn | layout | (private) |
| 966 | struct | QuotaProviderRow | (internal) |

## Quotio/Views/Screens/FallbackScreen.swift (528 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 8 | struct | FallbackScreen | (internal) |
| 105 | fn | loadModelsIfNeeded | (private) |
| 314 | struct | VirtualModelsEmptyState | (internal) |
| 356 | struct | VirtualModelRow | (internal) |
| 474 | struct | FallbackEntryRow | (internal) |

## Quotio/Views/Screens/LogsScreen.swift (541 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 8 | struct | LogsScreen | (internal) |
| 301 | struct | RequestRow | (internal) |
| 475 | fn | attemptOutcomeLabel | (private) |
| 486 | fn | attemptOutcomeColor | (private) |
| 501 | struct | StatItem | (internal) |
| 518 | struct | LogRow | (internal) |

## Quotio/Views/Screens/ProvidersScreen.swift (975 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 16 | struct | ProvidersScreen | (internal) |
| 377 | fn | handleAddProvider | (private) |
| 395 | fn | deleteAccount | (private) |
| 425 | fn | handleEditGlmAccount | (private) |
| 433 | fn | handleEditWarpAccount | (private) |
| 441 | fn | syncCustomProvidersToConfig | (private) |
| 451 | struct | CustomProviderRow | (internal) |
| 552 | struct | MenuBarBadge | (internal) |
| 575 | class | TooltipWindow | (private) |
| 587 | method | init | (private) |
| 617 | fn | show | (internal) |
| 646 | fn | hide | (internal) |
| 652 | class | TooltipTrackingView | (private) |
| 654 | fn | updateTrackingAreas | (internal) |
| 665 | fn | mouseEntered | (internal) |
| 669 | fn | mouseExited | (internal) |
| 673 | fn | hitTest | (internal) |
| 679 | struct | NativeTooltipView | (private) |
| 681 | fn | makeNSView | (internal) |
| 687 | fn | updateNSView | (internal) |
| 693 | mod | extension View | (private) |
| 694 | fn | nativeTooltip | (internal) |
| 701 | struct | MenuBarHintView | (internal) |
| 716 | struct | OAuthSheet | (internal) |
| 842 | struct | OAuthStatusView | (private) |

## Quotio/Views/Screens/QuotaScreen.swift (1599 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 8 | struct | QuotaScreen | (internal) |
| 37 | fn | accountCount | (private) |
| 54 | fn | lowestQuotaPercent | (private) |
| 213 | struct | QuotaDisplayHelper | (private) |
| 215 | fn | statusColor | (internal) |
| 231 | fn | displayPercent | (internal) |
| 240 | struct | ProviderSegmentButton | (private) |
| 318 | struct | QuotaStatusDot | (private) |
| 337 | struct | ProviderQuotaView | (private) |
| 419 | struct | AccountInfo | (private) |
| 431 | struct | AccountQuotaCardV2 | (private) |
| 815 | fn | standardContentByStyle | (private) |
| 843 | struct | PlanBadgeV2Compact | (private) |
| 897 | struct | PlanBadgeV2 | (private) |
| 952 | struct | SubscriptionBadgeV2 | (private) |
| 993 | struct | AntigravityDisplayGroup | (private) |
| 1003 | struct | AntigravityGroupRow | (private) |
| 1080 | struct | AntigravityLowestBarLayout | (private) |
| 1099 | fn | displayPercent | (private) |
| 1161 | struct | AntigravityRingLayout | (private) |
| 1173 | fn | displayPercent | (private) |
| 1202 | struct | StandardLowestBarLayout | (private) |
| 1221 | fn | displayPercent | (private) |
| 1294 | struct | StandardRingLayout | (private) |
| 1306 | fn | displayPercent | (private) |
| 1341 | struct | AntigravityModelsDetailSheet | (private) |
| 1410 | struct | ModelDetailCard | (private) |
| 1477 | struct | UsageRowV2 | (private) |
| 1565 | struct | QuotaLoadingView | (private) |

## Quotio/Views/Screens/SettingsScreen.swift (2935 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 9 | struct | SettingsScreen | (internal) |
| 93 | struct | OperatingModeSection | (internal) |
| 158 | fn | handleModeSelection | (private) |
| 177 | fn | switchToMode | (private) |
| 192 | struct | RemoteServerSection | (internal) |
| 313 | fn | saveRemoteConfig | (private) |
| 321 | fn | reconnect | (private) |
| 336 | struct | UnifiedProxySettingsSection | (internal) |
| 556 | fn | loadConfig | (private) |
| 597 | fn | saveProxyURL | (private) |
| 610 | fn | saveRoutingStrategy | (private) |
| 619 | fn | saveSwitchProject | (private) |
| 628 | fn | saveSwitchPreviewModel | (private) |
| 637 | fn | saveRequestRetry | (private) |
| 646 | fn | saveMaxRetryInterval | (private) |
| 655 | fn | saveLoggingToFile | (private) |
| 664 | fn | saveRequestLog | (private) |
| 673 | fn | saveDebugMode | (private) |
| 686 | struct | LocalProxyServerSection | (internal) |
| 748 | struct | NetworkAccessSection | (internal) |
| 782 | struct | LocalPathsSection | (internal) |
| 806 | struct | PathLabel | (internal) |
| 830 | struct | NotificationSettingsSection | (internal) |
| 900 | struct | QuotaDisplaySettingsSection | (internal) |
| 942 | struct | RefreshCadenceSettingsSection | (internal) |
| 981 | struct | UpdateSettingsSection | (internal) |
| 1023 | struct | ProxyUpdateSettingsSection | (internal) |
| 1153 | fn | checkForUpdate | (private) |
| 1163 | fn | performUpgrade | (private) |
| 1182 | struct | ProxyVersionManagerSheet | (internal) |
| 1341 | fn | sectionHeader | (private) |
| 1356 | fn | isVersionInstalled | (private) |
| 1360 | fn | refreshInstalledVersions | (private) |
| 1364 | fn | loadReleases | (private) |
| 1378 | fn | installVersion | (private) |
| 1396 | fn | performInstall | (private) |
| 1417 | fn | activateVersion | (private) |
| 1435 | fn | deleteVersion | (private) |
| 1448 | struct | InstalledVersionRow | (private) |
| 1506 | struct | AvailableVersionRow | (private) |
| 1592 | fn | formatDate | (private) |
| 1610 | struct | MenuBarSettingsSection | (internal) |
| 1751 | struct | AppearanceSettingsSection | (internal) |
| 1780 | struct | PrivacySettingsSection | (internal) |
| 1802 | struct | GeneralSettingsTab | (internal) |
| 1841 | struct | AboutTab | (internal) |
| 1868 | struct | AboutScreen | (internal) |
| 2083 | struct | AboutUpdateSection | (internal) |
| 2139 | struct | AboutProxyUpdateSection | (internal) |
| 2275 | fn | checkForUpdate | (private) |
| 2285 | fn | performUpgrade | (private) |
| 2304 | struct | VersionBadge | (internal) |
| 2356 | struct | AboutUpdateCard | (internal) |
| 2447 | struct | AboutProxyUpdateCard | (internal) |
| 2604 | fn | checkForUpdate | (private) |
| 2614 | fn | performUpgrade | (private) |
| 2633 | struct | LinkCard | (internal) |
| 2720 | struct | ManagementKeyRow | (internal) |
| 2814 | struct | LaunchAtLoginToggle | (internal) |
| 2872 | struct | UsageDisplaySettingsSection | (internal) |

