//
//  AgentConfigurationService.swift
//  Quotio - Generate agent configurations
//

import Foundation

actor AgentConfigurationService {
    private let fileManager = FileManager.default
    
    func generateConfiguration(
        agent: CLIAgent,
        config: AgentConfiguration,
        mode: ConfigurationMode,
        storageOption: ConfigStorageOption = .jsonOnly,
        detectionService: AgentDetectionService
    ) async throws -> AgentConfigResult {
        
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
            return generateOpenCodeConfig(config: config, mode: mode)
            
        case .factoryDroid:
            return generateFactoryDroidConfig(config: config, mode: mode)
        }
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
                targetPath: "~/.zshrc or ~/.bashrc",
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
                targetPath: "~/.zshrc (alternative)",
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
    
    private func generateOpenCodeConfig(config: AgentConfiguration, mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.config/opencode"
        let configPath = "\(configDir)/opencode.json"
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")
        
        let quotioModels: [String: [String: Any]] = [
            "gemini-claude-opus-4-5-thinking": [
                "name": "Claude Opus 4.5 Thinking",
                "limit": ["context": 200000, "output": 64000],
                "reasoning": true,
                "options": ["thinking": ["type": "enabled", "budgetTokens": 10000]]
            ],
            "gemini-claude-sonnet-4-5": [
                "name": "Claude Sonnet 4.5",
                "limit": ["context": 200000, "output": 64000]
            ],
            "gemini-claude-sonnet-4-5-thinking": [
                "name": "Claude Sonnet 4.5 Thinking",
                "limit": ["context": 200000, "output": 64000],
                "reasoning": true,
                "options": ["thinking": ["type": "enabled", "budgetTokens": 10000]]
            ],
            "gemini-3-pro-preview": [
                "name": "Gemini 3 Pro Preview",
                "limit": ["context": 1048576, "output": 65536]
            ],
            "gemini-3-pro-image-preview": [
                "name": "Gemini 3 Pro Image Preview",
                "limit": ["context": 1048576, "output": 65536]
            ],
            "gemini-3-flash-preview": [
                "name": "Gemini 3 Flash Preview",
                "limit": ["context": 1048576, "output": 65536]
            ],
            "gemini-2.5-flash": [
                "name": "Gemini 2.5 Flash",
                "limit": ["context": 1048576, "output": 65536]
            ],
            "gemini-2.5-flash-lite": [
                "name": "Gemini 2.5 Flash Lite",
                "limit": ["context": 1048576, "output": 65536]
            ],
            "gemini-2.5-computer-use-preview-10-2025": [
                "name": "Gemini 2.5 Computer Use Preview",
                "limit": ["context": 1048576, "output": 65536]
            ],
            "gpt-5.2": [
                "name": "GPT 5.2",
                "limit": ["context": 400000, "output": 32768],
                "reasoning": true,
                "options": ["reasoning": ["effort": "medium"]]
            ],
            "gpt-5.2-codex": [
                "name": "GPT 5.2 Codex",
                "limit": ["context": 400000, "output": 32768],
                "reasoning": true,
                "options": ["reasoning": ["effort": "medium"]]
            ],
            "gpt-5.1": [
                "name": "GPT 5.1",
                "limit": ["context": 400000, "output": 32768],
                "reasoning": true,
                "options": ["reasoning": ["effort": "medium"]]
            ],
            "gpt-5.1-codex": [
                "name": "GPT 5.1 Codex",
                "limit": ["context": 400000, "output": 32768],
                "reasoning": true,
                "options": ["reasoning": ["effort": "medium"]]
            ],
            "gpt-5.1-codex-max": [
                "name": "GPT 5.1 Codex Max",
                "limit": ["context": 400000, "output": 32768],
                "reasoning": true,
                "options": ["reasoning": ["effort": "high"]]
            ],
            "gpt-5.1-codex-mini": [
                "name": "GPT 5.1 Codex Mini",
                "limit": ["context": 400000, "output": 32768],
                "reasoning": true,
                "options": ["reasoning": ["effort": "low"]]
            ],
            "gpt-5": [
                "name": "GPT 5",
                "limit": ["context": 400000, "output": 32768],
                "reasoning": true,
                "options": ["reasoning": ["effort": "medium"]]
            ],
            "gpt-5-codex": [
                "name": "GPT 5 Codex",
                "limit": ["context": 400000, "output": 32768],
                "reasoning": true,
                "options": ["reasoning": ["effort": "medium"]]
            ],
            "gpt-5-codex-mini": [
                "name": "GPT 5 Codex Mini",
                "limit": ["context": 400000, "output": 32768],
                "reasoning": true,
                "options": ["reasoning": ["effort": "low"]]
            ],
            "gpt-oss-120b-medium": [
                "name": "GPT OSS 120B Medium",
                "limit": ["context": 128000, "output": 16384]
            ]
        ]
        
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
                    instructions: "Configuration updated. Run 'opencode' and use /models to select a model (e.g., quotio/gemini-3-pro-preview).",
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
    
    private func generateFactoryDroidConfig(config: AgentConfiguration, mode: ConfigurationMode) -> AgentConfigResult {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let configDir = "\(home)/.factory"
        let configPath = "\(configDir)/config.json"
        
        let openaiBaseURL = "\(config.proxyURL.replacingOccurrences(of: "/v1", with: ""))/v1"
        
        let customModels: [[String: Any]] = [
            ["model": "gemini-claude-opus-4-5-thinking", "model_display_name": "gemini-claude-opus-4-5-thinking", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gemini-claude-sonnet-4-5", "model_display_name": "gemini-claude-sonnet-4-5", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gemini-claude-sonnet-4-5-thinking", "model_display_name": "gemini-claude-sonnet-4-5-thinking", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gpt-5.2", "model_display_name": "gpt-5.2", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gpt-5.2-codex", "model_display_name": "gpt-5.2-codex", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gpt-5.1", "model_display_name": "gpt-5.1", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gpt-5.1-codex", "model_display_name": "gpt-5.1-codex", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gpt-5.1-codex-max", "model_display_name": "gpt-5.1-codex-max", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gpt-5.1-codex-mini", "model_display_name": "gpt-5.1-codex-mini", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gpt-5", "model_display_name": "gpt-5", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gpt-5-codex", "model_display_name": "gpt-5-codex", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gpt-5-codex-mini", "model_display_name": "gpt-5-codex-mini", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gpt-oss-120b-medium", "model_display_name": "gpt-oss-120b-medium", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gemini-3-pro-preview", "model_display_name": "gemini-3-pro-preview", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gemini-3-pro-image-preview", "model_display_name": "gemini-3-pro-image-preview", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gemini-3-flash-preview", "model_display_name": "gemini-3-flash-preview", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gemini-2.5-flash", "model_display_name": "gemini-2.5-flash", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gemini-2.5-flash-lite", "model_display_name": "gemini-2.5-flash-lite", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"],
            ["model": "gemini-2.5-computer-use-preview-10-2025", "model_display_name": "gemini-2.5-computer-use-preview-10-2025", "base_url": openaiBaseURL, "api_key": config.apiKey, "provider": "openai"]
        ]
        
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
                    modelsConfigured: 3,
                    backupPath: backupPath
                )
            } else {
                return .success(
                    type: .file,
                    mode: mode,
                    configPath: configPath,
                    rawConfigs: rawConfigs,
                    instructions: "Copy the configuration below and save it as ~/.factory/config.json:",
                    modelsConfigured: 3
                )
            }
        } catch {
            return .failure(error: "Failed to generate config: \(error.localizedDescription)")
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
