import Foundation

public enum CustomProviderType: String, CaseIterable, Codable, Identifiable, Sendable {
    case openaiCompatibility = "openai-compatibility"
    case claudeCompatibility = "claude-api-key"
    case geminiCompatibility = "gemini-api-key"
    case codexCompatibility = "codex-api-key"
    case glmCompatibility = "glm-api-key"
    case clinePass = "clinepass"

    public var id: String { rawValue }

    public var requiresBaseURL: Bool {
        self == .openaiCompatibility || self == .codexCompatibility
    }

    public var defaultBaseURL: String? {
        switch self {
        case .claudeCompatibility: "https://api.anthropic.com"
        case .geminiCompatibility: "https://generativelanguage.googleapis.com"
        case .glmCompatibility: "https://api.z.ai"
        case .clinePass: "https://api.cline.bot/api/v1"
        case .openaiCompatibility, .codexCompatibility: nil
        }
    }
    public var supportsModelMapping: Bool {
        self == .openaiCompatibility || self == .claudeCompatibility || self == .clinePass
    }
    public var supportsCustomHeaders: Bool {
        switch self {
        case .openaiCompatibility, .claudeCompatibility, .geminiCompatibility, .codexCompatibility: true
        case .glmCompatibility, .clinePass: false
        }
    }
}

public struct CustomAPIKeyEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var apiKey: String
    public var proxyURL: String?

    public init(id: UUID = UUID(), apiKey: String, proxyURL: String? = nil) {
        self.id = id
        self.apiKey = apiKey
        self.proxyURL = proxyURL
    }

    enum CodingKeys: String, CodingKey {
        case id
        case apiKey = "api-key"
        case proxyURL = "proxy-url"
    }

    public var maskedKey: String {
        guard apiKey.count > 12 else { return String(repeating: "•", count: apiKey.count) }
        return "\(apiKey.prefix(8))...\(apiKey.suffix(4))"
    }
}

public struct ModelMapping: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var alias: String
    public var thinkingBudget: String?

    public init(id: UUID = UUID(), name: String, alias: String, thinkingBudget: String? = nil) {
        self.id = id
        self.name = name
        self.alias = alias
        self.thinkingBudget = thinkingBudget
    }

    enum CodingKeys: String, CodingKey {
        case id, name, alias
        case thinkingBudget = "thinking-budget"
    }

    public var effectiveAlias: String {
        guard let thinkingBudget, !thinkingBudget.isEmpty else { return alias }
        return "\(alias)(\(thinkingBudget))"
    }
}

public enum CustomProviderValidationIssue: Equatable, Sendable {
    case nameRequired
    case duplicateName
    case baseURLRequired
    case invalidBaseURL
    case apiKeyRequired
    case emptyAPIKey(Int)
    case clinePassSingleKey
    case clinePassModelsRequired
    case invalidHeaderName
    case invalidHeaderValue
    case duplicateHeaderName
}

public struct CustomHeader: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var key: String
    public var value: String

    public init(id: UUID = UUID(), key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }

    private static let validNameSpecials = Set("!#$%&'*+-.^_`|~")
    private static let optionalWhitespace = CharacterSet(charactersIn: " \t")

    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || validNameSpecials.contains($0))
        }
    }
    public static func isValidValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value == 0x09 || (0x20...0x7e).contains($0.value) }
    }
    public var normalized: Self {
        Self(id: id, key: key.trimmingCharacters(in: Self.optionalWhitespace), value: value.trimmingCharacters(in: Self.optionalWhitespace))
    }
    public static func canonicalized(_ headers: [Self]) -> [Self] {
        headers.map(\.normalized).filter { !$0.key.isEmpty }
    }
    public static func validationIssues(in headers: [Self]) -> [CustomProviderValidationIssue] {
        var issues: [CustomProviderValidationIssue] = []
        var names = Set<String>()
        for header in headers {
            if !isValidName(header.key), !issues.contains(.invalidHeaderName) {
                issues.append(.invalidHeaderName)
            }
            if !isValidValue(header.value), !issues.contains(.invalidHeaderValue) {
                issues.append(.invalidHeaderValue)
            }
            if !names.insert(header.key.lowercased()).inserted,
               !issues.contains(.duplicateHeaderName) {
                issues.append(.duplicateHeaderName)
            }
        }
        return issues
    }
}

public struct CustomProvider: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var type: CustomProviderType
    public var baseURL: String
    public var prefix: String?
    public var apiKeys: [CustomAPIKeyEntry]
    public var models: [ModelMapping]
    public var headers: [CustomHeader]
    public var limitToSelectedModels: Bool
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
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
        case id, name, type, prefix, models, headers
        case baseURL = "base-url"; case apiKeys = "api-keys"
        case limitToSelectedModels = "limit-to-selected-models"; case isEnabled = "is-enabled"
        case createdAt = "created-at"; case updatedAt = "updated-at"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(CustomProviderType.self, forKey: .type)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix)
        apiKeys = try c.decodeIfPresent([CustomAPIKeyEntry].self, forKey: .apiKeys) ?? []
        models = try c.decodeIfPresent([ModelMapping].self, forKey: .models) ?? []
        headers = try c.decodeIfPresent([CustomHeader].self, forKey: .headers) ?? []
        limitToSelectedModels = try c.decodeIfPresent(Bool.self, forKey: .limitToSelectedModels) ?? true
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public var identity: String { name }

    public var effectiveHeaders: [CustomHeader] {
        guard type.supportsCustomHeaders else { return [] }
        return CustomHeader.canonicalized(headers).filter { CustomHeader.isValidName($0.key) && CustomHeader.isValidValue($0.value) }
    }
    public func validationIssues() -> [CustomProviderValidationIssue] {
        var issues: [CustomProviderValidationIssue] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.nameRequired)
        }
        if type.requiresBaseURL && baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.baseURLRequired)
        }
        if !baseURL.isEmpty,
           let url = URL(string: baseURL),
           url.scheme == nil || url.host == nil {
            issues.append(.invalidBaseURL)
        }
        if apiKeys.isEmpty { issues.append(.apiKeyRequired) }
        for (index, key) in apiKeys.enumerated()
            where key.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.emptyAPIKey(index + 1))
        }
        if type == .clinePass && apiKeys.count != 1 { issues.append(.clinePassSingleKey) }
        if type == .clinePass && models.isEmpty { issues.append(.clinePassModelsRequired) }
        if type.supportsCustomHeaders { issues += CustomHeader.validationIssues(in: CustomHeader.canonicalized(headers)) }
        return issues
    }
}
