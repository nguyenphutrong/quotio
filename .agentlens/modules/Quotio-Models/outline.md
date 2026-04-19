# Outline

[← Back to MODULE](MODULE.md) | [← Back to INDEX](../../INDEX.md)

Symbol maps for 4 large files in this module.

## Quotio/Models/AgentModels.swift (603 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 391 | fn | isSupported | (internal) |
| 398 | fn | extractFromModelName | (internal) |
| 414 | fn | encoded | (internal) |
| 432 | method | init | (internal) |
| 451 | method | init | (internal) |
| 519 | fn | success | (internal) |
| 545 | fn | failure | (internal) |

## Quotio/Models/CustomProviderModels.swift (546 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 14 | enum | CustomProviderType | (internal) |
| 148 | struct | CustomAPIKeyEntry | (internal) |
| 179 | struct | ModelMapping | (internal) |
| 206 | struct | CustomHeader | (internal) |
| 225 | struct | CustomProvider | (internal) |
| 277 | method | init | (internal) |
| 293 | fn | encode | (internal) |
| 311 | fn | validate | (internal) |
| 349 | mod | extension CustomProvider | (internal) |
| 351 | fn | toYAMLBlock | (internal) |
| 365 | fn | generateOpenAICompatibilityYAML | (private) |
| 394 | fn | generateClaudeCompatibilityYAML | (private) |
| 423 | fn | generateGeminiCompatibilityYAML | (private) |
| 451 | fn | generateCodexCompatibilityYAML | (private) |
| 468 | fn | generateGlmCompatibilityYAML | (private) |
| 498 | fn | toYAMLSections | (internal) |

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

## Quotio/Models/Models.swift (641 lines)

| Line | Kind | Name | Visibility |
| ---- | ---- | ---- | ---------- |
| 337 | fn | hash | (internal) |
| 528 | method | init | (internal) |
| 545 | mod | extension Int | (internal) |
| 591 | fn | validate | (internal) |
| 631 | fn | sanitize | (internal) |

