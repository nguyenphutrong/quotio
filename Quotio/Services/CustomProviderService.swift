//
//  CustomProviderService.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Service for managing custom AI provider configurations.
//  Handles CRUD operations, persistence, and YAML config generation.
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
    private let fileManager = FileManager.default
    
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
    
    // MARK: - Config Generation
    
    /// Generate YAML config sections for all enabled custom providers
    func generateYAMLConfig() -> String {
        enabledProviders.toYAMLSections()
    }
    
    /// Update the CLIProxyAPI config file to include custom providers
    func syncToConfigFile(configPath: String) throws {
        guard fileManager.fileExists(atPath: configPath) else {
            throw CustomProviderError.configFileNotFound
        }
        
        var content = try String(contentsOfFile: configPath, encoding: .utf8)
        
        // Remove existing custom provider sections
        content = removeCustomProviderSections(from: content)
        
        // Append new custom provider sections
        let customProviderYAML = generateYAMLConfig()
        if !customProviderYAML.isEmpty {
            content += "\n# Custom Providers (managed by Quotio)\n"
            content += customProviderYAML
        }
        
        try content.write(toFile: configPath, atomically: true, encoding: .utf8)
    }
    
    /// Remove custom provider sections from config content
    private func removeCustomProviderSections(from content: String) -> String {
        var result = content
        
        // Dynamically derive custom provider keys from CustomProviderType enum
        // This ensures new provider types are automatically handled
        let customProviderKeys = CustomProviderType.allCases.map { "\($0.rawValue):" }
        
        // Remove marker comment and everything after it that belongs to custom providers
        if let markerRange = result.range(of: "# Custom Providers (managed by Quotio)") {
            // Find the end of custom providers section (next top-level key or end of file)
            let afterMarker = result[markerRange.upperBound...]
            
            var endIndex = result.endIndex
            
            // Look for any non-custom-provider top-level key
            let topLevelKeyPattern = #"(?m)^[a-z][\w-]*:"#
            if let regex = try? NSRegularExpression(pattern: topLevelKeyPattern, options: []) {
                let searchRange = NSRange(afterMarker.startIndex..<afterMarker.endIndex, in: result)
                let matches = regex.matches(in: result, options: [], range: searchRange)
                
                for match in matches {
                    if let range = Range(match.range, in: result) {
                        let key = String(result[range])
                        if !customProviderKeys.contains(key) {
                            endIndex = range.lowerBound
                            break
                        }
                    }
                }
            }
            
            // Remove the custom providers section
            result.removeSubrange(markerRange.lowerBound..<endIndex)
        }
        
        // Also remove standalone custom provider sections that might exist without marker
        for key in customProviderKeys {
            result = removeYAMLSection(key, from: result)
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Remove a top-level YAML section by key
    private func removeYAMLSection(_ key: String, from content: String) -> String {
        var result = content
        
        // Pattern to match the section start
        guard let startRange = result.range(of: "\n\(key)") ?? result.range(of: key) else {
            return result
        }
        
        guard startRange.upperBound < result.endIndex else {
            result.removeSubrange(startRange.lowerBound..<result.endIndex)
            return result
        }
        
        let searchStart = result.index(after: startRange.upperBound)
        guard searchStart < result.endIndex else {
            result.removeSubrange(startRange.lowerBound..<result.endIndex)
            return result
        }
        
        // Find the next top-level key (line starting with non-whitespace followed by colon)
        let afterSection = result[searchStart...]
        let pattern = #"(?m)^[a-z][\w-]*:"#
        
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let firstMatch = regex.firstMatch(in: result, options: [], range: NSRange(afterSection.startIndex..<afterSection.endIndex, in: result)),
           let matchRange = Range(firstMatch.range, in: result) {
            result.removeSubrange(startRange.lowerBound..<matchRange.lowerBound)
        } else {
            // No more top-level keys, remove to end
            result.removeSubrange(startRange.lowerBound..<result.endIndex)
        }
        
        return result
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
