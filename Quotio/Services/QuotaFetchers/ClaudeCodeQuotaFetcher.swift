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
    private let tokenURL = "https://platform.claude.com/v1/oauth/token"
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
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let params: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
            "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: params)

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
    private func updateAuthFile(
        at path: String,
        expectedRefreshToken: String?,
        accessToken: String,
        refreshToken: String?,
        expiresIn: Int?
    ) {
        guard let latestData = FileManager.default.contents(atPath: path),
              let latestJSON = try? JSONSerialization.jsonObject(with: latestData) as? [String: Any] else { return }
        let latestOAuth = latestJSON["claudeAiOauth"] as? [String: Any]
        let latestRefresh = latestJSON["refresh_token"] as? String ?? latestOAuth?["refreshToken"] as? String
        guard latestRefresh == expectedRefreshToken else { return }
        let updatedJSON = updatedAuthJSON(
            latestJSON,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn
        )
        if let data = try? JSONSerialization.data(withJSONObject: updatedJSON, options: [.prettyPrinted, .sortedKeys]) {
            try? SecureAtomicFileWriter.write(data, to: URL(fileURLWithPath: path))
        }
    }

    private func updatedAuthJSON(
        _ json: [String: Any],
        accessToken: String,
        refreshToken: String?,
        expiresIn: Int?
    ) -> [String: Any] {
        var updatedJSON = json
        let now = Date()
        let formatter = ISO8601DateFormatter()
        if var oauth = updatedJSON["claudeAiOauth"] as? [String: Any] {
            oauth["accessToken"] = accessToken
            if let refreshToken { oauth["refreshToken"] = refreshToken }
            if let expiresIn {
                oauth["expiresAt"] = Int(now.addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970 * 1000)
            }
            updatedJSON["claudeAiOauth"] = oauth
        } else {
            updatedJSON["access_token"] = accessToken
            if let refreshToken { updatedJSON["refresh_token"] = refreshToken }
            updatedJSON["last_refresh"] = formatter.string(from: now)
            if let expiresIn {
                updatedJSON["expired"] = formatter.string(from: now.addingTimeInterval(TimeInterval(expiresIn)))
            }
        }

        return updatedJSON
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
        request.addValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await session.data(for: request)

            // Check HTTP status code
            if let httpResponse = response as? HTTPURLResponse {
                // 401 Unauthorized indicates authentication error
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
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
        let legacyFiles = (try? fileManager.contentsOfDirectory(atPath: expandedPath))?
            .filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") }
            .map { (expandedPath as NSString).appendingPathComponent($0) } ?? []
        let claudeHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nativeBase = (claudeHome?.isEmpty == false ? claudeHome! : NSString(string: "~/.claude").expandingTildeInPath)
        let nativePath = (nativeBase as NSString).appendingPathComponent(".credentials.json")
        let nativePaths = fileManager.fileExists(atPath: nativePath) ? [nativePath] : []
        var results = await fetchOwnedQuotas(forceRefresh: forceRefresh)
        for (key, quota) in await fetchNativeKeychainQuotas(forceRefresh: forceRefresh) where results[key] == nil {
            results[key] = quota
        }
        for filePath in nativePaths {
            guard let quota = await fetchQuotaFromAuthFile(at: filePath, forceRefresh: forceRefresh),
                  results[quota.email] == nil else { continue }
            results[quota.email] = quota.data
        }

        if let desktop = await fetchClaudeDesktopQuota(forceRefresh: forceRefresh),
           results[desktop.key] == nil {
            results[desktop.key] = desktop.value
        }

        for filePath in legacyFiles {
            guard let quota = await fetchQuotaFromAuthFile(at: filePath, forceRefresh: forceRefresh),
                  results[quota.email] == nil else { continue }
            results[quota.email] = quota.data
        }
        
        return results
    }

    private func fetchClaudeDesktopQuota(forceRefresh: Bool) async -> (key: String, value: ProviderQuotaData)? {
        let key = "Claude Desktop"
        if !forceRefresh, let cached = quotaCache[key], cached.isValid(ttl: cacheTTL) {
            return (key, cached.data)
        }
        guard let credential = ClaudeDesktopCredentialReader.load() else { return nil }
        let response = await fetchUsageFromAPI(accessToken: credential.accessToken, email: key)
        guard case .success(let info) = response, let quota = quotaData(from: info) else { return nil }
        quotaCache[key] = CachedQuota(data: quota, timestamp: Date())
        return (key, quota)
    }

    private func fetchNativeKeychainQuotas(forceRefresh: Bool) async -> [String: ProviderQuotaData] {
        guard let record = KeychainHelper.readExternalCredentialRecord(service: "Claude Code-credentials"),
              let json = try? JSONSerialization.jsonObject(with: record.data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              var accessToken = oauth["accessToken"] as? String else { return [:] }
        let email = oauth["email"] as? String ?? "Claude Code"
        if !forceRefresh, let cached = quotaCache[email], cached.isValid(ttl: cacheTTL) {
            return [email: cached.data]
        }
        let refreshToken = oauth["refreshToken"] as? String
        do {
            if isTokenExpired(json: normalizedExpiryJSON(json)), let refreshToken {
                let refreshed = try await refreshAccessToken(refreshToken: refreshToken)
                accessToken = refreshed.accessToken
                persistClaudeKeychainRefresh(
                    record: record,
                    json: json,
                    accessToken: refreshed.accessToken,
                    expectedRefreshToken: refreshToken,
                    newRefreshToken: refreshed.refreshToken ?? refreshToken,
                    expiresIn: refreshed.expiresIn
                )
            }
            var response = await fetchUsageFromAPI(accessToken: accessToken, email: email)
            if case .authenticationError = response,
               let latest = KeychainHelper.readExternalCredentialRecord(service: "Claude Code-credentials", account: record.account),
               let latestJSON = try? JSONSerialization.jsonObject(with: latest.data) as? [String: Any],
               let latestOAuth = latestJSON["claudeAiOauth"] as? [String: Any],
               let latestRefreshToken = latestOAuth["refreshToken"] as? String {
                let refreshed = try await refreshAccessToken(refreshToken: latestRefreshToken)
                accessToken = refreshed.accessToken
                persistClaudeKeychainRefresh(
                    record: latest,
                    json: latestJSON,
                    accessToken: refreshed.accessToken,
                    expectedRefreshToken: latestRefreshToken,
                    newRefreshToken: refreshed.refreshToken ?? latestRefreshToken,
                    expiresIn: refreshed.expiresIn
                )
                response = await fetchUsageFromAPI(accessToken: accessToken, email: email)
            }
            guard case .success(let info) = response, let quota = quotaData(from: info) else { return [:] }
            quotaCache[email] = CachedQuota(data: quota, timestamp: Date())
            return [email: quota]
        } catch {
            return quotaCache[email].map { [email: $0.data] } ?? [:]
        }
    }

    private func persistClaudeKeychainRefresh(
        record: (data: Data, account: String),
        json: [String: Any],
        accessToken: String,
        expectedRefreshToken: String,
        newRefreshToken: String,
        expiresIn: Int?
    ) {
        guard let oauth = json["claudeAiOauth"] as? [String: Any],
              oauth["refreshToken"] as? String == expectedRefreshToken else { return }
        let updated = updatedAuthJSON(
            json,
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresIn: expiresIn
        )
        guard let data = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]) else { return }
        _ = KeychainHelper.compareAndSwapExternalCredential(
            service: "Claude Code-credentials",
            account: record.account,
            expectedData: record.data,
            newData: data
        )
    }

    private func fetchOwnedQuotas(forceRefresh: Bool) async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        for account in await MonitorCredentialVault.shared.accounts().filter({ $0.provider == .claude && !$0.isDisabled }) {
            guard var credential = await MonitorCredentialVault.shared.credential(for: account.id) else { continue }
            if !forceRefresh, let cached = quotaCache[account.accountKey], cached.isValid(ttl: cacheTTL) {
                results[account.accountKey] = cached.data
                continue
            }
            do {
                if credential.expiresAt.map({ $0.timeIntervalSinceNow < 300 }) ?? false,
                   let refreshToken = credential.refreshToken {
                    let refreshed = try await refreshAccessToken(refreshToken: refreshToken)
                    credential.accessToken = refreshed.accessToken
                    credential.refreshToken = refreshed.refreshToken ?? refreshToken
                    credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                    try await MonitorCredentialVault.shared.save(credential, metadata: account)
                }
                var response = await fetchUsageFromAPI(accessToken: credential.accessToken, email: account.accountKey)
                if case .authenticationError = response {
                    if let latest = await MonitorCredentialVault.shared.reloadLatest(accountID: account.id) {
                        credential = latest
                    }
                    guard let refreshToken = credential.refreshToken else { continue }
                    let refreshed = try await refreshAccessToken(refreshToken: refreshToken)
                    credential.accessToken = refreshed.accessToken
                    credential.refreshToken = refreshed.refreshToken ?? refreshToken
                    credential.expiresAt = refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                    try await MonitorCredentialVault.shared.save(credential, metadata: account)
                    response = await fetchUsageFromAPI(accessToken: credential.accessToken, email: account.accountKey)
                }
                if case .success(let info) = response, let data = quotaData(from: info) {
                    quotaCache[account.accountKey] = CachedQuota(data: data, timestamp: Date())
                    results[account.accountKey] = data
                }
            } catch {
                if let cached = quotaCache[account.accountKey] { results[account.accountKey] = cached.data }
            }
        }
        return results
    }

    private func quotaData(from info: ClaudeCodeQuotaInfo) -> ProviderQuotaData? {
        var models: [ModelQuota] = []
        if let value = info.fiveHour {
            models.append(ModelQuota(name: "five-hour-session", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let value = info.sevenDay {
            models.append(ModelQuota(name: "seven-day-weekly", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let value = info.sevenDaySonnet {
            models.append(ModelQuota(name: "seven-day-sonnet", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let value = info.sevenDayOpus {
            models.append(ModelQuota(name: "seven-day-opus", percentage: value.remaining, resetTime: value.resetsAt))
        }
        if let extra = info.extraUsage, let remaining = extra.remaining {
            var model = ModelQuota(name: "extra-usage", percentage: remaining, resetTime: "")
            if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                model.used = Int(used)
                model.limit = Int(limit)
            }
            models.append(model)
        }
        guard !models.isEmpty else { return nil }
        return ProviderQuotaData(models: models, lastUpdated: Date(), isForbidden: false, planType: nil)
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

        let nestedOAuth = json["claudeAiOauth"] as? [String: Any]
        guard var accessToken = (json["access_token"] as? String) ?? (nestedOAuth?["accessToken"] as? String) else {
            return nil
        }
        let email = (json["email"] as? String) ?? (nestedOAuth?["email"] as? String) ?? "Claude Code"

        // Check cache first (unless force refresh)
        if !forceRefresh, let cached = quotaCache[email], cached.isValid(ttl: cacheTTL) {
            return (email, cached.data)
        }

        // Refresh expired token before fetching usage
        let refreshToken = (json["refresh_token"] as? String) ?? (nestedOAuth?["refreshToken"] as? String)
        if isTokenExpired(json: normalizedExpiryJSON(json)), let refreshToken {
            do {
                let refreshed = try await refreshAccessToken(refreshToken: refreshToken)
                accessToken = refreshed.accessToken
                updateAuthFile(at: path, expectedRefreshToken: refreshToken, accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken ?? refreshToken, expiresIn: refreshed.expiresIn)
                NSLog("[ClaudeQuota] Token refreshed for \(email)")
            } catch {
                NSLog("[ClaudeQuota] Token refresh failed for \(email): \(error.localizedDescription)")
                // Fall through with expired token; API call will return authenticationError
            }
        }

        // Fetch usage from API using the token
        var result = await fetchUsageFromAPI(accessToken: accessToken, email: email)
        if case .authenticationError = result {
            do {
                guard let latestData = fileManager.contents(atPath: path),
                      let latestJSON = try? JSONSerialization.jsonObject(with: latestData) as? [String: Any] else {
                    return (email, ProviderQuotaData(models: [], lastUpdated: Date(), isForbidden: true))
                }
                let latestOAuth = latestJSON["claudeAiOauth"] as? [String: Any]
                guard let latestRefreshToken = (latestJSON["refresh_token"] as? String) ?? (latestOAuth?["refreshToken"] as? String) else {
                    return (email, ProviderQuotaData(models: [], lastUpdated: Date(), isForbidden: true))
                }
                let refreshed = try await refreshAccessToken(refreshToken: latestRefreshToken)
                accessToken = refreshed.accessToken
                updateAuthFile(at: path, expectedRefreshToken: latestRefreshToken, accessToken: refreshed.accessToken, refreshToken: refreshed.refreshToken ?? latestRefreshToken, expiresIn: refreshed.expiresIn)
                result = await fetchUsageFromAPI(accessToken: accessToken, email: email)
            } catch {
                // The authentication result below is kept so the UI can ask for a new login.
            }
        }

        switch result {
        case .success(let info):
            guard let quotaData = quotaData(from: info) else { return nil }

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

    private func normalizedExpiryJSON(_ json: [String: Any]) -> [String: Any] {
        guard let oauth = json["claudeAiOauth"] as? [String: Any] else { return json }
        var normalized = json
        if let expiresAt = oauth["expiresAt"] as? Double {
            normalized["expired"] = Date(timeIntervalSince1970: expiresAt / 1000).ISO8601Format()
        } else if let expiresAt = oauth["expiresAt"] as? NSNumber {
            normalized["expired"] = Date(timeIntervalSince1970: expiresAt.doubleValue / 1000).ISO8601Format()
        }
        return normalized
    }
}
