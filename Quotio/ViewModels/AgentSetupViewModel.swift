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
    
    private let daemonManager = DaemonManager.shared
    private let daemonAgentService = DaemonAgentService.shared

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

    weak var daemonProxyService: DaemonProxyService?

    /// Reference to QuotaViewModel for quota checking
    weak var quotaViewModel: QuotaViewModel?

    init() {}

    func setup(daemonProxyService: DaemonProxyService? = nil, quotaViewModel: QuotaViewModel? = nil) {
        self.daemonProxyService = daemonProxyService
        self.quotaViewModel = quotaViewModel
    }

    func refreshAgentStatuses(forceRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        let daemonAvailable = await daemonManager.checkHealth()
        
        if daemonAvailable {
            agentStatuses = await daemonAgentService.detectAllAgents(forceRefresh: forceRefresh)
        } else {
            agentStatuses = await detectionService.detectAllAgents(forceRefresh: forceRefresh)
        }
        
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

        guard let daemonProxyService = daemonProxyService else {
            errorMessage = "Proxy service not available"
            return
        }

        selectedAgent = agent

        // Always use client endpoint - all traffic should go through Quotio's proxy
        let endpoint = daemonProxyService.endpoint

        currentConfiguration = AgentConfiguration(
            agent: agent,
            proxyURL: endpoint + "/v1",
            apiKey: apiKey
        )

        // Load previously saved model slots from existing config
        if agent == .claudeCode {
            loadSavedModelSlots()
        }

        // Load models for this agent
        Task { await loadModels() }
    }

    /// Load previously saved model slots from ~/.claude/settings.json
    private func loadSavedModelSlots() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = "\(home)/.claude/settings.json"

        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: String] else {
            return
        }

        // Load saved model selections
        if let opusModel = env["ANTHROPIC_DEFAULT_OPUS_MODEL"], !opusModel.isEmpty {
            currentConfiguration?.modelSlots[.opus] = opusModel
        }
        if let sonnetModel = env["ANTHROPIC_DEFAULT_SONNET_MODEL"], !sonnetModel.isEmpty {
            currentConfiguration?.modelSlots[.sonnet] = sonnetModel
        }
        if let haikuModel = env["ANTHROPIC_DEFAULT_HAIKU_MODEL"], !haikuModel.isEmpty {
            currentConfiguration?.modelSlots[.haiku] = haikuModel
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
    }

    func resetSheetState() {
        configResult = nil
        testResult = nil
        selectedRawConfigIndex = 0
        configurationMode = .automatic
        configStorageOption = .jsonOnly
        isConfiguring = false
        isTesting = false
        // Don't reset availableModels here to allow caching to persist across dismissals
    }

    func loadModels(forceRefresh: Bool = false) async {
        // Create config if not exists (for FallbackScreen scenarios)
        let config: AgentConfiguration
        if let existingConfig = currentConfiguration {
            config = existingConfig
        } else {
            guard let daemonProxyService = daemonProxyService else { return }
            let proxyURL = daemonProxyService.endpoint + "/v1"
            let apiKey = quotaViewModel?.apiKeys.first ?? ""
            config = AgentConfiguration(
                agent: .claudeCode,
                proxyURL: proxyURL,
                apiKey: apiKey
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
