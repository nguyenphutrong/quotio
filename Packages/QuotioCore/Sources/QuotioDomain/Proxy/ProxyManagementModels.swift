import Foundation

public struct ManagedAuthFile: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let provider: String
    public let label: String?
    public let status: String
    public let statusMessage: String?
    public let disabled: Bool
    public let unavailable: Bool
    public let runtimeOnly: Bool?
    public let source: String?
    public let path: String?
    public let email: String?
    public let accountType: String?
    public let account: String?
    public let authIndex: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let lastRefresh: String?

    public init(
        id: String,
        name: String,
        provider: String,
        label: String? = nil,
        status: String,
        statusMessage: String? = nil,
        disabled: Bool,
        unavailable: Bool,
        runtimeOnly: Bool? = nil,
        source: String? = nil,
        path: String? = nil,
        email: String? = nil,
        accountType: String? = nil,
        account: String? = nil,
        authIndex: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        lastRefresh: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.label = label
        self.status = status
        self.statusMessage = statusMessage
        self.disabled = disabled
        self.unavailable = unavailable
        self.runtimeOnly = runtimeOnly
        self.source = source
        self.path = path
        self.email = email
        self.accountType = accountType
        self.account = account
        self.authIndex = authIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRefresh = lastRefresh
    }

    enum CodingKeys: String, CodingKey {
        case id, name, provider, label, status, disabled, unavailable, source, path, email, account
        case authIndex = "auth_index"
        case statusMessage = "status_message"
        case runtimeOnly = "runtime_only"
        case accountType = "account_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastRefresh = "last_refresh"
    }

    public var providerID: QuotaProvider? {
        provider == "copilot" ? .copilot : QuotaProvider(rawValue: provider)
    }

    public var quotaLookupKey: String {
        if providerID == .codex {
            return name.removingProviderFilename(prefix: "codex-")
        }
        if providerID == .copilot {
            if let account = account?.nilIfBlank {
                return account
            }
            let filenameKey = name.removingProviderFilename(prefix: "github-copilot-")
            if !filenameKey.isEmpty {
                return filenameKey
            }
        }
        if let email = email?.nilIfBlank { return email }
        if let account = account?.nilIfBlank { return account }
        return name.removingProviderFilename(prefix: "github-copilot-")
    }

    public var menuBarAccountKey: String {
        let key = quotaLookupKey
        return key.isEmpty ? name : key
    }

    public var isReady: Bool {
        status == "ready" && !disabled && !unavailable
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(disabled)
        hasher.combine(status)
    }

    public static func == (lhs: ManagedAuthFile, rhs: ManagedAuthFile) -> Bool {
        lhs.id == rhs.id && lhs.disabled == rhs.disabled && lhs.status == rhs.status
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func removingProviderFilename(prefix: String) -> String {
        var key = self
        if key.hasPrefix(prefix) { key.removeFirst(prefix.count) }
        if key.hasSuffix(".json") { key.removeLast(".json".count) }
        return key
    }
}

public struct ManagedModelInfo: Codable, Equatable, Sendable {
    public let id: String
    public let ownedBy: String?
    public let type: String?

    public init(id: String, ownedBy: String? = nil, type: String? = nil) {
        self.id = id
        self.ownedBy = ownedBy
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case id, type
        case ownedBy = "owned_by"
    }
}

public struct ProxyUsageStats: Codable, Equatable, Sendable {
    public let usage: ProxyUsageData?
    public let failedRequests: Int?

    enum CodingKeys: String, CodingKey {
        case usage
        case failedRequests = "failed_requests"
    }
}

public struct ProxyUsageData: Codable, Equatable, Sendable {
    public let totalRequests: Int?
    public let successCount: Int?
    public let failureCount: Int?
    public let totalTokens: Int?
    public let inputTokens: Int?
    public let outputTokens: Int?

    public var successRate: Double {
        guard let totalRequests, totalRequests > 0, let successCount else { return 0 }
        return Double(successCount) / Double(totalRequests) * 100
    }

    enum CodingKeys: String, CodingKey {
        case totalRequests = "total_requests"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

public struct ProxyManagementConfiguration: Codable, Equatable, Sendable {
    public let debug: Bool?
    public let proxyURL: String?
    public let routingStrategy: String?
    public let requestRetry: Int?
    public let maxRetryInterval: Int?
    public let loggingToFile: Bool?
    public let requestLog: Bool?
    public let quotaExceeded: ProxyQuotaExceededConfiguration?

    enum CodingKeys: String, CodingKey {
        case debug
        case proxyURL = "proxy-url"
        case routingStrategy = "routing-strategy"
        case requestRetry = "request-retry"
        case maxRetryInterval = "max-retry-interval"
        case loggingToFile = "logging-to-file"
        case requestLog = "request-log"
        case quotaExceeded = "quota-exceeded"
    }
}

public struct ProxyQuotaExceededConfiguration: Codable, Equatable, Sendable {
    public let switchProject: Bool?
    public let switchPreviewModel: Bool?

    enum CodingKeys: String, CodingKey {
        case switchProject = "switch-project"
        case switchPreviewModel = "switch-preview-model"
    }
}

public struct ProxyAPICall: Codable, Equatable, Sendable {
    public let authIndex: String?
    public let method: String
    public let url: String
    public let header: [String: String]?
    public let data: String?

    public init(authIndex: String?, method: String, url: String, header: [String: String]?, data: String?) {
        self.authIndex = authIndex
        self.method = method
        self.url = url
        self.header = header
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case method, url, header, data
        case authIndex = "auth_index"
    }
}

public struct ProxyAPICallResult: Codable, Equatable, Sendable {
    public let statusCode: Int
    public let header: [String: [String]]?
    public let body: String?

    enum CodingKeys: String, CodingKey {
        case header, body
        case statusCode = "status_code"
    }
}

public struct ProxyOAuthStart: Codable, Equatable, Sendable {
    public let status: String
    public let url: String?
    public let state: String?
    public let error: String?
}

public struct ProxyOAuthStatus: Codable, Equatable, Sendable {
    public let status: String
    public let error: String?
}

public enum ProxyManagementOAuthProvider: String, Sendable {
    case claude
    case codex
    case qwen
    case iflow
    case antigravity
}

public struct ProxyLatestVersion: Codable, Equatable, Sendable {
    public let latestVersion: String

    enum CodingKeys: String, CodingKey {
        case latestVersion = "latest-version"
    }
}
