//
//  OpenAIQuotaFetcher.swift
//  Quotio
//

import Foundation

actor OpenAIQuotaFetcher {
    private let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private let tokenURL = "https://token.oaifree.com/api/auth/refresh"
    
    private var session: URLSession
    
    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

#if DEBUG
    private func debugMask(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<nil>" }
        if value.count <= 8 { return "\(value) (len=\(value.count))" }
        let prefix = value.prefix(4)
        let suffix = value.suffix(4)
        return "\(prefix)…\(suffix) (len=\(value.count))"
    }
#endif

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }
    
    private func extractAccountId(from authFile: CodexAuthFile, rawJSON: [String: Any]) -> String? {
        if let accountId = authFile.accountId, !accountId.isEmpty {
            return accountId
        }
        if let accountId = rawJSON["chatgpt_account_id"] as? String, !accountId.isEmpty {
            return accountId
        }
        if let idToken = authFile.idToken, let accountId = decodeAccountId(fromJWT: idToken) {
            return accountId
        }
        return nil
    }
    
    private func decodeAccountId(fromJWT token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        
        var base64 = String(segments[1])
        let padLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padLength)
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        if let authInfo = json["https://api.openai.com/auth"] as? [String: Any],
           let accountId = authInfo["chatgpt_account_id"] as? String,
           !accountId.isEmpty {
            return accountId
        }
        
        return nil
    }
    
    func fetchQuota(accessToken: String, accountId: String?) async throws -> CodexQuotaData {
        guard let url = URL(string: usageURL) else {
            throw CodexQuotaError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId, !accountId.isEmpty {
            request.addValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
#if DEBUG
        Log.quota("GET \\(usageURL) accountId=\\(debugMask(accountId))")
#endif
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexQuotaError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            throw CodexQuotaError.httpError(httpResponse.statusCode)
        }
        
        let quotaResponse = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
#if DEBUG
        Log.quota("plan_type=\(quotaResponse.planType ?? "<nil>")")
#endif
        return CodexQuotaData(from: quotaResponse)
    }
    
    func fetchQuotaForAuthFile(at path: String) async throws -> CodexQuotaData {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let authFile = try JSONDecoder().decode(CodexAuthFile.self, from: data)
        let rawJSON = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let accountId = extractAccountId(from: authFile, rawJSON: rawJSON)

        var accessToken = authFile.accessToken

        if authFile.isExpired, let refreshToken = authFile.refreshToken {
            do {
                accessToken = try await refreshAccessToken(refreshToken: refreshToken)
                persistRefreshedToken(at: url, originalData: data, newAccessToken: accessToken)
            } catch {
                Log.quota("Token refresh failed: \\(error)")
            }
        }

        return try await fetchQuota(accessToken: accessToken, accountId: accountId)
    }
    
    private func refreshAccessToken(refreshToken: String) async throws -> String {
        guard let url = URL(string: tokenURL) else {
            throw CodexQuotaError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = "refresh_token=\(refreshToken)"
        request.httpBody = body.data(using: .utf8)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw CodexQuotaError.tokenRefreshFailed
        }
        
        let tokenResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        return tokenResponse.accessToken
    }

    /// Persist refreshed access token back to auth file using read-modify-write
    /// to preserve all existing fields (including `disabled`, etc.)
    private func persistRefreshedToken(at url: URL, originalData: Data, newAccessToken: String) {
        guard var json = try? JSONSerialization.jsonObject(with: originalData) as? [String: Any] else { return }
        json["access_token"] = newAccessToken

        // Update expiry to prevent repeated refresh on every cycle
        // OpenAI TokenRefreshResponse does not include expires_in, use 1 hour as default
        let expiryDate = Date().addingTimeInterval(3600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        json["expired"] = formatter.string(from: expiryDate)

        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            try? updatedData.write(to: url)
        }
    }

    func fetchAllCodexQuotas(authDir: String = "~/.cli-proxy-api") async -> [String: ProviderQuotaData] {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default
        
        guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return [:]
        }
        
        var results: [String: ProviderQuotaData] = [:]
        
        for file in files where file.hasPrefix("codex-") && file.hasSuffix(".json") {
            let filePath = (expandedPath as NSString).appendingPathComponent(file)
            
            do {
                let quota = try await fetchQuotaForAuthFile(at: filePath)
                let email = file
                    .replacingOccurrences(of: "codex-", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                results[email] = quota.toProviderQuotaData()
            } catch {
                Log.quota("Failed to fetch Codex quota for \(file): \(error)")
            }
        }
        
        return results
    }
}

