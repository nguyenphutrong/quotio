//
//  Models.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation
import SwiftUI

// MARK: - Provider Types

enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case gemini = "gemini-cli"
    case claude = "claude"
    case codex = "codex"
    case qwen = "qwen"
    case iflow = "iflow"
    case antigravity = "antigravity"
    case vertex = "vertex"
    case kiro = "kiro"
    case copilot = "github-copilot"
    case cursor = "cursor"
    case trae = "trae"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .gemini: return "Gemini CLI"
        case .claude: return "Claude Code"
        case .codex: return "Codex (OpenAI)"
        case .qwen: return "Qwen Code"
        case .iflow: return "iFlow"
        case .antigravity: return "Antigravity"
        case .vertex: return "Vertex AI"
        case .kiro: return "Kiro (CodeWhisperer)"
        case .copilot: return "GitHub Copilot"
        case .cursor: return "Cursor"
        case .trae: return "Trae"
        }
    }
    
    var iconName: String {
        switch self {
        case .gemini: return "sparkles"
        case .claude: return "brain.head.profile"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .qwen: return "cloud"
        case .iflow: return "arrow.triangle.branch"
        case .antigravity: return "wand.and.stars"
        case .vertex: return "cube"
        case .kiro: return "cloud.fill"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .trae: return "cursorarrow.rays"
        }
    }
    
    /// Logo file name in ProviderIcons asset catalog
    var logoAssetName: String {
        switch self {
        case .gemini: return "gemini"
        case .claude: return "claude"
        case .codex: return "openai"
        case .qwen: return "qwen"
        case .iflow: return "iflow"
        case .antigravity: return "antigravity"
        case .vertex: return "vertex"
        case .kiro: return "kiro"
        case .copilot: return "copilot"
        case .cursor: return "cursor"
        case .trae: return "trae"
        }
    }
    
    var color: Color {
        switch self {
        case .gemini: return Color(hex: "4285F4") ?? .blue
        case .claude: return Color(hex: "D97706") ?? .orange
        case .codex: return Color(hex: "10A37F") ?? .green
        case .qwen: return Color(hex: "7C3AED") ?? .purple
        case .iflow: return Color(hex: "06B6D4") ?? .cyan
        case .antigravity: return Color(hex: "EC4899") ?? .pink
        case .vertex: return Color(hex: "EA4335") ?? .red
        case .kiro: return Color(hex: "9046FF") ?? .purple
        case .copilot: return Color(hex: "238636") ?? .green
        case .cursor: return Color(hex: "00D4AA") ?? .teal
        case .trae: return Color(hex: "00B4D8") ?? .cyan
        }
    }
    
    var oauthEndpoint: String {
        switch self {
        case .gemini: return "/gemini-cli-auth-url"
        case .claude: return "/anthropic-auth-url"
        case .codex: return "/codex-auth-url"
        case .qwen: return "/qwen-auth-url"
        case .iflow: return "/iflow-auth-url"
        case .antigravity: return "/antigravity-auth-url"
        case .vertex: return ""
        case .kiro: return ""  // Uses CLI-based auth like Copilot
        case .copilot: return ""
        case .cursor: return ""  // Uses browser session
        case .trae: return ""  // Uses browser session
        }
    }
    
    /// Short symbol for menu bar display
    var menuBarSymbol: String {
        switch self {
        case .gemini: return "G"
        case .claude: return "C"
        case .codex: return "O"
        case .qwen: return "Q"
        case .iflow: return "F"
        case .antigravity: return "A"
        case .vertex: return "V"
        case .kiro: return "K"
        case .copilot: return "CP"
        case .cursor: return "CR"
        case .trae: return "TR"
        }
    }
    
    /// Menu bar icon asset name (nil if should use SF Symbol fallback)
    var menuBarIconAsset: String? {
        switch self {
        case .gemini: return "gemini-menubar"
        case .claude: return "claude-menubar"
        case .codex: return "openai-menubar"
        case .qwen: return "qwen-menubar"
        case .copilot: return "copilot-menubar"
        // These don't have custom icons, use SF Symbols
        case .antigravity: return "antigravity-menubar"
        case .kiro: return "kiro-menubar"
        case .iflow: return "iflow-menubar"
        case .vertex: return "vertex-menubar"
        case .cursor: return "cursor-menubar"
        case .trae: return "trae-menubar"
        }
    }
    
    /// Whether this provider supports quota tracking in quota-only mode
    var supportsQuotaOnlyMode: Bool {
        switch self {
        case .claude, .codex, .cursor, .gemini, .antigravity, .copilot, .trae:
            return true
        case .qwen, .iflow, .vertex, .kiro:
            return false
        }
    }
    
    /// Whether this provider uses browser cookies for auth
    var usesBrowserAuth: Bool {
        switch self {
        case .cursor, .trae:
            return true
        default:
            return false
        }
    }
    
    /// Whether this provider uses CLI commands for quota
    var usesCLIQuota: Bool {
        switch self {
        case .claude, .codex, .gemini:
            return true
        default:
            return false
        }
    }
    
    /// Whether this provider can be added manually (via OAuth, CLI login, or file import)
    /// Cursor, Trae, Windsurf are excluded because they only read from local app databases
    var supportsManualAuth: Bool {
        switch self {
        case .cursor, .trae:
            return false  // Only reads from local app database, not a real provider
        default:
            return true
        }
    }
    
    /// Whether this provider is quota-tracking only (not a real provider that can route requests)
    var isQuotaTrackingOnly: Bool {
        switch self {
        case .cursor, .trae:
            return true  // Only for tracking usage, not a provider
        default:
            return false
        }
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
        // Handle "copilot" alias for "github-copilot"
        if provider == "copilot" {
            return .copilot
        }
        return AIProvider(rawValue: provider)
    }
    
    var quotaLookupKey: String {
        if let email = email, !email.isEmpty {
            return email
        }
        if let account = account, !account.isEmpty {
            return account
        }
        var key = name
        if key.hasPrefix("github-copilot-") {
            key = String(key.dropFirst("github-copilot-".count))
        }
        if key.hasSuffix(".json") {
            key = String(key.dropLast(".json".count))
        }
        return key
    }
    
    var isReady: Bool {
        status == "ready" && !disabled && !unavailable
    }
    
    var statusColor: Color {
        switch status {
        case "ready": return disabled ? .gray : .green
        case "cooling": return .orange
        case "error": return .red
        default: return .gray
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
    var routing: RoutingConfig = RoutingConfig()
    var quotaExceeded: QuotaExceededConfig = QuotaExceededConfig()
    var remoteManagement: RemoteManagementConfig = RemoteManagementConfig()
    
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
            case .info: return .primary
            case .warn: return .orange
            case .error: return .red
            case .debug: return .gray
            }
        }
    }
}

// MARK: - Navigation

enum NavigationPage: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case quota = "Quota"
    case providers = "Providers"
    case agents = "Agents"
    case apiKeys = "API Keys"
    case logs = "Logs"
    case settings = "Settings"
    case about = "About"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .quota: return "chart.bar.fill"
        case .providers: return "person.2.badge.key"
        case .agents: return "terminal"
        case .apiKeys: return "key.horizontal"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Formatting Helpers

extension Int {
    var formattedCompact: String {
        if self >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000)
        } else if self >= 1_000 {
            return String(format: "%.1fK", Double(self) / 1_000)
        }
        return "\(self)"
    }
}
