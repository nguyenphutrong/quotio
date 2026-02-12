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

## Quotio/Views/Screens/FallbackScreen.swift (539 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 8 | struct | FallbackScreen | (internal) |
| 113 | fn | loadModelsIfNeeded | (private) |
| 322 | struct | VirtualModelsEmptyState | (internal) |
| 364 | struct | VirtualModelRow | (internal) |
| 485 | struct | FallbackEntryRow | (internal) |

## Quotio/Views/Screens/LogsScreen.swift (541 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 8 | struct | LogsScreen | (internal) |
| 301 | struct | RequestRow | (internal) |
| 475 | fn | attemptOutcomeLabel | (private) |
| 486 | fn | attemptOutcomeColor | (private) |
| 501 | struct | StatItem | (internal) |
| 518 | struct | LogRow | (internal) |

## Quotio/Views/Screens/ProvidersScreen.swift (1008 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 16 | struct | ProvidersScreen | (internal) |
| 376 | fn | handleAddProvider | (private) |
| 394 | fn | deleteAccount | (private) |
| 424 | fn | toggleAccountDisabled | (private) |
| 434 | fn | handleEditGlmAccount | (private) |
| 441 | fn | handleEditWarpAccount | (private) |
| 449 | fn | syncCustomProvidersToConfig | (private) |
| 459 | struct | CustomProviderRow | (internal) |
| 560 | struct | MenuBarBadge | (internal) |
| 583 | class | TooltipWindow | (private) |
| 595 | method | init | (private) |
| 625 | fn | show | (internal) |
| 654 | fn | hide | (internal) |
| 660 | class | TooltipTrackingView | (private) |
| 662 | fn | updateTrackingAreas | (internal) |
| 673 | fn | mouseEntered | (internal) |
| 677 | fn | mouseExited | (internal) |
| 681 | fn | hitTest | (internal) |
| 687 | struct | NativeTooltipView | (private) |
| 689 | fn | makeNSView | (internal) |
| 695 | fn | updateNSView | (internal) |
| 701 | mod | extension View | (private) |
| 702 | fn | nativeTooltip | (internal) |
| 709 | struct | MenuBarHintView | (internal) |
| 724 | struct | OAuthSheet | (internal) |
| 850 | struct | OAuthStatusView | (private) |
| 987 | enum | CustomProviderSheetMode | (internal) |

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

## Quotio/Views/Screens/SettingsScreen.swift (3047 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 9 | struct | SettingsScreen | (internal) |
| 111 | struct | OperatingModeSection | (internal) |
| 176 | fn | handleModeSelection | (private) |
| 195 | fn | switchToMode | (private) |
| 210 | struct | RemoteServerSection | (internal) |
| 330 | fn | saveRemoteConfig | (private) |
| 338 | fn | reconnect | (private) |
| 353 | struct | UnifiedProxySettingsSection | (internal) |
| 573 | fn | loadConfig | (private) |
| 620 | fn | saveProxyURL | (private) |
| 638 | fn | saveRoutingStrategy | (private) |
| 647 | fn | saveSwitchProject | (private) |
| 656 | fn | saveSwitchPreviewModel | (private) |
| 665 | fn | saveRequestRetry | (private) |
| 674 | fn | saveMaxRetryInterval | (private) |
| 683 | fn | saveLoggingToFile | (private) |
| 692 | fn | saveRequestLog | (private) |
| 701 | fn | saveDebugMode | (private) |
| 714 | struct | LocalProxyServerSection | (internal) |
| 784 | struct | NetworkAccessSection | (internal) |
| 818 | struct | LocalPathsSection | (internal) |
| 842 | struct | PathLabel | (internal) |
| 866 | struct | NotificationSettingsSection | (internal) |
| 936 | struct | QuotaDisplaySettingsSection | (internal) |
| 978 | struct | RefreshCadenceSettingsSection | (internal) |
| 1017 | struct | UpdateSettingsSection | (internal) |
| 1059 | struct | ProxyUpdateSettingsSection | (internal) |
| 1219 | fn | checkForUpdate | (private) |
| 1233 | fn | performUpgrade | (private) |
| 1252 | struct | ProxyVersionManagerSheet | (internal) |
| 1411 | fn | sectionHeader | (private) |
| 1426 | fn | isVersionInstalled | (private) |
| 1430 | fn | refreshInstalledVersions | (private) |
| 1434 | fn | loadReleases | (private) |
| 1448 | fn | installVersion | (private) |
| 1466 | fn | performInstall | (private) |
| 1487 | fn | activateVersion | (private) |
| 1505 | fn | deleteVersion | (private) |
| 1518 | struct | InstalledVersionRow | (private) |
| 1576 | struct | AvailableVersionRow | (private) |
| 1662 | fn | formatDate | (private) |
| 1680 | struct | MenuBarSettingsSection | (internal) |
| 1821 | struct | AppearanceSettingsSection | (internal) |
| 1850 | struct | PrivacySettingsSection | (internal) |
| 1872 | struct | GeneralSettingsTab | (internal) |
| 1911 | struct | AboutTab | (internal) |
| 1938 | struct | AboutScreen | (internal) |
| 2153 | struct | AboutUpdateSection | (internal) |
| 2209 | struct | AboutProxyUpdateSection | (internal) |
| 2362 | fn | checkForUpdate | (private) |
| 2376 | fn | performUpgrade | (private) |
| 2395 | struct | VersionBadge | (internal) |
| 2447 | struct | AboutUpdateCard | (internal) |
| 2538 | struct | AboutProxyUpdateCard | (internal) |
| 2712 | fn | checkForUpdate | (private) |
| 2726 | fn | performUpgrade | (private) |
| 2745 | struct | LinkCard | (internal) |
| 2832 | struct | ManagementKeyRow | (internal) |
| 2926 | struct | LaunchAtLoginToggle | (internal) |
| 2984 | struct | UsageDisplaySettingsSection | (internal) |

