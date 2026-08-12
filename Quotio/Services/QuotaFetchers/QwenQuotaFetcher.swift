//
//  QwenQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Qwen Code CLI OAuth auth files
//  Calls DashScope API for usage data
//

import Foundation

/// API fetch result type
nonisolated enum QwenAPIResult: Sendable {
    case success(QwenQuotaInfo)
    case authenticationError  // Token expired or invalid - needs re-authentication
    case otherError
}

/// Quota data from Qwen/DashScope API
nonisolated struct QwenQuotaInfo: Sendable {
    let accessToken: String?
    let email: String?

    /// Usage quotas from DashScope API
    let fiveHour: QuotaUsage?
    let weekly: QuotaUsage?
    let monthly: QuotaUsage?

    struct QuotaUsage: Sendable {
        let utilization: Double  // Percentage used (0-100)
        let resetsAt: String     // ISO8601 date string
        let limit: Int?          // Optional limit value
        let used: Int?           // Optional used value

        /// Remaining percentage (100 - utilization), clamped to 0-100
        var remaining: Double {
            max(0, min(100, 100 - utilization))
        }

        /// Formatted reset time
        var formattedResetTime: String {
            guard !resetsAt.isEmpty,
                  let date = Self.parseISO8601Date(resetsAt) else {
                return ""
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
        private static func parseISO8601Date(_ dateString: String) -> Date? {
            let isoFormatterWithFractional = ISO8601DateFormatter()
            isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            let isoFormatterStandard = ISO8601DateFormatter()
            isoFormatterStandard.formatOptions = [.withInternetDateTime]

            return isoFormatterWithFractional.date(from: dateString)
                ?? isoFormatterStandard.date(from: dateString)
        }
    }
}

/// Fetches quota from Qwen auth files using DashScope API
actor QwenQuotaFetcher {

    /// Auth directory for CLI Proxy API
    private let authDir = "~/.cli-proxy-api"

    /// DashScope usage API endpoint
    private let usageURL = "https://dashscope-intl.aliyuncs.com/api/v1/usage"

    /// DashScope token refresh endpoint (if available)
    private let tokenURL = "https://dashscope-intl.aliyuncs.com/api/v1/token/refresh"

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

    /// Qwen auth file structure (~/.cli-proxy-api/qwen-*.json)
    nonisolated struct QwenAuthFile: Codable, Sendable {
        let accessToken: String?
        let refreshToken: String?
        let tokenType: String?
        let scope: String?
        let expiryDate: Double?  // Unix timestamp in milliseconds
        let idToken: String?
        let email: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case scope
            case expiryDate = "expiry_date"
            case idToken = "id_token"
            case email
        }
    }

    /// Check if the access token is expired
    private func isTokenExpired(json: [String: Any]) -> Bool {
        // Try expiry_date field (Unix timestamp in ms)
        if let expiryMs = json["expiry_date"] as? Double {
            let expiryDate = Date(timeIntervalSince1970: expiryMs / 1000)
            return Date() > expiryDate.addingTimeInterval(-60) // 60s buffer
        }

        // Try expired field (ISO8601 string)
        if let expiredStr = json["expired"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let expiryDate = formatter.date(from: expiredStr) {
                return Date() > expiryDate.addingTimeInterval(-60)
            }

            let fallback = ISO8601DateFormatter()
            if let expiryDate = fallback.date(from: expiredStr) {
                return Date() > expiryDate.addingTimeInterval(-60)
            }
        }

        return true // Assume expired if no expiry info
    }

    /// Refresh an expired access token using the refresh token
    private func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int?) {
        guard let url = URL(string: tokenURL) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        let body = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200...299 ~= httpResponse.statusCode else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            NSLog("[QwenQuota] Token refresh failed with HTTP \(statusCode)")
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

    /// Fetch usage data from DashScope API
    private func fetchUsageFromAPI(accessToken: String, email: String?) async -> QwenAPIResult {
        guard let url = URL(string: usageURL) else {
            return .otherError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

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
                    NSLog("[QwenQuota] HTTP error: \(httpResponse.statusCode)")
                    return .otherError
                }
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[QwenQuota] Failed to parse JSON response")
                return .otherError
            }

            // Check for API error response
            if json["type"] as? String == "error" {
                if let errorObj = json["error"] as? [String: Any],
                   let errorType = errorObj["type"] as? String,
                   errorType == "authentication_error" {
                    NSLog("[QwenQuota] Authentication error for \(email ?? "unknown")")
                    return .authenticationError
                }
                NSLog("[QwenQuota] API error: \(json)")
                return .otherError
            }

            // Parse usage data from response
            // Expected format: { "data": { "five_hour": {...}, "weekly": {...}, "monthly": {...} } }
            // or direct: { "five_hour": {...}, "weekly": {...}, "monthly": {...} }
            let dataObj = json["data"] as? [String: Any] ?? json

            let fiveHour = parseQuotaUsage(from: dataObj["five_hour"] as? [String: Any])
            let weekly = parseQuotaUsage(from: dataObj["weekly"] as? [String: Any])
            let monthly = parseQuotaUsage(from: dataObj["monthly"] as? [String: Any])

            return .success(QwenQuotaInfo(
                accessToken: accessToken,
                email: email,
                fiveHour: fiveHour,
                weekly: weekly,
                monthly: monthly
            ))
        } catch {
            NSLog("[QwenQuota] Network error: \(error.localizedDescription)")
            // Don't treat network errors as fatal - return success with no data
            // This allows the UI to show the account as connected even if quota API is unavailable
            return .success(QwenQuotaInfo(
                accessToken: accessToken,
                email: email,
                fiveHour: nil,
                weekly: nil,
                monthly: nil
            ))
        }
    }

    /// Parse a quota usage object from JSON
    private func parseQuotaUsage(from json: [String: Any]?) -> QwenQuotaInfo.QuotaUsage? {
        guard let json = json else { return nil }

        // Handle both Int and Double for utilization
        let utilization: Double
        if let doubleVal = json["utilization"] as? Double {
            utilization = doubleVal
        } else if let intVal = json["utilization"] as? Int {
            utilization = Double(intVal)
        } else if let percentVal = json["used_percent"] as? Double {
            utilization = percentVal
        } else if let percentVal = json["used_percent"] as? Int {
            utilization = Double(percentVal)
        } else {
            return nil
        }

        // resets_at can be null or in different formats
        let resetsAt = json["resets_at"] as? String ??
                       json["reset_at"] as? String ??
                       json["reset_time"] as? String ?? ""

        let limit = json["limit"] as? Int ?? json["total"] as? Int
        let used = json["used"] as? Int ?? json["used_amount"] as? Int

        return QwenQuotaInfo.QuotaUsage(
            utilization: utilization,
            resetsAt: resetsAt,
            limit: limit,
            used: used
        )
    }

    /// Fetch quota from all Qwen accounts from auth files in ~/.cli-proxy-api/
    func fetchAsProviderQuota(forceRefresh: Bool = false) async -> [String: ProviderQuotaData] {
        let expandedPath = NSString(string: authDir).expandingTildeInPath
        let fileManager = FileManager.default

        // Look for qwen-*.json files in ~/.cli-proxy-api/
        guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
            return [:]
        }

        // Filter for qwen auth files
        let qwenFiles = files.filter { file in
            file.hasPrefix("qwen-") && file.hasSuffix(".json")
        }

        NSLog("[QwenQuota] Found \(qwenFiles.count) qwen files: \(qwenFiles)")
        guard !qwenFiles.isEmpty else { return [:] }

        var results: [String: ProviderQuotaData] = [:]

        // Process Qwen auth files concurrently
        await withTaskGroup(of: (String, ProviderQuotaData?).self) { group in
            for file in qwenFiles {
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
                    NSLog("[QwenQuota] Fetched quota for \(email): \(data.models.count) models")
                    results[email] = data
                }
            }
        }

        NSLog("[QwenQuota] Returning quotas for \(results.count) accounts")
        return results
    }

    /// Fetch quota from a single auth file
    private func fetchQuotaFromAuthFile(at path: String, forceRefresh: Bool = false) async -> (email: String, data: ProviderQuotaData)? {
        let fileManager = FileManager.default

        guard let data = fileManager.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard var accessToken = json["access_token"] as? String else {
            return nil
        }

        // Extract email from JSON field (matches AuthFile.quotaLookupKey)
        let email = extractEmail(from: json, path: path)

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
                NSLog("[QwenQuota] Token refreshed for \(email)")
            } catch {
                NSLog("[QwenQuota] Token refresh failed for \(email): \(error.localizedDescription)")
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
                var model = ModelQuota(
                    name: "five-hour-session",
                    percentage: fiveHour.remaining,
                    resetTime: fiveHour.resetsAt
                )
                if let used = fiveHour.used, let limit = fiveHour.limit {
                    model.used = used
                    model.limit = limit
                }
                models.append(model)
            }

            if let weekly = info.weekly {
                var model = ModelQuota(
                    name: "weekly-quota",
                    percentage: weekly.remaining,
                    resetTime: weekly.resetsAt
                )
                if let used = weekly.used, let limit = weekly.limit {
                    model.used = used
                    model.limit = limit
                }
                models.append(model)
            }

            if let monthly = info.monthly {
                var model = ModelQuota(
                    name: "monthly-quota",
                    percentage: monthly.remaining,
                    resetTime: monthly.resetsAt
                )
                if let used = monthly.used, let limit = monthly.limit {
                    model.used = used
                    model.limit = limit
                }
                models.append(model)
            }

            // If no quota data available, show placeholder
            if models.isEmpty {
                models.append(ModelQuota(
                    name: "qwen-quota",
                    percentage: -1, // -1 indicates unknown/unavailable
                    resetTime: ""
                ))
            }

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

    /// Extract email from auth file JSON or path
    private func extractEmail(from json: [String: Any], path: String) -> String {
        // Try email field first - this matches AuthFile.quotaLookupKey
        if let email = json["email"] as? String, !email.isEmpty {
            return email
        }

        // Try id_token JWT as fallback
        if let idToken = json["id_token"] as? String,
           let email = extractEmailFromJWT(idToken) {
            return email
        }

        // Extract from filename as last resort
        let filename = (path as NSString).lastPathComponent

        // Parse qwen-*.json pattern
        if filename.hasPrefix("qwen-") && filename.hasSuffix(".json") {
            // Convert filename pattern to email format
            // qwen-user_example_com.json -> user@example.com
            let emailPart = filename.dropFirst(5).dropLast(5) // Remove "qwen-" and ".json"
            let emailString = String(emailPart)

            // Try to detect email pattern (user_domain_com -> user@domain.com)
            if emailString.contains("_") {
                let parts = emailString.components(separatedBy: "_")
                if parts.count >= 3 {
                    // Assume last two parts are domain (e.g., example_com -> example.com)
                    let user = parts.dropLast(2).joined(separator: ".")
                    let domain = parts.suffix(2).joined(separator: ".")
                    return "\(user)@\(domain)"
                } else if parts.count == 2 {
                    return "\(parts[0])@\(parts[1])"
                }
            }
            return emailString
        }

        // Fallback to filename without extension
        return filename.replacingOccurrences(of: ".json", with: "")
    }

    /// Extract email from JWT token
    private func extractEmailFromJWT(_ token: String) -> String? {
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

        return json["email"] as? String
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
