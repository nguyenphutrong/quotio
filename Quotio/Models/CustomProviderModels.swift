//
//  CustomProviderModels.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Models for custom AI providers (OpenAI-compatible, Claude, Gemini, Codex compatibility modes)
//

import Foundation
import SwiftUI

// MARK: - Custom Provider Type

/// Types of compatibility providers supported by CLIProxyAPI
enum CustomProviderType: String, CaseIterable, Codable, Identifiable, Sendable {
    case openaiCompatibility = "openai-compatibility"
    case claudeCompatibility = "claude-api-key"
    case geminiCompatibility = "gemini-api-key"
    case codexCompatibility = "codex-api-key"
    case glmCompatibility = "glm-api-key"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openaiCompatibility: return "OpenAI Compatible"
        case .claudeCompatibility: return "Claude Compatible"
        case .geminiCompatibility: return "Gemini Compatible"
        case .codexCompatibility: return "Codex Compatible"
        case .glmCompatibility: return "GLM Compatible"
        }
    }
    
    @MainActor
    var localizedDisplayName: String {
        switch self {
        case .openaiCompatibility: return "customProviders.type.openai".localized()
        case .claudeCompatibility: return "customProviders.type.claude".localized()
        case .geminiCompatibility: return "customProviders.type.gemini".localized()
        case .codexCompatibility: return "customProviders.type.codex".localized()
        case .glmCompatibility: return "customProviders.type.glm".localized()
        }
    }
    
    var description: String {
        switch self {
        case .openaiCompatibility:
            return "OpenRouter, Ollama, LM Studio, vLLM, or any OpenAI-compatible API"
        case .claudeCompatibility:
            return "Anthropic API or Claude-compatible providers"
        case .geminiCompatibility:
            return "Google Gemini API or Gemini-compatible providers"
        case .codexCompatibility:
            return "Custom Codex-compatible endpoints"
        case .glmCompatibility:
            return "GLM (BigModel.cn) API"
        }
    }
    
    @MainActor
    var localizedDescription: String {
        switch self {
        case .openaiCompatibility: return "customProviders.type.openai.desc".localized()
        case .claudeCompatibility: return "customProviders.type.claude.desc".localized()
        case .geminiCompatibility: return "customProviders.type.gemini.desc".localized()
        case .codexCompatibility: return "customProviders.type.codex.desc".localized()
        case .glmCompatibility: return "customProviders.type.glm.desc".localized()
        }
    }
    
    var providerIconName: String {
        switch self {
        case .openaiCompatibility: return "openai"
        case .claudeCompatibility: return "claude"
        case .geminiCompatibility: return "gemini"
        case .codexCompatibility: return "openai"
        case .glmCompatibility: return "glm"
        }
    }
    
    var menuBarIconName: String {
        switch self {
        case .openaiCompatibility: return "openai-menubar"
        case .claudeCompatibility: return "claude-menubar"
        case .geminiCompatibility: return "gemini-menubar"
        case .codexCompatibility: return "openai-menubar"
        case .glmCompatibility: return "glm-menubar"
        }
    }
    
    var color: Color {
        switch self {
        case .openaiCompatibility: return Color(hex: "10A37F") ?? .green
        case .claudeCompatibility: return Color(hex: "D97706") ?? .orange
        case .geminiCompatibility: return Color(hex: "4285F4") ?? .blue
        case .codexCompatibility: return Color(hex: "10A37F") ?? .green
        case .glmCompatibility: return Color(hex: "3B82F6") ?? .blue
        }
    }
    
    /// Whether this provider type requires a base URL
    var requiresBaseURL: Bool {
        switch self {
        case .openaiCompatibility, .codexCompatibility:
            return true
        case .claudeCompatibility, .geminiCompatibility, .glmCompatibility:
            return false // Has default base URL
        }
    }
    
    /// Default base URL for this provider type (if any)
    var defaultBaseURL: String? {
        switch self {
        case .claudeCompatibility:
            return "https://api.anthropic.com"
        case .geminiCompatibility:
            return "https://generativelanguage.googleapis.com"
        case .glmCompatibility:
            return "https://bigmodel.cn"
        case .openaiCompatibility, .codexCompatibility:
            return nil
        }
    }
    
    /// Whether this provider type supports model alias mapping
    var supportsModelMapping: Bool {
        switch self {
        case .openaiCompatibility, .claudeCompatibility:
            return true
        case .geminiCompatibility, .codexCompatibility, .glmCompatibility:
            return false
        }
    }

    /// Whether this provider type supports custom headers
    var supportsCustomHeaders: Bool {
        true
    }

    /// Whether the provider expects a versioned OpenAI-style API prefix.
    var usesVersionedAPIBaseURL: Bool {
        switch self {
        case .openaiCompatibility, .codexCompatibility:
            return true
        case .claudeCompatibility, .geminiCompatibility, .glmCompatibility:
            return false
        }
    }

    func normalizedStoredBaseURL(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultBaseURL ?? "" }

        guard var components = URLComponents(string: trimmed) else {
            return trimmed.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        }

        var normalizedPath = components.path.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        if usesVersionedAPIBaseURL, normalizedPath.lowercased().hasSuffix("/v1") {
            normalizedPath.removeLast(3)
        }

        components.path = normalizedPath
        components.percentEncodedQuery = nil
        components.fragment = nil

        return components.string?.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
            ?? trimmed.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }

    func apiBaseURL(from storedBaseURL: String) -> String {
        let normalized = normalizedStoredBaseURL(from: storedBaseURL)
        guard usesVersionedAPIBaseURL else { return normalized }
        guard !normalized.isEmpty else { return normalized }
        return normalized + "/v1"
    }

    func modelsEndpointURL(from storedBaseURL: String) -> URL? {
        let effectiveBaseURL = apiBaseURL(from: storedBaseURL)
        guard let url = URL(string: effectiveBaseURL) else { return nil }
        return url.appendingPathComponent("models")
    }
}

