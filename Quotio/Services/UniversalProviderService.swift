//
//  UniversalProviderService.swift
//  Quotio
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class UniversalProviderService {
    static let shared = UniversalProviderService()
    
    private(set) var providers: [UniversalProvider] = []
    private(set) var activeState = ActiveProviderState()
    private(set) var isLoading = false
    private(set) var lastError: String?
    
    private let storageKey = "universalProviders"
    private let activeStateKey = "universalProviderActiveState"
    private let keychain = KeychainService.shared
    
    private init() {
        loadProviders()
        loadActiveState()
    }
    
    // MARK: - Provider Access
    
    var enabledProviders: [UniversalProvider] {
        providers.filter(\.isEnabled)
    }
    
    var customProviders: [UniversalProvider] {
        providers.filter { !$0.isBuiltIn }
    }
    
    var builtInProviders: [UniversalProvider] {
        providers.filter(\.isBuiltIn)
    }
    
    func provider(withId id: UUID) -> UniversalProvider? {
        providers.first { $0.id == id }
    }
    
    func activeProvider(for agent: CLIAgent) -> UniversalProvider? {
        guard let id = activeState.activeProviderId(for: agent) else { return nil }
        return provider(withId: id)
    }
    
    // MARK: - CRUD Operations
    
    func addProvider(_ provider: UniversalProvider) {
        var newProvider = provider
        newProvider = UniversalProvider(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            modelId: provider.modelId,
            isBuiltIn: false,
            iconAssetName: provider.iconAssetName,
            color: provider.color,
            supportedAgents: provider.supportedAgents,
            isEnabled: provider.isEnabled,
            createdAt: Date(),
            updatedAt: Date()
        )
        providers.append(newProvider)
        saveProviders()
    }
    
    func updateProvider(_ provider: UniversalProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else {
            lastError = "Provider not found"
            return
        }
        
        var updated = provider
        updated = UniversalProvider(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            modelId: provider.modelId,
            isBuiltIn: providers[index].isBuiltIn,
            iconAssetName: provider.iconAssetName,
            color: provider.color,
            supportedAgents: provider.supportedAgents,
            isEnabled: provider.isEnabled,
            createdAt: providers[index].createdAt,
            updatedAt: Date()
        )
        providers[index] = updated
        saveProviders()
    }
    
    func removeProvider(id: UUID) {
        guard let provider = provider(withId: id), !provider.isBuiltIn else {
            lastError = "Cannot remove built-in provider"
            return
        }
        providers.removeAll { $0.id == id }
        saveProviders()
    }
    
    func toggleProvider(id: UUID) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        var provider = providers[index]
        provider = UniversalProvider(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            modelId: provider.modelId,
            isBuiltIn: provider.isBuiltIn,
            iconAssetName: provider.iconAssetName,
            color: provider.color,
            supportedAgents: provider.supportedAgents,
            isEnabled: !provider.isEnabled,
            createdAt: provider.createdAt,
            updatedAt: Date()
        )
        providers[index] = provider
        saveProviders()
    }
    
    // MARK: - Active Provider Management
    
    func setActive(_ provider: UniversalProvider, for agent: CLIAgent) {
        activeState.setActive(provider.id, for: agent)
        saveActiveState()
    }
    
    func clearActive(for agent: CLIAgent) {
        activeState.providerIdByAgent.removeValue(forKey: agent.rawValue)
        saveActiveState()
    }
    
    // MARK: - API Key Management
    
    func validateAPIKey(_ key: String, for provider: UniversalProvider) -> ValidationResult {
        guard !key.isEmpty else {
            return .invalid("API key cannot be empty")
        }
        
        guard key.count >= 8 else {
            return .invalid("API key appears too short")
        }
        
        let baseURL = provider.baseURL.lowercased()
        
        if baseURL.contains("anthropic") {
            if !key.hasPrefix("sk-ant-") {
                return .warning("Anthropic keys typically start with 'sk-ant-'")
            }
        } else if baseURL.contains("openai") {
            if !key.hasPrefix("sk-") {
                return .warning("OpenAI keys typically start with 'sk-'")
            }
        } else if baseURL.contains("openrouter") {
            if !key.hasPrefix("sk-or-") {
                return .warning("OpenRouter keys typically start with 'sk-or-'")
            }
        }
        
        return .valid
    }
    
    func storeAPIKey(_ key: String, for provider: UniversalProvider) async throws -> ValidationResult {
        let validation = validateAPIKey(key, for: provider)
        
        if case .invalid = validation {
            return validation
        }
        
        let account = "universal.\(provider.id.uuidString)"
        try await keychain.storeByAccount(account, key: key)
        return validation
    }
    
    func retrieveAPIKey(for provider: UniversalProvider) async throws -> String? {
        let account = "universal.\(provider.id.uuidString)"
        return try await keychain.retrieveByAccount(account)
    }
    
    func deleteAPIKey(for provider: UniversalProvider) async throws {
        let account = "universal.\(provider.id.uuidString)"
        try await keychain.deleteByAccount(account)
    }
    
    func hasAPIKey(for provider: UniversalProvider) async -> Bool {
        let account = "universal.\(provider.id.uuidString)"
        return await keychain.existsByAccount(account)
    }
    
    // MARK: - Persistence
    
    private func loadProviders() {
        isLoading = true
        defer { isLoading = false }
        
        var loaded: [UniversalProvider] = []
        
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                loaded = try decoder.decode([UniversalProvider].self, from: data)
            } catch {
                lastError = "Failed to load providers: \(error.localizedDescription)"
            }
        }
        
        for builtIn in UniversalProvider.builtInProviders {
            if !loaded.contains(where: { $0.id == builtIn.id }) {
                loaded.append(builtIn)
            }
        }
        
        providers = loaded
    }
    
    private func saveProviders() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(providers)
            UserDefaults.standard.set(data, forKey: storageKey)
            lastError = nil
        } catch {
            lastError = "Failed to save providers: \(error.localizedDescription)"
        }
    }
    
    private func loadActiveState() {
        guard let data = UserDefaults.standard.data(forKey: activeStateKey) else { return }
        do {
            activeState = try JSONDecoder().decode(ActiveProviderState.self, from: data)
        } catch {
            lastError = "Failed to load active state: \(error.localizedDescription)"
        }
    }
    
    private func saveActiveState() {
        do {
            let data = try JSONEncoder().encode(activeState)
            UserDefaults.standard.set(data, forKey: activeStateKey)
        } catch {
            lastError = "Failed to save active state: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Migration
    
    func migrateFromCustomProviderService() {
        let customService = CustomProviderService.shared
        
        for customProvider in customService.providers {
            if !providers.contains(where: { $0.id == customProvider.id }) {
                let universal = UniversalProvider(from: customProvider)
                providers.append(universal)
            }
        }
        
        saveProviders()
    }
    
    func reloadProviders() {
        loadProviders()
        loadActiveState()
    }
}
