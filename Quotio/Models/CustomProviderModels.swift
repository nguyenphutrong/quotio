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
    case clinePass = "clinepass"

    var id: String { rawValue }

    /// CLIProxyAPI section key. Kept separate from rawValue, which is persisted.
    var yamlSectionKey: String {
        switch self {
        case .clinePass:
            return CustomProviderType.openaiCompatibility.rawValue
        default:
            return rawValue
        }
    }

    var displayName: String {
        switch self {
        case .openaiCompatibility: return "OpenAI Compatible"
        case .claudeCompatibility: return "Claude Compatible"
        case .geminiCompatibility: return "Gemini Compatible"
        case .codexCompatibility: return "Codex Compatible"
        case .glmCompatibility: return "Z.ai / GLM"
        case .clinePass: return "ClinePass"
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
        case .clinePass: return "customProviders.type.clinepass".localized()
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
            return "Z.ai GLM Coding Plan API"
        case .clinePass:
            return "ClinePass subscription with OpenAI-compatible routing"
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
        case .clinePass: return "customProviders.type.clinepass.desc".localized()
        }
    }
    
    var providerIconName: String {
        switch self {
        case .openaiCompatibility: return "openai"
        case .claudeCompatibility: return "claude"
        case .geminiCompatibility: return "gemini"
        case .codexCompatibility: return "openai"
        case .glmCompatibility: return "glm"
        case .clinePass: return "clinepass"
        }
    }
    
    var menuBarIconName: String {
        switch self {
        case .openaiCompatibility: return "openai-menubar"
        case .claudeCompatibility: return "claude-menubar"
        case .geminiCompatibility: return "gemini-menubar"
        case .codexCompatibility: return "openai-menubar"
        case .glmCompatibility: return "glm-menubar"
        case .clinePass: return "clinepass-menubar"
        }
    }
    
    var color: Color {
        switch self {
        case .openaiCompatibility: return Color(hex: "10A37F") ?? .green
        case .claudeCompatibility: return Color(hex: "D97706") ?? .orange
        case .geminiCompatibility: return Color(hex: "4285F4") ?? .blue
        case .codexCompatibility: return Color(hex: "10A37F") ?? .green
        case .glmCompatibility: return Color(hex: "3B82F6") ?? .blue
        case .clinePass: return Color(hex: "61A3FA") ?? .blue
        }
    }
    
    /// Whether this provider type requires a base URL
    var requiresBaseURL: Bool {
        switch self {
        case .openaiCompatibility, .codexCompatibility:
            return true
        case .claudeCompatibility, .geminiCompatibility, .glmCompatibility, .clinePass:
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
            return "https://api.z.ai"
        case .clinePass:
            return "https://api.cline.bot/api/v1"
        case .openaiCompatibility, .codexCompatibility:
            return nil
        }
    }
    
    /// Whether this provider type supports model alias mapping
    var supportsModelMapping: Bool {
        switch self {
        case .openaiCompatibility, .claudeCompatibility, .clinePass:
            return true
        case .geminiCompatibility, .codexCompatibility, .glmCompatibility:
            return false
        }
    }

    /// Whether this provider type supports custom headers.
    /// CLIProxyAPI accepts a `headers` map for `openai-compatibility` providers (provider level)
    /// and for `claude-api-key`, `gemini-api-key`, and `codex-api-key` entries (per key).
    /// GLM and ClinePass are excluded: `glm-api-key` has no documented headers support,
    /// and ClinePass is a managed service with fixed authentication.
    var supportsCustomHeaders: Bool {
        switch self {
        case .openaiCompatibility, .claudeCompatibility, .geminiCompatibility, .codexCompatibility:
            return true
        case .glmCompatibility, .clinePass:
            return false
        }
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

/// A custom HTTP header sent with requests to the upstream provider
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

    /// Non-alphanumeric characters allowed in an HTTP header field name (RFC 7230 token)
    private static let validNameSpecials = Set("!#$%&'*+-.^_`|~")

    /// RFC 7230 optional whitespace: the only characters stripped when normalizing.
    /// Deliberately narrower than `CharacterSet.whitespaces` (which also covers
    /// U+00A0 and friends) so normalization never silently rewrites a value that
    /// validation would otherwise reject.
    private static let optionalWhitespace = CharacterSet(charactersIn: " \t")

    /// Whether the given string is a valid HTTP header field name (RFC 7230 token: ASCII letters, digits, and select punctuation)
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || validNameSpecials.contains(character))
        }
    }

    /// Whether the given string is a valid HTTP header field value (RFC 7230 `field-value`:
    /// horizontal tab, space, and visible US-ASCII).
    ///
    /// CR/LF and other control characters must be rejected rather than escaped: CFNetwork
    /// either drops such a header or folds it into the previous one, Go's outbound HTTP
    /// stack refuses to send it, and a literal newline inside a YAML scalar is folded into
    /// a space when CLIProxyAPI parses the config back — silently changing the secret.
    /// Non-ASCII is rejected because its wire encoding is not interoperable (RFC 9110 §5.5).
    static func isValidValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value <= 0x7E)
        }
    }

    /// This header in canonical form: surrounding RFC 7230 optional whitespace removed
    /// from both the name and the value.
    var normalized: CustomHeader {
        CustomHeader(
            id: id,
            key: key.trimmingCharacters(in: Self.optionalWhitespace),
            value: value.trimmingCharacters(in: Self.optionalWhitespace)
        )
    }

    /// The canonical representation of an editor-entered header list: every entry
    /// normalized, entries without a name dropped.
    ///
    /// This is the single form that may be persisted, validated, emitted into the
    /// CLIProxyAPI config, or attached to a `URLRequest` — see `CustomProvider.effectiveHeaders`.
    static func canonicalized(_ headers: [CustomHeader]) -> [CustomHeader] {
        headers.map(\.normalized).filter { !$0.key.isEmpty }
    }

    /// Validation errors for a canonical header list (as produced by `canonicalized(_:)`).
    /// Each problem is reported at most once so the alert stays readable.
    static func validationErrors(in headers: [CustomHeader]) -> [String] {
        var errors: [String] = []
        var seenNames = Set<String>()
        var reportedInvalidName = false
        var reportedInvalidValue = false
        var reportedDuplicateName = false

        for header in headers {
            if !isValidName(header.key), !reportedInvalidName {
                errors.append("customProviders.error.headerNameInvalid".localizedStatic())
                reportedInvalidName = true
            }
            if !isValidValue(header.value), !reportedInvalidValue {
                errors.append("customProviders.error.headerValueInvalid".localizedStatic())
                reportedInvalidValue = true
            }
            if !seenNames.insert(header.key.lowercased()).inserted, !reportedDuplicateName {
                errors.append("customProviders.error.headerNameDuplicate".localizedStatic())
                reportedDuplicateName = true
            }
        }

        return errors
    }
}

