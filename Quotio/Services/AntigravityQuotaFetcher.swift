//
//  AntigravityQuotaFetcher.swift
//  Quotio
//

import Foundation

// MARK: - Models

// MARK: - Model Group

enum AntigravityModelGroup: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case geminiPro = "Gemini Pro"
    case geminiFlash = "Gemini Flash"
    
    var id: String { rawValue }
    
    var displayName: String { rawValue }
    
    var icon: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .geminiPro: return "sparkles"
        case .geminiFlash: return "bolt.fill"
        }
    }
    
    static func group(for modelName: String) -> AntigravityModelGroup? {
        let name = modelName.lowercased()
        
        // Claude group includes gpt and oss models
        if name.contains("claude") || name.contains("gpt") || name.contains("oss") {
            return .claude
        }
        
        if name.contains("gemini") && name.contains("pro") {
            return .geminiPro
        }
        
        if name.contains("gemini") && name.contains("flash") {
            return .geminiFlash
        }
        
        return nil
    }
}

struct GroupedModelQuota: Identifiable, Sendable {
    let group: AntigravityModelGroup
    let models: [ModelQuota]
    
    var id: String { group.id }
    
    var percentage: Double {
        models.map(\.percentage).min() ?? 0
    }
    
    var formattedPercentage: String {
        if percentage == percentage.rounded() {
            return String(format: "%.0f%%", percentage)
        }
        return String(format: "%.2f%%", percentage)
    }
    
    // Uses earliest reset time among all models in the group
    var resetTime: String {
        models.compactMap { model -> Date? in
            ISO8601DateFormatter().date(from: model.resetTime)
        }.min().map { date in
            ISO8601DateFormatter().string(from: date)
        } ?? ""
    }
    
    var formattedResetTime: String {
        guard !resetTime.isEmpty,
              let date = ISO8601DateFormatter().date(from: resetTime) else {
            return "—"
        }
        
        let now = Date()
        let interval = date.timeIntervalSince(now)
        
        if interval <= 0 {
            return "now"
        }
        
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let days = hours / 24
        let remainingHours = hours % 24
        
        if days > 0 {
            if remainingHours > 0 {
                return "\(days)d \(remainingHours)h"
            }
            return "\(days)d"
        } else if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        } else {
            return "\(max(1, minutes))m"
        }
    }
    
    var displayName: String { group.displayName }
}

// MARK: - Models

struct ModelQuota: Codable, Identifiable, Sendable {
    let name: String
    let percentage: Double
    let resetTime: String
    
    // Optional usage details for providers that support it (e.g., Cursor)
    var used: Int?
    var limit: Int?
    var remaining: Int?
    
    var id: String { name }
    
    var usedPercentage: Double {
        100 - percentage
    }
    
    var formattedPercentage: String {
        if percentage < 0 {
            return "—" // Unknown/unavailable
        }
        if percentage == percentage.rounded() {
            return String(format: "%.0f%%", percentage)
        }
        return String(format: "%.2f%%", percentage)
    }
    
    /// Formatted usage string like "150/2000" or "150 used"
    var formattedUsage: String? {
        guard let used = used else { return nil }
        if let limit = limit, limit > 0 {
            return "\(used)/\(limit)"
        }
        return "\(used) used"
    }
    
    var modelGroup: AntigravityModelGroup? {
        AntigravityModelGroup.group(for: name)
    }
    
    var displayName: String {
        switch name {
        case "gemini-3-pro-high": return "Gemini 3 Pro"
        case "gemini-3-flash": return "Gemini 3 Flash"
        case "gemini-3-pro-image": return "Gemini 3 Image"
        case "claude-sonnet-4-5-thinking": return "Claude 4.5"
        case "codex-session": return "Session"
        case "codex-weekly": return "Weekly"
        case "copilot-chat": return "Chat"
        case "copilot-completions": return "Completions"
        case "copilot-premium": return "Premium"
        // Cursor quota names
        case "plan-usage": return "Plan Usage"
        case "on-demand": return "On-Demand"
        case "cursor-usage": return "Usage"
        // Claude Code quota names
        case "weekly-usage": return "Weekly Usage"
        case "sonnet-only": return "Sonnet Only"
        // Gemini CLI
        case "gemini-quota": return "Gemini"
        // Trae quota names
        case "trae-usage": return "Usage"
        case "premium-fast": return "Fast Requests"
        case "premium-slow": return "Slow Requests"
        case "advanced-model": return "Advanced"
        case "auto-completion": return "Completions"
        // Windsurf quota names
        case "windsurf-usage": return "Usage"
        default: return name
        }
    }
    
    var formattedResetTime: String {
        guard let date = ISO8601DateFormatter().date(from: resetTime) else {
            return "—"
        }
        
        let now = Date()
        let interval = date.timeIntervalSince(now)
        
        if interval <= 0 {
            return "now"
        }
        
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let days = hours / 24
        let remainingHours = hours % 24
        
        if days > 0 {
            if remainingHours > 0 {
                return "\(days)d \(remainingHours)h"
            }
            return "\(days)d"
        } else if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        } else {
            return "\(max(1, minutes))m"
        }
    }
}

