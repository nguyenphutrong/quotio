//
//  AgentSetupViewModel.swift
//  Quotio - Agent Setup State Management
//

import Foundation
import SwiftUI
import AppKit

@MainActor
@Observable
final class AgentSetupViewModel {
    private let detectionService = AgentDetectionService()
    private let configurationService = AgentConfigurationService()
    private let shellManager = ShellProfileManager()
    private let fallbackSettings = FallbackSettingsManager.shared

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

    func startConfiguration(for agent: CLIAgent, apiKey: String) {
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

        selectedAgent = agent

        // Always use client endpoint - all traffic should go through Quotio's proxy
        let endpoint = proxyManager.clientEndpoint

        // Create configuration with defaults first
        currentConfiguration = AgentConfiguration(
            agent: agent,
            proxyURL: endpoint + "/v1",
            apiKey: apiKey,
            setupMode: selectedSetupMode
        )

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



    func updateModelSlot(_ slot: ModelSlot, model: String) {
        currentConfiguration?.modelSlots[slot] = model
    }

    func applyConfiguration() async {
        guard let agent = selectedAgent,
              let config = currentConfiguration else { return }

        isConfiguring = true
        defer { isConfiguring = false }

        do {
            let result = try await configurationService.generateConfiguration(
                agent: agent,
                config: config,
                mode: configurationMode,
                storageOption: agent == .claudeCode ? configStorageOption : .jsonOnly,
                detectionService: detectionService,
                availableModels: availableModels
            )

            if configurationMode == .automatic && result.success {
                let shouldUpdateShell = agent.configType == .both
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

    func loadModels(forceRefresh: Bool = false) async {
        // Create config if not exists (for FallbackScreen scenarios)
        let config: AgentConfiguration
        if let existingConfig = currentConfiguration {
            config = existingConfig
        } else {
            guard let proxyManager = proxyManager else { return }
            config = AgentConfiguration(
                agent: .claudeCode,
                proxyURL: proxyManager.clientEndpoint + "/v1",
                apiKey: proxyManager.managementKey
            )
        }

        let cacheKey = "quotio.models.cache.\(config.agent.id)"

        // Check if auth files changed since cache was created (decoupled invalidation)
        let authFilesChanged = UserDefaults.standard.double(forKey: QuotaViewModel.authFilesChangedKey)

        if !forceRefresh, let cache = loadCache(key: cacheKey) {
            // Invalidate cache if auth files changed after cache was created
            let cacheInvalidated = authFilesChanged > cache.timestamp.timeIntervalSince1970

            if !cacheInvalidated {
                self.availableModels = cache.models
                refreshVirtualModels()

                if !cache.isStale {
                    return
                }

                Task.detached { [weak self] in
                    await self?.silentRefreshModels(cacheKey: cacheKey, config: config)
                }
                return
            }
        }

        isFetchingModels = true
        defer { isFetchingModels = false }

        await fetchAndCacheModels(cacheKey: cacheKey, config: config)
    }

    private func silentRefreshModels(cacheKey: String, config: AgentConfiguration) async {
        do {
            let fetchedModels = try await configurationService.fetchAvailableModels(config: config)
            let processedModels = processModels(fetchedModels)

            saveCache(models: processedModels, key: cacheKey, agentId: config.agent.id)

            await MainActor.run {
                if self.hasModelChanges(current: self.availableModels, new: processedModels) {
                    self.availableModels = processedModels
                    self.refreshVirtualModels()
                }
            }
        } catch {
            print("[ModelCache] Silent refresh failed: \(error.localizedDescription)")
        }
    }

    private func fetchAndCacheModels(cacheKey: String, config: AgentConfiguration) async {
        do {
            let fetchedModels = try await configurationService.fetchAvailableModels(config: config)
            let processedModels = processModels(fetchedModels)

            self.availableModels = processedModels
            saveCache(models: processedModels, key: cacheKey, agentId: config.agent.id)
        } catch {
            if let staleCache = loadCache(key: cacheKey, ignoreExpiry: true) {
                self.availableModels = staleCache.models
            } else if availableModels.isEmpty {
                self.availableModels = AvailableModel.allModels
            }
        }

        refreshVirtualModels()
    }

    private func loadCache(key: String, ignoreExpiry: Bool = false) -> ModelCache? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cache = try? JSONDecoder().decode(ModelCache.self, from: data) else {
            return nil
        }
        if ignoreExpiry || !cache.isExpired {
            return cache
        }
        return nil
    }

    private func saveCache(models: [AvailableModel], key: String, agentId: String) {
        let cache = ModelCache(models: models, timestamp: Date(), agentId: agentId)
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func processModels(_ fetchedModels: [AvailableModel]) -> [AvailableModel] {
        var uniqueModels = fetchedModels

        for defaultModel in AvailableModel.allModels {
            if !uniqueModels.contains(where: { $0.id == defaultModel.id }) {
                uniqueModels.append(defaultModel)
            }
        }

        uniqueModels.sort { $0.displayName < $1.displayName }
        return uniqueModels
    }

    private func hasModelChanges(current: [AvailableModel], new: [AvailableModel]) -> Bool {
        let currentIds = Set(current.filter { $0.provider.lowercased() != "fallback" }.map { $0.id })
        let newIds = Set(new.map { $0.id })
        return currentIds != newIds
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
