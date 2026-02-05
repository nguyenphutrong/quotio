//
//  AgentConfigurationService.swift
//  Quotio - Generate agent configurations
//

import Foundation

actor AgentConfigurationService {
    private let fileManager = FileManager.default
    
    // MARK: - Saved Configuration Models
    
    /// Represents the currently saved configuration for an agent
    struct SavedAgentConfig: Sendable {
        let baseURL: String?
        let apiKey: String?
        let modelSlots: [ModelSlot: String]
        let isProxyConfigured: Bool
        let backupFiles: [BackupFile]
    }
    
    /// Represents a backup file that can be restored
    struct BackupFile: Identifiable, Sendable {
        let path: String
        let timestamp: Date
        let agent: CLIAgent
        
        var id: String { path }
        
        // Use static formatter for performance
        private static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()
        
        var displayName: String {
            Self.dateFormatter.string(from: timestamp)
        }
    }
    
    // MARK: - Read Existing Configuration
    
    /// Read the current saved configuration for an agent
    func readConfiguration(agent: CLIAgent) -> SavedAgentConfig? {
        switch agent {
        case .claudeCode:
            return readClaudeCodeConfig()
        case .codexCLI:
            return readCodexConfig()
        case .geminiCLI:
            return readGeminiCLIConfig()
        case .ampCLI:
            return readAmpConfig()
        case .openCode:
            return readOpenCodeConfig()
        case .factoryDroid:
            return readFactoryDroidConfig()
        }
    }
    
    /// List available backup files for an agent
    func listBackups(agent: CLIAgent) -> [BackupFile] {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var backups: [BackupFile] = []
        
        for configPath in agent.configPaths {
            let expandedPath = configPath.replacingOccurrences(of: "~", with: home)
            let directory = (expandedPath as NSString).deletingLastPathComponent
            let filename = (expandedPath as NSString).lastPathComponent
            
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            
            for file in contents {
                if file.hasPrefix(filename + ".backup.") {
                    let fullPath = "\(directory)/\(file)"
                    // Extract timestamp from filename (e.g., settings.json.backup.1736840000)
                    if let timestampStr = file.components(separatedBy: ".backup.").last,
                       let timestamp = Double(timestampStr) {
                        let date = Date(timeIntervalSince1970: timestamp)
                        backups.append(BackupFile(path: fullPath, timestamp: date, agent: agent))
                    }
                }
            }
        }
        
        // Sort by most recent first
        return backups.sorted { $0.timestamp > $1.timestamp }
    }
    
    /// Restore configuration from a backup file
    func restoreFromBackup(_ backup: BackupFile) throws {
        // Determine the original config path from the backup path
        // e.g., ~/.claude/settings.json.backup.123 -> ~/.claude/settings.json
        let originalPath = backup.path
            .replacingOccurrences(of: ".backup.\(Int(backup.timestamp.timeIntervalSince1970))", with: "")
        
        // Create a backup of current config before restoring
        if fileManager.fileExists(atPath: originalPath) {
            let currentBackupPath = "\(originalPath).backup.\(Int(Date().timeIntervalSince1970))"
            try? fileManager.copyItem(atPath: originalPath, toPath: currentBackupPath)
            try fileManager.removeItem(atPath: originalPath)
        }
        
        // Copy backup to original location
        try fileManager.copyItem(atPath: backup.path, toPath: originalPath)
    }
    
    // MARK: - Agent-Specific Read Implementations
    
    private func readClaudeCodeConfig() -> SavedAgentConfig? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.claude/settings.json"
        
        guard fileManager.fileExists(atPath: configPath),
              let data = fileManager.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        let env = json["env"] as? [String: String] ?? [:]
        
        let baseURL = env["ANTHROPIC_BASE_URL"]
        let apiKey = env["ANTHROPIC_AUTH_TOKEN"]
        let opusModel = env["ANTHROPIC_DEFAULT_OPUS_MODEL"]
        let sonnetModel = env["ANTHROPIC_DEFAULT_SONNET_MODEL"]
        let haikuModel = env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]
        
        var modelSlots: [ModelSlot: String] = [:]
        if let opus = opusModel { modelSlots[.opus] = opus }
        if let sonnet = sonnetModel { modelSlots[.sonnet] = sonnet }
        if let haiku = haikuModel { modelSlots[.haiku] = haiku }
        
        // Check if proxy is configured (localhost or 127.0.0.1 in base URL)
        let isProxy = baseURL?.contains("127.0.0.1") == true || 
                      baseURL?.contains("localhost") == true
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            modelSlots: modelSlots,
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .claudeCode)
        )
    }
    
    private func readCodexConfig() -> SavedAgentConfig? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.codex/config.toml"
        
        guard fileManager.fileExists(atPath: configPath),
              let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return nil
        }
        
        // Simple TOML parsing for the values we need
        var baseURL: String?
        var model: String?
        var isProxy = false
        
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("base_url") {
                if let value = extractTOMLValue(from: trimmed) {
                    baseURL = value
                    isProxy = value.contains("127.0.0.1") || value.contains("localhost")
                }
            } else if trimmed.hasPrefix("model =") {
                model = extractTOMLValue(from: trimmed)
            } else if trimmed.contains("model_provider") && trimmed.contains("cliproxyapi") {
                isProxy = true
            }
        }
        
        var modelSlots: [ModelSlot: String] = [:]
        if let m = model {
            modelSlots[.sonnet] = m  // Codex uses single model
        }
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: nil,  // API key is in auth.json
            modelSlots: modelSlots,
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .codexCLI)
        )
    }
    
    private func readGeminiCLIConfig() -> SavedAgentConfig? {
        // Gemini CLI uses environment variables, check shell profile
        let shellPaths = ShellType.allCases.map { $0.profilePath }
        
        for shellPath in shellPaths {
            guard let content = try? String(contentsOfFile: shellPath, encoding: .utf8) else { continue }
            
            var baseURL: String?
            var apiKey: String?
            var isProxy = false
            
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                
                if trimmed.contains("CODE_ASSIST_ENDPOINT") || trimmed.contains("GOOGLE_GEMINI_BASE_URL") {
                    if let value = extractExportValue(from: trimmed) {
                        baseURL = value
                        isProxy = value.contains("127.0.0.1") || value.contains("localhost")
                    }
                } else if trimmed.contains("GEMINI_API_KEY") {
                    apiKey = extractExportValue(from: trimmed)
                }
            }
            
            if baseURL != nil || apiKey != nil {
                return SavedAgentConfig(
                    baseURL: baseURL,
                    apiKey: apiKey,
                    modelSlots: [:],
                    isProxyConfigured: isProxy,
                    backupFiles: []
                )
            }
        }
        
        return nil
    }
    
    private func readAmpConfig() -> SavedAgentConfig? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let settingsPath = "\(home)/.config/amp/settings.json"
        
        guard fileManager.fileExists(atPath: settingsPath),
              let data = fileManager.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        let baseURL = json["amp.url"] as? String
        let isProxy = baseURL?.contains("127.0.0.1") == true || 
                      baseURL?.contains("localhost") == true
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: nil,  // API key is in secrets.json
            modelSlots: [:],
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .ampCLI)
        )
    }
    
    private func readOpenCodeConfig() -> SavedAgentConfig? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.config/opencode/opencode.json"
        
        guard fileManager.fileExists(atPath: configPath),
              let data = fileManager.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        // Check for quotio provider
        guard let providers = json["provider"] as? [String: Any],
              let quotioProvider = providers["quotio"] as? [String: Any],
              let options = quotioProvider["options"] as? [String: Any] else {
            return SavedAgentConfig(
                baseURL: nil,
                apiKey: nil,
                modelSlots: [:],
                isProxyConfigured: false,
                backupFiles: listBackups(agent: .openCode)
            )
        }
        
        let baseURL = options["baseURL"] as? String
        let apiKey = options["apiKey"] as? String
        let isProxy = baseURL?.contains("127.0.0.1") == true || 
                      baseURL?.contains("localhost") == true
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            modelSlots: [:],
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .openCode)
        )
    }
    
    private func readFactoryDroidConfig() -> SavedAgentConfig? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.factory/config.json"
        
        guard fileManager.fileExists(atPath: configPath),
              let data = fileManager.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        guard let customModels = json["custom_models"] as? [[String: Any]],
              let firstModel = customModels.first else {
            return SavedAgentConfig(
                baseURL: nil,
                apiKey: nil,
                modelSlots: [:],
                isProxyConfigured: false,
                backupFiles: listBackups(agent: .factoryDroid)
            )
        }
        
        let baseURL = firstModel["base_url"] as? String
        let apiKey = firstModel["api_key"] as? String
        let isProxy = baseURL?.contains("127.0.0.1") == true || 
                      baseURL?.contains("localhost") == true
        
        return SavedAgentConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            modelSlots: [:],
            isProxyConfigured: isProxy,
            backupFiles: listBackups(agent: .factoryDroid)
        )
    }
    
    // MARK: - Helper Functions
    
    private func extractTOMLValue(from line: String) -> String? {
        guard let equalIndex = line.firstIndex(of: "=") else { return nil }
        let valueStart = line.index(after: equalIndex)
        var value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        // Remove quotes
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
    
    private func extractExportValue(from line: String) -> String? {
        // Handle: export VAR="value" or export VAR=value
        guard let equalIndex = line.firstIndex(of: "=") else { return nil }
        let valueStart = line.index(after: equalIndex)
        var value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
        // Remove quotes
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }
    
    func generateConfiguration(
        agent: CLIAgent,
        config: AgentConfiguration,
        mode: ConfigurationMode,
        storageOption: ConfigStorageOption = .jsonOnly,
        detectionService: AgentDetectionService,
        availableModels: [AvailableModel] = []
    ) async throws -> AgentConfigResult {
        
        // Check if we should generate default (non-proxy) configuration
        if config.setupMode == .defaultSetup {
            return try await generateDefaultConfiguration(agent: agent, mode: mode)
        }

        switch agent {
        case .claudeCode:
            return generateClaudeCodeConfig(config: config, mode: mode, storageOption: storageOption)

        case .codexCLI:
            return try await generateCodexConfig(config: config, mode: mode)

        case .geminiCLI:
            return generateGeminiCLIConfig(config: config, mode: mode)

        case .ampCLI:
            return try await generateAmpConfig(config: config, mode: mode)

        case .openCode:
            return generateOpenCodeConfig(config: config, mode: mode, availableModels: availableModels)

        case .factoryDroid:
            return generateFactoryDroidConfig(config: config, mode: mode, availableModels: availableModels)
        }
    }
    
    // MARK: - Generate Default (Non-Proxy) Configuration
    
    /// Generates configuration that removes Quotio proxy settings while preserving user settings
    private func generateDefaultConfiguration(agent: CLIAgent, mode: ConfigurationMode) async throws -> AgentConfigResult {
        switch agent {
        case .claudeCode:
            return generateClaudeCodeDefaultConfig(mode: mode)
        case .codexCLI:
            return generateCodexDefaultConfig(mode: mode)
        case .geminiCLI:
            return generateGeminiCLIDefaultConfig(mode: mode)
        case .ampCLI:
            return generateAmpDefaultConfig(mode: mode)
        case .openCode:
            return generateOpenCodeDefaultConfig(mode: mode)
        case .factoryDroid:
            return generateFactoryDroidDefaultConfig(mode: mode)
        }
    }
    
    private func generateClaudeCodeDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.claude"
        let configPath = "\(configDir)/settings.json"
        
        // Keys to remove (Quotio-managed proxy config)
        let keysToRemove = [
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL"
        ]
        
        if mode == .automatic && fileManager.fileExists(atPath: configPath) {
            do {
                // Read existing settings
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var existingSettings = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                
                // Create backup
                let backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                try fileManager.copyItem(atPath: configPath, toPath: backupPath)
                
                // Remove Quotio env keys
                if var env = existingSettings["env"] as? [String: String] {
                    for key in keysToRemove {
                        env.removeValue(forKey: key)
                    }
                    existingSettings["env"] = env.isEmpty ? nil : env
                }
                
                // Remove model if it was set by Quotio to a proxy model
                if let modelName = existingSettings["model"] as? String,
                   modelName.contains("gemini") || modelName.contains("gpt") {
                    existingSettings.removeValue(forKey: "model")
                }
                
                // Write updated settings
                let updatedData = try JSONSerialization.data(withJSONObject: existingSettings, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: configPath))
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed Quotio proxy configuration. Claude Code will now use its default Anthropic API endpoint.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update settings: \(error.localizedDescription)")
            }
        }
        
        // Manual mode - show what would be removed
        let instructions = """
        To revert to default, remove these environment variables from ~/.claude/settings.json:
        - ANTHROPIC_BASE_URL
        - ANTHROPIC_AUTH_TOKEN
        - ANTHROPIC_DEFAULT_OPUS_MODEL
        - ANTHROPIC_DEFAULT_SONNET_MODEL
        - ANTHROPIC_DEFAULT_HAIKU_MODEL
        """
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [RawConfigOutput(
                format: .json,
                content: "Remove the above keys from ~/.claude/settings.json env section",
                filename: "instructions.txt",
                targetPath: configPath,
                instructions: instructions
            )],
            instructions: instructions,
            modelsConfigured: 0
        )
    }
    
    private func generateCodexDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.codex/config.toml"
        
        if mode == .automatic && fileManager.fileExists(atPath: configPath) {
            do {
                var content = try String(contentsOfFile: configPath, encoding: .utf8)
                
                // Create backup
                let backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                try content.write(toFile: backupPath, atomically: true, encoding: .utf8)
                
                // Remove cliproxyapi provider section
                let lines = content.components(separatedBy: .newlines)
                var newLines: [String] = []
                var skipSection = false
                
                for line in lines {
                    if line.contains("[model_providers.cliproxyapi]") {
                        skipSection = true
                        continue
                    }
                    if skipSection && line.hasPrefix("[") && !line.contains("cliproxyapi") {
                        skipSection = false
                    }
                    if !skipSection {
                        // Also update model_provider if set to cliproxyapi
                        if line.contains("model_provider") && line.contains("cliproxyapi") {
                            newLines.append("model_provider = \"openai\"")
                        } else {
                            newLines.append(line)
                        }
                    }
                }
                
                let newContent = newLines.joined(separator: "\n")
                try newContent.write(toFile: configPath, atomically: true, encoding: .utf8)
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed CLIProxyAPI configuration. Codex CLI will now use OpenAI API directly.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update config: \(error.localizedDescription)")
            }
        }
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "Remove [model_providers.cliproxyapi] section from ~/.codex/config.toml",
            modelsConfigured: 0
        )
    }
    
    private func generateGeminiCLIDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let instructions = """
        Remove these environment variables from your shell profile:
        - CODE_ASSIST_ENDPOINT
        - GOOGLE_GEMINI_BASE_URL
        - GEMINI_API_KEY (if using proxy key)
        
        Gemini CLI will use Google's default API endpoint.
        """
        
        return .success(
            type: .environment,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [RawConfigOutput(
                format: .shellExport,
                content: "# Remove from shell profile:\n# export CODE_ASSIST_ENDPOINT=...\n# export GOOGLE_GEMINI_BASE_URL=...",
                filename: "remove_exports.sh",
                targetPath: nil,
                instructions: instructions
            )],
            instructions: instructions,
            modelsConfigured: 0
        )
    }
    
    private func generateAmpDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let settingsPath = "\(home)/.config/amp/settings.json"
        
        if mode == .automatic && fileManager.fileExists(atPath: settingsPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
                var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                
                // Create backup
                let backupPath = "\(settingsPath).backup.\(Int(Date().timeIntervalSince1970))"
                try fileManager.copyItem(atPath: settingsPath, toPath: backupPath)
                
                // Remove amp.url
                settings.removeValue(forKey: "amp.url")
                
                let updatedData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: settingsPath))
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: settingsPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed proxy URL. Amp CLI will now use its default endpoint.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update settings: \(error.localizedDescription)")
            }
        }
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "Remove 'amp.url' from ~/.config/amp/settings.json",
            modelsConfigured: 0
        )
    }
    
    private func generateOpenCodeDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.config/opencode/opencode.json"
        
        if mode == .automatic && fileManager.fileExists(atPath: configPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                
                // Create backup
                let backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                try fileManager.copyItem(atPath: configPath, toPath: backupPath)
                
                // Remove quotio provider
                if var providers = config["provider"] as? [String: Any] {
                    providers.removeValue(forKey: "quotio")
                    config["provider"] = providers.isEmpty ? nil : providers
                }
                
                let updatedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: configPath))
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed Quotio provider. OpenCode will use its default providers.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update config: \(error.localizedDescription)")
            }
        }
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "Remove 'provider.quotio' section from ~/.config/opencode/opencode.json",
            modelsConfigured: 0
        )
    }
    
    private func generateFactoryDroidDefaultConfig(mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.factory/config.json"
        
        if mode == .automatic && fileManager.fileExists(atPath: configPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
                var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                
                // Create backup
                let backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                try fileManager.copyItem(atPath: configPath, toPath: backupPath)
                
                // Remove custom_models that point to localhost
                if var customModels = config["custom_models"] as? [[String: Any]] {
                    customModels = customModels.filter { model in
                        guard let baseURL = model["base_url"] as? String else { return true }
                        return !baseURL.contains("127.0.0.1") && !baseURL.contains("localhost")
                    }
                    config["custom_models"] = customModels.isEmpty ? nil : customModels
                }
                
                let updatedData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: configPath))
                
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    authPath: nil,
                    shellConfig: nil,
                    rawConfigs: [],
                    instructions: "Removed proxy models. Factory Droid will use its default configurations.",
                    modelsConfigured: 0
                )
            } catch {
                return .failure(error: "Failed to update config: \(error.localizedDescription)")
            }
        }
        
        return .success(
            type: .file,
            mode: mode,
            configPath: nil,
            authPath: nil,
            shellConfig: nil,
            rawConfigs: [],
            instructions: "Remove custom_models with localhost base_url from ~/.factory/config.json",
            modelsConfigured: 0
        )
    }
    
    /// Generates Claude Code configuration with smart merge behavior
    ///
    /// **Merge Strategy:**
    /// - Reads existing settings.json if present
    /// - Preserves ALL user configuration: permissions, hooks, mcpServers, statusLine, plugins, etc.
    /// - Merges env object: keeps user's env keys (MCP_API_KEY, etc.), updates only Quotio's ANTHROPIC_* keys
    /// - Updates model field with current selection
    ///
    /// **Backup Behavior:**
    /// - Creates timestamped backup on each reconfigure: settings.json.backup.{unix_timestamp}
    /// - Each backup is unique and never overwritten
    /// - All previous backups are preserved
    private func generateClaudeCodeConfig(config: AgentConfiguration, mode: ConfigurationMode, storageOption: ConfigStorageOption) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.claude"
        let configPath = "\(configDir)/settings.json"

        let opusModel = config.modelSlots[.opus] ?? "gemini-claude-opus-4-5-thinking"
        let sonnetModel = config.modelSlots[.sonnet] ?? "gemini-claude-sonnet-4-5"
        let haikuModel = config.modelSlots[.haiku] ?? "gemini-3-flash-preview"
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")

        // Quotio-managed env keys (will be updated/added)
        let quotioEnvConfig: [String: String] = [
            "ANTHROPIC_BASE_URL": baseURL,
            "ANTHROPIC_AUTH_TOKEN": config.apiKey,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": opusModel,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": sonnetModel,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": haikuModel
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
               let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                existingConfig = parsed
            }

            // Merge env object: preserve user's existing env keys, update only Quotio-managed keys
            // User keys like MCP_API_KEY, DISABLE_INTERLEAVED_THINKING are preserved
            // Quotio keys (ANTHROPIC_*) are updated with new values
            var mergedEnv = existingConfig["env"] as? [String: String] ?? [:]
            for (key, value) in quotioEnvConfig {
                mergedEnv[key] = value
            }
            existingConfig["env"] = mergedEnv

            // Update model field (other top-level keys are automatically preserved)
            existingConfig["model"] = opusModel

            // Generate JSON from merged config
            let jsonData = try JSONSerialization.data(withJSONObject: existingConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            
            let shellProfilePath = ShellType.zsh.profilePath
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
                    targetPath: shellProfilePath,
                    instructions: "Option 2: Add to your shell profile"
                )
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
                
                let instructions: String
                switch storageOption {
                case .jsonOnly:
                    instructions = "Configuration saved to ~/.claude/settings.json"
                case .shellOnly:
                    instructions = "Shell exports ready. Add to your shell profile to complete setup."
                case .both:
                    instructions = "Configuration saved to ~/.claude/settings.json and shell profile updated."
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
    
    private func generateCodexConfig(config: AgentConfiguration, mode: ConfigurationMode) async throws -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let codexDir = "\(home)/.codex"
        let configPath = "\(codexDir)/config.toml"
        let authPath = "\(codexDir)/auth.json"
        
        let configTOML = """
        # CLIProxyAPI Configuration for Codex CLI
        model_provider = "cliproxyapi"
        model = "\(config.modelSlots[.sonnet] ?? "gpt-5-codex")"
        model_reasoning_effort = "high"

        [model_providers.cliproxyapi]
        name = "cliproxyapi"
        base_url = "\(config.proxyURL)"
        wire_api = "responses"
        """
        
        let authJSON = """
        {
          "OPENAI_API_KEY": "\(config.apiKey)"
        }
        """
        
        let rawConfigs = [
            RawConfigOutput(
                format: .toml,
                content: configTOML,
                filename: "config.toml",
                targetPath: configPath,
                instructions: "Save this as ~/.codex/config.toml"
            ),
            RawConfigOutput(
                format: .json,
                content: authJSON,
                filename: "auth.json",
                targetPath: authPath,
                instructions: "Save this as ~/.codex/auth.json"
            )
        ]
        
        if mode == .automatic {
            try fileManager.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
            
            var backupPath: String? = nil
            if fileManager.fileExists(atPath: configPath) {
                backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                try? fileManager.copyItem(atPath: configPath, toPath: backupPath!)
            }
            
            try configTOML.write(toFile: configPath, atomically: true, encoding: .utf8)
            try authJSON.write(toFile: authPath, atomically: true, encoding: .utf8)
            
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath)
            
            return .success(
                type: .file,
                mode: mode,
                configPath: configPath,
                authPath: authPath,
                rawConfigs: rawConfigs,
                instructions: "Configuration files created. Codex CLI is now configured to use CLIProxyAPI.",
                modelsConfigured: 1,
                backupPath: backupPath
            )
        } else {
            return .success(
                type: .file,
                mode: mode,
                configPath: configPath,
                authPath: authPath,
                rawConfigs: rawConfigs,
                instructions: "Create the files below in ~/.codex/ directory:",
                modelsConfigured: 1
            )
        }
    }
    
    private func generateGeminiCLIConfig(config: AgentConfiguration, mode: ConfigurationMode) -> AgentConfigResult {
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")
        
        let exports: String
        let instructions: String
        
        if config.useOAuth {
            exports = """
            # CLIProxyAPI Configuration for Gemini CLI (OAuth Mode)
            export CODE_ASSIST_ENDPOINT="\(baseURL)"
            """
            instructions = "Gemini CLI will use your existing OAuth authentication with the proxy endpoint."
        } else {
            exports = """
            # CLIProxyAPI Configuration for Gemini CLI (API Key Mode)
            export GOOGLE_GEMINI_BASE_URL="\(baseURL)"
            export GEMINI_API_KEY="\(config.apiKey)"
            """
            instructions = "Add these environment variables to your shell profile."
        }
        
        let rawConfigs = [
            RawConfigOutput(
                format: .shellExport,
                content: exports,
                filename: nil,
                targetPath: ShellType.zsh.profilePath,
                instructions: instructions
            )
        ]
        
        return .success(
            type: .environment,
            mode: mode,
            shellConfig: exports,
            rawConfigs: rawConfigs,
            instructions: mode == .automatic
                ? "Configuration added to shell profile. Restart your terminal for changes to take effect."
                : "Copy the configuration below and add it to your shell profile:",
            modelsConfigured: 0
        )
    }
    
    private func generateAmpConfig(config: AgentConfiguration, mode: ConfigurationMode) async throws -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.config/amp"
        let dataDir = "\(home)/.local/share/amp"
        let settingsPath = "\(configDir)/settings.json"
        let secretsPath = "\(dataDir)/secrets.json"
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")
        
        let settingsJSON = """
        {
          "amp.url": "\(baseURL)"
        }
        """
        
        let secretsJSON = """
        {
          "apiKey@\(baseURL)": "\(config.apiKey)"
        }
        """
        
        let envExports = """
        # Alternative: Environment variables for Amp CLI
        export AMP_URL="\(baseURL)"
        export AMP_API_KEY="\(config.apiKey)"
        """
        
        let rawConfigs = [
            RawConfigOutput(
                format: .json,
                content: settingsJSON,
                filename: "settings.json",
                targetPath: settingsPath,
                instructions: "Save this as ~/.config/amp/settings.json"
            ),
            RawConfigOutput(
                format: .json,
                content: secretsJSON,
                filename: "secrets.json",
                targetPath: secretsPath,
                instructions: "Save this as ~/.local/share/amp/secrets.json"
            ),
            RawConfigOutput(
                format: .shellExport,
                content: envExports,
                filename: nil,
                targetPath: "\(ShellType.zsh.profilePath) (alternative)",
                instructions: "Or add these environment variables instead"
            )
        ]
        
        if mode == .automatic {
            try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
            
            try settingsJSON.write(toFile: settingsPath, atomically: true, encoding: .utf8)
            try secretsJSON.write(toFile: secretsPath, atomically: true, encoding: .utf8)
            
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretsPath)
            
            return .success(
                type: .both,
                mode: mode,
                configPath: settingsPath,
                authPath: secretsPath,
                shellConfig: envExports,
                rawConfigs: rawConfigs,
                instructions: "Configuration files created. Amp CLI is now configured to use CLIProxyAPI.",
                modelsConfigured: 1
            )
        } else {
            return .success(
                type: .both,
                mode: mode,
                configPath: settingsPath,
                authPath: secretsPath,
                shellConfig: envExports,
                rawConfigs: rawConfigs,
                instructions: "Create the files below or use environment variables:",
                modelsConfigured: 1
            )
        }
    }
    
    private func generateOpenCodeConfig(config: AgentConfiguration, mode: ConfigurationMode, availableModels: [AvailableModel]) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.config/opencode"
        let configPath = "\(configDir)/opencode.json"
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")

        // Convert available models to OpenCode format dynamically
        var quotioModels: [String: [String: Any]] = [:]
        let modelsToUse = availableModels.isEmpty ? AvailableModel.allModels : availableModels

        for model in modelsToUse {
            quotioModels[model.name] = buildOpenCodeModelConfig(for: model.name)
        }

        let quotioProvider: [String: Any] = [
            "models": quotioModels,
            "name": "Quotio",
            "npm": "@ai-sdk/anthropic",
            "options": [
                "apiKey": config.apiKey,
                "baseURL": "\(baseURL)/v1"
            ]
        ]

        do {
            var existingConfig: [String: Any] = [:]

            if fileManager.fileExists(atPath: configPath),
               let existingData = fileManager.contents(atPath: configPath),
               let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                existingConfig = parsed
            }

            if existingConfig["$schema"] == nil {
                existingConfig["$schema"] = "https://opencode.ai/config.json"
            }

            var providers = existingConfig["provider"] as? [String: Any] ?? [:]
            providers["quotio"] = quotioProvider
            existingConfig["provider"] = providers

            let jsonData = try JSONSerialization.data(withJSONObject: existingConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            let rawConfigs = [
                RawConfigOutput(
                    format: .json,
                    content: jsonString,
                    filename: "opencode.json",
                    targetPath: configPath,
                    instructions: "Merge provider.quotio into ~/.config/opencode/opencode.json"
                )
            ]

            if mode == .automatic {
                try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)

                var backupPath: String? = nil
                if fileManager.fileExists(atPath: configPath) {
                    backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                    try? fileManager.copyItem(atPath: configPath, toPath: backupPath!)
                }

                try jsonData.write(to: URL(fileURLWithPath: configPath))

                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Configuration updated. Run 'opencode' and use /models to select a model (e.g., quotio/\(modelsToUse.first?.name ?? "model")).",
                    modelsConfigured: quotioModels.count,
                    backupPath: backupPath
                )
            } else {
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Merge provider.quotio section into your existing ~/.config/opencode/opencode.json:",
                    modelsConfigured: quotioModels.count
                )
            }
        } catch {
            return .failure(error: "Failed to generate config: \(error.localizedDescription)")
        }
    }

    /// Build OpenCode model configuration based on model name patterns
    private func buildOpenCodeModelConfig(for modelName: String) -> [String: Any] {
        let displayName = modelName.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")

        var modelConfig: [String: Any] = ["name": displayName]

        // Determine limits and capabilities based on model family
        if modelName.contains("claude") {
            modelConfig["limit"] = ["context": 200000, "output": 64000]
            // Claude models support vision
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else if modelName.contains("gemini") {
            modelConfig["limit"] = ["context": 1048576, "output": 65536]
            // Gemini models support vision
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else if modelName.contains("gpt") {
            modelConfig["limit"] = ["context": 400000, "output": 32768]
            // GPT-4+ models support vision
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else if modelName.contains("qwen") && modelName.contains("vl") {
            // Qwen VL (vision-language) models
            modelConfig["limit"] = ["context": 128000, "output": 16384]
            modelConfig["attachment"] = true
            modelConfig["modalities"] = ["input": ["text", "image"], "output": ["text"]]
        } else {
            // Default: text-only models
            modelConfig["limit"] = ["context": 128000, "output": 16384]
            modelConfig["attachment"] = false
            modelConfig["modalities"] = ["input": ["text"], "output": ["text"]]
        }

        // Add reasoning options for thinking/reasoning models
        if modelName.contains("thinking") {
            modelConfig["reasoning"] = true
            modelConfig["options"] = ["thinking": ["type": "enabled", "budgetTokens": 10000]]
        } else if modelName.contains("codex") || modelName.hasPrefix("gpt-5") || modelName.hasPrefix("o1") || modelName.hasPrefix("o3") {
            modelConfig["reasoning"] = true
            if modelName.contains("max") {
                modelConfig["options"] = ["reasoning": ["effort": "high"]]
            } else if modelName.contains("mini") {
                modelConfig["options"] = ["reasoning": ["effort": "low"]]
            } else {
                modelConfig["options"] = ["reasoning": ["effort": "medium"]]
            }
        }

        return modelConfig
    }
    
    private func generateFactoryDroidConfig(config: AgentConfiguration, mode: ConfigurationMode, availableModels: [AvailableModel]) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.factory"
        let configPath = "\(configDir)/config.json"

        let openaiBaseURL = "\(config.proxyURL.replacingOccurrences(of: "/v1", with: ""))/v1"

        // Convert available models to Factory Droid format dynamically
        let modelsToUse = availableModels.isEmpty ? AvailableModel.allModels : availableModels
        let customModels: [[String: Any]] = modelsToUse.map { model in
            [
                "model": model.name,
                "model_display_name": model.name,
                "base_url": openaiBaseURL,
                "api_key": config.apiKey,
                "provider": "openai"
            ]
        }

        let factoryConfig: [String: Any] = ["custom_models": customModels]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: factoryConfig, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

            let rawConfigs = [
                RawConfigOutput(
                    format: .json,
                    content: jsonString,
                    filename: "config.json",
                    targetPath: configPath,
                    instructions: "Save this as ~/.factory/config.json"
                )
            ]

            if mode == .automatic {
                try fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)

                var backupPath: String? = nil
                if fileManager.fileExists(atPath: configPath) {
                    backupPath = "\(configPath).backup.\(Int(Date().timeIntervalSince1970))"
                    try? fileManager.copyItem(atPath: configPath, toPath: backupPath!)
                }

                try jsonData.write(to: URL(fileURLWithPath: configPath))

                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Configuration saved. Run 'droid' or 'factory' to start using Factory Droid.",
                    modelsConfigured: customModels.count,
                    backupPath: backupPath
                )
            } else {
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Copy the configuration below and save it as ~/.factory/config.json:",
                    modelsConfigured: customModels.count
                )
            }
        } catch {
            return .failure(error: "Failed to generate config: \(error.localizedDescription)")
        }
    }
    
    func fetchAvailableModels(config: AgentConfiguration) async throws -> [AvailableModel] {
        guard let url = URL(string: "\(config.proxyURL)/models") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.addValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let proxyConfig = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 10)
        let session = URLSession(configuration: proxyConfig)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        // Parse struct matching OpenAI /v1/models response
        struct ModelsResponse: Decodable {
            struct ModelItem: Decodable {
                let id: String
                let owned_by: String?
            }
            let data: [ModelItem]
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)

        // Fetch available Copilot models to filter out unavailable ones
        let copilotFetcher = CopilotQuotaFetcher()
        let availableCopilotModelIds = await copilotFetcher.fetchUserAvailableModelIds()

        return decoded.data.compactMap { item in
            let provider = item.owned_by ?? "openai"

            // Filter GitHub Copilot models - only include those actually available to the user
            if provider == "github-copilot" {
                // If we have Copilot accounts, filter by available models
                if !availableCopilotModelIds.isEmpty {
                    guard availableCopilotModelIds.contains(item.id) else {
                        return nil
                    }
                }
                // If no Copilot accounts, still show the model (user might add account later)
            }

            return AvailableModel(
                id: item.id,
                name: item.id,
                provider: provider,
                isDefault: false
            )
        }
    }
    
    func testConnection(agent: CLIAgent, config: AgentConfiguration) async -> ConnectionTestResult {
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
            let proxyConfig = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 10)
            let session = URLSession(configuration: proxyConfig)
            let (data, response) = try await session.data(for: request)
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
                   let firstModel = models.first?["id"] as? String {
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
                var errorMessage = "HTTP \(httpResponse.statusCode)"
                
                // Try to parse detailed error message from proxy response (OpenAI format)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errorObj = json["error"] as? [String: Any],
                   let detailedMessage = errorObj["message"] as? String {
                    errorMessage = detailedMessage
                }
                
                return ConnectionTestResult(
                    success: false,
                    message: errorMessage,
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
