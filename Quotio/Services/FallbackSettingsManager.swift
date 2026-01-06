//
//  FallbackSettingsManager.swift
//  Quotio - Model Fallback Configuration Manager
//

import Foundation
import Observation

@MainActor
@Observable
final class FallbackSettingsManager {
    static let shared = FallbackSettingsManager()

    private let defaults = UserDefaults.standard
    private let configurationKey = "fallbackConfiguration"

    /// The current fallback configuration
    var configuration: FallbackConfiguration {
        didSet {
            persist()
            onConfigurationChanged?(configuration)
        }
    }

    /// Callback when configuration changes
    var onConfigurationChanged: ((FallbackConfiguration) -> Void)?

    private init() {
        if let data = defaults.data(forKey: configurationKey),
           let decoded = try? JSONDecoder().decode(FallbackConfiguration.self, from: data) {
            self.configuration = decoded
        } else {
            self.configuration = FallbackConfiguration()
        }
    }

    // MARK: - Global Settings

    /// Whether fallback is globally enabled
    var isEnabled: Bool {
        get { configuration.isEnabled }
        set {
            configuration.isEnabled = newValue
        }
    }

    // MARK: - Virtual Model Management

    /// All virtual models
    var virtualModels: [VirtualModel] {
        configuration.virtualModels
    }

    /// Add a new virtual model
    func addVirtualModel(name: String) -> VirtualModel {
        let model = VirtualModel(name: name)
        configuration.virtualModels.append(model)
        return model
    }

    /// Remove a virtual model by ID
    func removeVirtualModel(id: UUID) {
        configuration.virtualModels.removeAll { $0.id == id }
    }

    /// Update a virtual model
    func updateVirtualModel(_ model: VirtualModel) {
        if let index = configuration.virtualModels.firstIndex(where: { $0.id == model.id }) {
            configuration.virtualModels[index] = model
        }
    }

    /// Find a virtual model by name
    func findVirtualModel(name: String) -> VirtualModel? {
        configuration.findVirtualModel(name: name)
    }

    /// Toggle virtual model enabled state
    func toggleVirtualModel(id: UUID) {
        if let index = configuration.virtualModels.firstIndex(where: { $0.id == id }) {
            configuration.virtualModels[index].isEnabled.toggle()
        }
    }

    /// Rename a virtual model
    func renameVirtualModel(id: UUID, newName: String) {
        if let index = configuration.virtualModels.firstIndex(where: { $0.id == id }) {
            configuration.virtualModels[index].name = newName
        }
    }

    // MARK: - Fallback Entry Management

    /// Add a fallback entry to a virtual model
    func addFallbackEntry(to modelId: UUID, provider: AIProvider, modelName: String) {
        guard let index = configuration.virtualModels.firstIndex(where: { $0.id == modelId }) else { return }
        configuration.virtualModels[index].addEntry(provider: provider, modelId: modelName)
    }

    /// Remove a fallback entry from a virtual model
    func removeFallbackEntry(from modelId: UUID, entryId: UUID) {
        guard let index = configuration.virtualModels.firstIndex(where: { $0.id == modelId }) else { return }
        configuration.virtualModels[index].removeEntry(id: entryId)
    }

    /// Move fallback entry within a virtual model
    func moveFallbackEntry(in modelId: UUID, from source: IndexSet, to destination: Int) {
        guard let index = configuration.virtualModels.firstIndex(where: { $0.id == modelId }) else { return }
        configuration.virtualModels[index].moveEntry(from: source, to: destination)
    }

    // MARK: - Fallback Resolution

    /// Resolve a model name to the best available provider + model combination
    /// - Parameters:
    ///   - modelName: The requested model name (could be a virtual model name)
    ///   - quotaChecker: A closure that checks if a provider has available quota for a model
    /// - Returns: The resolved provider and model, or nil if no fallback is available
    func resolveModel(
        modelName: String,
        quotaChecker: (AIProvider, String) -> Bool
    ) -> FallbackResolution? {
        // If fallback is disabled, return nil (use original model)
        guard isEnabled else { return nil }

        // Find matching virtual model
        guard let virtualModel = findVirtualModel(name: modelName) else { return nil }

        // Try each fallback entry in priority order
        for (index, entry) in virtualModel.sortedEntries.enumerated() {
            if quotaChecker(entry.provider, entry.modelId) {
                return FallbackResolution(
                    provider: entry.provider,
                    modelId: entry.modelId,
                    virtualModelName: modelName,
                    fallbackIndex: index
                )
            }
        }

        // No available fallback found
        return nil
    }

    /// Resolve model with async quota checker
    func resolveModel(
        modelName: String,
        quotaChecker: (AIProvider, String) async -> Bool
    ) async -> FallbackResolution? {
        guard isEnabled else { return nil }
        guard let virtualModel = findVirtualModel(name: modelName) else { return nil }

        for (index, entry) in virtualModel.sortedEntries.enumerated() {
            if await quotaChecker(entry.provider, entry.modelId) {
                return FallbackResolution(
                    provider: entry.provider,
                    modelId: entry.modelId,
                    virtualModelName: modelName,
                    fallbackIndex: index
                )
            }
        }

        return nil
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: configurationKey)
    }

    /// Export configuration as JSON string
    func exportConfiguration() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(configuration) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Import configuration from JSON string
    func importConfiguration(from json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FallbackConfiguration.self, from: data) else {
            return false
        }
        configuration = decoded
        return true
    }

    /// Reset to default configuration
    func resetToDefaults() {
        configuration = FallbackConfiguration()
    }
}

// MARK: - Quota Checking Helpers

extension FallbackSettingsManager {
    /// Get all enabled virtual model names for display in Agent configuration
    var enabledVirtualModelNames: [String] {
        configuration.enabledModelNames
    }

    /// Check if a model name is a virtual model
    func isVirtualModel(_ name: String) -> Bool {
        configuration.virtualModels.contains { $0.name == name && $0.isEnabled }
    }

    /// Get providers that support a specific model family
    static func providersForModelFamily(_ family: String) -> [AIProvider] {
        // This maps model families to providers that support them
        switch family.lowercased() {
        case "claude", "anthropic":
            return [.antigravity, .claude, .kiro]
        case "gpt", "openai":
            return [.kiro, .codex, .copilot]
        case "gemini", "google":
            return [.antigravity, .gemini]
        default:
            return AIProvider.allCases.filter { !$0.isQuotaTrackingOnly }
        }
    }
}
