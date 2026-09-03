import Foundation
import QuotioApplication
import QuotioDomain

public actor FactoryDroidAgentConfigurationAdapter: AgentConfigurationRepository {
    public nonisolated let agent = CLIAgent.factoryDroid

    private let fileStore: AgentFileStore
    private let configPath: String

    public init(fileStore: AgentFileStore) {
        self.fileStore = fileStore
        self.configPath = fileStore.path("~/.factory/config.json")
    }

    public func inspect() async -> SavedAgentConfiguration? {
        guard let data = await fileStore.data(at: configPath),
              let config = try? AgentJSONConfigurationCodec.object(from: data) else { return nil }
        guard let models = config["custom_models"] as? [[String: Any]],
              let firstModel = models.first else {
            return SavedAgentConfiguration(
                baseURL: nil,
                apiKey: nil,
                modelSlots: [:],
                isProxyConfigured: false,
                backupFiles: await listBackups()
            )
        }
        let baseURL = firstModel["base_url"] as? String
        return SavedAgentConfiguration(
            baseURL: baseURL,
            apiKey: firstModel["api_key"] as? String,
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
        guard mode == .automatic, let data = await fileStore.data(at: configPath) else {
            return .success(
                type: .file,
                mode: mode,
                instructions: "Remove custom_models with localhost base_url from ~/.factory/config.json",
                modelsConfigured: 0
            )
        }

        do {
            var config = try AgentJSONConfigurationCodec.object(from: data)
            if let models = config["custom_models"] as? [[String: Any]] {
                let remaining = models.filter { !Self.isLocalEndpoint($0["base_url"] as? String) }
                config["custom_models"] = remaining.isEmpty ? nil : remaining
            }
            let updated = try AgentJSONConfigurationCodec.data(
                from: config,
                withoutEscapingSlashes: true
            )
            _ = try await fileStore.apply([AgentFileWrite(path: configPath, data: updated)])
            return .success(
                type: .file,
                mode: mode,
                configPath: configPath,
                instructions: "Removed proxy models. Factory Droid will use its default configurations.",
                modelsConfigured: 0
            )
        } catch {
            return .failure(error: "Failed to update config: \(error.localizedDescription)")
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
        let baseURL = config.proxyURL.replacingOccurrences(of: "/v1", with: "") + "/v1"
        let models = request.availableModels.isEmpty ? AvailableModel.allModels : request.availableModels
        let managedModels: [[String: Any]] = models.map {
            [
                "model": $0.name,
                "model_display_name": $0.name,
                "base_url": baseURL,
                "api_key": config.apiKey,
                "provider": "openai",
            ]
        }
        let managedData = try AgentJSONConfigurationCodec.data(
            from: ["custom_models": managedModels],
            withoutEscapingSlashes: true
        )
        let rawConfigs = [RawConfigOutput(
            format: .json,
            content: String(decoding: managedData, as: UTF8.self),
            filename: "config.json",
            targetPath: configPath,
            instructions: "Save this as ~/.factory/config.json"
        )]

        var backupPath: String?
        if write {
            var existing = try AgentJSONConfigurationCodec.object(
                from: await fileStore.data(at: configPath)
            )
            let userModels = (existing["custom_models"] as? [[String: Any]] ?? [])
                .filter { !Self.isLocalEndpoint($0["base_url"] as? String) }
            existing["custom_models"] = userModels + managedModels
            let mergedData = try AgentJSONConfigurationCodec.data(
                from: existing,
                withoutEscapingSlashes: true
            )
            let backups = try await fileStore.apply([
                AgentFileWrite(path: configPath, data: mergedData),
            ])
            backupPath = backups[configPath]
        }

        return .success(
            type: .file,
            mode: request.mode,
            configPath: configPath,
            rawConfigs: rawConfigs,
            instructions: write
                ? "Configuration saved. Run 'droid' or 'factory' to start using Factory Droid."
                : "Copy the configuration below and save it as ~/.factory/config.json:",
            modelsConfigured: managedModels.count,
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
