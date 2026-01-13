# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 3 large files in this module.

## Quotio/Services/AgentConfigurationService.swift (696 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 8 | class | AgentConfigurationService | (internal) |
| 10 | fn | generateConfiguration | (internal) |
| 53 | fn | generateClaudeCodeConfig | (private) |
| 174 | fn | generateCodexConfig | (private) |
| 252 | fn | generateGeminiCLIConfig | (private) |
| 295 | fn | generateAmpConfig | (private) |
| 378 | fn | generateOpenCodeConfig | (private) |
| 469 | fn | buildOpenCodeModelConfig | (private) |
| 505 | fn | generateFactoryDroidConfig | (private) |
| 575 | fn | fetchAvailableModels | (internal) |
| 630 | fn | testConnection | (internal) |

## Quotio/Services/ManagementAPIClient.swift (718 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 8 | class | ManagementAPIClient | (internal) |
| 44 | fn | custom | (internal) |
| 54 | fn | log | (private) |
| 60 | fn | incrementActiveRequests | (private) |
| 67 | fn | decrementActiveRequests | (private) |
| 78 | method | init | (internal) |
| 101 | method | init | (internal) |
| 126 | method | init | (internal) |
| 139 | fn | invalidate | (internal) |
| 144 | fn | makeRequest | (private) |
| 202 | fn | fetchAuthFiles | (internal) |
| 208 | fn | fetchAuthFileModels | (internal) |
| 215 | fn | apiCall | (internal) |
| 221 | fn | deleteAuthFile | (internal) |
| 225 | fn | deleteAllAuthFiles | (internal) |
| 229 | fn | fetchUsageStats | (internal) |
| 234 | fn | getOAuthURL | (internal) |
| 255 | fn | pollOAuthStatus | (internal) |
| 260 | fn | fetchLogs | (internal) |
| 269 | fn | clearLogs | (internal) |
| 273 | fn | setDebug | (internal) |
| 278 | fn | setRoutingStrategy | (internal) |
| 294 | fn | getRoutingStrategy | (internal) |
| 307 | fn | setQuotaExceededSwitchProject | (internal) |
| 312 | fn | setQuotaExceededSwitchPreviewModel | (internal) |
| 317 | fn | setRequestRetry | (internal) |
| 326 | fn | fetchConfig | (internal) |
| 332 | fn | getDebug | (internal) |
| 339 | fn | getProxyURL | (internal) |
| 346 | fn | setProxyURL | (internal) |
| 352 | fn | deleteProxyURL | (internal) |
| 357 | fn | getLoggingToFile | (internal) |
| 364 | fn | setLoggingToFile | (internal) |
| 370 | fn | getRequestLog | (internal) |
| 377 | fn | setRequestLog | (internal) |
| 383 | fn | getRequestRetry | (internal) |
| 390 | fn | getMaxRetryInterval | (internal) |
| 397 | fn | setMaxRetryInterval | (internal) |
| 403 | fn | getQuotaExceededSwitchProject | (internal) |
| 410 | fn | getQuotaExceededSwitchPreviewModel | (internal) |
| 415 | fn | uploadVertexServiceAccount | (internal) |
| 421 | fn | uploadVertexServiceAccount | (internal) |
| 425 | fn | fetchAPIKeys | (internal) |
| 431 | fn | addAPIKey | (internal) |
| 438 | fn | replaceAPIKeys | (internal) |
| 443 | fn | updateAPIKey | (internal) |
| 448 | fn | deleteAPIKey | (internal) |
| 453 | fn | deleteAPIKeyByIndex | (internal) |
| 462 | fn | fetchLatestVersion | (internal) |
| 469 | fn | checkProxyResponding | (internal) |
| 491 | class | SessionDelegate | (private) |
| 494 | method | init | (internal) |
| 500 | fn | urlSession | (internal) |
| 505 | fn | urlSession | (internal) |
| 515 | fn | urlSession | (internal) |
| 694 | method | init | (internal) |
| 708 | fn | encode | (internal) |

## Quotio/Services/StatusBarMenuBuilder.swift (1365 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 18 | class | StatusBarMenuBuilder | (internal) |
| 29 | method | init | (internal) |
| 35 | fn | buildMenu | (internal) |
| 127 | fn | resolveSelectedProvider | (private) |
| 136 | fn | accountsForProvider | (private) |
| 143 | fn | buildHeaderItem | (private) |
| 150 | fn | buildNetworkInfoItem | (private) |
| 177 | fn | buildAccountCardItem | (private) |
| 206 | fn | buildViewMoreAccountsItem | (private) |
| 217 | fn | buildAntigravitySubmenu | (private) |
| 233 | fn | showSwitchConfirmation | (private) |
| 262 | fn | buildEmptyStateItem | (private) |
| 269 | fn | buildActionItems | (private) |
| 293 | class | MenuActionHandler | (internal) |
| 302 | fn | refresh | (internal) |
| 308 | fn | openApp | (internal) |
| 312 | fn | quit | (internal) |
| 316 | fn | openMainWindow | (internal) |
| 341 | struct | MenuHeaderView | (private) |
| 366 | struct | MenuProviderPickerView | (private) |
| 401 | struct | ProviderFilterButton | (private) |
| 433 | struct | ProviderIconMono | (private) |
| 457 | struct | MenuNetworkInfoView | (private) |
| 565 | fn | triggerCopyState | (private) |
| 576 | fn | setCopied | (private) |
| 587 | fn | copyButton | (private) |
| 604 | struct | MenuAccountCardView | (private) |
| 844 | fn | formatLocalTime | (private) |
| 854 | struct | ModelBadgeData | (private) |
| 884 | struct | AntigravityDisplayGroup | (private) |
| 891 | fn | menuDisplayPercent | (private) |
| 895 | fn | menuStatusColor | (private) |
| 913 | struct | LowestBarLayout | (private) |
| 993 | struct | RingGridLayout | (private) |
| 1037 | struct | CardGridLayout | (private) |
| 1086 | struct | ModernProgressBar | (private) |
| 1121 | struct | PercentageBadge | (private) |
| 1157 | struct | MenuModelDetailView | (private) |
| 1209 | struct | MenuEmptyStateView | (private) |
| 1224 | struct | MenuViewMoreAccountsView | (private) |
| 1272 | mod | extension AIProvider | (private) |
| 1293 | struct | MenuActionsView | (private) |
| 1331 | struct | MenuBarActionButton | (private) |

