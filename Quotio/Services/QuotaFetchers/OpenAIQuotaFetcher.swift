//
//  OpenAIQuotaFetcher.swift
//  Quotio
//

import Foundation

actor OpenAIQuotaFetcher {
    private let defaultChatGPTBaseURL = "https://chatgpt.com/backend-api"
    private let chatGPTUsagePath = "/wham/usage"
    private let codexUsagePath = "/api/codex/usage"
    private let tokenURL = "https://token.oaifree.com/api/auth/refresh"
    
    private var session: URLSession
    
    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }
    
    func fetchQuota(accessToken: String, accountId: String?) async throws -> CodexQuotaData {
        var request = URLRequest(url: resolveUsageURL())
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("CodexBar", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            request.addValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexQuotaError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            throw CodexQuotaError.httpError(httpResponse.statusCode)
        }
        
        let quotaResponse = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        return CodexQuotaData(from: quotaResponse)
    }
    
    func fetchQuotaForAuthFile(at path: String) async throws -> (CodexQuotaData, AuthOverrides) {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let overrides = extractAuthOverrides(from: data)
        var authFile = try JSONDecoder().decode(CodexAuthFile.self, from: data)
        
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
        
        let quota = try await fetchQuota(accessToken: accessToken, accountId: overrides.accountId)
        return (quota, overrides)
    }
    
    private func refreshAccessToken(refreshToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: tokenURL)!)
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
                let (quota, overrides) = try await fetchQuotaForAuthFile(at: filePath)
                let email = file
                    .replacingOccurrences(of: "codex-", with: "")
                    .replacingOccurrences(of: ".json", with: "")
                results[email] = quota.toProviderQuotaData()
            } catch {
                print("Failed to fetch Codex quota for \(file): \(error)")
            }
        }
        
        return results
    }

    struct AuthOverrides {
        let accountId: String?
    }

    private func extractAuthOverrides(from data: Data) -> AuthOverrides {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AuthOverrides(accountId: nil)
        }

        if let accountId = json["account_id"] as? String, !accountId.isEmpty {
            return AuthOverrides(accountId: accountId)
        }

        if let idTokenObject = json["id_token"] as? [String: Any] {
            let accountId = (idTokenObject["chatgpt_account_id"] as? String)?.isEmpty == false
                ? idTokenObject["chatgpt_account_id"] as? String
                : (idTokenObject["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
            return AuthOverrides(accountId: accountId)
        }

        if let idTokenString = json["id_token"] as? String {
            return authOverridesFromJWT(idTokenString)
        }
        if let idTokenString = json["idToken"] as? String {
            return authOverridesFromJWT(idTokenString)
        }

        return AuthOverrides(accountId: nil)
    }

    private func authOverridesFromJWT(_ token: String) -> AuthOverrides {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return AuthOverrides(accountId: nil) }

        var base64 = String(segments[1])
        let padLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padLength)
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AuthOverrides(accountId: nil)
        }

        if let authInfo = json["https://api.openai.com/auth"] as? [String: Any] {
            let accountId = authInfo["chatgpt_account_id"] as? String
            return AuthOverrides(accountId: accountId)
        }

        return AuthOverrides(accountId: nil)
    }

    private func resolveUsageURL() -> URL {
        resolveUsageURL(env: ProcessInfo.processInfo.environment, configContents: nil)
    }

    private func resolveUsageURL(env: [String: String], configContents: String?) -> URL {
        let baseURL = resolveChatGPTBaseURL(env: env, configContents: configContents)
        let normalized = normalizeChatGPTBaseURL(baseURL)
        let path = normalized.contains("/backend-api") ? chatGPTUsagePath : codexUsagePath
        let full = normalized + path
        return URL(string: full) ?? URL(string: defaultChatGPTBaseURL + chatGPTUsagePath)!
    }

    private func resolveChatGPTBaseURL(env: [String: String], configContents: String?) -> String {
        if let configContents, let parsed = parseChatGPTBaseURL(from: configContents) {
            return parsed
        }
        if let contents = loadConfigContents(env: env),
           let parsed = parseChatGPTBaseURL(from: contents) {
            return parsed
        }
        return defaultChatGPTBaseURL
    }

    private func normalizeChatGPTBaseURL(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = defaultChatGPTBaseURL }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if (trimmed.hasPrefix("https://chatgpt.com") || trimmed.hasPrefix("https://chat.openai.com")),
           !trimmed.contains("/backend-api") {
            trimmed += "/backend-api"
        }
        return trimmed
    }

    private func parseChatGPTBaseURL(from contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true).first
            let trimmed = line?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "chatgpt_base_url" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func loadConfigContents(env: [String: String]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = (codexHome?.isEmpty == false)
            ? URL(fileURLWithPath: codexHome!)
            : home.appendingPathComponent(".codex")
        let url = root.appendingPathComponent("config.toml")
        return try? String(contentsOf: url, encoding: .utf8)
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
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountId = "account_id"
        case email
        case expired
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case type
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
    case httpError(Int)
    case noAccessToken
    case tokenRefreshFailed
    case decodingError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from ChatGPT"
        case .httpError(let code): return "HTTP error: \(code)"
        case .noAccessToken: return "No access token found in auth file"
        case .tokenRefreshFailed: return "Failed to refresh token"
        case .decodingError(let msg): return "Failed to decode: \(msg)"
        }
    }
}
