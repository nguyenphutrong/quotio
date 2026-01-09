# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 5 large files in this module.

## Quotio/Views/Screens/DashboardScreen.swift (915 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 9 | struct | DashboardScreen | (internal) |
| 560 | fn | handleStepAction | (private) |
| 571 | fn | showProviderPicker | (private) |
| 595 | fn | showAgentPicker | (private) |
| 709 | struct | GettingStartedStep | (internal) |
| 718 | struct | GettingStartedStepRow | (internal) |
| 773 | struct | KPICard | (internal) |
| 801 | struct | ProviderChip | (internal) |
| 825 | struct | FlowLayout | (internal) |
| 839 | fn | layout | (private) |
| 867 | struct | QuotaProviderRow | (internal) |

## Quotio/Views/Screens/FallbackScreen.swift (528 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 8 | struct | FallbackScreen | (internal) |
| 103 | fn | loadModelsIfNeeded | (private) |
| 314 | struct | VirtualModelsEmptyState | (internal) |
| 356 | struct | VirtualModelRow | (internal) |
| 474 | struct | FallbackEntryRow | (internal) |

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

## Quotio/Views/Screens/SettingsScreen.swift (2691 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 10 | struct | SettingsScreen | (internal) |
| 103 | struct | OperatingModeSection | (internal) |
| 168 | fn | handleModeSelection | (private) |
| 187 | fn | switchToMode | (private) |
| 202 | struct | RemoteServerSection | (internal) |
| 320 | fn | saveRemoteConfig | (private) |
| 328 | fn | reconnect | (private) |
| 343 | struct | UnifiedProxySettingsSection | (internal) |
| 554 | fn | loadConfig | (private) |
| 585 | fn | saveProxyURL | (private) |
| 598 | fn | saveRoutingStrategy | (private) |
| 607 | fn | saveSwitchProject | (private) |
| 616 | fn | saveSwitchPreviewModel | (private) |
| 625 | fn | saveRequestRetry | (private) |
| 634 | fn | saveMaxRetryInterval | (private) |
| 643 | fn | saveLoggingToFile | (private) |
| 652 | fn | saveRequestLog | (private) |
| 661 | fn | saveDebugMode | (private) |
| 674 | struct | LocalProxyServerSection | (internal) |
| 726 | struct | LocalPathsSection | (internal) |
| 750 | struct | PathLabel | (internal) |
| 774 | struct | NotificationSettingsSection | (internal) |
| 844 | struct | QuotaDisplaySettingsSection | (internal) |
| 872 | struct | RefreshCadenceSettingsSection | (internal) |
| 911 | struct | UpdateSettingsSection | (internal) |
| 953 | struct | ProxyUpdateSettingsSection | (internal) |
| 1083 | fn | checkForUpdate | (private) |
| 1093 | fn | performUpgrade | (private) |
| 1112 | struct | ProxyVersionManagerSheet | (internal) |
| 1271 | fn | sectionHeader | (private) |
| 1286 | fn | isVersionInstalled | (private) |
| 1290 | fn | refreshInstalledVersions | (private) |
| 1294 | fn | loadReleases | (private) |
| 1308 | fn | installVersion | (private) |
| 1326 | fn | performInstall | (private) |
| 1347 | fn | activateVersion | (private) |
| 1365 | fn | deleteVersion | (private) |
| 1378 | struct | InstalledVersionRow | (private) |
| 1436 | struct | AvailableVersionRow | (private) |
| 1522 | fn | formatDate | (private) |
| 1540 | struct | MenuBarSettingsSection | (internal) |
| 1622 | struct | AppearanceSettingsSection | (internal) |
| 1651 | struct | PrivacySettingsSection | (internal) |
| 1673 | struct | GeneralSettingsTab | (internal) |
| 1724 | struct | AboutTab | (internal) |
| 1751 | struct | AboutScreen | (internal) |
| 1966 | struct | AboutUpdateSection | (internal) |
| 2022 | struct | AboutProxyUpdateSection | (internal) |
| 2158 | fn | checkForUpdate | (private) |
| 2168 | fn | performUpgrade | (private) |
| 2187 | struct | VersionBadge | (internal) |
| 2239 | struct | AboutUpdateCard | (internal) |
| 2330 | struct | AboutProxyUpdateCard | (internal) |
| 2487 | fn | checkForUpdate | (private) |
| 2497 | fn | performUpgrade | (private) |
| 2516 | struct | LinkCard | (internal) |
| 2603 | struct | ManagementKeyRow | (internal) |

