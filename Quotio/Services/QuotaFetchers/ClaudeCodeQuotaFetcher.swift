//
//  ClaudeCodeQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Claude auth files in ~/.cli-proxy-api/
//  Calls Anthropic OAuth API for usage data
//

import Foundation

/// API fetch result type
nonisolated enum ClaudeAPIResult: Sendable {
    case success(ClaudeCodeQuotaInfo)
    case authenticationError  // Token expired or invalid - needs re-authentication
    case otherError
}

/// Quota data from Claude Code OAuth API
nonisolated struct ClaudeCodeQuotaInfo: Sendable {
    let accessToken: String?
    let email: String?

    /// Usage quotas from OAuth API
    let fiveHour: QuotaUsage?
    let sevenDay: QuotaUsage?
    let sevenDaySonnet: QuotaUsage?
    let sevenDayOpus: QuotaUsage?
    let extraUsage: ExtraUsage?

    struct QuotaUsage: Sendable {
        let utilization: Double  // Percentage used (0-100)
        let resetsAt: String     // ISO8601 date string

        /// Remaining percentage (100 - utilization), clamped to 0-100
        var remaining: Double {
            max(0, min(100, 100 - utilization))
        }
    }

    struct ExtraUsage: Sendable {
        let isEnabled: Bool
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Double?

        /// Remaining percentage for extra usage, clamped to 0-100
        var remaining: Double? {
            guard let util = utilization else { return nil }
            return max(0, min(100, 100 - util))
        }
    }
}

