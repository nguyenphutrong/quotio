//
//  CodexCLIQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Codex CLI by reading ~/.codex/auth.json and calling ChatGPT usage API
//  Used in Quota-Only mode for direct quota tracking without proxy
//

import Foundation

/// Auth file structure for Codex CLI (~/.codex/auth.json)
nonisolated struct CodexCLIAuthFile: Codable, Sendable {
    let OPENAI_API_KEY: String?
    let tokens: CodexCLITokens?
    let lastRefresh: String?
    
    enum CodingKeys: String, CodingKey {
        case OPENAI_API_KEY
        case tokens
        case lastRefresh = "last_refresh"
    }
}

nonisolated struct CodexCLITokens: Codable, Sendable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?
    let accountId: String?
    
    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountId = "account_id"
    }
}

/// Decoded JWT claims from Codex id_token
nonisolated struct CodexJWTClaims: Sendable {
    let email: String?
    let emailVerified: Bool
    let planType: String?
    let accountId: String?
    let userId: String?
    let organizationName: String?
    let subscriptionActiveUntil: Date?
}

/// Quota data from Codex CLI
nonisolated struct CodexCLIQuotaInfo: Sendable {
    let email: String
    let planType: String?
    let organizationName: String?
    let subscriptionActiveUntil: Date?
    
    /// Session (3-hour window) usage
    let sessionUsedPercent: Int
    let sessionResetAt: Date?
    
    /// Weekly usage
    let weeklyUsedPercent: Int
    let weeklyResetAt: Date?
    
    let limitReached: Bool
}

