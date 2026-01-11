//
//  UniversalProviderModels.swift
//  Quotio
//

import Foundation
import SwiftUI

// MARK: - Universal Provider

struct UniversalProvider: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var name: String
    var baseURL: String
    var modelId: String
    var isBuiltIn: Bool
    var iconAssetName: String?
    var color: String
    var supportedAgents: Set<String>
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        modelId: String = "",
        isBuiltIn: Bool = false,
        iconAssetName: String? = nil,
        color: String = "#6366F1",
        supportedAgents: Set<String> = [],
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.modelId = modelId
        self.isBuiltIn = isBuiltIn
        self.iconAssetName = iconAssetName
        self.color = color
        self.supportedAgents = supportedAgents
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    var swiftUIColor: Color {
        Color(hex: color) ?? .indigo
    }
    
    var initials: String {
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
    
    func supportsAgent(_ agent: CLIAgent) -> Bool {
        supportedAgents.isEmpty || supportedAgents.contains(agent.rawValue)
    }
}

// MARK: - Active Provider State

struct ActiveProviderState: Codable, Sendable {
    var providerIdByAgent: [String: UUID]
    
    init() {
        self.providerIdByAgent = [:]
    }
    
    mutating func setActive(_ providerId: UUID, for agent: CLIAgent) {
        providerIdByAgent[agent.rawValue] = providerId
    }
    
    func activeProviderId(for agent: CLIAgent) -> UUID? {
        providerIdByAgent[agent.rawValue]
    }
}

// MARK: - Built-in Providers

extension UniversalProvider {
    static let builtInProviders: [UniversalProvider] = [
        UniversalProvider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Anthropic",
            baseURL: "https://api.anthropic.com",
            modelId: "claude-sonnet-4-20250514",
            isBuiltIn: true,
            iconAssetName: "claude",
            color: "#D97706"
        ),
        UniversalProvider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            modelId: "gpt-4o",
            isBuiltIn: true,
            iconAssetName: "codex",
            color: "#10B981"
        ),
        UniversalProvider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com",
            modelId: "gemini-2.5-pro",
            isBuiltIn: true,
            iconAssetName: "gemini",
            color: "#4285F4"
        ),
        UniversalProvider(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            modelId: "",
            isBuiltIn: true,
            iconAssetName: nil,
            color: "#6366F1"
        )
    ]
}

// MARK: - Migration Helper

extension UniversalProvider {
    init(from customProvider: CustomProvider) {
        self.id = customProvider.id
        self.name = customProvider.name
        self.baseURL = customProvider.baseURL
        self.modelId = customProvider.models.first?.name ?? ""
        self.isBuiltIn = false
        self.iconAssetName = nil
        self.color = customProvider.type.color.toHex() ?? "#6366F1"
        self.supportedAgents = []
        self.isEnabled = customProvider.isEnabled
        self.createdAt = customProvider.createdAt
        self.updatedAt = customProvider.updatedAt
    }
}

// MARK: - Color Extension

extension Color {
    func toHex() -> String? {
        guard let srgbColor = NSColor(self).usingColorSpace(.sRGB),
              let components = srgbColor.cgColor.components,
              components.count >= 3 else {
            if let grayComponents = NSColor(self).cgColor.components,
               !grayComponents.isEmpty {
                let gray = Int(grayComponents[0] * 255)
                return String(format: "#%02X%02X%02X", gray, gray, gray)
            }
            return nil
        }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