// MARK: - API Key Entry

/// A single API key with optional proxy configuration
struct CustomAPIKeyEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var apiKey: String
    var proxyURL: String?
    
    init(id: UUID = UUID(), apiKey: String, proxyURL: String? = nil) {
        self.id = id
        self.apiKey = apiKey
        self.proxyURL = proxyURL
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case apiKey = "api-key"
        case proxyURL = "proxy-url"
    }
    
    /// Masked API key for display (shows first 8 and last 4 characters)
    var maskedKey: String {
        guard apiKey.count > 12 else {
            return String(repeating: "•", count: apiKey.count)
        }
        let prefix = String(apiKey.prefix(8))
        let suffix = String(apiKey.suffix(4))
        return "\(prefix)...\(suffix)"
    }
}

// MARK: - Model Mapping

/// Maps an upstream model name to a local alias with optional thinking budget
struct ModelMapping: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var alias: String
    var thinkingBudget: String?
    
    init(id: UUID = UUID(), name: String, alias: String, thinkingBudget: String? = nil) {
        self.id = id
        self.name = name
        self.alias = alias
        self.thinkingBudget = thinkingBudget
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, alias
        case thinkingBudget = "thinking-budget"
    }
    
    var effectiveAlias: String {
        guard let budget = thinkingBudget, !budget.isEmpty else { return alias }
        return "\(alias)(\(budget))"
    }
}

// MARK: - Custom Header

/// A custom HTTP header for a user-defined provider
struct CustomHeader: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var key: String
    var value: String
    
    init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
    
    enum CodingKeys: String, CodingKey {
        case id, key, value
    }
}

// MARK: - Custom Provider

