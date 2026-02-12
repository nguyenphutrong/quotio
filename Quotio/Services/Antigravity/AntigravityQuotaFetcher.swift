//
//  AntigravityQuotaFetcher.swift
//  Quotio
//

import Foundation
import SwiftUI

// MARK: - Models

// MARK: - Model Group

nonisolated enum AntigravityModelGroup: String, CaseIterable, Identifiable {
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

nonisolated struct GroupedModelQuota: Identifiable, Sendable {
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
            parseISO8601Date(model.resetTime)
        }.min().map { date in
            ISO8601DateFormatter().string(from: date)
        } ?? ""
    }

    var formattedResetTime: String {
        guard !resetTime.isEmpty,
              let date = parseISO8601Date(resetTime) else {
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

    /// Parse ISO8601 date string, trying both with and without fractional seconds
    private func parseISO8601Date(_ dateString: String) -> Date? {
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        return isoFormatterWithFractional.date(from: dateString)
            ?? isoFormatterStandard.date(from: dateString)
    }

    var displayName: String { group.displayName }
}

// MARK: - Models

nonisolated struct ModelQuota: Codable, Identifiable, Sendable {
    let name: String
    let percentage: Double
    let resetTime: String

    // Optional usage details for providers that support it (e.g., Cursor)
    var used: Int?
    var limit: Int?
    var remaining: Int?

    // Optional tooltip message (e.g., Warp bonus userFacingMessage)
    var tooltip: String?

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
        // Antigravity Gemini models
        case "gemini-3-pro-high": return "Gemini 3 Pro"
        case "gemini-3-pro": return "Gemini 3 Pro"
        case "gemini-3-flash": return "Gemini 3 Flash"
        case "gemini-3-flash-high": return "Gemini 3 Flash"
        case "gemini-3-pro-image": return "Gemini 3 Image"
        case "gemini-3-flash-image": return "Gemini 3 Image"
        // Antigravity Claude models
        case "claude-sonnet-4-5": return "Claude Sonnet 4.5"
        case "claude-sonnet-4-5-thinking": return "Claude Sonnet 4.5 (Thinking)"
        case "claude-opus-4": return "Claude Opus 4"
        case "claude-opus-4-5": return "Claude Opus 4.5"
        case "claude-opus-4-5-thinking": return "Claude Opus 4.5 (Thinking)"
        case "claude-opus-4-6": return "Claude Opus 4.6"
        case "claude-opus-4-6-thinking": return "Claude Opus 4.6 (Thinking)"
        case "claude-4-sonnet": return "Claude 4 Sonnet"
        case "claude-4-opus": return "Claude 4 Opus"
        // Codex quota names
        case "codex-session": return "Session"
        case "codex-weekly": return "Weekly"
        // Copilot quota names
        case "copilot-chat": return "Chat"
        case "copilot-completions": return "Completions"
        case "copilot-premium": return "Premium"
        // Cursor quota names
        case "plan-usage": return "Plan Usage"
        case "on-demand": return "On-Demand"
        case "cursor-usage": return "Usage"
        // Claude Code quota names
        case "five-hour-session": return "Session"
        case "seven-day-weekly": return "Weekly"
        case "seven-day-sonnet": return "Sonnet"
        case "seven-day-opus": return "Opus"
        case "extra-usage": return "Extra"
        case "weekly-usage": return "Weekly"
        case "sonnet-only": return "Sonnet"
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
        // Warp quota names
        case "warp-usage": return "warp.credits.label".localizedStatic()
        case let name where name.hasPrefix("warp-bonus-"):
            let index = Int(String(name.dropFirst("warp-bonus-".count))) ?? 0
            return "Bonus \(index + 1)"
        default: return name
        }
    }

    var formattedResetTime: String {
        guard !resetTime.isEmpty else { return "—" }

        // Try parsing with fractional seconds first, then standard format
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        guard let date = isoFormatterWithFractional.date(from: resetTime)
              ?? isoFormatterStandard.date(from: resetTime) else {
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

nonisolated struct ProviderQuotaData: Codable, Sendable {
    var models: [ModelQuota]
    var lastUpdated: Date
    var isForbidden: Bool
    var planType: String?
    var tokenExpiresAt: Date?  // For Kiro: token expiry time

    init(models: [ModelQuota] = [], lastUpdated: Date = Date(), isForbidden: Bool = false, planType: String? = nil, tokenExpiresAt: Date? = nil) {
        self.models = models
        self.lastUpdated = lastUpdated
        self.isForbidden = isForbidden
        self.planType = planType
        self.tokenExpiresAt = tokenExpiresAt
    }

    /// Format token expiry time in user's local timezone
    var formattedTokenExpiry: String? {
        guard let expiresAt = tokenExpiresAt else { return nil }

        let now = Date()
        let interval = expiresAt.timeIntervalSince(now)

        // If expired
        if interval <= 0 {
            return "Expired"
        }

        // Format as local time
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone.current
        return "Token expires \(formatter.string(from: expiresAt))"
    }

    var planDisplayName: String? {
        guard let plan = planType?.lowercased() else { return nil }
        switch plan {
        case "guest": return "Guest"
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "free_workspace": return "Free Workspace"
        case "team": return "Team"
        case "business": return "Business"
        case "education": return "Education"
        case "quorum": return "Quorum"
        case "k12": return "K-12"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
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

nonisolated struct SubscriptionTier: Codable, Sendable {
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

nonisolated struct PrivacyNotice: Codable, Sendable {
    let showNotice: Bool?
    let noticeText: String?
}

nonisolated struct SubscriptionInfo: Codable, Sendable {
    let currentTier: SubscriptionTier?
    let allowedTiers: [SubscriptionTier]?
    let cloudaicompanionProject: String?
    let gcpManaged: Bool?
    let upgradeSubscriptionUri: String?
    let paidTier: SubscriptionTier?

    /// Get the effective tier - prioritize paidTier over currentTier
    private var effectiveTier: SubscriptionTier? {
        paidTier ?? currentTier
    }

    var tierDisplayName: String {
        effectiveTier?.name ?? "Unknown"
    }

    var tierDescription: String {
        effectiveTier?.description ?? ""
    }

    var tierId: String {
        effectiveTier?.id ?? "unknown"
    }

    var isPaidTier: Bool {
        guard let id = effectiveTier?.id else { return false }
        return id.contains("pro") || id.contains("ultra")
    }

    var canUpgrade: Bool {
        effectiveTier?.upgradeSubscriptionUri != nil
    }

    var upgradeURL: URL? {
        guard let uri = effectiveTier?.upgradeSubscriptionUri else { return nil }
        return URL(string: uri)
    }
}

// MARK: - API Response Models

nonisolated private struct QuotaAPIResponse: Codable, Sendable {
    let models: [String: ModelInfo]
}

nonisolated private struct ModelInfo: Codable, Sendable {
    let quotaInfo: QuotaInfo?
}

nonisolated private struct QuotaInfo: Codable, Sendable {
    let remainingFraction: Double?
    let resetTime: String?
}

nonisolated private struct TokenRefreshResponse: Codable, Sendable {
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

nonisolated struct AntigravityAuthFile: Codable, Sendable {
    var accessToken: String
    let email: String
    var expired: String?
    let expiresIn: Int?
    let refreshToken: String?
    let timestamp: Int?
    let type: String?
    // Fields preserved during token refresh (used by CLIProxyAPI)
    var prefix: String?
    var projectId: String?
    var proxyUrl: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case email
        case expired
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case timestamp
        case type
        case prefix
        case projectId = "project_id"
        case proxyUrl = "proxy_url"
    }

    nonisolated var isExpired: Bool {
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

    private var session: URLSession

    // Cache subscription info to avoid duplicate API calls within same refresh cycle
    private var subscriptionCache: [String: SubscriptionInfo] = [:]

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    /// Clear the subscription cache and release memory (call at start of refresh cycle)
    func clearCache() {
        // Create new empty dictionary to release old capacity, not just removeAll()
        subscriptionCache = [:]
    }

    func refreshAccessToken(refreshToken: String) async throws -> String {
        let (accessToken, _) = try await refreshAccessTokenWithExpiry(refreshToken: refreshToken)
        return accessToken
    }

    private func refreshAccessTokenWithExpiry(refreshToken: String) async throws -> (String, Int) {
        guard let url = URL(string: tokenURL) else {
            throw QuotaFetchError.invalidURL
        }
        var request = URLRequest(url: url)
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
        return (tokenResponse.accessToken, tokenResponse.expiresIn)
    }

    /// Persist refreshed access token back to auth file using read-modify-write
    /// to preserve all existing fields (including `disabled`, etc.)
    private func persistRefreshedToken(at url: URL, originalData: Data, newAccessToken: String, expiresIn: Int) {
        guard var json = try? JSONSerialization.jsonObject(with: originalData) as? [String: Any] else { return }
        json["access_token"] = newAccessToken

        let now = Date()
        let expiryDate = now.addingTimeInterval(TimeInterval(expiresIn))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        json["expired"] = formatter.string(from: expiryDate)
        json["expires_in"] = expiresIn
        json["timestamp"] = Int64(now.timeIntervalSince1970 * 1000)

        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            try? updatedData.write(to: url)
        }
    }

    func fetchQuota(accessToken: String) async throws -> ProviderQuotaData {
        let projectId = await fetchProjectId(accessToken: accessToken)

        guard let url = URL(string: quotaAPIURL) else {
            throw QuotaFetchError.invalidURL
        }
        var request = URLRequest(url: url)
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
                        // Clamp to 0-100 range (API can return remainingFraction > 1.0)
                        let percentage = min(100, max(0, (quotaInfo.remainingFraction ?? 0) * 100))
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
        // Use cached subscription info if available, otherwise fetch
        if let cached = subscriptionCache[accessToken] {
            return cached.cloudaicompanionProject
        }
        let result = await fetchSubscriptionInfo(accessToken: accessToken)
        if let info = result {
            subscriptionCache[accessToken] = info
        }
        return result?.cloudaicompanionProject
    }

    func fetchSubscriptionInfo(accessToken: String) async -> SubscriptionInfo? {
        guard let url = URL(string: loadProjectAPIURL) else {
            return nil
        }
        var request = URLRequest(url: url)
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
              let authFile = try? JSONDecoder().decode(AntigravityAuthFile.self, from: data) else {
            return nil
        }

        var accessToken = authFile.accessToken

        if authFile.isExpired, let refreshToken = authFile.refreshToken {
            do {
                let (token, expiresIn) = try await refreshAccessTokenWithExpiry(refreshToken: refreshToken)
                accessToken = token
                persistRefreshedToken(at: url, originalData: data, newAccessToken: accessToken, expiresIn: expiresIn)
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
        let authFile = try JSONDecoder().decode(AntigravityAuthFile.self, from: data)

        var accessToken = authFile.accessToken

        if authFile.isExpired, let refreshToken = authFile.refreshToken {
            do {
                let (token, expiresIn) = try await refreshAccessTokenWithExpiry(refreshToken: refreshToken)
                accessToken = token
                persistRefreshedToken(at: url, originalData: data, newAccessToken: accessToken, expiresIn: expiresIn)
            } catch {
                Log.auth("Token refresh failed: \(error)")
            }
        }

        return try await fetchQuota(accessToken: accessToken)
    }

    /// Fetch both quota and subscription for an auth file in one operation
    /// This reuses the subscription info fetched during quota fetch (via fetchProjectId)
    func fetchQuotaAndSubscriptionForAuthFile(at path: String) async -> (quota: ProviderQuotaData?, subscription: SubscriptionInfo?) {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let authFile = try? JSONDecoder().decode(AntigravityAuthFile.self, from: data) else {
            return (nil, nil)
        }

        var accessToken = authFile.accessToken

        if authFile.isExpired, let refreshToken = authFile.refreshToken {
            do {
                let (token, expiresIn) = try await refreshAccessTokenWithExpiry(refreshToken: refreshToken)
                accessToken = token
                persistRefreshedToken(at: url, originalData: data, newAccessToken: accessToken, expiresIn: expiresIn)
            } catch {
                return (nil, nil)
            }
        }

        // Fetch quota - this internally calls fetchProjectId which fetches and caches subscription
        var quota: ProviderQuotaData? = nil
        do {
            quota = try await fetchQuota(accessToken: accessToken)
        } catch {
            // Quota fetch failed, but we might still have subscription in cache
        }

        // Get subscription from cache (was fetched during fetchProjectId in fetchQuota)
        let subscription = subscriptionCache[accessToken]

        return (quota, subscription)
    }

    func fetchAllAntigravityQuotas(authDir: String = "~/.cli-proxy-api") async -> [String: ProviderQuotaData] {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return [:]
        }

        var results: [String: ProviderQuotaData] = [:]

        // Run all fetches concurrently using TaskGroup
        await withTaskGroup(of: (String, ProviderQuotaData?).self) { group in
            for file in files where file.hasPrefix("antigravity-") && file.hasSuffix(".json") {
                let filePath = (expandedPath as NSString).appendingPathComponent(file)
                let email = file
                    .replacingOccurrences(of: "antigravity-", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                    .replacingOccurrences(of: "_", with: ".")
                    .replacingOccurrences(of: ".gmail.com", with: "@gmail.com")

                group.addTask {
                    do {
                        let quota = try await self.fetchQuotaForAuthFile(at: filePath)
                        return (email, quota)
                    } catch {
                        return (email, nil)
                    }
                }
            }

            for await (email, quota) in group {
                if let quota = quota {
                    results[email] = quota
                }
            }
        }

        return results
    }

    /// Fetch all Antigravity data (quotas + subscriptions) in one call
    /// This avoids duplicate API calls by reusing cached subscription info
    func fetchAllAntigravityData(authDir: String = "~/.cli-proxy-api") async -> (quotas: [String: ProviderQuotaData], subscriptions: [String: SubscriptionInfo]) {
        // Clear cache at start of refresh cycle
        clearCache()

        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default

        guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return ([:], [:])
        }

        var quotaResults: [String: ProviderQuotaData] = [:]
        var subscriptionResults: [String: SubscriptionInfo] = [:]

        // Run all fetches concurrently using TaskGroup
        await withTaskGroup(of: (String, ProviderQuotaData?, SubscriptionInfo?).self) { group in
            for file in files where file.hasPrefix("antigravity-") && file.hasSuffix(".json") {
                let filePath = (expandedPath as NSString).appendingPathComponent(file)
                let email = file
                    .replacingOccurrences(of: "antigravity-", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                    .replacingOccurrences(of: "_", with: ".")
                    .replacingOccurrences(of: ".gmail.com", with: "@gmail.com")

                group.addTask {
                    // Fetch both quota and subscription in one call
                    let result = await self.fetchQuotaAndSubscriptionForAuthFile(at: filePath)
                    return (email, result.quota, result.subscription)
                }
            }

            for await (email, quota, subscription) in group {
                if let quota = quota {
                    quotaResults[email] = quota
                }
                if let subscription = subscription {
                    subscriptionResults[email] = subscription
                }
            }
        }

        return (quotaResults, subscriptionResults)
    }

    /// Legacy function - now just calls fetchAllAntigravityQuotas
    @available(*, deprecated, message: "Use fetchAllAntigravityData instead")
    func fetchAllAntigravityQuotasLegacy(authDir: String = "~/.cli-proxy-api") async -> [String: ProviderQuotaData] {
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
                Log.quota("Failed to fetch Antigravity quota for \(file): \(error)")
            }
        }

        return results
    }
}

// MARK: - Errors

nonisolated enum QuotaFetchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case forbidden
    case httpError(Int)
    case unknown
    case apiErrorMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response from server"
        case .forbidden: return "Access forbidden"
        case .httpError(let code): return "HTTP error: \(code)"
        case .unknown: return "Unknown error"
        case .apiErrorMessage(let msg): return "API error: \(msg)"
        }
    }
}
