//
//  AgentSetupViewModel.swift
//  Quotio - Agent Setup State Management
//

import Foundation
import SwiftUI
import AppKit
import os.log

@MainActor
@Observable
final class AgentSetupViewModel {
    private let detectionService = AgentDetectionService()
    private let configurationService = AgentConfigurationService()
    private let shellManager = ShellProfileManager()
    private let fallbackSettings = FallbackSettingsManager.shared
    private let copilotFetcher = CopilotQuotaFetcher()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Quotio", category: "AgentSetup")

    var agentStatuses: [AgentStatus] = []
    var isLoading = false
    var isConfiguring = false
    var isTesting = false
    var selectedAgent: CLIAgent?
    var configResult: AgentConfigResult?
    var testResult: ConnectionTestResult?
    var errorMessage: String?

    var availableModels: [AvailableModel] = []
    var isFetchingModels = false

    var currentConfiguration: AgentConfiguration?
    var detectedShell: ShellType = .zsh
    var configurationMode: ConfigurationMode = .automatic
    var configStorageOption: ConfigStorageOption = .jsonOnly
    var selectedRawConfigIndex: Int = 0
    
    // MARK: - Saved Configuration State
    
    /// Currently saved configuration read from agent's config files
    var savedConfig: AgentConfigurationService.SavedAgentConfig?
    
    /// Available backup files for the selected agent
    var availableBackups: [AgentConfigurationService.BackupFile] = []
    
    /// Selected setup mode (proxy or default)
    var selectedSetupMode: ConfigurationSetup = .proxy
    
    /// Task reference for cancellation when switching agents quickly
    private var configurationLoadTask: Task<Void, Never>?

    weak var proxyManager: CLIProxyManager?

    /// Reference to QuotaViewModel for quota checking
    weak var quotaViewModel: QuotaViewModel?

    init() {}

    func setup(proxyManager: CLIProxyManager, quotaViewModel: QuotaViewModel? = nil) {
        self.proxyManager = proxyManager
        self.quotaViewModel = quotaViewModel
    }

    func refreshAgentStatuses(forceRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        agentStatuses = await detectionService.detectAllAgents(forceRefresh: forceRefresh)
        detectedShell = await shellManager.detectShell()
    }

    func status(for agent: CLIAgent) -> AgentStatus? {
        agentStatuses.first { $0.agent == agent }
    }

    func startConfiguration(for agent: CLIAgent) {
        configResult = nil
        testResult = nil
        selectedRawConfigIndex = 0
        configurationMode = .automatic
        configStorageOption = .jsonOnly
        isConfiguring = false
        isTesting = false
        savedConfig = nil
        availableBackups = []
        selectedSetupMode = .proxy  // Reset to default

        guard let proxyManager = proxyManager else {
            errorMessage = "Proxy manager not available"
            return
        }

        guard let apiKey = preferredProxyAPIKey() else {
            errorMessage = "No proxy API key available. Add one in API Keys before configuring agents."
            return
        }

        selectedAgent = agent

        // Use tunnel URL if active, otherwise use local proxy endpoint
        let endpoint: String
        if let tunnelURL = TunnelManager.shared.tunnelState.publicURL {
            endpoint = tunnelURL
        } else {
            endpoint = proxyManager.clientEndpoint
        }

        // Create configuration with defaults first
        currentConfiguration = AgentConfiguration(
            agent: agent,
            proxyURL: endpoint + "/v1",
            apiKey: apiKey,
            setupMode: selectedSetupMode
        )

        if agent == .copilotCLI {
            currentConfiguration?.modelSlots[.sonnet] = AvailableModel.copilotDefaultModel
            currentConfiguration?.modelSlotProviders[.sonnet] = "github-copilot"
        }

        if currentConfiguration?.copilotAuthFileName == nil, let defaultCopilotAccount = availableCopilotAccounts.first {
            currentConfiguration?.copilotAuthFileName = defaultCopilotAccount.name
            currentConfiguration?.copilotAuthIndex = defaultCopilotAccount.authIndex
        }

        // Cancel any previous configuration load task to prevent race conditions
        configurationLoadTask?.cancel()
        
        // Then load existing config, apply saved values, and load models - all in sequence
        configurationLoadTask = Task { [weak self] in
            guard let self else { return }
            
            await self.loadExistingConfiguration(for: agent)
            
            // Guard that selectedAgent still matches after async work
            guard !Task.isCancelled, self.selectedAgent == agent else { return }
            
            await self.loadModels()
        }
    }
    