/// Fetches quota from Codex CLI auth file
actor CodexCLIQuotaFetcher {
    private let authFilePath = "~/.codex/auth.json"
    private let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private let refreshURL = "https://auth.openai.com/oauth/token"
    
    private let session: URLSession
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }
    
    /// Check if Codex auth file exists
    func isAuthFilePresent() -> Bool {
        let expandedPath = NSString(string: authFilePath).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expandedPath)
    }
    
    /// Read auth file from ~/.codex/auth.json
    func readAuthFile() -> CodexCLIAuthFile? {
        let expandedPath = NSString(string: authFilePath).expandingTildeInPath
        
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: expandedPath)) else {
            return nil
        }
        
        return try? JSONDecoder().decode(CodexCLIAuthFile.self, from: data)
    }
    
    /// Decode JWT to extract email and plan info
    func decodeJWT(token: String) -> CodexJWTClaims? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        
        var base64 = String(segments[1])
        // Add padding if needed
        let padLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padLength)
        
        // Replace URL-safe characters
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        
        guard let data = Data(base64Encoded: base64) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        
        // Extract email
        let email = json["email"] as? String
        let emailVerified = json["email_verified"] as? Bool ?? false
        
        // Extract plan info from nested auth object
        var planType: String? = nil
        var accountId: String? = nil
        var userId: String? = nil
        var orgName: String? = nil
        var subscriptionUntil: Date? = nil
        
        if let authInfo = json["https://api.openai.com/auth"] as? [String: Any] {
            planType = authInfo["chatgpt_plan_type"] as? String
            accountId = authInfo["chatgpt_account_id"] as? String
            userId = authInfo["chatgpt_user_id"] as? String
            
            // Parse organizations
            if let orgs = authInfo["organizations"] as? [[String: Any]], let firstOrg = orgs.first {
                orgName = firstOrg["title"] as? String
            }
            
            // Parse subscription end date
            if let untilStr = authInfo["chatgpt_subscription_active_until"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                subscriptionUntil = formatter.date(from: untilStr)
            }
        }
        
        return CodexJWTClaims(
            email: email,
            emailVerified: emailVerified,
            planType: planType,
            accountId: accountId,
            userId: userId,
            organizationName: orgName,
            subscriptionActiveUntil: subscriptionUntil
        )
    }
    
    /// Fetch quota from ChatGPT usage API
    func fetchQuota(accessToken: String) async throws -> CodexCLIQuotaInfo {
        var request = URLRequest(url: URL(string: usageURL)!)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexCLIQuotaError.invalidResponse
        }
        
        guard 200...299 ~= httpResponse.statusCode else {
            throw CodexCLIQuotaError.httpError(httpResponse.statusCode)
        }
        
        // Parse the usage response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexCLIQuotaError.invalidResponse
        }
        
        return parseUsageResponse(json)
    }
    
    /// Parse usage API response
    private func parseUsageResponse(_ json: [String: Any]) -> CodexCLIQuotaInfo {
        let planType = json["plan_type"] as? String
        
        var sessionUsedPercent = 0
        var sessionResetAt: Date? = nil
        var weeklyUsedPercent = 0
        var weeklyResetAt: Date? = nil
        var limitReached = false
        
        if let rateLimit = json["rate_limit"] as? [String: Any] {
            limitReached = rateLimit["limit_reached"] as? Bool ?? false
            
            // Primary window = session (3h)
            if let primaryWindow = rateLimit["primary_window"] as? [String: Any] {
                sessionUsedPercent = primaryWindow["used_percent"] as? Int ?? 0
                if let resetAt = primaryWindow["reset_at"] as? Int {
                    sessionResetAt = Date(timeIntervalSince1970: TimeInterval(resetAt))
                }
            }
            
            // Secondary window = weekly
            if let secondaryWindow = rateLimit["secondary_window"] as? [String: Any] {
                weeklyUsedPercent = secondaryWindow["used_percent"] as? Int ?? 0
                if let resetAt = secondaryWindow["reset_at"] as? Int {
                    weeklyResetAt = Date(timeIntervalSince1970: TimeInterval(resetAt))
                }
            }
        }
        
        return CodexCLIQuotaInfo(
            email: "Codex User",
            planType: planType,
            organizationName: nil,
            subscriptionActiveUntil: nil,
            sessionUsedPercent: sessionUsedPercent,
            sessionResetAt: sessionResetAt,
            weeklyUsedPercent: weeklyUsedPercent,
            weeklyResetAt: weeklyResetAt,
            limitReached: limitReached
        )
    }
    
    /// Refresh access token using refresh token
    func refreshAccessToken(refreshToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: refreshURL)!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"  // Codex CLI client ID
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            throw CodexCLIQuotaError.tokenRefreshFailed
        }
        
        struct RefreshResponse: Codable {
            let access_token: String
        }
        
        let tokenResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return tokenResponse.access_token
    }
    
    /// Check if access token is expired by decoding JWT
    func isTokenExpired(accessToken: String) -> Bool {
        let segments = accessToken.split(separator: ".")
        guard segments.count >= 2 else { return true }
        
        var base64 = String(segments[1])
        let padLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: padLength)
        base64 = base64.replacingOccurrences(of: "-", with: "+")
        base64 = base64.replacingOccurrences(of: "_", with: "/")
        
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return true
        }
        
        // Token is expired if exp is in the past (with 60s buffer)
        return Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(60)
    }
    
    /// Fetch quota and convert to ProviderQuotaData for unified display
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        guard let authFile = readAuthFile(),
              let tokens = authFile.tokens,
              let accessToken = tokens.accessToken else {
            return [:]
        }
        
        // Get email and plan from id_token
        var email = "Codex User"
        var planType: String? = nil
        
        if let idToken = tokens.idToken, let claims = decodeJWT(token: idToken) {
            email = claims.email ?? email
            planType = claims.planType
        }
        
        // Check if token is expired and try to refresh
        var currentAccessToken = accessToken
        if isTokenExpired(accessToken: accessToken), let refreshToken = tokens.refreshToken {
            do {
                currentAccessToken = try await refreshAccessToken(refreshToken: refreshToken)
            } catch {
                print("Failed to refresh Codex token: \(error)")
                // Continue with potentially expired token, API will fail if truly expired
            }
        }
        
        // Fetch quota from API
        do {
            let quotaInfo = try await fetchQuota(accessToken: currentAccessToken)
            
            // Build model quotas
            var models: [ModelQuota] = []
            
            // Session quota (3-hour window)
            let sessionResetStr: String
            if let resetAt = quotaInfo.sessionResetAt {
                sessionResetStr = ISO8601DateFormatter().string(from: resetAt)
            } else {
                sessionResetStr = ""
            }
            models.append(ModelQuota(
                name: "codex-session",
                percentage: Double(100 - quotaInfo.sessionUsedPercent),
                resetTime: sessionResetStr
            ))
            
            // Weekly quota
            let weeklyResetStr: String
            if let resetAt = quotaInfo.weeklyResetAt {
                weeklyResetStr = ISO8601DateFormatter().string(from: resetAt)
            } else {
                weeklyResetStr = ""
            }
            models.append(ModelQuota(
                name: "codex-weekly",
                percentage: Double(100 - quotaInfo.weeklyUsedPercent),
                resetTime: weeklyResetStr
            ))
            
            let providerQuota = ProviderQuotaData(
                models: models,
                lastUpdated: Date(),
                isForbidden: quotaInfo.limitReached,
                planType: planType ?? quotaInfo.planType
            )
            
            return [email: providerQuota]
        } catch {
            print("Failed to fetch Codex quota: \(error)")
            return [:]
        }
    }
}

// MARK: - Errors

nonisolated enum CodexCLIQuotaError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case noAccessToken
    case tokenRefreshFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from ChatGPT"
        case .httpError(let code): return "HTTP error: \(code)"
        case .noAccessToken: return "No access token found in Codex auth file"
        case .tokenRefreshFailed: return "Failed to refresh Codex token"
        }
    }
}