/// A user-defined custom provider configuration
struct CustomProvider: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var type: CustomProviderType
    var baseURL: String
    var prefix: String?
    var apiKeys: [CustomAPIKeyEntry]
    var models: [ModelMapping]
    var headers: [CustomHeader]  // Optional custom headers for upstream requests
    var limitToSelectedModels: Bool
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        type: CustomProviderType,
        baseURL: String = "",
        prefix: String? = nil,
        apiKeys: [CustomAPIKeyEntry] = [],
        models: [ModelMapping] = [],
        headers: [CustomHeader] = [],
        limitToSelectedModels: Bool = true,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.type = type
        let inputBaseURL = baseURL.isEmpty ? (type.defaultBaseURL ?? "") : baseURL
        self.baseURL = type.normalizedStoredBaseURL(from: inputBaseURL)
        self.prefix = prefix
        self.apiKeys = apiKeys
        self.models = models
        self.headers = headers
        self.limitToSelectedModels = limitToSelectedModels
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, type, prefix
        case baseURL = "base-url"
        case apiKeys = "api-keys"
        case models, headers
        case limitToSelectedModels = "limit-to-selected-models"
        case isEnabled = "is-enabled"
        case createdAt = "created-at"
        case updatedAt = "updated-at"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(CustomProviderType.self, forKey: .type)
        let decodedBaseURL = try container.decode(String.self, forKey: .baseURL)
        baseURL = type.normalizedStoredBaseURL(from: decodedBaseURL)
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix)
        apiKeys = try container.decodeIfPresent([CustomAPIKeyEntry].self, forKey: .apiKeys) ?? []
        models = try container.decodeIfPresent([ModelMapping].self, forKey: .models) ?? []
        headers = try container.decodeIfPresent([CustomHeader].self, forKey: .headers) ?? []
        limitToSelectedModels = try container.decodeIfPresent(Bool.self, forKey: .limitToSelectedModels) ?? true
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(type.normalizedStoredBaseURL(from: baseURL), forKey: .baseURL)
        try container.encodeIfPresent(prefix, forKey: .prefix)
        try container.encode(apiKeys, forKey: .apiKeys)
        try container.encode(models, forKey: .models)
        try container.encode(headers, forKey: .headers)
        try container.encode(limitToSelectedModels, forKey: .limitToSelectedModels)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
    
    /// Validate the provider configuration
    func validate() -> [String] {
        var errors: [String] = []
        
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Provider name is required")
        }
        
        if type.requiresBaseURL && baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Base URL is required for \(type.displayName)")
        }
        
        if !baseURL.isEmpty {
            if let url = URL(string: baseURL), url.scheme == nil || url.host == nil {
                errors.append("Invalid base URL format")
            }
        }
        
        if apiKeys.isEmpty {
            errors.append("At least one API key is required")
        }
        
        for (index, key) in apiKeys.enumerated() {
            if key.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                errors.append("API key #\(index + 1) is empty")
            }
        }
        
        return errors
    }
    
    /// Check if provider is valid
    var isValid: Bool {
        validate().isEmpty
    }
}

// MARK: - YAML Generation Extensions

extension CustomProvider {
    var normalizedStoredBaseURL: String {
        type.normalizedStoredBaseURL(from: baseURL)
    }

    var effectiveAPIBaseURL: String {
        type.apiBaseURL(from: baseURL)
    }

    var modelsEndpointURL: URL? {
        type.modelsEndpointURL(from: baseURL)
    }

    /// Generate YAML config block for this provider
    func toYAMLBlock() -> String {
        switch type {
        case .openaiCompatibility:
            return generateOpenAICompatibilityYAML()
        case .claudeCompatibility:
            return generateClaudeCompatibilityYAML()
        case .geminiCompatibility:
            return generateGeminiCompatibilityYAML()
        case .codexCompatibility:
            return generateCodexCompatibilityYAML()
        case .glmCompatibility:
            return generateGlmCompatibilityYAML()
        }
    }

    private func generateOpenAICompatibilityYAML() -> String {
        var yaml = "  - name: \"\(escapedName)\"\n"
        yaml += "    base-url: \"\(effectiveAPIBaseURL)\"\n"

        if let prefix = prefix, !prefix.isEmpty {
            yaml += "    prefix: \"\(prefix)\"\n"
        }

        appendHeadersYAML(to: &yaml)

        if !apiKeys.isEmpty {
            yaml += "    api-key-entries:\n"
            for key in apiKeys {
                yaml += "      - api-key: \"\(key.apiKey)\"\n"
                if let proxyURL = key.proxyURL, !proxyURL.isEmpty {
                    yaml += "        proxy-url: \"\(proxyURL)\"\n"
                }
            }
        }
        
        if !models.isEmpty {
            yaml += "    models:\n"
            for model in models {
                yaml += "      - name: \"\(model.name)\"\n"
                yaml += "        alias: \"\(model.effectiveAlias)\"\n"
            }
        }
        
        return yaml
    }
    
    private func generateClaudeCompatibilityYAML() -> String {
        var yaml = ""
        for key in apiKeys {
            yaml += "  - api-key: \"\(key.apiKey)\"\n"

            // Only include base-url if not default
            if !baseURL.isEmpty && baseURL != type.defaultBaseURL {
                yaml += "    base-url: \"\(baseURL)\"\n"
            }

            if let prefix = prefix, !prefix.isEmpty {
                yaml += "    prefix: \"\(prefix)\"\n"
            }

            appendHeadersYAML(to: &yaml)

            if let proxyURL = key.proxyURL, !proxyURL.isEmpty {
                yaml += "    proxy-url: \"\(proxyURL)\"\n"
            }
            
            if !models.isEmpty {
                yaml += "    models:\n"
                for model in models {
                    yaml += "      - name: \"\(model.name)\"\n"
                    yaml += "        alias: \"\(model.effectiveAlias)\"\n"
                }
            }
        }
        return yaml
    }
    
