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

## Quotio/Services/StatusBarMenuBuilder.swift (995 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 18 | class | StatusBarMenuBuilder | (internal) |
| 27 | method | init | (internal) |
| 33 | fn | buildMenu | (internal) |
| 119 | fn | resolveSelectedProvider | (private) |
| 128 | fn | accountsForProvider | (private) |
| 135 | fn | buildHeaderItem | (private) |
| 142 | fn | buildProxyInfoItem | (private) |
| 158 | fn | buildTunnelItem | (private) |
| 176 | fn | buildAccountCardItem | (private) |
| 209 | fn | showSwitchConfirmation | (private) |
| 238 | fn | buildAntigravitySubmenu | (private) |
| 254 | fn | buildEmptyStateItem | (private) |
| 261 | fn | buildActionItems | (private) |
| 285 | class | MenuActionHandler | (internal) |
| 294 | fn | refresh | (internal) |
| 300 | fn | openApp | (internal) |
| 304 | fn | quit | (internal) |
| 308 | fn | openMainWindow | (internal) |
| 333 | struct | MenuHeaderView | (private) |
| 356 | struct | MenuProxyInfoView | (private) |
| 415 | struct | MenuProviderPickerView | (private) |
| 450 | struct | ProviderFilterButton | (private) |
| 475 | struct | ProviderIconMono | (private) |
| 499 | struct | MenuAccountCardView | (private) |
| 697 | struct | AntigravityDisplayGroup | (private) |
| 706 | struct | ModelBadgeData | (private) |
| 713 | struct | ModelGridBadge | (private) |
| 768 | struct | MenuModelDetailView | (private) |
| 820 | struct | MenuEmptyStateView | (private) |
| 835 | mod | extension AIProvider | (private) |
| 856 | struct | MenuActionsView | (private) |
| 894 | struct | MenuBarActionButton | (private) |
| 932 | struct | MenuTunnelView | (private) |

