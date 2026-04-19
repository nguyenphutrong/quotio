# Quotio/Services/AgentConfigurationService.swift

[← Back to Module](../modules/root/MODULE.md) | [← Back to INDEX](../INDEX.md)

## Overview

- **Lines:** 2144
- **Language:** Swift
- **Symbols:** 52
- **Public symbols:** 0

## Symbol Table

| Line | Kind | Name | Visibility | Signature |
| ---- | ---- | ---- | ---------- | --------- |
| 8 | class | AgentConfigurationService | (internal) | `actor AgentConfigurationService` |
| 56 | fn | readConfiguration | (internal) | `func readConfiguration(agent: CLIAgent) -> Save...` |
| 77 | fn | migrateProxyCredentialsIfNeeded | (internal) | `func migrateProxyCredentialsIfNeeded(validAPIKe...` |
| 111 | fn | listBackups | (internal) | `func listBackups(agent: CLIAgent) -> [BackupFile]` |
| 140 | fn | restoreFromBackup | (internal) | `func restoreFromBackup(_ backup: BackupFile) th...` |
| 158 | fn | readClaudeCodeConfig | (private) | `private func readClaudeCodeConfig() -> SavedAge...` |
| 220 | fn | readCodexConfig | (private) | `private func readCodexConfig() -> SavedAgentCon...` |
| 276 | fn | readCopilotCLIConfig | (private) | `private func readCopilotCLIConfig() -> SavedAge...` |
| 345 | fn | readGeminiCLIConfig | (private) | `private func readGeminiCLIConfig() -> SavedAgen...` |
| 387 | fn | readAmpConfig | (private) | `private func readAmpConfig() -> SavedAgentConfig?` |
| 414 | fn | readOpenCodeConfig | (private) | `private func readOpenCodeConfig() -> SavedAgent...` |
| 459 | fn | readFactoryDroidConfig | (private) | `private func readFactoryDroidConfig() -> SavedA...` |
| 502 | fn | migrateClaudeCodeProxyCredentialIfNeeded | (private) | `private func migrateClaudeCodeProxyCredentialIf...` |
| 523 | fn | migrateCodexProxyCredentialIfNeeded | (private) | `private func migrateCodexProxyCredentialIfNeede...` |
| 545 | fn | migrateAmpProxyCredentialIfNeeded | (private) | `private func migrateAmpProxyCredentialIfNeeded(...` |
| 569 | fn | migrateOpenCodeProxyCredentialIfNeeded | (private) | `private func migrateOpenCodeProxyCredentialIfNe...` |
| 594 | fn | migrateFactoryDroidProxyCredentialIfNeeded | (private) | `private func migrateFactoryDroidProxyCredential...` |
| 628 | fn | extractTOMLValue | (private) | `private func extractTOMLValue(from line: String...` |
| 639 | fn | extractExportValue | (private) | `private func extractExportValue(from line: Stri...` |
| 651 | fn | extractCodexBaseURL | (private) | `private func extractCodexBaseURL(from configCon...` |
| 661 | fn | normalizeBaseURL | (private) | `private func normalizeBaseURL(_ rawValue: Strin...` |
| 667 | fn | writeJSONWithBackupIfChanged | (private) | `@discardableResult   private func writeJSONWith...` |
| 693 | fn | escapeTOMLString | (private) | `private func escapeTOMLString(_ value: String) ...` |
| 721 | fn | buildManagedCodexTOML | (private) | `private func buildManagedCodexTOML(model: Strin...` |
| 741 | fn | parseTOMLSectionName | (private) | `private func parseTOMLSectionName(from line: St...` |
| 759 | fn | isCodexManagedTopLevelKey | (private) | `private func isCodexManagedTopLevelKey(_ line: ...` |
| 768 | fn | splitManagedCodexConfig | (private) | `private func splitManagedCodexConfig(_ managedC...` |
| 776 | fn | extractManagedCodexBanner | (private) | `private func extractManagedCodexBanner(from man...` |
| 785 | fn | filterExistingCodexLines | (private) | `private func filterExistingCodexLines(existingC...` |
| 826 | fn | composeMergedCodexConfig | (private) | `private func composeMergedCodexConfig(filteredL...` |
| 897 | fn | mergeCodexConfig | (private) | `private func mergeCodexConfig(existingContent: ...` |
| 904 | fn | generateConfiguration | (internal) | `func generateConfiguration(     agent: CLIAgent...` |
| 946 | fn | generateDefaultConfiguration | (private) | `private func generateDefaultConfiguration(agent...` |
| 964 | fn | generateClaudeCodeDefaultConfig | (private) | `private func generateClaudeCodeDefaultConfig(mo...` |
| 1054 | fn | generateCodexDefaultConfig | (private) | `private func generateCodexDefaultConfig(mode: C...` |
| 1101 | fn | generateGeminiCLIDefaultConfig | (private) | `private func generateGeminiCLIDefaultConfig(mod...` |
| 1129 | fn | generateCopilotCLIDefaultConfig | (private) | `private func generateCopilotCLIDefaultConfig(mo...` |
| 1160 | fn | generateAmpDefaultConfig | (private) | `private func generateAmpDefaultConfig(mode: Con...` |
| 1206 | fn | generateOpenCodeDefaultConfig | (private) | `private func generateOpenCodeDefaultConfig(mode...` |
| 1255 | fn | generateFactoryDroidDefaultConfig | (private) | `private func generateFactoryDroidDefaultConfig(...` |
| 1320 | fn | generateClaudeCodeConfig | (private) | `private func generateClaudeCodeConfig(config: A...` |
| 1406 | fn | mergeClaudeConfig | (private) | `private func mergeClaudeConfig(existingPath: St...` |
| 1423 | fn | generateClaudeResult | (private) | `private func generateClaudeResult(     configPa...` |
| 1498 | fn | generateCodexConfig | (private) | `private func generateCodexConfig(config: AgentC...` |
| 1583 | fn | generateGeminiCLIConfig | (private) | `private func generateGeminiCLIConfig(config: Ag...` |
| 1626 | fn | generateCopilotCLIConfig | (private) | `private func generateCopilotCLIConfig(config: A...` |
| 1717 | fn | generateAmpConfig | (private) | `private func generateAmpConfig(config: AgentCon...` |
| 1800 | fn | generateOpenCodeConfig | (private) | `private func generateOpenCodeConfig(config: Age...` |
| 1892 | fn | buildOpenCodeModelConfig | (private) | `private func buildOpenCodeModelConfig(for model...` |
| 1944 | fn | generateFactoryDroidConfig | (private) | `private func generateFactoryDroidConfig(config:...` |
| 2014 | fn | fetchAvailableModels | (internal) | `func fetchAvailableModels(config: AgentConfigur...` |
| 2069 | fn | testConnection | (internal) | `func testConnection(agent: CLIAgent, config: Ag...` |

