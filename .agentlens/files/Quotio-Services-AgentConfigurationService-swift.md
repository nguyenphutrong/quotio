# Quotio/Services/AgentConfigurationService.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1610
- **Language:** Swift
- **Symbols:** 38
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 8 | class | AgentConfigurationService | (internal) | `actor AgentConfigurationService` |
| 46 | fn | readConfiguration | (internal) | `func readConfiguration(agent: CLIAgent) -> Save...` |
| 64 | fn | listBackups | (internal) | `func listBackups(agent: CLIAgent) -> [BackupFile]` |
| 93 | fn | restoreFromBackup | (internal) | `func restoreFromBackup(_ backup: BackupFile) th...` |
| 111 | fn | readClaudeCodeConfig | (private) | `private func readClaudeCodeConfig() -> SavedAge...` |
| 147 | fn | readCodexConfig | (private) | `private func readCodexConfig() -> SavedAgentCon...` |
| 190 | fn | readGeminiCLIConfig | (private) | `private func readGeminiCLIConfig() -> SavedAgen...` |
| 228 | fn | readAmpConfig | (private) | `private func readAmpConfig() -> SavedAgentConfig?` |
| 251 | fn | readOpenCodeConfig | (private) | `private func readOpenCodeConfig() -> SavedAgent...` |
| 288 | fn | readFactoryDroidConfig | (private) | `private func readFactoryDroidConfig() -> SavedA...` |
| 325 | fn | extractTOMLValue | (private) | `private func extractTOMLValue(from line: String...` |
| 336 | fn | extractExportValue | (private) | `private func extractExportValue(from line: Stri...` |
| 351 | fn | escapeTOMLString | (private) | `private func escapeTOMLString(_ value: String) ...` |
| 379 | fn | buildManagedCodexTOML | (private) | `private func buildManagedCodexTOML(model: Strin...` |
| 396 | fn | parseTOMLSectionName | (private) | `private func parseTOMLSectionName(from line: St...` |
| 414 | fn | isCodexManagedTopLevelKey | (private) | `private func isCodexManagedTopLevelKey(_ line: ...` |
| 423 | fn | splitManagedCodexConfig | (private) | `private func splitManagedCodexConfig(_ managedC...` |
| 431 | fn | extractManagedCodexBanner | (private) | `private func extractManagedCodexBanner(from man...` |
| 440 | fn | filterExistingCodexLines | (private) | `private func filterExistingCodexLines(existingC...` |
| 481 | fn | composeMergedCodexConfig | (private) | `private func composeMergedCodexConfig(filteredL...` |
| 552 | fn | mergeCodexConfig | (private) | `private func mergeCodexConfig(existingContent: ...` |
| 559 | fn | generateConfiguration | (internal) | `func generateConfiguration(     agent: CLIAgent...` |
| 598 | fn | generateDefaultConfiguration | (private) | `private func generateDefaultConfiguration(agent...` |
| 614 | fn | generateClaudeCodeDefaultConfig | (private) | `private func generateClaudeCodeDefaultConfig(mo...` |
| 699 | fn | generateCodexDefaultConfig | (private) | `private func generateCodexDefaultConfig(mode: C...` |
| 746 | fn | generateGeminiCLIDefaultConfig | (private) | `private func generateGeminiCLIDefaultConfig(mod...` |
| 774 | fn | generateAmpDefaultConfig | (private) | `private func generateAmpDefaultConfig(mode: Con...` |
| 820 | fn | generateOpenCodeDefaultConfig | (private) | `private func generateOpenCodeDefaultConfig(mode...` |
| 869 | fn | generateFactoryDroidDefaultConfig | (private) | `private func generateFactoryDroidDefaultConfig(...` |
| 934 | fn | generateClaudeCodeConfig | (private) | `private func generateClaudeCodeConfig(config: A...` |
| 1056 | fn | generateCodexConfig | (private) | `private func generateCodexConfig(config: AgentC...` |
| 1140 | fn | generateGeminiCLIConfig | (private) | `private func generateGeminiCLIConfig(config: Ag...` |
| 1183 | fn | generateAmpConfig | (private) | `private func generateAmpConfig(config: AgentCon...` |
| 1266 | fn | generateOpenCodeConfig | (private) | `private func generateOpenCodeConfig(config: Age...` |
| 1358 | fn | buildOpenCodeModelConfig | (private) | `private func buildOpenCodeModelConfig(for model...` |
| 1410 | fn | generateFactoryDroidConfig | (private) | `private func generateFactoryDroidConfig(config:...` |
| 1480 | fn | fetchAvailableModels | (internal) | `func fetchAvailableModels(config: AgentConfigur...` |
| 1535 | fn | testConnection | (internal) | `func testConnection(agent: CLIAgent, config: Ag...` |