extension URLRequest {
    /// Attach a canonical custom header list to this request.
    ///
    /// Both outgoing request paths in the provider editor (Fetch Models and the mandatory
    /// pre-save connection test) go through here, so neither can drift from the header set
    /// that is validated, persisted, and written to the CLIProxyAPI config.
    /// - Parameter headers: headers already normalized via `CustomHeader.canonicalized(_:)`
    ///   or read from `CustomProvider.effectiveHeaders`.
    mutating func applyCustomHeaders(_ headers: [CustomHeader]) {
        for header in headers {
            setValue(header.value, forHTTPHeaderField: header.key)
        }
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
    var headers: [CustomHeader]  // Custom HTTP headers (types where supportsCustomHeaders is true)
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
        self.baseURL = baseURL.isEmpty ? (type.defaultBaseURL ?? "") : baseURL
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
        baseURL = try container.decode(String.self, forKey: .baseURL)
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
        try container.encode(baseURL, forKey: .baseURL)
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

        if type == .clinePass, apiKeys.count != 1 {
            errors.append("clinepass.error.singleKey".localizedStatic())
        }

        if type == .clinePass, models.isEmpty {
            errors.append("clinepass.error.modelsRequired".localizedStatic())
        }

        if type.supportsCustomHeaders {
            // Validate the canonical form, not the raw form: normalization happens once
            // and every consumer (YAML, model fetch, connection test) sees that same set.
            errors.append(contentsOf: CustomHeader.validationErrors(in: CustomHeader.canonicalized(headers)))
        }

        return errors
    }
    
    /// Check if provider is valid
    var isValid: Bool {
        validate().isEmpty
    }

    /// The one representation of this provider's custom headers that any consumer may use:
    /// the generated CLIProxyAPI YAML, the pre-save connection test, and the Fetch Models
    /// request all read this property, so the editor, the outgoing requests, the persisted
    /// provider, and the proxy config always agree on the exact header set.
    ///
    /// Entries are canonicalized (surrounding optional whitespace stripped, unnamed entries
    /// dropped) and then filtered to wire-safe name/value pairs. The filter is defence in
    /// depth: `validate()` refuses to save anything it would drop, but a provider decoded
    /// from storage that predates that validation must still not produce a corrupt request
    /// or an invalid config.
    var effectiveHeaders: [CustomHeader] {
        guard type.supportsCustomHeaders else { return [] }
        return CustomHeader.canonicalized(headers).filter {
            CustomHeader.isValidName($0.key) && CustomHeader.isValidValue($0.value)
        }
    }
}

// MARK: - YAML Generation Extensions

