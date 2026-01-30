# Quotio/Services/AgentConfigurationService.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 1394
- **Language:** Swift
- **Symbols:** 29
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
| 348 | fn | generateConfiguration | (internal) | `func generateConfiguration(     agent: CLIAgent...` |
| 387 | fn | generateDefaultConfiguration | (private) | `private func generateDefaultConfiguration(agent...` |
| 403 | fn | generateClaudeCodeDefaultConfig | (private) | `private func generateClaudeCodeDefaultConfig(mo...` |
| 488 | fn | generateCodexDefaultConfig | (private) | `private func generateCodexDefaultConfig(mode: C...` |
| 553 | fn | generateGeminiCLIDefaultConfig | (private) | `private func generateGeminiCLIDefaultConfig(mod...` |
| 581 | fn | generateAmpDefaultConfig | (private) | `private func generateAmpDefaultConfig(mode: Con...` |
| 627 | fn | generateOpenCodeDefaultConfig | (private) | `private func generateOpenCodeDefaultConfig(mode...` |
| 676 | fn | generateFactoryDroidDefaultConfig | (private) | `private func generateFactoryDroidDefaultConfig(...` |
| 741 | fn | generateClaudeCodeConfig | (private) | `private func generateClaudeCodeConfig(config: A...` |
| 863 | fn | generateCodexConfig | (private) | `private func generateCodexConfig(config: AgentC...` |
| 941 | fn | generateGeminiCLIConfig | (private) | `private func generateGeminiCLIConfig(config: Ag...` |
| 984 | fn | generateAmpConfig | (private) | `private func generateAmpConfig(config: AgentCon...` |
| 1067 | fn | generateOpenCodeConfig | (private) | `private func generateOpenCodeConfig(config: Age...` |
| 1158 | fn | buildOpenCodeModelConfig | (private) | `private func buildOpenCodeModelConfig(for model...` |
| 1194 | fn | generateFactoryDroidConfig | (private) | `private func generateFactoryDroidConfig(config:...` |
| 1264 | fn | fetchAvailableModels | (internal) | `func fetchAvailableModels(config: AgentConfigur...` |
| 1319 | fn | testConnection | (internal) | `func testConnection(agent: CLIAgent, config: Ag...` |