struct ProviderQuotaData: Codable, Sendable {
    var models: [ModelQuota]
    var lastUpdated: Date
    var isForbidden: Bool
    var planType: String?
    
    init(models: [ModelQuota] = [], lastUpdated: Date = Date(), isForbidden: Bool = false, planType: String? = nil) {
        self.models = models
        self.lastUpdated = lastUpdated
        self.isForbidden = isForbidden
        self.planType = planType
    }
    
    var planDisplayName: String? {
        guard let plan = planType?.lowercased() else { return nil }
        switch plan {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return planType?.capitalized
        }
    }
    
    var groupedModels: [GroupedModelQuota] {
        var grouped: [AntigravityModelGroup: [ModelQuota]] = [:]
        
        for model in models {
            guard let group = model.modelGroup else { continue }
            grouped[group, default: []].append(model)
        }
        
        return AntigravityModelGroup.allCases.compactMap { group in
            guard let models = grouped[group], !models.isEmpty else { return nil }
            return GroupedModelQuota(group: group, models: models)
        }
    }
    
    var hasGroupedModels: Bool {
        models.contains { $0.modelGroup != nil }
    }
}

// MARK: - Subscription Info Models

struct SubscriptionTier: Codable, Sendable {
    let id: String
    let name: String
    let description: String
    let privacyNotice: PrivacyNotice?
    let isDefault: Bool?
    let upgradeSubscriptionUri: String?
    let upgradeSubscriptionText: String?
    let upgradeSubscriptionType: String?
    let userDefinedCloudaicompanionProject: Bool?
}

struct PrivacyNotice: Codable, Sendable {
    let showNotice: Bool?
    let noticeText: String?
}

struct SubscriptionInfo: Codable, Sendable {
    let currentTier: SubscriptionTier?
    let allowedTiers: [SubscriptionTier]?
    let cloudaicompanionProject: String?
    let gcpManaged: Bool?
    let upgradeSubscriptionUri: String?
    let paidTier: SubscriptionTier?
    
    var tierDisplayName: String {
        currentTier?.name ?? "Unknown"
    }
    
    var tierDescription: String {
        currentTier?.description ?? ""
    }
    
    var tierId: String {
        currentTier?.id ?? "unknown"
    }
    
    var isPaidTier: Bool {
        guard let id = currentTier?.id else { return false }
        return id == "g1-pro-tier" || id == "standard-tier"
    }
    
    var canUpgrade: Bool {
        currentTier?.upgradeSubscriptionUri != nil
    }
    
    var upgradeURL: URL? {
        guard let uri = currentTier?.upgradeSubscriptionUri else { return nil }
        return URL(string: uri)
    }
}

// MARK: - API Response Models

private struct QuotaAPIResponse: Codable, Sendable {
    let models: [String: ModelInfo]
}

private struct ModelInfo: Codable, Sendable {
    let quotaInfo: QuotaInfo?
}

private struct QuotaInfo: Codable, Sendable {
    let remainingFraction: Double?
    let resetTime: String?
}

private struct TokenRefreshResponse: Codable, Sendable {
    let accessToken: String
    let expiresIn: Int
    let tokenType: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - Auth File Model

struct AntigravityAuthFile: Codable, Sendable {
    var accessToken: String
    let email: String
    let expired: String?
    let expiresIn: Int?
    let refreshToken: String?
    let timestamp: Int?
    let type: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case email
        case expired
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case timestamp
        case type
    }
    
    var isExpired: Bool {
        guard let expired = expired else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let expiryDate = formatter.date(from: expired) {
            return Date() > expiryDate
        }
        
        let fallbackFormatter = ISO8601DateFormatter()
        if let expiryDate = fallbackFormatter.date(from: expired) {
            return Date() > expiryDate
        }
        
        return true
    }
}

// MARK: - Fetcher