    /// Load existing configuration from agent's config files and apply to current configuration
    private func loadExistingConfiguration(for agent: CLIAgent) async {
        // Read saved configuration
        savedConfig = await configurationService.readConfiguration(agent: agent)
        
        // Load available backups
        availableBackups = await configurationService.listBackups(agent: agent)
        
        // Pre-populate configuration with saved values
        guard let saved = savedConfig else { return }
        
        // Determine setup mode from saved config
        selectedSetupMode = saved.isProxyConfigured ? .proxy : .defaultSetup
        
        // Update current configuration with saved model slots
        for (slot, model) in saved.modelSlots {
            currentConfiguration?.modelSlots[slot] = model
        }
        for (slot, provider) in saved.modelSlotProviders {
            currentConfiguration?.modelSlotProviders[slot] = provider
        }
        for (slot, effort) in saved.modelSlotReasoningEfforts {
            currentConfiguration?.modelSlotReasoningEfforts[slot] = effort
        }
        currentConfiguration?.copilotAuthFileName = saved.copilotAuthFileName
        currentConfiguration?.copilotAuthIndex = saved.copilotAuthIndex
        
        // Update setup mode in current configuration
        currentConfiguration?.setupMode = selectedSetupMode
    }
    
    /// Switch to proxy setup mode
    func switchToProxySetup() {
        selectedSetupMode = .proxy
        currentConfiguration?.setupMode = .proxy
    }
    
    /// Switch to default (non-proxy) setup mode
    func switchToDefaultSetup() {
        selectedSetupMode = .defaultSetup
        currentConfiguration?.setupMode = .defaultSetup
    }
    
    /// Restore configuration from a backup file
    func restoreFromBackup(_ backup: AgentConfigurationService.BackupFile) async {
        do {
            try await configurationService.restoreFromBackup(backup)
            
            // Reload configuration after restore
            if let agent = selectedAgent {
                await loadExistingConfiguration(for: agent)
                await refreshAgentStatuses()
            }
        } catch {
            errorMessage = "Failed to restore backup: \(error.localizedDescription)"
        }
    }



    var availableCopilotAccounts: [AuthFile] {
        (quotaViewModel?.authFiles ?? [])
            .filter { $0.providerType == .copilot && $0.isReady }
            .sorted { $0.menuBarAccountKey.localizedCaseInsensitiveCompare($1.menuBarAccountKey) == .orderedAscending }
    }

    func updateCopilotAccount(authFileName: String) {
        currentConfiguration?.copilotAuthFileName = authFileName
        currentConfiguration?.copilotAuthIndex = availableCopilotAccounts.first(where: { $0.name == authFileName })?.authIndex
    }

    func updateModelSlot(_ slot: ModelSlot, model: AvailableModel) {
        currentConfiguration?.modelSlots[slot] = model.name
        currentConfiguration?.modelSlotProviders[slot] = model.provider
        // Clear effort if the new model doesn't support it
        if !ReasoningEffort.isSupported(for: model.name) {
            currentConfiguration?.modelSlotReasoningEfforts.removeValue(forKey: slot)
        }
    }

    func updateModelSlotReasoningEffort(_ slot: ModelSlot, effort: ReasoningEffort?) {
        if let effort {
            currentConfiguration?.modelSlotReasoningEfforts[slot] = effort
        } else {
            currentConfiguration?.modelSlotReasoningEfforts.removeValue(forKey: slot)
        }
    }

    func applyConfiguration() async {
        guard let agent = selectedAgent,
              let config = currentConfiguration else { return }

        isConfiguring = true
        defer { isConfiguring = false }

        do {
            try await enforceSelectedCopilotAccountIfNeeded(config: config)

            let result = try await configurationService.generateConfiguration(
                agent: agent,
                config: config,
                mode: configurationMode,
                storageOption: agent == .claudeCode ? configStorageOption : .jsonOnly,
                detectionService: detectionService,
                availableModels: availableModels
            )

            if configurationMode == .automatic && result.success {
                let shouldUpdateShell = agent == .copilotCLI
                    ? result.shellConfig != nil
                    : agent.configType == .both
                    ? (configStorageOption == .shellOnly || configStorageOption == .both)
                    : agent.configType != .file

                if let shellConfig = result.shellConfig, shouldUpdateShell {
                    try await shellManager.addToProfile(
                        shell: detectedShell,
                        configuration: shellConfig,
                        agent: agent
                    )
                }

                await detectionService.markAsConfigured(agent)
                await refreshAgentStatuses()
            }

            configResult = result

            if !result.success {
                errorMessage = result.error
            }
        } catch {
            errorMessage = error.localizedDescription
            configResult = .failure(error: error.localizedDescription)
        }
    }

