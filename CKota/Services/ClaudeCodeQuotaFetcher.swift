//
//  ClaudeCodeQuotaFetcher.swift
//  CKota - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Anthropic OAuth usage API
//  Uses auth files from ~/.ccs/cliproxy/auth/claude-*.json (or ~/.cli-proxy-api/)
//

import Foundation

// MARK: - API Response Models

/// Response from Anthropic OAuth usage endpoint
private struct ClaudeUsageResponse: Codable, Sendable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOauthApps: UsageWindow?
    let sevenDayOpus: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
    }

    struct UsageWindow: Codable, Sendable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}

/// Auth file format for Claude OAuth tokens
private struct ClaudeAuthFile: Codable, Sendable {
    var accessToken: String
    let refreshToken: String?
    let email: String?
    let expired: String?
    let lastRefresh: String?
    let type: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case email
        case expired
        case lastRefresh = "last_refresh"
        case type
        case idToken = "id_token"
    }

    var isExpired: Bool {
        guard let expired else { return true }

        // Try parsing ISO 8601 date with timezone
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let expiryDate = formatter.date(from: expired) {
            return Date() > expiryDate
        }

        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let expiryDate = formatter.date(from: expired) {
            return Date() > expiryDate
        }

        // Try with timezone offset format (+07:00)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        if let expiryDate = dateFormatter.date(from: expired) {
            return Date() > expiryDate
        }

        return true
    }
}

// MARK: - Fetcher

