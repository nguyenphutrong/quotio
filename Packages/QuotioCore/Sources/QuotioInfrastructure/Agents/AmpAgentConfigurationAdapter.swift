import Foundation
import QuotioApplication
import QuotioDomain

public actor AmpAgentConfigurationAdapter: AgentConfigurationRepository {
    public nonisolated let agent = CLIAgent.ampCLI

    private let fileStore: AgentFileStore
    private let localize: AgentTextLocalizer
    private let settingsPath: String
    private let secretsPath: String
    private let shellProfilePath: String

    public init(
        fileStore: AgentFileStore,
        shellProfilePath: String? = nil,
        localize: @escaping AgentTextLocalizer = { $0 }
    ) {
        self.fileStore = fileStore
        self.localize = localize
        self.settingsPath = fileStore.path("~/.config/amp/settings.json")
        self.secretsPath = fileStore.path("~/.local/share/amp/secrets.json")
        self.shellProfilePath = shellProfilePath ?? fileStore.path("~/.zshrc")
    }

    public func inspect() async -> SavedAgentConfiguration? {
        guard let data = await fileStore.data(at: settingsPath),
              let settings = try? AgentJSONConfigurationCodec.object(from: data) else { return nil }
        let baseURL = settings["amp.url"] as? String
        return SavedAgentConfiguration(
            baseURL: baseURL,
            apiKey: nil,
            modelSlots: [:],
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
        guard mode == .automatic, let data = await fileStore.data(at: settingsPath) else {
            return .success(
                type: .file,
                mode: mode,
                instructions: "Remove 'amp.url' from ~/.config/amp/settings.json",
                modelsConfigured: 0
            )
        }

        do {
            var settings = try AgentJSONConfigurationCodec.object(from: data)
            settings.removeValue(forKey: "amp.url")
            let updated = try AgentJSONConfigurationCodec.data(from: settings)
            _ = try await fileStore.apply([AgentFileWrite(path: settingsPath, data: updated)])
            return .success(
                type: .file,
                mode: mode,
                configPath: settingsPath,
                instructions: "Removed proxy URL. Amp CLI will now use its default endpoint.",
                modelsConfigured: 0
            )
        } catch {
            return .failure(error: "Failed to update settings: \(error.localizedDescription)")
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
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "")
        let settingsUpdates = ["amp.url": baseURL]
        let secretsUpdates = ["apiKey@\(baseURL)": config.apiKey]
        let managedSettings = try AgentJSONConfigurationCodec.merging(
            existing: nil,
            updates: settingsUpdates
        )
        let managedSecrets = try AgentJSONConfigurationCodec.merging(
            existing: nil,
            updates: secretsUpdates
        )
        let shellExports = """
        # Alternative: Environment variables for Amp CLI
        export AMP_URL="\(baseURL)"
        export AMP_API_KEY="\(config.apiKey)"
        """
        let rawConfigs = [
            RawConfigOutput(
                format: .json,
                content: String(decoding: managedSettings, as: UTF8.self),
                filename: "settings.json",
                targetPath: settingsPath,
                instructions: localize("agents.amp.mergeSettings")
            ),
            RawConfigOutput(
                format: .json,
                content: String(decoding: managedSecrets, as: UTF8.self),
                filename: "secrets.json",
                targetPath: secretsPath,
                instructions: localize("agents.amp.mergeSecrets")
            ),
            RawConfigOutput(
                format: .shellExport,
                content: shellExports,
                filename: nil,
                targetPath: shellProfilePath + " (alternative)",
                instructions: localize("agents.amp.useEnvironmentVariables")
            ),
        ]

        var backupPath: String?
        if write {
            let mergedSettings = try AgentJSONConfigurationCodec.merging(
                existing: await fileStore.data(at: settingsPath),
                updates: settingsUpdates
            )
            let mergedSecrets = try AgentJSONConfigurationCodec.merging(
                existing: await fileStore.data(at: secretsPath),
                updates: secretsUpdates
            )
            let backups = try await fileStore.apply([
                AgentFileWrite(path: settingsPath, data: mergedSettings),
                AgentFileWrite(path: secretsPath, data: mergedSecrets, permissions: 0o600),
            ])
            backupPath = backups[settingsPath]
        }

        return .success(
            type: .both,
            mode: request.mode,
            configPath: settingsPath,
            authPath: secretsPath,
            shellConfig: shellExports,
            rawConfigs: rawConfigs,
            instructions: localize(write ? "agents.amp.configSuccess" : "agents.amp.mergeAndSaveFiles"),
            modelsConfigured: 1,
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