/// Fetches quota from Claude auth files using OAuth API
actor ClaudeCodeQuotaFetcher {

    /// Auth directory for CLI Proxy API
    private let authDir = "~/.cli-proxy-api"

    /// Anthropic OAuth usage API endpoint
    private let usageURL = "https://api.anthropic.com/api/oauth/usage"

    /// Anthropic OAuth token refresh endpoint
    private let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// URLSession for network requests
    private var session: URLSession

    /// Cache for quota data to reduce API calls
    private var quotaCache: [String: CachedQuota] = [:]

    /// Cache TTL: 5 minutes
    private let cacheTTL: TimeInterval = 300

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    private struct CachedQuota {
        let data: ProviderQuotaData
        let timestamp: Date

        func isValid(ttl: TimeInterval) -> Bool {
            Date().timeIntervalSince(timestamp) < ttl
        }
    }

    /// Parse a quota usage object from JSON
    private func parseQuotaUsage(from json: [String: Any]?) -> ClaudeCodeQuotaInfo.QuotaUsage? {
        guard let json = json else { return nil }
        
        // Handle both Int and Double for utilization
        let utilization: Double
        if let doubleVal = json["utilization"] as? Double {
            utilization = doubleVal
        } else if let intVal = json["utilization"] as? Int {
            utilization = Double(intVal)
        } else {
            return nil
        }
        
        // resets_at can be null
        let resetsAt = json["resets_at"] as? String ?? ""
        
        return ClaudeCodeQuotaInfo.QuotaUsage(utilization: utilization, resetsAt: resetsAt)
    }
    
    /// Parse extra usage object from JSON
    private func parseExtraUsage(from json: [String: Any]?) -> ClaudeCodeQuotaInfo.ExtraUsage? {
        guard let json = json else { return nil }
        
        let isEnabled = json["is_enabled"] as? Bool ?? false
        
        // Only parse if enabled
        guard isEnabled else { return nil }
        
        let monthlyLimit = json["monthly_limit"] as? Double
        let usedCredits = json["used_credits"] as? Double
        let utilization = json["utilization"] as? Double
        
        return ClaudeCodeQuotaInfo.ExtraUsage(
            isEnabled: isEnabled,
            monthlyLimit: monthlyLimit,
            usedCredits: usedCredits,
            utilization: utilization
        )
    }

    /// Check if the access token is expired based on the auth file's "expired" field
    private func isTokenExpired(json: [String: Any]) -> Bool {
        guard let expiredStr = json["expired"] as? String else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let expiryDate = formatter.date(from: expiredStr) {
            return Date() > expiryDate.addingTimeInterval(-60) // 60s buffer
        }
        // Fallback without fractional seconds
        let fallback = ISO8601DateFormatter()
        if let expiryDate = fallback.date(from: expiredStr) {
            return Date() > expiryDate.addingTimeInterval(-60)
        }
        return false
    }

    /// Refresh an expired access token using the refresh token
    /// - Returns: Tuple of new access token, optional new refresh token, and optional expires_in
    private func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int?) {
        guard let url = URL(string: tokenURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId
        ]
        let body = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            NSLog("[ClaudeQuota] Token refresh failed with HTTP \(statusCode)")
            throw URLError(.userAuthenticationRequired)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            throw URLError(.cannotParseResponse)
        }

        let newRefreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? Int

        return (newAccessToken, newRefreshToken, expiresIn)
    }

    /// Update the auth file on disk with refreshed token data
    private func updateAuthFile(at path: String, json: [String: Any], accessToken: String, refreshToken: String?, expiresIn: Int?) {
        var updatedJSON = json
        updatedJSON["access_token"] = accessToken
        if let refreshToken = refreshToken {
            updatedJSON["refresh_token"] = refreshToken
        }

        let now = Date()
        let formatter = ISO8601DateFormatter()
        updatedJSON["last_refresh"] = formatter.string(from: now)

        if let expiresIn = expiresIn {
            let expiryDate = now.addingTimeInterval(TimeInterval(expiresIn))
            updatedJSON["expired"] = formatter.string(from: expiryDate)
        }

        if let data = try? JSONSerialization.data(withJSONObject: updatedJSON, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Fetch usage data from Anthropic OAuth API
    /// - Returns: ClaudeAPIResult indicating success, auth error, or other error
    private func fetchUsageFromAPI(accessToken: String, email: String?) async -> ClaudeAPIResult {
        guard let url = URL(string: usageURL) else {
            return .otherError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        do {
            let (data, response) = try await session.data(for: request)

            // Check HTTP status code
            if let httpResponse = response as? HTTPURLResponse {
                // 401 Unauthorized indicates authentication error
                if httpResponse.statusCode == 401 {
                    return .authenticationError
                }
                // Other non-2xx status codes
                if !(200...299 ~= httpResponse.statusCode) {
                    NSLog("[ClaudeQuota] HTTP error: \(httpResponse.statusCode)")
                    return .otherError
                }
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[ClaudeQuota] Failed to parse JSON response")
                return .otherError
            }

            // Check for API error response
            if json["type"] as? String == "error" {
                // Check if it's an authentication error
                if let errorObj = json["error"] as? [String: Any],
                   let errorType = errorObj["type"] as? String,
                   errorType == "authentication_error" {
                    // Token expired or invalid
                    NSLog("[ClaudeQuota] Authentication error for \(email ?? "unknown")")
                    return .authenticationError
                }
                NSLog("[ClaudeQuota] API error: \(json)")
                return .otherError
            }

            // API returns data directly (no wrapper)
            let fiveHour = parseQuotaUsage(from: json["five_hour"] as? [String: Any])
            let sevenDay = parseQuotaUsage(from: json["seven_day"] as? [String: Any])
            let sevenDaySonnet = parseQuotaUsage(from: json["seven_day_sonnet"] as? [String: Any])
            let sevenDayOpus = parseQuotaUsage(from: json["seven_day_opus"] as? [String: Any])
            let extraUsage = parseExtraUsage(from: json["extra_usage"] as? [String: Any])

            return .success(ClaudeCodeQuotaInfo(
                accessToken: accessToken,
                email: email,
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                sevenDaySonnet: sevenDaySonnet,
                sevenDayOpus: sevenDayOpus,
                extraUsage: extraUsage
            ))
        } catch {
            NSLog("[ClaudeQuota] Network error: \(error.localizedDescription)")
            return .otherError
        }
    }

    /// Fetch quota for all Claude accounts from auth files in ~/.cli-proxy-api/
    /// - Parameter forceRefresh: If true, bypass cache and fetch fresh data
    func fetchAsProviderQuota(forceRefresh: Bool = false) async -> [String: ProviderQuotaData] {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default
        
        guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return [:]
        }
        
        // Filter for claude auth files
        let claudeFiles = files.filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") }
        
        guard !claudeFiles.isEmpty else { return [:] }
        
        var results: [String: ProviderQuotaData] = [:]
        
        // Process Claude auth files concurrently
        await withTaskGroup(of: (String, ProviderQuotaData?).self) { group in
            for file in claudeFiles {
                let filePath = (expandedPath as NSString).appendingPathComponent(file)
                
                group.addTask {
                    guard let quota = await self.fetchQuotaFromAuthFile(at: filePath, forceRefresh: forceRefresh) else {
                        return ("", nil)
                    }
                    return (quota.email, quota.data)
                }
            }
            
            for await (email, data) in group {
                if !email.isEmpty, let data = data {
                    results[email] = data
                }
            }
        }
        
        return results
    }
    
    /// Fetch quota from a single auth file
    /// - Parameters:
    ///   - path: Path to the auth file
    ///   - forceRefresh: If true, bypass cache
    private func fetchQuotaFromAuthFile(at path: String, forceRefresh: Bool = false) async -> (email: String, data: ProviderQuotaData)? {
        let fileManager = FileManager.default

        guard let data = fileManager.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard var accessToken = json["access_token"] as? String,
              let email = json["email"] as? String else {
            return nil
        }

        // Check cache first (unless force refresh)
        if !forceRefresh, let cached = quotaCache[email], cached.isValid(ttl: cacheTTL) {
            return (email, cached.data)
        }

        // Refresh expired token before fetching usage
        if isTokenExpired(json: json), let refreshToken = json["refresh_token"] as? String {
            do {
                let refreshed = try await refreshAccessToken(refreshToken: refreshToken)
                accessToken = refreshed.accessToken
                updateAuthFile(at: path, json: json, accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken, expiresIn: refreshed.expiresIn)
                NSLog("[ClaudeQuota] Token refreshed for \(email)")
            } catch {
                NSLog("[ClaudeQuota] Token refresh failed for \(email): \(error.localizedDescription)")
                // Fall through with expired token; API call will return authenticationError
            }
        }

        // Fetch usage from API using the token
        let result = await fetchUsageFromAPI(accessToken: accessToken, email: email)

        switch result {
        case .success(let info):
            // Convert to ProviderQuotaData
            var models: [ModelQuota] = []

            if let fiveHour = info.fiveHour {
                models.append(ModelQuota(
                    name: "five-hour-session",
                    percentage: fiveHour.remaining,
                    resetTime: fiveHour.resetsAt
                ))
            }

            if let sevenDay = info.sevenDay {
                models.append(ModelQuota(
                    name: "seven-day-weekly",
                    percentage: sevenDay.remaining,
                    resetTime: sevenDay.resetsAt
                ))
            }

            if let sonnet = info.sevenDaySonnet {
                models.append(ModelQuota(
                    name: "seven-day-sonnet",
                    percentage: sonnet.remaining,
                    resetTime: sonnet.resetsAt
                ))
            }

            if let opus = info.sevenDayOpus {
                models.append(ModelQuota(
                    name: "seven-day-opus",
                    percentage: opus.remaining,
                    resetTime: opus.resetsAt
                ))
            }

            if let extra = info.extraUsage, let remaining = extra.remaining {
                var extraModel = ModelQuota(
                    name: "extra-usage",
                    percentage: remaining,
                    resetTime: ""
                )
                // Add usage details if available
                if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                    extraModel.used = Int(used)
                    extraModel.limit = Int(limit)
                }
                models.append(extraModel)
            }

            guard !models.isEmpty else { return nil }

            let quotaData = ProviderQuotaData(
                models: models,
                lastUpdated: Date(),
                isForbidden: false,
                planType: nil
            )

            // Update cache
            quotaCache[email] = CachedQuota(data: quotaData, timestamp: Date())

            return (email, quotaData)

        case .authenticationError:
            // Token expired and refresh failed - return isForbidden to trigger re-authentication UI
            let quotaData = ProviderQuotaData(
                models: [],
                lastUpdated: Date(),
                isForbidden: true,  // Indicates re-authentication needed
                planType: nil
            )
            // Don't cache auth errors - allow retry
            return (email, quotaData)

        case .otherError:
            // Return cached data if API fails with non-auth error
            if let cached = quotaCache[email] {
                return (email, cached.data)
            }
            return nil
        }
    }
    
    /// Clear the quota cache
    func clearCache() {
        quotaCache.removeAll()
    }
    
    /// Clear cache for a specific email
    func clearCache(for email: String) {
        quotaCache.removeValue(forKey: email)
    }
}
