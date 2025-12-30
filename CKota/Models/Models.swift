//
//  Models.swift
//  CKota - CLIProxyAPI GUI Wrapper
//

import Foundation
import SwiftUI

// MARK: - Provider Types

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case claude
    case antigravity

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .antigravity: "Antigravity"
        }
    }

    var iconName: String {
        switch self {
        case .claude: "brain.head.profile"
        case .antigravity: "wand.and.stars"
        }
    }

    /// Logo file name in ProviderIcons asset catalog
    var logoAssetName: String {
        switch self {
        case .claude: "claude"
        case .antigravity: "antigravity"
        }
    }

    var color: Color {
        switch self {
        case .claude: Color(hex: "D97706")
        case .antigravity: Color(hex: "4D7CFF")
        }
    }

    var oauthEndpoint: String {
        switch self {
        case .claude: "/anthropic-auth-url"
        case .antigravity: "/antigravity-auth-url"
        }
    }

    /// Short symbol for menu bar display
    var menuBarSymbol: String {
        switch self {
        case .claude: "C"
        case .antigravity: "A"
        }
    }

    /// Menu bar icon asset name (nil if should use SF Symbol fallback)
    var menuBarIconAsset: String? {
        switch self {
        case .claude: "claude-menubar"
        case .antigravity: "antigravity-menubar"
        }
    }

    /// Whether this provider supports quota tracking in quota-only mode
    var supportsQuotaOnlyMode: Bool {
        true
    }

    /// Whether this provider uses browser cookies for auth
    var usesBrowserAuth: Bool {
        false
    }

    /// Whether this provider uses CLI commands for quota
    var usesCLIQuota: Bool {
        switch self {
        case .claude: true
        case .antigravity: false
        }
    }

    /// Whether this provider can be added manually (via OAuth, CLI login, or file import)
    var supportsManualAuth: Bool {
        true
    }

    /// Whether this provider is quota-tracking only (not a real provider that can route requests)
    var isQuotaTrackingOnly: Bool {
        false
    }
}

// MARK: - Proxy Status

struct ProxyStatus: Codable {
    var running: Bool = false
    var port: UInt16 = 8317

    var endpoint: String {
        "http://localhost:\(port)/v1"
    }
}

// MARK: - Auth File (from Management API)

struct AuthFile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let provider: String
    let label: String?
    let status: String
    let statusMessage: String?
    let disabled: Bool
    let unavailable: Bool
    let runtimeOnly: Bool?
    let source: String?
    let path: String?
    let email: String?
    let accountType: String?
    let account: String?
    let createdAt: String?
    let updatedAt: String?
    let lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case id, name, provider, label, status, disabled, unavailable, source, path, email, account
        case statusMessage = "status_message"
        case runtimeOnly = "runtime_only"
        case accountType = "account_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastRefresh = "last_refresh"
    }

    var providerType: AIProvider? {
        AIProvider(rawValue: provider)
    }

    var quotaLookupKey: String {
        if let email, !email.isEmpty {
            return email
        }
        if let account, !account.isEmpty {
            return account
        }
        var key = name
        // Strip .json suffix
        if key.hasSuffix(".json") {
            key = String(key.dropLast(".json".count))
        }
        // Strip provider prefixes (e.g., "claude-email@example.com" -> "email@example.com")
        let providerPrefixes = ["claude-", "antigravity-", "gemini-", "codex-", "copilot-", "kiro-", "cursor-"]
        for prefix in providerPrefixes {
            if key.hasPrefix(prefix) {
                key = String(key.dropFirst(prefix.count))
                break
            }
        }
        return key
    }

    var isReady: Bool {
        status == "ready" && !disabled && !unavailable
    }

    var statusColor: Color {
        switch status {
        case "ready": disabled ? .gray : .green
        case "cooling": .orange
        case "error": .red
        default: .gray
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AuthFile, rhs: AuthFile) -> Bool {
        lhs.id == rhs.id
    }
}

