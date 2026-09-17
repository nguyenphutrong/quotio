import Foundation
import QuotioApplication
import QuotioDomain

public struct CodexAgentConfigurationAdapter: AgentConfigurationRepository {
    public let agent: CLIAgent = .codexCLI

    private let fileStore: AgentFileStore
    private let configPath: String
    private let authPath: String
    private let catalogPath: String

    public init(fileStore: AgentFileStore) {
        self.fileStore = fileStore
        self.configPath = fileStore.path("~/.codex/config.toml")
        self.authPath = fileStore.path("~/.codex/auth.json")
        self.catalogPath = fileStore.path("~/.codex/\(CodexModelCatalog.fileName)")
    }

    public func inspect() async -> SavedAgentConfiguration? {
        guard let content = try? await fileStore.string(at: configPath) else { return nil }
        let snapshot = CodexConfigurationCodec.snapshot(from: content)
        return SavedAgentConfiguration(
            baseURL: snapshot.baseURL,
            apiKey: nil,
            modelSlots: snapshot.model.map { [.sonnet: $0] } ?? [:],
            isProxyConfigured: snapshot.isProxyConfigured,
            backupFiles: await listBackups(),
            reasoningEffort: snapshot.reasoningEffort
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
        guard mode == .automatic else {
            return .success(
                type: .file,
                mode: mode,
                instructions: .codexRemoveProxyManually,
                modelsConfigured: 0
            )
        }

        var writes: [AgentFileWrite] = []
        if let content = try? await fileStore.string(at: configPath) {
            writes.append(AgentFileWrite(path: configPath, data: Data(CodexConfigurationCodec.removingManagedTOML(from: content).utf8)))
        }
        if let auth = await fileStore.data(at: authPath),
           let cleaned = try? CodexConfigurationCodec.removingManagedAuthKey(from: auth) {
            writes.append(AgentFileWrite(path: authPath, data: cleaned, permissions: 0o600))
        }
        if !writes.isEmpty { _ = try await fileStore.apply(writes) }
        return .success(
            type: .file,
            mode: mode,
            configPath: writes.contains { $0.path == configPath } ? configPath : nil,
            instructions: .codexProxyRemoved,
            modelsConfigured: 0
        )
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

    private func validate(_ request: AgentConfigurationRequest) throws {
        guard request.configuration.agent == agent else {
            throw AgentConfigurationServiceError.adapterMismatch(expected: agent, actual: request.configuration.agent)
        }
        try request.configuration.validate()
    }

    private func result(for request: AgentConfigurationRequest, write: Bool) async throws -> AgentConfigResult {
        let configuration = request.configuration
        let model = configuration.modelSlots[.sonnet] ?? AgentConfiguration.defaultCodexModel
        // The roster the proxy answered with, so Codex knows every model it can be switched
        // to; when it could not be read, the one being configured is still better than none.
        let catalogModels = request.availableModels.isEmpty
            ? [model]
            : request.availableModels.map(\.id)
        let catalog = try CodexModelCatalog.json(models: catalogModels)
        let managed = CodexConfigurationCodec.managedTOML(
            model: model,
            proxyURL: configuration.proxyURL,
            reasoningEffort: configuration.codexReasoningEffort,
            apiKey: configuration.apiKey,
            catalogPath: catalogPath
        )
        let existingConfig = try? await fileStore.string(at: configPath)
        let config = existingConfig.map {
            CodexConfigurationCodec.mergeTOML(existing: $0, managed: managed)
        } ?? managed + "\n"
        let auth = CodexConfigurationCodec.authPayloads(
            existing: await fileStore.data(at: authPath),
            apiKey: configuration.apiKey
        )
        let rawConfigs = [
            RawConfigOutput(
                format: .toml,
                content: config,
                filename: "config.toml",
                targetPath: configPath,
                instructions: .codexSaveConfig
            ),
            RawConfigOutput(
                format: .json,
                content: String(decoding: auth.managed, as: UTF8.self),
                filename: "auth.json",
                targetPath: authPath,
                instructions: .codexMergeAuthKey
            ),
            RawConfigOutput(
                format: .json,
                content: String(decoding: catalog, as: UTF8.self),
                filename: CodexModelCatalog.fileName,
                targetPath: catalogPath,
                instructions: .codexSaveModelCatalog
            ),
        ]
        var backupPath: String?
        if write {
            let backups = try await fileStore.apply([
                // The proxy's API key now lives in this file, so it gets the same
                // owner-only permissions auth.json has; left alone, an existing config
                // keeps whatever it had (commonly 0644) and a new one follows the umask.
                AgentFileWrite(path: configPath, data: Data(config.utf8), permissions: 0o600),
                AgentFileWrite(path: authPath, data: auth.merged, permissions: 0o600),
                AgentFileWrite(path: catalogPath, data: catalog),
            ])
            backupPath = backups[configPath]
        }
        return .success(
            type: .file,
            mode: request.mode,
            configPath: configPath,
            authPath: authPath,
            rawConfigs: rawConfigs,
            instructions: write ? .codexConfigured : .codexMergeAndSaveFiles,
            modelsConfigured: 1,
            backupPath: backupPath
        )
    }
}
