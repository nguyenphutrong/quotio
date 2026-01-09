# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 3 large files in this module.

## Quotio/Services/AgentConfigurationService.swift (692 lines)

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
| 628 | fn | testConnection | (internal) |

## Quotio/Services/ManagementAPIClient.swift (675 lines)

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
| 292 | fn | setQuotaExceededSwitchProject | (internal) |
| 297 | fn | setQuotaExceededSwitchPreviewModel | (internal) |
| 302 | fn | setRequestRetry | (internal) |
| 311 | fn | fetchConfig | (internal) |
| 317 | fn | getDebug | (internal) |
| 324 | fn | getProxyURL | (internal) |
| 331 | fn | setProxyURL | (internal) |
| 337 | fn | deleteProxyURL | (internal) |
| 342 | fn | getLoggingToFile | (internal) |
| 349 | fn | setLoggingToFile | (internal) |
| 355 | fn | getRequestLog | (internal) |
| 362 | fn | setRequestLog | (internal) |
| 368 | fn | getRequestRetry | (internal) |
| 375 | fn | getMaxRetryInterval | (internal) |
| 382 | fn | setMaxRetryInterval | (internal) |
| 388 | fn | getQuotaExceededSwitchProject | (internal) |
| 395 | fn | getQuotaExceededSwitchPreviewModel | (internal) |
| 400 | fn | uploadVertexServiceAccount | (internal) |
| 406 | fn | uploadVertexServiceAccount | (internal) |
| 410 | fn | fetchAPIKeys | (internal) |
| 416 | fn | addAPIKey | (internal) |
| 423 | fn | replaceAPIKeys | (internal) |
| 428 | fn | updateAPIKey | (internal) |
| 433 | fn | deleteAPIKey | (internal) |
| 438 | fn | deleteAPIKeyByIndex | (internal) |
| 447 | fn | fetchLatestVersion | (internal) |
| 454 | fn | checkProxyResponding | (internal) |
| 476 | class | SessionDelegate | (private) |
| 479 | method | init | (internal) |
| 485 | fn | urlSession | (internal) |
| 490 | fn | urlSession | (internal) |
| 500 | fn | urlSession | (internal) |

## Quotio/Services/StatusBarMenuBuilder.swift (907 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 18 | class | StatusBarMenuBuilder | (internal) |
| 27 | method | init | (internal) |
| 33 | fn | buildMenu | (internal) |
| 113 | fn | resolveSelectedProvider | (private) |
| 122 | fn | accountsForProvider | (private) |
| 129 | fn | buildHeaderItem | (private) |
| 136 | fn | buildProxyInfoItem | (private) |
| 154 | fn | buildAccountCardItem | (private) |
| 187 | fn | showSwitchConfirmation | (private) |
| 216 | fn | buildAntigravitySubmenu | (private) |
| 232 | fn | buildEmptyStateItem | (private) |
| 239 | fn | buildActionItems | (private) |
| 263 | class | MenuActionHandler | (internal) |
| 272 | fn | refresh | (internal) |
| 278 | fn | openApp | (internal) |
| 282 | fn | quit | (internal) |
| 286 | fn | openMainWindow | (internal) |
| 311 | struct | MenuHeaderView | (private) |
| 334 | struct | MenuProxyInfoView | (private) |
| 393 | struct | MenuProviderPickerView | (private) |
| 428 | struct | ProviderFilterButton | (private) |
| 453 | struct | ProviderIconMono | (private) |
| 477 | struct | MenuAccountCardView | (private) |
| 675 | struct | AntigravityDisplayGroup | (private) |
| 684 | struct | ModelBadgeData | (private) |
| 691 | struct | ModelGridBadge | (private) |
| 746 | struct | MenuModelDetailView | (private) |
| 798 | struct | MenuEmptyStateView | (private) |
| 813 | mod | extension AIProvider | (private) |
| 834 | struct | MenuActionsView | (private) |
| 872 | struct | MenuBarActionButton | (private) |