struct AuthFilesResponse: Codable, Sendable {
    let files: [AuthFile]
}

// MARK: - API Keys (Proxy Service Auth)

struct APIKeysResponse: Codable, Sendable {
    let apiKeys: [String]

    enum CodingKeys: String, CodingKey {
        case apiKeys = "api-keys"
    }
}

// MARK: - Usage Statistics

struct UsageStats: Codable, Sendable {
    let usage: UsageData?
    let failedRequests: Int?

    enum CodingKeys: String, CodingKey {
        case usage
        case failedRequests = "failed_requests"
    }
}

struct UsageData: Codable, Sendable {
    let totalRequests: Int?
    let successCount: Int?
    let failureCount: Int?
    let totalTokens: Int?
    let inputTokens: Int?
    let outputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case totalRequests = "total_requests"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }

    var successRate: Double {
        guard let total = totalRequests, total > 0, let success = successCount else { return 0 }
        return Double(success) / Double(total) * 100
    }
}

// MARK: - OAuth Flow

struct OAuthURLResponse: Codable, Sendable {
    let status: String
    let url: String?
    let state: String?
    let error: String?
}

struct OAuthStatusResponse: Codable, Sendable {
    let status: String
    let error: String?
}

// MARK: - App Config

struct AppConfig: Codable {
    var host: String = ""
    var port: UInt16 = 8317
    var authDir: String = "~/.cli-proxy-api"
    var apiKeys: [String] = []
    var debug: Bool = false
    var loggingToFile: Bool = false
    var usageStatisticsEnabled: Bool = true
    var requestRetry: Int = 3
    var maxRetryInterval: Int = 30
    var wsAuth: Bool = false
    var routing: RoutingConfig = .init()
    var quotaExceeded: QuotaExceededConfig = .init()
    var remoteManagement: RemoteManagementConfig = .init()

    enum CodingKeys: String, CodingKey {
        case host, port, debug, routing
        case authDir = "auth-dir"
        case apiKeys = "api-keys"
        case loggingToFile = "logging-to-file"
        case usageStatisticsEnabled = "usage-statistics-enabled"
        case requestRetry = "request-retry"
        case maxRetryInterval = "max-retry-interval"
        case wsAuth = "ws-auth"
        case quotaExceeded = "quota-exceeded"
        case remoteManagement = "remote-management"
    }
}

struct RoutingConfig: Codable {
    var strategy: String = "round-robin"
}

struct QuotaExceededConfig: Codable {
    var switchProject: Bool = true
    var switchPreviewModel: Bool = true

    enum CodingKeys: String, CodingKey {
        case switchProject = "switch-project"
        case switchPreviewModel = "switch-preview-model"
    }
}

struct RemoteManagementConfig: Codable {
    var allowRemote: Bool = false
    var secretKey: String = ""
    var disableControlPanel: Bool = false

    enum CodingKeys: String, CodingKey {
        case allowRemote = "allow-remote"
        case secretKey = "secret-key"
        case disableControlPanel = "disable-control-panel"
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String

    enum LogLevel: String {
        case info, warn, error, debug

        var color: Color {
            switch self {
            case .info: .primary
            case .warn: .orange
            case .error: .red
            case .debug: .gray
            }
        }
    }
}

// MARK: - Navigation

enum NavigationPage: String, CaseIterable, Identifiable {
    case home = "Home"
    case analytics = "Analytics"
    case providers = "Providers"
    case settings = "Settings"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "house"
        case .analytics: "chart.bar.xaxis"
        case .providers: "person.2"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

// MARK: - Color Extension

// Note: hex initializer moved to Design/Color+CKota.swift

// MARK: - Formatting Helpers

extension Int {
    var formattedCompact: String {
        if self >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000)
        } else if self >= 1000 {
            return String(format: "%.1fK", Double(self) / 1000)
        }
        return "\(self)"
    }
}
