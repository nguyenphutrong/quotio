# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 5 large files in this module.

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

## Quotio/Views/Screens/ProvidersScreen.swift (973 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 16 | struct | ProvidersScreen | (internal) |
| 375 | fn | handleAddProvider | (private) |
| 393 | fn | deleteAccount | (private) |
| 423 | fn | handleEditGlmAccount | (private) |
| 431 | fn | handleEditWarpAccount | (private) |
| 439 | fn | syncCustomProvidersToConfig | (private) |
| 449 | struct | CustomProviderRow | (internal) |
| 550 | struct | MenuBarBadge | (internal) |
| 573 | class | TooltipWindow | (private) |
| 585 | method | init | (private) |
| 615 | fn | show | (internal) |
| 644 | fn | hide | (internal) |
| 650 | class | TooltipTrackingView | (private) |
| 652 | fn | updateTrackingAreas | (internal) |
| 663 | fn | mouseEntered | (internal) |
| 667 | fn | mouseExited | (internal) |
| 671 | fn | hitTest | (internal) |
| 677 | struct | NativeTooltipView | (private) |
| 679 | fn | makeNSView | (internal) |
| 685 | fn | updateNSView | (internal) |
| 691 | mod | extension View | (private) |
| 692 | fn | nativeTooltip | (internal) |
| 699 | struct | MenuBarHintView | (internal) |
| 714 | struct | OAuthSheet | (internal) |
| 840 | struct | OAuthStatusView | (private) |

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

## Quotio/Views/Screens/SettingsScreen.swift (2876 lines)

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
| 1692 | struct | AppearanceSettingsSection | (internal) |
| 1721 | struct | PrivacySettingsSection | (internal) |
| 1743 | struct | GeneralSettingsTab | (internal) |
| 1782 | struct | AboutTab | (internal) |
| 1809 | struct | AboutScreen | (internal) |
| 2024 | struct | AboutUpdateSection | (internal) |
| 2080 | struct | AboutProxyUpdateSection | (internal) |
| 2216 | fn | checkForUpdate | (private) |
| 2226 | fn | performUpgrade | (private) |
| 2245 | struct | VersionBadge | (internal) |
| 2297 | struct | AboutUpdateCard | (internal) |
| 2388 | struct | AboutProxyUpdateCard | (internal) |
| 2545 | fn | checkForUpdate | (private) |
| 2555 | fn | performUpgrade | (private) |
| 2574 | struct | LinkCard | (internal) |
| 2661 | struct | ManagementKeyRow | (internal) |
| 2755 | struct | LaunchAtLoginToggle | (internal) |
| 2813 | struct | UsageDisplaySettingsSection | (internal) |

