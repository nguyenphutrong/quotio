import Foundation
import QuotioApplication
import QuotioDomain

public actor ClaudeCodeAgentConfigurationAdapter: AgentConfigurationRepository {
    public nonisolated let agent = CLIAgent.claudeCode

    private static let managedEnvironmentKeys = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    ]

    private let fileStore: AgentFileStore
    private let configPath: String
    private let shellProfilePath: String

    public init(fileStore: AgentFileStore, shellProfilePath: String? = nil) {
        self.fileStore = fileStore
        self.configPath = fileStore.path("~/.claude/settings.json")
        self.shellProfilePath = shellProfilePath ?? fileStore.path("~/.zshrc")
    }

    public func inspect() async -> SavedAgentConfiguration? {
        guard let data = await fileStore.data(at: configPath),
              let json = try? AgentJSONConfigurationCodec.object(from: data) else { return nil }
        let environment = json["env"] as? [String: String] ?? [:]
        let baseURL = environment["ANTHROPIC_BASE_URL"]
        var modelSlots: [ModelSlot: String] = [:]
        modelSlots[.opus] = environment["ANTHROPIC_DEFAULT_OPUS_MODEL"]
        modelSlots[.sonnet] = environment["ANTHROPIC_DEFAULT_SONNET_MODEL"]
        modelSlots[.haiku] = environment["ANTHROPIC_DEFAULT_HAIKU_MODEL"]
        return SavedAgentConfiguration(
            baseURL: baseURL,
            apiKey: environment["ANTHROPIC_AUTH_TOKEN"],
            modelSlots: modelSlots,
            isProxyConfigured: Self.isLocalEndpoint(baseURL),
            backupFiles: await listBackups()
        )
    }

    public func preview(_ request: AgentConfigurationRequest) async throws -> AgentConfigResult {
        try validate(request)
        return try await result(for: request, write: false)
    }

    public func apply(_ request: AgentConfigurationRequest) async throws -> AgentConfigResult {
        try validate(request)
        return try await result(for: request, write: request.mode == .automatic)
    }

    public func reset(mode: ConfigurationMode) async throws -> AgentConfigResult {
        guard mode == .automatic, let data = await fileStore.data(at: configPath) else {
            return .success(
                type: .file,
                mode: mode,
                rawConfigs: [RawConfigOutput(
                    format: .json,
                    content: "Remove the above keys from ~/.claude/settings.json env section",
                    filename: "instructions.txt",
                    targetPath: configPath,
                    instructions: .claudeRemoveProxyManually
                )],
                instructions: .claudeRemoveProxyManually,
                modelsConfigured: 0
            )
        }

        do {
            var settings = try AgentJSONConfigurationCodec.object(from: data)
            if var environment = settings["env"] as? [String: String] {
                for key in Self.managedEnvironmentKeys {
                    environment.removeValue(forKey: key)
                }
                settings["env"] = environment.isEmpty ? nil : environment
            }
            if let model = settings["model"] as? String,
               model.contains("gemini") || model.contains("gpt") {
                settings.removeValue(forKey: "model")
            }
            let updated = try AgentJSONConfigurationCodec.data(from: settings)
            _ = try await fileStore.apply([AgentFileWrite(path: configPath, data: updated)])
            return .success(
                type: .file,
                mode: mode,
                configPath: configPath,
                instructions: .claudeProxyRemoved,
                modelsConfigured: 0
            )
        } catch {
            return .failure(.updateSettingsFailed(details: error.localizedDescription))
        }
    }

    public func listBackups() async -> [AgentBackupFile] {
        await fileStore.listBackups(for: agent)
    }

    public func restore(_ backup: AgentBackupFile) async throws {
        guard backup.agent == agent else {
            throw AgentConfigurationServiceError.adapterMismatch(expected: agent, actual: backup.agent)
        }
        try await fileStore.restore(backup)
    }

    private func result(for request: AgentConfigurationRequest, write: Bool) async throws -> AgentConfigResult {
        let config = request.configuration
        let opusModel = config.modelSlots[.opus] ?? "gemini-claude-opus-4-5-thinking"
        let sonnetModel = config.modelSlots[.sonnet] ?? "gemini-claude-sonnet-4-5"
        let haikuModel = config.modelSlots[.haiku] ?? "gemini-3-flash-preview"
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")
        let managedEnvironment = [
            "ANTHROPIC_BASE_URL": baseURL,
            "ANTHROPIC_AUTH_TOKEN": config.apiKey,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": opusModel,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": sonnetModel,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": haikuModel,
        ]

        var settings: [String: Any]
        if let existing = await fileStore.data(at: configPath) {
            settings = try AgentJSONConfigurationCodec.object(from: existing)
        } else {
            settings = [:]
        }
        var environment = settings["env"] as? [String: String] ?? [:]
        environment.merge(managedEnvironment) { _, new in new }
        settings["env"] = environment
        settings["model"] = opusModel
        let jsonData = try AgentJSONConfigurationCodec.data(
            from: settings,
            withoutEscapingSlashes: true
        )
        let shellExports = """
        # CLIProxyAPI Configuration for Claude Code
        export ANTHROPIC_BASE_URL="\(baseURL)"
        export ANTHROPIC_AUTH_TOKEN="\(config.apiKey)"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="\(opusModel)"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="\(sonnetModel)"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="\(haikuModel)"
        """
        let rawConfigs = [
            RawConfigOutput(
                format: .json,
                content: String(decoding: jsonData, as: UTF8.self),
                filename: "settings.json",
                targetPath: configPath,
                instructions: .claudeSaveSettings
            ),
            RawConfigOutput(
                format: .shellExport,
                content: shellExports,
                filename: nil,
                targetPath: shellProfilePath,
                instructions: .claudeAddShellExports
            ),
        ]

        let shouldWriteJSON = write
            && (request.storageOption == .jsonOnly || request.storageOption == .both)
        var backupPath: String?
        if shouldWriteJSON {
            let backups = try await fileStore.apply([
                AgentFileWrite(path: configPath, data: jsonData),
            ])
            backupPath = backups[configPath]
        }
        let shellConfig = request.storageOption == .shellOnly || request.storageOption == .both
            ? shellExports : nil
        let instructions: AgentConfigurationInstruction
        if write {
            switch request.storageOption {
            case .jsonOnly: instructions = .claudeSettingsSaved
            case .shellOnly: instructions = .claudeShellExportsReady
            case .both: instructions = .claudeSettingsAndShellSaved
            }
        } else {
            instructions = .claudeChooseManualOption
        }
        return .success(
            type: .both,
            mode: request.mode,
            configPath: write ? (shouldWriteJSON ? configPath : nil) : configPath,
            shellConfig: write ? shellConfig : shellExports,
            rawConfigs: rawConfigs,
            instructions: instructions,
            modelsConfigured: 3,
            backupPath: backupPath
        )
    }

    private func validate(_ request: AgentConfigurationRequest) throws {
        guard request.configuration.agent == agent else {
            throw AgentConfigurationServiceError.adapterMismatch(expected: agent, actual: request.configuration.agent)
        }
        try request.configuration.validate()
    }

    private static func isLocalEndpoint(_ value: String?) -> Bool {
        value?.contains("127.0.0.1") == true || value?.contains("localhost") == true
    }
}
