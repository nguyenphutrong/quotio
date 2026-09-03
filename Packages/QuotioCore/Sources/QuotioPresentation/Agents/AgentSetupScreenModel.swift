import Foundation
import Observation
import QuotioApplication
import QuotioDomain

public struct AgentEndpointContext: Equatable, Sendable {
    public let baseURL: String
    public let apiKey: String

    public init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}

public extension AvailableModel {
    var displayName: String {
        name.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

@MainActor
@Observable
public final class AgentSetupScreenModel {
    public private(set) var agentStatuses: [AgentStatus] = []
    public private(set) var isLoading = false
    public private(set) var isConfiguring = false
    public private(set) var isTesting = false
    public private(set) var selectedAgent: CLIAgent?
    public private(set) var configResult: AgentConfigResult?
    public private(set) var testResult: ConnectionTestResult?
    public var errorMessage: String?

    public private(set) var availableModels: [AvailableModel] = []
    public private(set) var isFetchingModels = false

    public var currentConfiguration: AgentConfiguration?
    public private(set) var detectedShell: ShellType = .zsh
    public private(set) var detectedShellProfilePath = ""
    public var configurationMode: ConfigurationMode = .automatic
    public var configStorageOption: ConfigStorageOption = .jsonOnly
    public var selectedRawConfigIndex = 0
    public private(set) var savedConfig: SavedAgentConfiguration?
    public private(set) var availableBackups: [AgentBackupFile] = []
    public var selectedSetupMode: ConfigurationSetup = .proxy

    @ObservationIgnored private let service: AgentConfigurationService
    @ObservationIgnored private let endpointContext: @MainActor () -> AgentEndpointContext?
    @ObservationIgnored private let log: @Sendable (_ message: String) -> Void
    @ObservationIgnored private var configurationLoadTask: Task<Void, Never>?

    public init(
        service: AgentConfigurationService,
        endpointContext: @escaping @MainActor () -> AgentEndpointContext?,
        log: @escaping @Sendable (_ message: String) -> Void = { _ in }
    ) {
        self.service = service
        self.endpointContext = endpointContext
        self.log = log
    }

    deinit {
        configurationLoadTask?.cancel()
    }

    public func refreshAgentStatuses(forceRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        async let statuses = service.detectAgents(forceRefresh: forceRefresh)
        async let profile = service.detectShellProfile()
        agentStatuses = await statuses
        let resolvedProfile = await profile
        detectedShell = resolvedProfile.shell
        detectedShellProfilePath = resolvedProfile.path
    }

    public func status(for agent: CLIAgent) -> AgentStatus? {
        agentStatuses.first { $0.agent == agent }
    }

    public func startConfiguration(for agent: CLIAgent) {
        resetConfigurationState()
        guard let context = endpointContext() else {
            errorMessage = "Proxy manager not available"
            return
        }

        selectedAgent = agent
        currentConfiguration = AgentConfiguration(
            agent: agent,
            proxyURL: context.baseURL + "/v1",
            apiKey: context.apiKey,
            setupMode: selectedSetupMode
        )

        configurationLoadTask?.cancel()
        configurationLoadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadExistingConfiguration(for: agent)
            guard !Task.isCancelled, self.selectedAgent == agent else { return }
            await self.loadModels()
        }
    }

    public func switchToProxySetup() {
        selectedSetupMode = .proxy
        currentConfiguration?.setupMode = .proxy
    }

    public func switchToDefaultSetup() {
        selectedSetupMode = .defaultSetup
        currentConfiguration?.setupMode = .defaultSetup
    }

    public func restoreFromBackup(_ backup: AgentBackupFile) async {
        do {
            try await service.restore(backup)
            if let agent = selectedAgent {
                await loadExistingConfiguration(for: agent)
                await refreshAgentStatuses()
            }
        } catch {
            errorMessage = "Failed to restore backup: \(error.localizedDescription)"
        }
    }

    public func updateModelSlot(_ slot: ModelSlot, model: String) {
        currentConfiguration?.modelSlots[slot] = model
    }

    public func updateReasoningEffort(_ effort: CodexReasoningEffort) {
        currentConfiguration?.codexReasoningEffort = effort
    }

    public func applyConfiguration() async {
        guard let config = currentConfiguration else { return }
        isConfiguring = true
        defer { isConfiguring = false }

        do {
            let profile = ShellProfile(shell: detectedShell, path: detectedShellProfilePath)
            let result = try await service.apply(request(for: config), shellProfile: profile)
            configResult = result
            if result.success, configurationMode == .automatic {
                await refreshAgentStatuses()
            } else if !result.success {
                errorMessage = result.failure?.localizedText
            }
        } catch {
            let message = agentConfigurationErrorMessage(error)
            errorMessage = message
            configResult = .failure(.operationFailed(details: message))
        }
    }

    public func addToShellProfile() async {
        guard let agent = selectedAgent,
              let shellConfig = configResult?.shellConfig else { return }
        do {
            let profile = ShellProfile(shell: detectedShell, path: detectedShellProfilePath)
            try await service.addToShellProfile(
                configuration: shellConfig,
                agent: agent,
                profile: profile
            )
            let result = configResult
            configResult = .success(
                type: result?.configType ?? .environment,
                mode: configurationMode,
                configPath: result?.configPath,
                authPath: result?.authPath,
                shellConfig: shellConfig,
                rawConfigs: result?.rawConfigs ?? [],
                instructions: .shellProfileUpdated(path: detectedShellProfilePath),
                modelsConfigured: result?.modelsConfigured ?? 0
            )
            await refreshAgentStatuses()
        } catch {
            errorMessage = "Failed to update shell profile: \(error.localizedDescription)"
        }
    }

    public func testConnection() async {
        guard let agent = selectedAgent, let config = currentConfiguration else { return }
        isTesting = true
        defer { isTesting = false }
        testResult = await service.testConnection(agent: agent, configuration: config)
    }

    public func generatePreviewConfig() async -> AgentConfigResult? {
        guard let config = currentConfiguration else { return nil }
        do {
            var request = request(for: config)
            request = AgentConfigurationRequest(
                configuration: request.configuration,
                mode: .manual,
                storageOption: request.storageOption,
                availableModels: request.availableModels
            )
            return try await service.generatePreview(request)
        } catch {
            return nil
        }
    }

    public func dismissConfiguration() {
        configurationLoadTask?.cancel()
        configurationLoadTask = nil
        selectedAgent = nil
        configResult = nil
        testResult = nil
        currentConfiguration = nil
        errorMessage = nil
        selectedRawConfigIndex = 0
        isConfiguring = false
        isTesting = false
        savedConfig = nil
        availableBackups = []
        selectedSetupMode = .proxy
    }

    public func resetSheetState() {
        configResult = nil
        testResult = nil
        selectedRawConfigIndex = 0
        configurationMode = .automatic
        configStorageOption = .jsonOnly
        isConfiguring = false
        isTesting = false
        selectedSetupMode = .proxy
    }

    @discardableResult
    public func loadModels(forceRefresh _: Bool = false) async -> Bool {
        guard let config = modelRequestConfiguration() else { return false }
        isFetchingModels = true
        defer { isFetchingModels = false }

        do {
            let fetched = try await service.fetchAvailableModels(configuration: config)
            let processed = processModels(fetched)
            availableModels = processed
            log("Loaded \(processed.count) models")
            return true
        } catch {
            log("Failed to load models: \(error.localizedDescription)")
            if availableModels.isEmpty {
                availableModels = AvailableModel.allModels
            }
            return false
        }
    }

    public func fetchModelCatalog() async throws -> [ModelCatalogEntry] {
        guard let config = modelRequestConfiguration() else {
            throw ModelCatalogError.proxyUnavailable
        }
        return try await service.fetchModelCatalog(configuration: config)
    }

    private func loadExistingConfiguration(for agent: CLIAgent) async {
        do {
            async let inspected = service.inspect(agent)
            async let backups = service.listBackups(for: agent)
            let (saved, availableBackups) = try await (inspected, backups)
            guard !Task.isCancelled, selectedAgent == agent else { return }

            savedConfig = saved
            self.availableBackups = availableBackups
            guard let saved else { return }

            selectedSetupMode = saved.isProxyConfigured ? .proxy : .defaultSetup
            for (slot, model) in saved.modelSlots {
                currentConfiguration?.modelSlots[slot] = model
            }
            if let effort = saved.reasoningEffort {
                currentConfiguration?.codexReasoningEffort = effort
            }
            currentConfiguration?.setupMode = selectedSetupMode
        } catch where error is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = agentConfigurationErrorMessage(error)
        }
    }

    private func request(for configuration: AgentConfiguration) -> AgentConfigurationRequest {
        AgentConfigurationRequest(
            configuration: configuration,
            mode: configurationMode,
            storageOption: configuration.agent == .claudeCode ? configStorageOption : .jsonOnly,
            availableModels: availableModels
        )
    }

    private func modelRequestConfiguration() -> AgentConfiguration? {
        if let currentConfiguration { return currentConfiguration }
        guard let context = endpointContext() else { return nil }
        return AgentConfiguration(
            agent: .claudeCode,
            proxyURL: context.baseURL + "/v1",
            apiKey: context.apiKey
        )
    }

    private func processModels(_ fetchedModels: [AvailableModel]) -> [AvailableModel] {
        let models = fetchedModels.isEmpty ? AvailableModel.allModels : fetchedModels
        return models.sorted { $0.displayName < $1.displayName }
    }

    private func resetConfigurationState() {
        configResult = nil
        testResult = nil
        selectedRawConfigIndex = 0
        configurationMode = .automatic
        configStorageOption = .jsonOnly
        isConfiguring = false
        isTesting = false
        savedConfig = nil
        availableBackups = []
        selectedSetupMode = .proxy
    }
}
