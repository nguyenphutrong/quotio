import Foundation
import QuotioApplication
import QuotioDomain

public struct CodexAgentConfigurationAdapter: AgentConfigurationRepository {
    public let agent: CLIAgent = .codexCLI

    private let fileStore: AgentFileStore
    private let localize: AgentTextLocalizer
    private let configPath: String
    private let authPath: String

    public init(
        fileStore: AgentFileStore,
        localize: @escaping AgentTextLocalizer = { $0 }
    ) {
        self.fileStore = fileStore
        self.localize = localize
        self.configPath = fileStore.path("~/.codex/config.toml")
        self.authPath = fileStore.path("~/.codex/auth.json")
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
                instructions: localize("agents.codex.revertManualInstructions"),
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
            instructions: "Removed CLIProxyAPI configuration. Codex CLI will now use OpenAI API directly.",
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
        let managed = CodexConfigurationCodec.managedTOML(
            model: configuration.modelSlots[.sonnet] ?? "gpt-5-codex",
            proxyURL: configuration.proxyURL,
            reasoningEffort: configuration.codexReasoningEffort
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
                instructions: localize("agents.codex.saveConfigTOML")
            ),
            RawConfigOutput(
                format: .json,
                content: String(decoding: auth.managed, as: UTF8.self),
                filename: "auth.json",
                targetPath: authPath,
                instructions: localize("agents.codex.authJSONMergeKey")
            ),
        ]
        var backupPath: String?
        if write {
            let backups = try await fileStore.apply([
                AgentFileWrite(path: configPath, data: Data(config.utf8)),
                AgentFileWrite(path: authPath, data: auth.merged, permissions: 0o600),
            ])
            backupPath = backups[configPath]
        }
        return .success(
            type: .file,
            mode: request.mode,
            configPath: configPath,
            authPath: authPath,
            rawConfigs: rawConfigs,
            instructions: localize(write ? "agents.codex.applySuccess" : "agents.codex.mergeAndSaveFiles"),
            modelsConfigured: 1,
            backupPath: backupPath
        )
    }
}