    private func generateGeminiCompatibilityYAML() -> String {
        var yaml = ""
        for key in apiKeys {
            yaml += "  - api-key: \"\(key.apiKey)\"\n"

            // Only include base-url if not default
            if !baseURL.isEmpty && baseURL != type.defaultBaseURL {
                yaml += "    base-url: \"\(baseURL)\"\n"
            }

            if let prefix = prefix, !prefix.isEmpty {
                yaml += "    prefix: \"\(prefix)\"\n"
            }

            appendHeadersYAML(to: &yaml)
            
            if let proxyURL = key.proxyURL, !proxyURL.isEmpty {
                yaml += "    proxy-url: \"\(proxyURL)\"\n"
            }
        }
        return yaml
    }
    
    private func generateCodexCompatibilityYAML() -> String {
        var yaml = ""
        for key in apiKeys {
            yaml += "  - api-key: \"\(key.apiKey)\"\n"
            yaml += "    base-url: \"\(effectiveAPIBaseURL)\"\n"

            if let prefix = prefix, !prefix.isEmpty {
                yaml += "    prefix: \"\(prefix)\"\n"
            }

            appendHeadersYAML(to: &yaml)

            if let proxyURL = key.proxyURL, !proxyURL.isEmpty {
                yaml += "    proxy-url: \"\(proxyURL)\"\n"
            }
        }
        return yaml
    }

    private func generateGlmCompatibilityYAML() -> String {
        var yaml = ""
        for key in apiKeys {
            yaml += "  - api-key: \"\(key.apiKey)\"\n"

            if !baseURL.isEmpty && baseURL != type.defaultBaseURL {
                yaml += "    base-url: \"\(baseURL)\"\n"
            }

            if let prefix = prefix, !prefix.isEmpty {
                yaml += "    prefix: \"\(prefix)\"\n"
            }

            appendHeadersYAML(to: &yaml)

            if let proxyURL = key.proxyURL, !proxyURL.isEmpty {
                yaml += "    proxy-url: \"\(proxyURL)\"\n"
            }
        }
        return yaml
    }

    private func appendHeadersYAML(to yaml: inout String, indent: String = "    ") {
        let validHeaders = headers.compactMap { header -> (key: String, value: String)? in
            let normalizedKey = header.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty else { return nil }
            return (normalizedKey, header.value)
        }

        guard !validHeaders.isEmpty else { return }

        yaml += "\(indent)headers:\n"
        for header in validHeaders {
            yaml += "\(indent)  \"\(escapeYAMLString(header.key))\": \"\(escapeYAMLString(header.value))\"\n"
        }
    }
    
    private var escapedName: String {
        escapeYAMLString(name)
    }

    private func escapeYAMLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Provider Collection for YAML

extension Array where Element == CustomProvider {
    /// Generate complete YAML sections for all custom providers grouped by type
    func toYAMLSections() -> String {
        var yaml = ""
        
        // Group by type
        let grouped = Dictionary(grouping: self.filter(\.isEnabled), by: \.type)
        
        // OpenAI Compatibility
        if let openaiProviders = grouped[.openaiCompatibility], !openaiProviders.isEmpty {
            yaml += "\nopenai-compatibility:\n"
            for provider in openaiProviders {
                yaml += provider.toYAMLBlock()
            }
        }
        
        // Claude Compatibility
        if let claudeProviders = grouped[.claudeCompatibility], !claudeProviders.isEmpty {
            yaml += "\nclaude-api-key:\n"
            for provider in claudeProviders {
                yaml += provider.toYAMLBlock()
            }
        }
        
        // Gemini Compatibility
        if let geminiProviders = grouped[.geminiCompatibility], !geminiProviders.isEmpty {
            yaml += "\ngemini-api-key:\n"
            for provider in geminiProviders {
                yaml += provider.toYAMLBlock()
            }
        }
        
        // Codex Compatibility
        if let codexProviders = grouped[.codexCompatibility], !codexProviders.isEmpty {
            yaml += "\ncodex-api-key:\n"
            for provider in codexProviders {
                yaml += provider.toYAMLBlock()
            }
        }

        // GLM Compatibility
        if let glmProviders = grouped[.glmCompatibility], !glmProviders.isEmpty {
            yaml += "\nglm-api-key:\n"
            for provider in glmProviders {
                yaml += provider.toYAMLBlock()
            }
        }

        return yaml
    }
}