nonisolated struct CodexUsageResponse: Codable, Sendable {
    let planType: String?
    let rateLimit: RateLimitInfo?
    let codeReviewRateLimit: RateLimitInfo?
    let credits: CreditsInfo?
    
    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case credits
    }
}

nonisolated struct RateLimitInfo: Codable, Sendable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: WindowInfo?
    let secondaryWindow: WindowInfo?
    
    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

nonisolated struct WindowInfo: Codable, Sendable {
    let usedPercent: Int?
    let limitWindowSeconds: Int?
    let resetAfterSeconds: Int?
    let resetAt: Int?
    
    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

nonisolated struct CreditsInfo: Codable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
    
    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

nonisolated struct CodexQuotaData: Codable, Sendable {
    let planType: String
    let sessionUsedPercent: Int
    let sessionResetAt: Date?
    let weeklyUsedPercent: Int
    let weeklyResetAt: Date?
    let limitReached: Bool
    let lastUpdated: Date
    
    init(from response: CodexUsageResponse) {
        self.planType = response.planType ?? "unknown"
        self.sessionUsedPercent = response.rateLimit?.primaryWindow?.usedPercent ?? 0
        self.weeklyUsedPercent = response.rateLimit?.secondaryWindow?.usedPercent ?? 0
        self.limitReached = response.rateLimit?.limitReached ?? false
        self.lastUpdated = Date()
        
        if let resetAt = response.rateLimit?.primaryWindow?.resetAt {
            self.sessionResetAt = Date(timeIntervalSince1970: TimeInterval(resetAt))
        } else {
            self.sessionResetAt = nil
        }
        
        if let resetAt = response.rateLimit?.secondaryWindow?.resetAt {
            self.weeklyResetAt = Date(timeIntervalSince1970: TimeInterval(resetAt))
        } else {
            self.weeklyResetAt = nil
        }
    }
    
    nonisolated var sessionRemainingPercent: Double {
        Double(100 - sessionUsedPercent)
    }
    
    nonisolated var weeklyRemainingPercent: Double {
        Double(100 - weeklyUsedPercent)
    }
    
    nonisolated func toProviderQuotaData() -> ProviderQuotaData {
        var models: [ModelQuota] = []
        
        models.append(ModelQuota(
            name: "codex-session",
            percentage: sessionRemainingPercent,
            resetTime: sessionResetAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        ))
        
        models.append(ModelQuota(
            name: "codex-weekly",
            percentage: weeklyRemainingPercent,
            resetTime: weeklyResetAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        ))
        
        return ProviderQuotaData(
            models: models,
            lastUpdated: lastUpdated,
            isForbidden: limitReached,
            planType: planType
        )
    }
}

nonisolated struct CodexAuthFile: Codable, Sendable {
    var accessToken: String
    let accountId: String?
    let email: String?
    let expired: String?
    let idToken: String?
    let refreshToken: String?
    let type: String?
    // Fields preserved during token refresh (used by CLIProxyAPI)
    var prefix: String?
    var proxyUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountId = "account_id"
        case email
        case expired
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case type
        case prefix
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

private nonisolated struct TokenRefreshResponse: Codable, Sendable {
    let accessToken: String
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

nonisolated enum CodexQuotaError: LocalizedError {
    case invalidResponse
    case invalidURL
    case httpError(Int)
    case noAccessToken
    case tokenRefreshFailed
    case decodingError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from ChatGPT"
        case .invalidURL: return "Invalid URL"
        case .httpError(let code): return "HTTP error: \(code)"
        case .noAccessToken: return "No access token found in auth file"
        case .tokenRefreshFailed: return "Failed to refresh token"
        case .decodingError(let msg): return "Failed to decode: \(msg)"
        }
    }
}
