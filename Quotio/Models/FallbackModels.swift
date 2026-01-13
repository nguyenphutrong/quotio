//
//  FallbackModels.swift
//  Quotio - Model Fallback Configuration
//

import Foundation
import SwiftUI

// MARK: - Fallback Entry

/// A single entry in a fallback chain, representing a Provider + Model combination
struct FallbackEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let provider: AIProvider
    let modelId: String
    var priority: Int

    init(id: UUID = UUID(), provider: AIProvider, modelId: String, priority: Int) {
        self.id = id
        self.provider = provider
        self.modelId = modelId
        self.priority = priority
    }

    /// Display name for UI
    var displayName: String {
        "\(provider.displayName) → \(modelId)"
    }
}

// MARK: - Virtual Model

/// A virtual model with a fallback chain
/// Example: "quotio-opus-4-5-thinking" with fallback entries:
///   1. Antigravity → gemini-claude-opus-4-5-thinking
///   2. Kiro → kiro-claude-opus-4-5-agentic
///   3. Claude Code → claude-opus-4-5-thinking
struct VirtualModel: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var fallbackEntries: [FallbackEntry]
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, fallbackEntries: [FallbackEntry] = [], isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.fallbackEntries = fallbackEntries
        self.isEnabled = isEnabled
    }

    /// Get entries sorted by priority
    var sortedEntries: [FallbackEntry] {
        fallbackEntries.sorted { $0.priority < $1.priority }
    }

    /// Add a new entry at the end of the chain
    mutating func addEntry(provider: AIProvider, modelId: String) {
        let nextPriority = (fallbackEntries.map(\.priority).max() ?? 0) + 1
        let entry = FallbackEntry(provider: provider, modelId: modelId, priority: nextPriority)
        fallbackEntries.append(entry)
    }

    /// Remove an entry by ID
    mutating func removeEntry(id: UUID) {
        fallbackEntries.removeAll { $0.id == id }
        reorderPriorities()
    }

    /// Move entry from one position to another
    mutating func moveEntry(from source: IndexSet, to destination: Int) {
        var sorted = sortedEntries
        sorted.move(fromOffsets: source, toOffset: destination)

        // Update priorities based on new order
        for (index, var entry) in sorted.enumerated() {
            entry.priority = index + 1
            if let existingIndex = fallbackEntries.firstIndex(where: { $0.id == entry.id }) {
                fallbackEntries[existingIndex].priority = entry.priority
            }
        }
    }

    /// Reorder priorities to be sequential (1, 2, 3, ...)
    private mutating func reorderPriorities() {
        let sorted = sortedEntries
        for (index, entry) in sorted.enumerated() {
            if let existingIndex = fallbackEntries.firstIndex(where: { $0.id == entry.id }) {
                fallbackEntries[existingIndex].priority = index + 1
            }
        }
    }
}

// MARK: - Fallback Configuration

/// Global fallback configuration
struct FallbackConfiguration: Codable, Sendable, Equatable {
    var isEnabled: Bool
    var virtualModels: [VirtualModel]

    init(isEnabled: Bool = false, virtualModels: [VirtualModel] = []) {
        self.isEnabled = isEnabled
        self.virtualModels = virtualModels
    }

    /// Find a virtual model by name
    func findVirtualModel(name: String) -> VirtualModel? {
        virtualModels.first { $0.name == name && $0.isEnabled }
    }

    /// Get all enabled virtual model names
    var enabledModelNames: [String] {
        virtualModels.filter(\.isEnabled).map(\.name)
    }
}