    func addToShellProfile() async {
        guard let agent = selectedAgent,
              let shellConfig = configResult?.shellConfig else { return }

        do {
            try await shellManager.addToProfile(
                shell: detectedShell,
                configuration: shellConfig,
                agent: agent
            )

            configResult = AgentConfigResult.success(
                type: configResult?.configType ?? .environment,
                mode: configurationMode,
                configPath: configResult?.configPath,
                authPath: configResult?.authPath,
                shellConfig: shellConfig,
                rawConfigs: configResult?.rawConfigs ?? [],
                instructions: "Added to \(detectedShell.profilePath). Restart your terminal for changes to take effect.",
                modelsConfigured: configResult?.modelsConfigured ?? 0
            )

            await detectionService.markAsConfigured(agent)
            await refreshAgentStatuses()
        } catch {
            errorMessage = "Failed to update shell profile: \(error.localizedDescription)"
        }
    }

    func copyToClipboard() {
        guard let shellConfig = configResult?.shellConfig else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shellConfig, forType: .string)
    }

    func copyRawConfigToClipboard(index: Int) {
        guard let result = configResult,
              index < result.rawConfigs.count else { return }

        let rawConfig = result.rawConfigs[index]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawConfig.content, forType: .string)
    }

    func copyAllRawConfigsToClipboard() {
        guard let result = configResult else { return }

        let allContent = result.rawConfigs.map { config in
            """
            # \(config.filename ?? "Configuration")
            # Target: \(config.targetPath ?? "N/A")

            \(config.content)
            """
        }.joined(separator: "\n\n---\n\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allContent, forType: .string)
    }

    func testConnection() async {
        guard let agent = selectedAgent,
              let config = currentConfiguration else { return }

        isTesting = true
        defer { isTesting = false }

        testResult = await configurationService.testConnection(
            agent: agent,
            config: config
        )
    }

    func generatePreviewConfig() async -> AgentConfigResult? {
        guard let agent = selectedAgent,
              let config = currentConfiguration else { return nil }

        do {
            return try await configurationService.generateConfiguration(
                agent: agent,
                config: config,
                mode: .manual,
                detectionService: detectionService,
                availableModels: availableModels
            )
        } catch {
            return nil
        }
    }

    func dismissConfiguration() {
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

    func resetSheetState() {
        configResult = nil
        testResult = nil
        selectedRawConfigIndex = 0
        configurationMode = .automatic
        configStorageOption = .jsonOnly
        isConfiguring = false
        isTesting = false
        selectedSetupMode = .proxy
        // Don't reset availableModels here to allow caching to persist across dismissals
        // Don't reset savedConfig/availableBackups - they persist while sheet is open
    }

    /// Load available models for agent configuration.
    ///
    /// - Parameter forceRefresh: Reserved for future use.
    /// - Returns: `true` when models were fetched from remote successfully; `false` on fetch error.
    @discardableResult
    func loadModels(forceRefresh: Bool = false) async -> Bool {
        // Create config if not exists (for FallbackScreen scenarios)
        let config: AgentConfiguration
        if let existingConfig = currentConfiguration {
            config = existingConfig
        } else {
            guard let proxyManager = proxyManager else { return false }
            guard let apiKey = preferredProxyAPIKey() else {
                errorMessage = "No proxy API key available. Add one in API Keys before configuring agents."
                return false
            }

            // Use tunnel URL if active, otherwise use local proxy endpoint
            let modelEndpoint: String
            if let tunnelURL = TunnelManager.shared.tunnelState.publicURL {
                modelEndpoint = tunnelURL
            } else {
                modelEndpoint = proxyManager.clientEndpoint
            }

            config = AgentConfiguration(
                agent: .claudeCode,
                proxyURL: modelEndpoint + "/v1",
                apiKey: apiKey
            )
        }

        isFetchingModels = true
        defer { isFetchingModels = false }
        var loadedFromRemote = false

        do {
            let fetchedModels = try await configurationService.fetchAvailableModels(config: config)
            let processedModels = await processModels(fetchedModels)
            self.availableModels = processedModels
            loadedFromRemote = true

            // Log model list
            let modelList = processedModels.map { "\($0.id) (provider: \($0.provider))" }.joined(separator: ", ")
            logger.debug("[AgentSetupViewModel] Loaded \(processedModels.count) models: \(modelList)")
        } catch {
            // On error, use default models if list is empty
            logger.error("[AgentSetupViewModel] Failed to load models: \(error.localizedDescription)")
            if availableModels.isEmpty {
                self.availableModels = await processModels([])
                logger.debug("[AgentSetupViewModel] Using \(self.availableModels.count) default models")
            }
        }

        refreshVirtualModels()
        return loadedFromRemote
    }

    private func preferredProxyAPIKey() -> String? {
        if let liveAPIKey = quotaViewModel?.apiKeys.first, !liveAPIKey.isEmpty {
            return liveAPIKey
        }

        return proxyManager?.firstConfiguredAPIKey
    }

    private func processModels(_ fetchedModels: [AvailableModel]) async -> [AvailableModel] {
        // Merge the live catalog with the built-in catalog so manually curated models
        // remain selectable even if the current proxy response is incomplete.
        let builtinModels = availableCopilotAccounts.isEmpty ? AvailableModel.allModels : AvailableModel.allModelsExcludingCopilot
        var mergedModels = (fetchedModels + builtinModels).reduce(into: [String: AvailableModel]()) { result, model in
            result[model.selectionKey] = result[model.selectionKey] ?? model
        }

        if !availableCopilotAccounts.isEmpty {
            for key in mergedModels.keys where mergedModels[key]?.provider.lowercased() == "github-copilot" {
                mergedModels.removeValue(forKey: key)
            }

            let exactCopilotModels = await fetchSelectedCopilotModels()
            for model in exactCopilotModels {
                mergedModels[model.selectionKey] = model
            }
        }

        if !mergedModels.isEmpty {
            return mergedModels.values.sorted { $0.displayName < $1.displayName }
        }

        return builtinModels.sorted { $0.displayName < $1.displayName }
    }

    private func fetchSelectedCopilotModels() async -> [AvailableModel] {
        guard let selectedAccount = selectedCopilotAccount else { return [] }

        if currentConfiguration?.copilotAuthFileName != selectedAccount.name {
            currentConfiguration?.copilotAuthFileName = selectedAccount.name
            currentConfiguration?.copilotAuthIndex = selectedAccount.authIndex
        }

        if let authPath = selectedAccount.path {
            let models = await copilotFetcher.fetchAvailableModels(authFilePath: authPath)
            return models.filter(\.isAvailable).map {
                AvailableModel(
                    id: $0.id,
                    name: $0.id,
                    provider: "github-copilot",
                    isDefault: false
                )
            }
        }

        if let client = quotaViewModel?.apiClient {
            do {
                let models = try await client.fetchAuthFileModels(name: selectedAccount.name)
                return models.map {
                    AvailableModel(
                        id: $0.id,
                        name: $0.id,
                        provider: "github-copilot",
                        isDefault: false
                    )
                }
            } catch {
                logger.error("[AgentSetupViewModel] Failed to fetch auth-file models for \(selectedAccount.name): \(error.localizedDescription)")
            }
        }

        return []
    }

    private var selectedCopilotAccount: AuthFile? {
        if let selectedName = currentConfiguration?.copilotAuthFileName,
           let match = availableCopilotAccounts.first(where: { $0.name == selectedName }) {
            return match
        }
        return availableCopilotAccounts.first
    }

    private func configurationUsesCopilot(_ config: AgentConfiguration) -> Bool {
        if config.agent == .copilotCLI {
            return true
        }
        return config.modelSlotProviders.values.contains(where: { $0.lowercased() == "github-copilot" })
    }

    private func enforceSelectedCopilotAccountIfNeeded(config: AgentConfiguration) async throws {
        guard configurationUsesCopilot(config),
              let selectedName = config.copilotAuthFileName,
              !selectedName.isEmpty else { return }
        guard let client = quotaViewModel?.apiClient else { return }

        let copilotAccounts = availableCopilotAccounts
        guard !copilotAccounts.isEmpty else { return }

        for account in copilotAccounts {
            let shouldDisable = account.name != selectedName
            if account.disabled != shouldDisable {
                try await client.setAuthFileDisabled(name: account.name, disabled: shouldDisable)
            }
        }

        await quotaViewModel?.refreshData()
    }

    /// Refresh virtual models - removes old ones and adds current ones
    private func refreshVirtualModels() {
        // First remove any existing virtual models (provider == "fallback")
        availableModels.removeAll { $0.provider.lowercased() == "fallback" }

        // Then add current virtual models
        guard fallbackSettings.isEnabled else { return }

        for virtualModel in fallbackSettings.virtualModels where virtualModel.isEnabled {
            let model = AvailableModel(
                id: virtualModel.name,
                name: virtualModel.name,
                provider: "fallback",
                isDefault: false
            )
            availableModels.append(model)
        }
    }

    /// Check if a provider has available quota for a specific model
    func checkProviderQuota(provider: AIProvider, modelId: String) -> Bool {
        guard let quotaVM = quotaViewModel else { return true }

        guard let providerQuotas = quotaVM.providerQuotas[provider] else { return false }

        for (_, quotaData) in providerQuotas {
            let hasQuotaForModel = quotaData.models.contains { model in
                model.id == modelId && model.percentage > 0
            }
            if hasQuotaForModel {
                return true
            }
        }

        return false
    }

    /// Resolve a virtual model to a real provider + model combination
    /// Returns nil if the model is not a virtual model or no fallback is available
    /// Note: Actual fallback resolution happens at request time in ProxyBridge
    func isVirtualModel(_ modelName: String) -> Bool {
        return fallbackSettings.isVirtualModel(modelName)
    }
}
