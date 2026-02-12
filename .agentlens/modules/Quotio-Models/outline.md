# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 3 large files in this module.

## Quotio/Models/CustomProviderModels.swift (510 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 14 | enum | CustomProviderType | (internal) |
| 148 | struct | CustomAPIKeyEntry | (internal) |
| 179 | struct | ModelMapping | (internal) |
| 206 | struct | CustomHeader | (internal) |
| 225 | struct | CustomProvider | (internal) |
| 275 | fn | validate | (internal) |
| 313 | mod | extension CustomProvider | (internal) |
| 315 | fn | toYAMLBlock | (internal) |
| 329 | fn | generateOpenAICompatibilityYAML | (private) |
| 358 | fn | generateClaudeCompatibilityYAML | (private) |
| 387 | fn | generateGeminiCompatibilityYAML | (private) |
| 415 | fn | generateCodexCompatibilityYAML | (private) |
| 432 | fn | generateGlmCompatibilityYAML | (private) |
| 462 | fn | toYAMLSections | (internal) |

## Quotio/Models/MenuBarSettings.swift (632 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 13 | mod | extension String | (internal) |
| 17 | fn | masked | (internal) |
| 38 | fn | masked | (internal) |
| 46 | struct | MenuBarQuotaItem | (internal) |
| 70 | enum | AppearanceMode | (internal) |
| 97 | class | AppearanceManager | (internal) |
| 112 | method | init | (private) |
| 119 | fn | applyAppearance | (internal) |
| 134 | enum | MenuBarColorMode | (internal) |
| 151 | enum | QuotaDisplayMode | (internal) |
| 165 | fn | displayValue | (internal) |
| 183 | enum | QuotaDisplayStyle | (internal) |
| 210 | enum | RefreshCadence | (internal) |
| 253 | enum | TotalUsageMode | (internal) |
| 270 | enum | ModelAggregationMode | (internal) |
| 286 | mod | extension MenuBarSettingsManager | (internal) |
| 334 | fn | calculateTotalUsagePercent | (internal) |
| 359 | fn | aggregateModelPercentages | (internal) |
| 376 | class | RefreshSettingsManager | (internal) |
| 394 | method | init | (private) |
| 404 | struct | MenuBarQuotaDisplayItem | (internal) |
| 423 | class | MenuBarSettingsManager | (internal) |
| 515 | method | init | (private) |
| 553 | fn | saveSelectedItems | (private) |
| 559 | fn | loadSelectedItems | (private) |
| 567 | fn | addItem | (internal) |
| 581 | fn | removeItem | (internal) |
| 587 | fn | isSelected | (internal) |
| 592 | fn | toggleItem | (internal) |
| 602 | fn | pruneInvalidItems | (internal) |
| 606 | fn | autoSelectNewAccounts | (internal) |
| 621 | fn | enforceMaxItems | (private) |
| 628 | fn | clampedMenuBarMax | (private) |

## Quotio/Models/Models.swift (630 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 326 | fn | hash | (internal) |
| 517 | method | init | (internal) |
| 534 | mod | extension Int | (internal) |
| 580 | fn | validate | (internal) |
| 620 | fn | sanitize | (internal) |

