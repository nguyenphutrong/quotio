import QuotioDomain

public actor AgentConfigurationService {
    private let adapters: [CLIAgent: any AgentConfigurationRepository]
    private let detector: any AgentDetecting
    private let shellProfiles: any ShellProfileRepository
    private let modelCatalog: any AgentModelCatalogRepository

    public init(
        adapters: [any AgentConfigurationRepository],
        detector: any AgentDetecting,
        shellProfiles: any ShellProfileRepository,
        modelCatalog: any AgentModelCatalogRepository
    ) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.agent, $0) })
        self.detector = detector
        self.shellProfiles = shellProfiles
        self.modelCatalog = modelCatalog
    }

    public func detectAgents(forceRefresh: Bool = false) async -> [AgentStatus] {
        await detector.detectAll(forceRefresh: forceRefresh)
    }

    public func detectAgent(_ agent: CLIAgent) async -> AgentStatus {
        await detector.detect(agent)
    }

    public func inspect(_ agent: CLIAgent) async throws -> SavedAgentConfiguration? {
        try await adapter(for: agent).inspect()
    }

    public func generatePreview(_ request: AgentConfigurationRequest) async throws -> AgentConfigResult {
        try request.configuration.validate()
        let repository = try adapter(for: request.configuration.agent)
        if request.configuration.setupMode == .defaultSetup {
            return try await repository.reset(mode: .manual)
        }
        return try await repository.preview(request)
    }

    public func apply(_ request: AgentConfigurationRequest, shellProfile: ShellProfile) async throws -> AgentConfigResult {
        try request.configuration.validate()
        let repository = try adapter(for: request.configuration.agent)
        if request.configuration.setupMode == .defaultSetup {
            let result = try await repository.reset(mode: request.mode)
            if result.success, request.mode == .automatic {
                await detector.clearConfigured(request.configuration.agent)
            }
            return result
        }
        let result = try await repository.apply(request)

        let agent = request.configuration.agent
        let shouldUpdateShell = agent.configType == .both
            ? (request.storageOption == .shellOnly || request.storageOption == .both)
            : agent.configType != .file

        if result.success,
           shouldUpdateShell,
           let shellConfig = result.shellConfig {
            try await shellProfiles.add(configuration: shellConfig, for: agent, to: shellProfile)
        }

        if result.success {
            await detector.markConfigured(agent)
        }
        return result
    }

    public func testConnection(
        agent: CLIAgent,
        configuration: AgentConfiguration
    ) async -> ConnectionTestResult {
        await modelCatalog.testConnection(agent: agent, configuration: configuration)
    }

    public func listBackups(for agent: CLIAgent) async throws -> [AgentBackupFile] {
        try await adapter(for: agent).listBackups()
    }

    public func restore(_ backup: AgentBackupFile) async throws {
        try await adapter(for: backup.agent).restore(backup)
    }

    public func reset(agent: CLIAgent, mode: ConfigurationMode) async throws -> AgentConfigResult {
        let result = try await adapter(for: agent).reset(mode: mode)
        if result.success, mode == .automatic {
            await detector.clearConfigured(agent)
        }
        return result
    }

    public func detectShellProfile() async -> ShellProfile {
        await shellProfiles.detect()
    }

    public func addToShellProfile(
        configuration: String,
        agent: CLIAgent,
        profile: ShellProfile
    ) async throws {
        try await shellProfiles.add(configuration: configuration, for: agent, to: profile)
        await detector.markConfigured(agent)
    }

    public func fetchModelCatalog(configuration: AgentConfiguration) async throws -> [ModelCatalogEntry] {
        try await modelCatalog.fetchCatalog(configuration: configuration)
    }

    public func fetchAvailableModels(configuration: AgentConfiguration) async throws -> [AvailableModel] {
        try await modelCatalog.fetchAvailableModels(configuration: configuration)
    }

    private func adapter(for agent: CLIAgent) throws -> any AgentConfigurationRepository {
        guard let adapter = adapters[agent] else {
            throw AgentConfigurationServiceError.missingAdapter(agent)
        }
        guard adapter.agent == agent else {
            throw AgentConfigurationServiceError.adapterMismatch(expected: agent, actual: adapter.agent)
        }
        return adapter
    }
}
