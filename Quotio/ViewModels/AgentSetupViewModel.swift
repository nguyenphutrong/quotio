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
    
    weak var proxyManager: CLIProxyManager?
    
    init() {}
    
    func setup(proxyManager: CLIProxyManager) {
        self.proxyManager = proxyManager
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
        
        guard let proxyManager = proxyManager else {
            errorMessage = "Proxy manager not available"
            return
        }
        
        selectedAgent = agent
        currentConfiguration = AgentConfiguration(
            agent: agent,
            proxyURL: proxyManager.baseURL + "/v1",
            apiKey: apiKey
        )
        
        // Load models for this agent
        Task { await loadModels() }
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
        guard let config = currentConfiguration else { return }
        
        isFetchingModels = true
        defer { isFetchingModels = false }
        
        // 1. Try memory cache (already in avaliableModels if not empty and not force refresh)
        if !availableModels.isEmpty && !forceRefresh {
            return
        }
        
        // 2. Try disk cache (UserDefaults)
        let cacheKey = "quotio.models.cache.\(config.agent.id)"
        if !forceRefresh,
           let data = UserDefaults.standard.data(forKey: cacheKey),
           let cachedModels = try? JSONDecoder().decode([AvailableModel].self, from: data) {
            self.availableModels = cachedModels
            // Even if we have cache, we might want to fetch fresh in background? 
            // For now, respect the cache unless user clicks refresh.
            return
        }
        
        // 3. Fetch from Proxy
        do {
            let fetchedModels = try await configurationService.fetchAvailableModels(config: config)
            
            // Deduplicate and process
            var uniqueModels = fetchedModels
            
            // Ensure default models are included if missing (fallback)
            for defaultModel in AvailableModel.allModels {
                if !uniqueModels.contains(where: { $0.id == defaultModel.id }) {
                    uniqueModels.append(defaultModel)
                }
            }
            
            // Sort: Default models first? Or just alphabetical? 
            // Let's keep the fetch order but maybe prioritize known models?
            // For now, simple sort by name
            uniqueModels.sort { $0.displayName < $1.displayName }
            
            self.availableModels = uniqueModels
            
            // Save to cache
            if let data = try? JSONEncoder().encode(uniqueModels) {
                UserDefaults.standard.set(data, forKey: cacheKey)
            }
        } catch {
            // Fallback to hardcoded list if fetch fails and no cache
            if availableModels.isEmpty {
                self.availableModels = AvailableModel.allModels
            }
        }
    }
}
