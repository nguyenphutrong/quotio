//
//  AgentConfigurationService.swift
//  CKota - Generate agent configurations
//

import Foundation

actor AgentConfigurationService {
    private let fileManager = FileManager.default

    func generateConfiguration(
        agent: CLIAgent,
        config: AgentConfiguration,
        mode: ConfigurationMode,
        storageOption: ConfigStorageOption = .jsonOnly,
        detectionService _: AgentDetectionService
    ) async throws -> AgentConfigResult {
        switch agent {
        case .claudeCode:
            generateClaudeCodeConfig(config: config, mode: mode, storageOption: storageOption)
        }
    }

    /// Generates Claude Code configuration with smart merge behavior
    ///
    /// **Merge Strategy:**
    /// - Reads existing settings.json if present
    /// - Preserves ALL user configuration: permissions, hooks, mcpServers, statusLine, plugins, etc.
    /// - Merges env object: keeps user's env keys (MCP_API_KEY, etc.), updates only CKota's ANTHROPIC_* keys
    /// - Updates model field with current selection
    ///
    /// **Backup Behavior:**
    /// - Creates timestamped backup on each reconfigure: settings.json.backup.{unix_timestamp}
    /// - Each backup is unique and never overwritten
    /// - All previous backups are preserved
    private func generateClaudeCodeConfig(
        config: AgentConfiguration,
        mode: ConfigurationMode,
        storageOption: ConfigStorageOption
    ) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.claude"
        let configPath = "\(configDir)/settings.json"

        let opusModel = config.modelSlots[.opus] ?? "gemini-claude-opus-4-5-thinking"
        let sonnetModel = config.modelSlots[.sonnet] ?? "gemini-claude-sonnet-4-5"
        let haikuModel = config.modelSlots[.haiku] ?? "gemini-3-flash-preview"
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")

        // CKota-managed env keys (will be updated/added)
        let ckotaEnvConfig: [String: String] = [
            "ANTHROPIC_BASE_URL": baseURL,
            "ANTHROPIC_AUTH_TOKEN": config.apiKey,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": opusModel,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": sonnetModel,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": haikuModel,
        ]

        let shellExports = """
        # CLIProxyAPI Configuration for Claude Code
        export ANTHROPIC_BASE_URL="\(baseURL)"
        export ANTHROPIC_AUTH_TOKEN="\(config.apiKey)"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="\(opusModel)"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="\(sonnetModel)"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="\(haikuModel)"
        """

        do {
            // Read existing settings.json to preserve user configuration
            // This preserves: permissions, hooks, mcpServers, statusLine, plugins, etc.
            var existingConfig: [String: Any] = [:]
            if fileManager.fileExists(atPath: configPath),
               let existingData = fileManager.contents(atPath: configPath),
               let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any]
            {
                existingConfig = parsed
            }

            // Merge env object: preserve user's existing env keys, update only CKota-managed keys
            // User keys like MCP_API_KEY, DISABLE_INTERLEAVED_THINKING are preserved
            // CKota keys (ANTHROPIC_*) are updated with new values
            var mergedEnv = existingConfig["env"] as? [String: String] ?? [:]
            for (key, value) in ckotaEnvConfig {
                mergedEnv[key] = value
            }
            existingConfig["env"] = mergedEnv

            // Update model field (other top-level keys are automatically preserved)
            existingConfig["model"] = opusModel

            // Generate JSON from merged config
            let jsonData = try JSONSerialization.data(
                withJSONObject: existingConfig,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            let rawConfigs = [
                RawConfigOutput(
                    format: .json,
                    content: jsonString,
                    filename: "settings.json",
                    targetPath: configPath,
                    instructions: "Option 1: Save as ~/.claude/settings.json"
                ),
                RawConfigOutput(
                    format: .shellExport,
                    content: shellExports,
                    filename: nil,
                    targetPath: "~/.zshrc or ~/.bashrc",
                    instructions: "Option 2: Add to your shell profile"
                ),
            ]

            if mode == .automatic {
                var backupPath: String? = nil
                let shouldWriteJson = storageOption == .jsonOnly || storageOption == .both

                if shouldWriteJson {
                    try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)

                    if fileManager.fileExists(atPath: configPath) {
                        backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                        try? fileManager.copyItem(atPath: configPath, toPath: backupPath!)
                    }

                    try jsonData.write(to: URL(fileURLWithPath: configPath))
                }

                let instructions = switch storageOption {
                case .jsonOnly:
                    "Configuration saved to ~/.claude/settings.json"
                case .shellOnly:
                    "Shell exports ready. Add to your shell profile to complete setup."
                case .both:
                    "Configuration saved to ~/.claude/settings.json and shell profile updated."
                }

                return .success(
                    type: .both,
                    mode: mode,
                    configPath: shouldWriteJson ? configPath : nil,
                    shellConfig: (storageOption == .shellOnly || storageOption == .both) ? shellExports : nil,
                    rawConfigs: rawConfigs,
                    instructions: instructions,
                    modelsConfigured: 3,
                    backupPath: backupPath
                )
            } else {
                return .success(
                    type: .both,
                    mode: mode,
                    configPath: configPath,
                    shellConfig: shellExports,
                    rawConfigs: rawConfigs,
                    instructions: "Choose one option: save settings.json OR add shell exports to your profile:",
                    modelsConfigured: 3
                )
            }
        } catch {
            return .failure(error: "Failed to generate config: \(error.localizedDescription)")
        }
    }

    func testConnection(agent _: CLIAgent, config: AgentConfiguration) async -> ConnectionTestResult {
        let startTime = Date()

        guard let url = URL(string: "\(config.proxyURL)/models") else {
            return ConnectionTestResult(
                success: false,
                message: "Invalid proxy URL",
                latencyMs: nil,
                modelResponded: nil
            )
        }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let latencyMs = Int(Date().timeIntervalSince(startTime) * 1000)

            guard let httpResponse = response as? HTTPURLResponse else {
                return ConnectionTestResult(
                    success: false,
                    message: "Invalid response",
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            }

            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["data"] as? [[String: Any]],
                   let firstModel = models.first?["id"] as? String
                {
                    return ConnectionTestResult(
                        success: true,
                        message: "Connected successfully",
                        latencyMs: latencyMs,
                        modelResponded: firstModel
                    )
                }
                return ConnectionTestResult(
                    success: true,
                    message: "Connected successfully",
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            } else {
                return ConnectionTestResult(
                    success: false,
                    message: "HTTP \(httpResponse.statusCode)",
                    latencyMs: latencyMs,
                    modelResponded: nil
                )
            }
        } catch {
            return ConnectionTestResult(
                success: false,
                message: error.localizedDescription,
                latencyMs: nil,
                modelResponded: nil
            )
        }
    }
}
