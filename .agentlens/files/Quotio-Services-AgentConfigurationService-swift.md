# Quotio/Services/AgentConfigurationService.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1940
- **Language:** Swift
- **Symbols:** 43
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 8 | class | AgentConfigurationService | (internal) | `actor AgentConfigurationService` |
| 50 | fn | readConfiguration | (internal) | `func readConfiguration(agent: CLIAgent) -> Save...` |
| 70 | fn | listBackups | (internal) | `func listBackups(agent: CLIAgent) -> [BackupFile]` |
| 99 | fn | restoreFromBackup | (internal) | `func restoreFromBackup(_ backup: BackupFile) th...` |
| 117 | fn | readClaudeCodeConfig | (private) | `private func readClaudeCodeConfig() -> SavedAge...` |
| 179 | fn | readCodexConfig | (private) | `private func readCodexConfig() -> SavedAgentCon...` |
| 235 | fn | readCopilotCLIConfig | (private) | `private func readCopilotCLIConfig() -> SavedAge...` |
| 304 | fn | readGeminiCLIConfig | (private) | `private func readGeminiCLIConfig() -> SavedAgen...` |
| 346 | fn | readAmpConfig | (private) | `private func readAmpConfig() -> SavedAgentConfig?` |
| 373 | fn | readOpenCodeConfig | (private) | `private func readOpenCodeConfig() -> SavedAgent...` |
| 418 | fn | readFactoryDroidConfig | (private) | `private func readFactoryDroidConfig() -> SavedA...` |
| 463 | fn | extractTOMLValue | (private) | `private func extractTOMLValue(from line: String...` |
| 474 | fn | extractExportValue | (private) | `private func extractExportValue(from line: Stri...` |
| 489 | fn | escapeTOMLString | (private) | `private func escapeTOMLString(_ value: String) ...` |
| 517 | fn | buildManagedCodexTOML | (private) | `private func buildManagedCodexTOML(model: Strin...` |
| 537 | fn | parseTOMLSectionName | (private) | `private func parseTOMLSectionName(from line: St...` |
| 555 | fn | isCodexManagedTopLevelKey | (private) | `private func isCodexManagedTopLevelKey(_ line: ...` |
| 564 | fn | splitManagedCodexConfig | (private) | `private func splitManagedCodexConfig(_ managedC...` |
| 572 | fn | extractManagedCodexBanner | (private) | `private func extractManagedCodexBanner(from man...` |
| 581 | fn | filterExistingCodexLines | (private) | `private func filterExistingCodexLines(existingC...` |
| 622 | fn | composeMergedCodexConfig | (private) | `private func composeMergedCodexConfig(filteredL...` |
| 693 | fn | mergeCodexConfig | (private) | `private func mergeCodexConfig(existingContent: ...` |
| 700 | fn | generateConfiguration | (internal) | `func generateConfiguration(     agent: CLIAgent...` |
| 742 | fn | generateDefaultConfiguration | (private) | `private func generateDefaultConfiguration(agent...` |
| 760 | fn | generateClaudeCodeDefaultConfig | (private) | `private func generateClaudeCodeDefaultConfig(mo...` |
| 850 | fn | generateCodexDefaultConfig | (private) | `private func generateCodexDefaultConfig(mode: C...` |
| 897 | fn | generateGeminiCLIDefaultConfig | (private) | `private func generateGeminiCLIDefaultConfig(mod...` |
| 925 | fn | generateCopilotCLIDefaultConfig | (private) | `private func generateCopilotCLIDefaultConfig(mo...` |
| 956 | fn | generateAmpDefaultConfig | (private) | `private func generateAmpDefaultConfig(mode: Con...` |
| 1002 | fn | generateOpenCodeDefaultConfig | (private) | `private func generateOpenCodeDefaultConfig(mode...` |
| 1051 | fn | generateFactoryDroidDefaultConfig | (private) | `private func generateFactoryDroidDefaultConfig(...` |
| 1116 | fn | generateClaudeCodeConfig | (private) | `private func generateClaudeCodeConfig(config: A...` |
| 1202 | fn | mergeClaudeConfig | (private) | `private func mergeClaudeConfig(existingPath: St...` |
| 1219 | fn | generateClaudeResult | (private) | `private func generateClaudeResult(     configPa...` |
| 1294 | fn | generateCodexConfig | (private) | `private func generateCodexConfig(config: AgentC...` |
| 1379 | fn | generateGeminiCLIConfig | (private) | `private func generateGeminiCLIConfig(config: Ag...` |
| 1422 | fn | generateCopilotCLIConfig | (private) | `private func generateCopilotCLIConfig(config: A...` |
| 1513 | fn | generateAmpConfig | (private) | `private func generateAmpConfig(config: AgentCon...` |
| 1596 | fn | generateOpenCodeConfig | (private) | `private func generateOpenCodeConfig(config: Age...` |
| 1688 | fn | buildOpenCodeModelConfig | (private) | `private func buildOpenCodeModelConfig(for model...` |
| 1740 | fn | generateFactoryDroidConfig | (private) | `private func generateFactoryDroidConfig(config:...` |
| 1810 | fn | fetchAvailableModels | (internal) | `func fetchAvailableModels(config: AgentConfigur...` |
| 1865 | fn | testConnection | (internal) | `func testConnection(agent: CLIAgent, config: Ag...` |