/// Fetches quota from Anthropic OAuth usage API
actor ClaudeCodeQuotaFetcher {
    private let usageAPIURL = "https://api.anthropic.com/api/oauth/usage"
    private let tokenRefreshURL = "https://api.anthropic.com/oauth/token"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Auth directories to scan (CCS path first, then legacy)
    private static let authDirectories = [
        "~/.ccs/cliproxy/auth", // CCS managed (preferred)
        "~/.cli-proxy-api", // Legacy fallback
    ]

    /// Fetch quota for all Claude auth files and return as ProviderQuotaData
    func fetchAsProviderQuota(authDir: String? = nil) async -> [String: ProviderQuotaData] {
        let fileManager = FileManager.default
        var results: [String: ProviderQuotaData] = [:]

        // Determine directories to scan
        let dirsToScan: [String] = if let authDir {
            [authDir]
        } else {
            Self.authDirectories
        }

        for dir in dirsToScan {
            let expandedPath = NSString(string: dir).expandingTildeInPath

            guard let files = try? fileManager.contentsOfDirectory(atPath: expandedPath) else {
                continue
            }

            // Find all claude-*.json files
            let claudeFiles = files.filter { $0.hasPrefix("claude-") && $0.hasSuffix(".json") }
            print("[DEBUG] ClaudeCodeQuotaFetcher: Found \(claudeFiles.count) claude files in \(dir): \(claudeFiles)")

            for file in claudeFiles {
                let filePath = (expandedPath as NSString).appendingPathComponent(file)
                let email = extractEmailFromFilename(file)

                // Skip if already found (avoid duplicates)
                if results[email] != nil { continue }

                do {
                    let quota = try await fetchQuotaForAuthFile(at: filePath)
                    print(
                        "[DEBUG] ClaudeCodeQuotaFetcher: Fetched quota for '\(email)' - models: \(quota.models.count), forbidden: \(quota.isForbidden)"
                    )
                    results[email] = quota
                } catch {
                    print("[DEBUG] ClaudeCodeQuotaFetcher: Failed to fetch quota for \(file): \(error)")
                }
            }
        }

        print("[DEBUG] ClaudeCodeQuotaFetcher: Returning \(results.count) results with keys: \(results.keys.sorted())")
        return results
    }

    /// Fetch quota for specific auth file paths (from proxy API)
    func fetchFromPaths(_ paths: [String]) async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]

        print("[DEBUG] ClaudeCodeQuotaFetcher: Fetching from \(paths.count) paths: \(paths)")

        for path in paths {
            do {
                let quota = try await fetchQuotaForAuthFile(at: path)

                // Extract email from filename
                let filename = (path as NSString).lastPathComponent
                let email = extractEmailFromFilename(filename)
                print(
                    "[DEBUG] ClaudeCodeQuotaFetcher: Fetched quota for '\(email)' from path - models: \(quota.models.count), forbidden: \(quota.isForbidden)"
                )
                results[email] = quota
            } catch {
                print("[DEBUG] ClaudeCodeQuotaFetcher: Failed to fetch quota from \(path): \(error)")
            }
        }

        print("[DEBUG] ClaudeCodeQuotaFetcher: Returning \(results.count) results with keys: \(results.keys.sorted())")
        return results
    }

    // MARK: - Private Methods

    /// Extract email from Claude auth filename
    private func extractEmailFromFilename(_ filename: String) -> String {
        var name = filename
        name = name.replacingOccurrences(of: "claude-", with: "")
        name = name.replacingOccurrences(of: ".json", with: "")
        return name
    }

    /// Fetch quota for a specific auth file
    private func fetchQuotaForAuthFile(at path: String) async throws -> ProviderQuotaData {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        var authFile = try JSONDecoder().decode(ClaudeAuthFile.self, from: data)

        var accessToken = authFile.accessToken

        // Refresh token if expired
        if authFile.isExpired, let refreshToken = authFile.refreshToken {
            do {
                accessToken = try await refreshAccessToken(refreshToken: refreshToken)
                authFile.accessToken = accessToken

                // Update auth file with new token
                if let updatedData = try? JSONEncoder().encode(authFile) {
                    try? updatedData.write(to: url)
                }
            } catch {
                print("Claude token refresh failed: \(error)")
                // Continue with existing token, might still work
            }
        }

        return try await fetchQuota(accessToken: accessToken)
    }

    /// Refresh OAuth access token
    private func refreshAccessToken(refreshToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: tokenRefreshURL)!)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params = [
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]

        let body = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              200 ... 299 ~= httpResponse.statusCode
        else {
            throw ClaudeQuotaError.tokenRefreshFailed
        }

        struct TokenResponse: Codable {
            let accessToken: String
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
            }
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        return tokenResponse.accessToken
    }

    /// Fetch quota from Anthropic API
    private func fetchQuota(accessToken: String) async throws -> ProviderQuotaData {
        var request = URLRequest(url: URL(string: usageAPIURL)!)
        request.httpMethod = "GET"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeQuotaError.invalidResponse
        }

        if httpResponse.statusCode == 403 || httpResponse.statusCode == 401 {
            return ProviderQuotaData(isForbidden: true)
        }

        guard 200 ... 299 ~= httpResponse.statusCode else {
            throw ClaudeQuotaError.httpError(httpResponse.statusCode)
        }

        let usageResponse = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)

        var models: [ModelQuota] = []

        // Seven-day usage (main weekly quota)
        if let sevenDay = usageResponse.sevenDay,
           let utilization = sevenDay.utilization
        {
            // Utilization is percentage used, we need remaining percentage
            let remaining = max(0, 100 - utilization)
            let resetTime = sevenDay.resetsAt ?? ""

            models.append(ModelQuota(
                name: "weekly-usage",
                percentage: remaining,
                resetTime: resetTime
            ))
        }

        // Five-hour burst usage
        if let fiveHour = usageResponse.fiveHour,
           let utilization = fiveHour.utilization
        {
            let remaining = max(0, 100 - utilization)
            let resetTime = fiveHour.resetsAt ?? ""

            models.append(ModelQuota(
                name: "five-hour",
                percentage: remaining,
                resetTime: resetTime
            ))
        }

        // Opus-specific quota (if available)
        if let opus = usageResponse.sevenDayOpus,
           let utilization = opus.utilization
        {
            let remaining = max(0, 100 - utilization)
            let resetTime = opus.resetsAt ?? ""

            models.append(ModelQuota(
                name: "opus-usage",
                percentage: remaining,
                resetTime: resetTime
            ))
        }

        return ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false
        )
    }
}

// MARK: - Errors

enum ClaudeQuotaError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case tokenRefreshFailed
    case noAuthFiles

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from Anthropic API"
        case let .httpError(code): "HTTP error: \(code)"
        case .tokenRefreshFailed: "Failed to refresh OAuth token"
        case .noAuthFiles: "No Claude auth files found"
        }
    }
}
