//
//  CustomProviderService.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Service for managing custom AI provider configurations.
//  Handles CRUD operations and local draft persistence.
//

import Foundation

@MainActor
@Observable
final class CustomProviderService {
    static let shared = CustomProviderService()
    
    // MARK: - Properties
    
    private(set) var providers: [CustomProvider] = []
    private(set) var isLoading = false
    private(set) var lastError: String?
    
    private let storageKey = "customProviders"
    
    // MARK: - Initialization
    
    private init() {
        loadProviders()
    }
    
    // MARK: - CRUD Operations
    
    /// Add a new custom provider
    func addProvider(_ provider: CustomProvider) {
        var newProvider = provider
        newProvider = CustomProvider(
            id: provider.id,
            name: provider.name,
            type: provider.type,
            baseURL: provider.baseURL,
            prefix: provider.prefix,
            apiKeys: provider.apiKeys,
            models: provider.models,
            headers: provider.headers,
            limitToSelectedModels: provider.limitToSelectedModels,
            isEnabled: provider.isEnabled,
            createdAt: Date(),
            updatedAt: Date()
        )
        providers.append(newProvider)
        saveProviders()
    }
    
    /// Update an existing custom provider
    func updateProvider(_ provider: CustomProvider) {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else {
            lastError = "Provider not found"
            return
        }
        
        var updatedProvider = provider
        updatedProvider = CustomProvider(
            id: provider.id,
            name: provider.name,
            type: provider.type,
            baseURL: provider.baseURL,
            prefix: provider.prefix,
            apiKeys: provider.apiKeys,
            models: provider.models,
            headers: provider.headers,
            limitToSelectedModels: provider.limitToSelectedModels,
            isEnabled: provider.isEnabled,
            createdAt: providers[index].createdAt,
            updatedAt: Date()
        )
        providers[index] = updatedProvider
        saveProviders()
    }
    
    /// Delete a custom provider by ID
    func deleteProvider(id: UUID) {
        providers.removeAll { $0.id == id }
        saveProviders()
    }
    
    /// Toggle provider enabled state
    func toggleProvider(id: UUID) {
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        
        let provider = providers[index]
        let updatedProvider = CustomProvider(
            id: provider.id,
            name: provider.name,
            type: provider.type,
            baseURL: provider.baseURL,
            prefix: provider.prefix,
            apiKeys: provider.apiKeys,
            models: provider.models,
            headers: provider.headers,
            limitToSelectedModels: provider.limitToSelectedModels,
            isEnabled: !provider.isEnabled,
            createdAt: provider.createdAt,
            updatedAt: Date()
        )
        providers[index] = updatedProvider
        saveProviders()
    }
    
    /// Get a provider by ID
    func getProvider(id: UUID) -> CustomProvider? {
        providers.first { $0.id == id }
    }
    
    /// Get all enabled providers
    var enabledProviders: [CustomProvider] {
        providers.filter(\.isEnabled)
    }
    
    /// Get providers grouped by type
    var providersByType: [CustomProviderType: [CustomProvider]] {
        Dictionary(grouping: providers, by: \.type)
    }
    
    // MARK: - Persistence
    
    private func loadProviders() {
        isLoading = true
        defer { isLoading = false }
        
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            providers = []
            return
        }
        
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            providers = try decoder.decode([CustomProvider].self, from: data)
        } catch {
            lastError = "Failed to load providers: \(error.localizedDescription)"
            providers = []
        }
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
    
    /// Force reload providers from storage
    func reloadProviders() {
        loadProviders()
    }
    
    // MARK: - Validation
    
    /// Validate a provider before saving
    func validateProvider(_ provider: CustomProvider) -> [String] {
        var errors = provider.validate()
        
        // Check for duplicate names (excluding current provider if updating)
        let existingNames = providers
            .filter { $0.id != provider.id }
            .map { $0.name.lowercased() }
        
        if existingNames.contains(provider.name.lowercased()) {
            errors.append("A provider with this name already exists")
        }
        
        return errors
    }
    
    // MARK: - Import/Export
    
    /// Export providers to JSON data
    func exportProviders() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(providers)
    }
    
    /// Import providers from JSON data
    func importProviders(from data: Data, merge: Bool = true) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let importedProviders = try decoder.decode([CustomProvider].self, from: data)
        
        if merge {
            // Merge: add new providers, update existing ones by ID
            for imported in importedProviders {
                if let existingIndex = providers.firstIndex(where: { $0.id == imported.id }) {
                    providers[existingIndex] = imported
                } else {
                    providers.append(imported)
                }
            }
        } else {
            // Replace all providers
            providers = importedProviders
        }
        
        saveProviders()
    }
}

// MARK: - Errors

enum CustomProviderError: LocalizedError {
    case configFileNotFound
    case invalidProvider(String)
    case saveError(String)
    
    var errorDescription: String? {
        switch self {
        case .configFileNotFound:
            return "Config file not found"
        case .invalidProvider(let message):
            return "Invalid provider: \(message)"
        case .saveError(let message):
            return "Failed to save: \(message)"
        }
    }
}