actor AntigravityQuotaFetcher {
    private let quotaAPIURL = "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
    private let loadProjectAPIURL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let clientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private let clientSecret = "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"
    private let userAgent = "antigravity/1.11.3 Darwin/arm64"
    
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }
    
    func refreshAccessToken(refreshToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        
        let body = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw QuotaFetchError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        return tokenResponse.accessToken
    }
    
    func fetchQuota(accessToken: String) async throws -> ProviderQuotaData {
        let projectId = await fetchProjectId(accessToken: accessToken)
        
        var request = URLRequest(url: URL(string: quotaAPIURL)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var payload: [String: Any] = [:]
        if let projectId = projectId {
            payload["project"] = projectId
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        var lastError: Error?
        
        for attempt in 1...3 {
            do {
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw QuotaFetchError.invalidResponse
                }
                
                if httpResponse.statusCode == 403 {
                    return ProviderQuotaData(isForbidden: true)
                }
                
                guard 200...299 ~= httpResponse.statusCode else {
                    throw QuotaFetchError.httpError(httpResponse.statusCode)
                }
                
                let decoder = JSONDecoder()
                let quotaResponse = try decoder.decode(QuotaAPIResponse.self, from: data)
                
                var models: [ModelQuota] = []
                
                for (name, info) in quotaResponse.models {
                    guard name.contains("gemini") || name.contains("claude") else { continue }
                    
                    if let quotaInfo = info.quotaInfo {
                        let percentage = (quotaInfo.remainingFraction ?? 0) * 100
                        let resetTime = quotaInfo.resetTime ?? ""
                        models.append(ModelQuota(name: name, percentage: percentage, resetTime: resetTime))
                    }
                }
                
                return ProviderQuotaData(models: models, lastUpdated: Date())
                
            } catch {
                lastError = error
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        
        throw lastError ?? QuotaFetchError.unknown
    }
    
    private func fetchProjectId(accessToken: String) async -> String? {
        let result = await fetchSubscriptionInfo(accessToken: accessToken)
        return result?.cloudaicompanionProject
    }
    
    func fetchSubscriptionInfo(accessToken: String) async -> SubscriptionInfo? {
        var request = URLRequest(url: URL(string: loadProjectAPIURL)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = ["metadata": ["ideType": "ANTIGRAVITY"]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  200...299 ~= httpResponse.statusCode else {
                return nil
            }
            
            let subscriptionInfo = try JSONDecoder().decode(SubscriptionInfo.self, from: data)
            return subscriptionInfo
            
        } catch {
            return nil
        }
    }
    
    func fetchSubscriptionInfoForAuthFile(at path: String) async -> SubscriptionInfo? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              var authFile = try? JSONDecoder().decode(AntigravityAuthFile.self, from: data) else {
            return nil
        }
        
        var accessToken = authFile.accessToken
        
        if authFile.isExpired, let refreshToken = authFile.refreshToken {
            do {
                accessToken = try await refreshAccessToken(refreshToken: refreshToken)
                authFile.accessToken = accessToken
                
                if let updatedData = try? JSONEncoder().encode(authFile) {
                    try? updatedData.write(to: url)
                }
            } catch {
                return nil
            }
        }
        
        return await fetchSubscriptionInfo(accessToken: accessToken)
    }
    
    func fetchAllSubscriptionInfo(authDir: String = "~/.cli-proxy-api") async -> [String: SubscriptionInfo] {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default
        
        guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return [:]
        }
        
        var results: [String: SubscriptionInfo] = [:]
        
        for file in files where file.hasPrefix("antigravity-") && file.hasSuffix(".json") {
            let filePath = (expandedPath as NSString).appendingPathComponent(file)
            
            if let info = await fetchSubscriptionInfoForAuthFile(at: filePath) {
                let email = file
                    .replacingOccurrences(of: "antigravity-", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                    .replacingOccurrences(of: "_", with: ".")
                    .replacingOccurrences(of: ".gmail.com", with: "@gmail.com")
                results[email] = info
            }
        }
        
        return results
    }
    
    func fetchQuotaForAuthFile(at path: String) async throws -> ProviderQuotaData {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        var authFile = try JSONDecoder().decode(AntigravityAuthFile.self, from: data)
        
        var accessToken = authFile.accessToken
        
        if authFile.isExpired, let refreshToken = authFile.refreshToken {
            do {
                accessToken = try await refreshAccessToken(refreshToken: refreshToken)
                authFile.accessToken = accessToken
                
                if let updatedData = try? JSONEncoder().encode(authFile) {
                    try? updatedData.write(to: url)
                }
            } catch {
                print("Token refresh failed: \(error)")
            }
        }
        
        return try await fetchQuota(accessToken: accessToken)
    }
    
    func fetchAllAntigravityQuotas(authDir: String = "~/.cli-proxy-api") async -> [String: ProviderQuotaData] {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default
        
        guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return [:]
        }
        
        var results: [String: ProviderQuotaData] = [:]
        
        for file in files where file.hasPrefix("antigravity-") && file.hasSuffix(".json") {
            let filePath = (expandedPath as NSString).appendingPathComponent(file)
            
            do {
                let quota = try await fetchQuotaForAuthFile(at: filePath)
                let email = file
                    .replacingOccurrences(of: "antigravity-", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                    .replacingOccurrences(of: "_", with: ".")
                    .replacingOccurrences(of: ".gmail.com", with: "@gmail.com")
                results[email] = quota
            } catch {
                print("Failed to fetch quota for \(file): \(error)")
            }
        }
        
        return results
    }
}

// MARK: - Errors

enum QuotaFetchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case forbidden
    case httpError(Int)
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response from server"
        case .forbidden: return "Access forbidden"
        case .httpError(let code): return "HTTP error: \(code)"
        case .unknown: return "Unknown error"
        }
    }
}