extension CustomProvider {
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
        case .clinePass:
            return generateOpenAICompatibilityYAML()
        }
    }

    /// Render the custom headers map at the given indentation level (in spaces)
    private func headersYAML(indent: Int) -> String {
        let entries = effectiveHeaders
        guard !entries.isEmpty else { return "" }

        let pad = String(repeating: " ", count: indent)
        var yaml = "\(pad)headers:\n"
        for header in entries {
            yaml += "\(pad)  \"\(Self.escapedYAMLString(header.key))\": \"\(Self.escapedYAMLString(header.value))\"\n"
        }
        return yaml
    }

    /// Escape a string for a YAML double-quoted scalar.
    ///
    /// Covers the complete double-quoted escape set rather than just `\` and `"`, so the
    /// emitted config round-trips to the exact input string. Without this a literal CR/LF
    /// is folded into a space by the YAML parser (silently changing a secret) and other C0
    /// controls make the generated CLIProxyAPI config unparseable. Header names and values
    /// carrying such characters are already rejected before persistence; this keeps the
    /// emitter correct on its own for any string it is handed.
    static func escapedYAMLString(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.unicodeScalars.count)

        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\u{00}": escaped += "\\0"
            case "\u{07}": escaped += "\\a"
            case "\u{08}": escaped += "\\b"
            case "\u{09}": escaped += "\\t"
            case "\u{0A}": escaped += "\\n"
            case "\u{0B}": escaped += "\\v"
            case "\u{0C}": escaped += "\\f"
            case "\u{0D}": escaped += "\\r"
            case "\u{1B}": escaped += "\\e"
            case "\u{85}": escaped += "\\N"
            case "\u{A0}": escaped += "\\_"
            case "\u{2028}": escaped += "\\L"
            case "\u{2029}": escaped += "\\P"
            default:
                // Remaining C0/C1 controls and DEL have no dedicated escape.
                if scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value) {
                    escaped += String(format: "\\x%02X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }

        return escaped
    }

    private func generateOpenAICompatibilityYAML() -> String {
        var yaml = "  - name: \"\(escapedName)\"\n"
        yaml += "    base-url: \"\(baseURL)\"\n"

        if let prefix = prefix, !prefix.isEmpty {
            yaml += "    prefix: \"\(prefix)\"\n"
        }

        // Provider-level custom headers (CLIProxyAPI OpenAICompatibility.Headers)
        yaml += headersYAML(indent: 4)

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

            // Per-key custom headers (CLIProxyAPI ClaudeKey.Headers)
            yaml += headersYAML(indent: 4)

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

            // Per-key custom headers (CLIProxyAPI GeminiKey.Headers)
            yaml += headersYAML(indent: 4)

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
            yaml += "    base-url: \"\(baseURL)\"\n"

            if let prefix = prefix, !prefix.isEmpty {
                yaml += "    prefix: \"\(prefix)\"\n"
            }

            // Per-key custom headers (CLIProxyAPI CodexKey.Headers)
            yaml += headersYAML(indent: 4)

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

            if let proxyURL = key.proxyURL, !proxyURL.isEmpty {
                yaml += "    proxy-url: \"\(proxyURL)\"\n"
            }
        }
        return yaml
    }
    
    private var escapedName: String {
        name.replacingOccurrences(of: "\"", with: "\\\"")
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
        let openaiProviders = (grouped[.openaiCompatibility] ?? []) + (grouped[.clinePass] ?? [])
        if !openaiProviders.isEmpty {
            yaml += "\n\(CustomProviderType.openaiCompatibility.yamlSectionKey):\n"
            for provider in openaiProviders {
                yaml += provider.toYAMLBlock()
            }
        }
        
        // Claude Compatibility
        if let claudeProviders = grouped[.claudeCompatibility], !claudeProviders.isEmpty {
            yaml += "\n\(CustomProviderType.claudeCompatibility.yamlSectionKey):\n"
            for provider in claudeProviders {
                yaml += provider.toYAMLBlock()
            }
        }
        
        // Gemini Compatibility
        if let geminiProviders = grouped[.geminiCompatibility], !geminiProviders.isEmpty {
            yaml += "\n\(CustomProviderType.geminiCompatibility.yamlSectionKey):\n"
            for provider in geminiProviders {
                yaml += provider.toYAMLBlock()
            }
        }
        
        // Codex Compatibility
        if let codexProviders = grouped[.codexCompatibility], !codexProviders.isEmpty {
            yaml += "\n\(CustomProviderType.codexCompatibility.yamlSectionKey):\n"
            for provider in codexProviders {
                yaml += provider.toYAMLBlock()
            }
        }

        // GLM Compatibility
        if let glmProviders = grouped[.glmCompatibility], !glmProviders.isEmpty {
            yaml += "\n\(CustomProviderType.glmCompatibility.yamlSectionKey):\n"
            for provider in glmProviders {
                yaml += provider.toYAMLBlock()
            }
        }

        return yaml
    }
}
