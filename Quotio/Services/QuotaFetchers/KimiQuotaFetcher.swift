//
//  KimiQuotaFetcher.swift
//  Quotio
//
//  Kimi (Moonshot AI) Quota Fetcher
//  Uses Kimi API to fetch coding usage quota
//

import Foundation

// MARK: - Kimi Response Models

nonisolated struct KimiUsageResponse: Decodable {
    let usages: [KimiUsage]
    
    struct KimiUsage: Decodable {
        let scope: String
        let detail: KimiUsageDetail
        let limits: [KimiRateLimit]?
    }
    
    struct KimiUsageDetail: Decodable {
        let limit: String
        let used: String?
        let remaining: String?
        let resetTime: String
    }
    
    struct KimiRateLimit: Decodable {
        let window: KimiRateWindow
        let detail: KimiUsageDetail
        
        struct KimiRateWindow: Decodable {
            let duration: Int
            let timeUnit: String
        }
    }
}

// MARK: - Kimi Quota Fetcher

actor KimiQuotaFetcher {
    private let usageURL = "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages"
    
    private var session: URLSession
    
    /// Known tier mappings based on weekly limit
    private static let tierByLimit: [Int: String] = [
        1024: "Andante",
        2048: "Moderato",
        7168: "Allegretto",
    ]
    
    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 30)
        self.session = URLSession(configuration: config)
    }
    
    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 30)
        self.session = URLSession(configuration: config)
    }
    
    /// Fetch quota from Kimi API using auth token
    func fetchQuota(authToken: String) async throws -> ProviderQuotaData {
        guard let url = URL(string: usageURL) else {
            throw KimiQuotaError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])
        
        // Apply headers
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(authToken)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KimiQuotaError.invalidResponse
        }
        
        switch httpResponse.statusCode {
        case 200:
            break
        case 401, 403:
            throw KimiQuotaError.authenticationRequired
        default:
            throw KimiQuotaError.httpError(httpResponse.statusCode)
        }
        
        return try parseResponse(data)
    }
    
    /// Parse Kimi API response into ProviderQuotaData
    private func parseResponse(_ data: Data) throws -> ProviderQuotaData {
        let decoded: KimiUsageResponse
        do {
            decoded = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
        } catch {
            throw KimiQuotaError.parseFailed(error.localizedDescription)
        }
        
        guard let coding = decoded.usages.first(where: { $0.scope == "FEATURE_CODING" }) else {
            throw KimiQuotaError.parseFailed("Missing FEATURE_CODING scope in response")
        }
        
        var models: [ModelQuota] = []
        
        // Parse weekly quota from detail
        let weekly = parseUsageNumbers(detail: coding.detail)
        let weeklyPercentRemaining: Double
        if weekly.limit > 0 {
            weeklyPercentRemaining = (Double(weekly.remaining) / Double(weekly.limit)) * 100.0
        } else {
            weeklyPercentRemaining = 100.0
        }
        
        let weeklyResetDate = parseISO8601(coding.detail.resetTime)
        let weeklyResetStr = weeklyResetDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        
        models.append(ModelQuota(
            name: "kimi-weekly",
            percentage: weeklyPercentRemaining,
            resetTime: weeklyResetStr,
            used: weekly.used,
            limit: weekly.limit,
            remaining: weekly.remaining
        ))
        
        // Parse 5-hour rate limit from limits array
        // Look for window with duration=300, timeUnit=TIME_UNIT_MINUTE (300 min = 5 hours)
        let fiveHourRate = coding.limits?.first(where: {
            $0.window.duration == 300 && $0.window.timeUnit == "TIME_UNIT_MINUTE"
        }) ?? coding.limits?.first
        
        if let rateLimit = fiveHourRate {
            let rate = parseUsageNumbers(detail: rateLimit.detail)
            let ratePercentRemaining: Double
            if rate.limit > 0 {
                ratePercentRemaining = (Double(rate.remaining) / Double(rate.limit)) * 100.0
            } else {
                ratePercentRemaining = 100.0
            }
            
            let rateResetDate = parseISO8601(rateLimit.detail.resetTime)
            let rateResetStr = rateResetDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            
            models.append(ModelQuota(
                name: "kimi-5h",
                percentage: ratePercentRemaining,
                resetTime: rateResetStr,
                used: rate.used,
                limit: rate.limit,
                remaining: rate.remaining
            ))
        }
        
        // Detect account tier from weekly limit
        let planType = Self.tierByLimit[weekly.limit]
        
        return ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: planType
        )
    }
    
    private func parseUsageNumbers(detail: KimiUsageResponse.KimiUsageDetail) -> (used: Int, limit: Int, remaining: Int) {
        let limit = Int(detail.limit) ?? 0
        let rawUsed = Int(detail.used ?? "")
        let rawRemaining = Int(detail.remaining ?? "")
        
        let used: Int
        let remaining: Int
        
        if let rawUsed, let rawRemaining {
            used = rawUsed
            remaining = rawRemaining
        } else if let rawUsed {
            used = rawUsed
            remaining = max(0, limit - rawUsed)
        } else if let rawRemaining {
            used = max(0, limit - rawRemaining)
            remaining = rawRemaining
        } else {
            used = 0
            remaining = max(0, limit)
        }
        
        return (used: used, limit: limit, remaining: remaining)
    }
    
    private func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: raw) {
            return value
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
    
    /// Fetch quota using token from environment or auth file
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        // Try environment variable first
        if let envToken = ProcessInfo.processInfo.environment["KIMI_AUTH_TOKEN"],
           !envToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let quota = try await fetchQuota(authToken: envToken)
                return ["Kimi": quota]
            } catch {
                Log.quota("Failed to fetch Kimi quota with env token: \(error)")
            }
        }
        
        // Try to read from auth files (if any exist in ~/.cli-proxy-api/)
        let authDir = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
        let fileManager = FileManager.default
        
        guard let files = try? fileManager.contentsOfDirectory(atPath: authDir) else {
            return [:]
        }
        
        var results: [String: ProviderQuotaData] = [:]
        
        for file in files where file.hasPrefix("kimi-") && file.hasSuffix(".json") {
            let filePath = (authDir as NSString).appendingPathComponent(file)
            
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Prefer kimi_auth_cookie (browser cookie) over access_token (OAuth)
                    // The GetUsages API requires the browser session cookie, not OAuth token
                    let token = json["kimi_auth_cookie"] as? String
                        ?? json["kimi-auth"] as? String
                        ?? json["access_token"] as? String
                        ?? json["token"] as? String
                    
                    guard let token, !token.isEmpty else {
                        Log.quota("No valid token found in \(file)")
                        continue
                    }
                    
                    let quota = try await fetchQuota(authToken: token)
                    let email = file
                        .replacingOccurrences(of: "kimi-", with: "")
                        .replacingOccurrences(of: ".json", with: "")
                    results[email] = quota
                }
            } catch {
                Log.quota("Failed to fetch Kimi quota for \(file): \(error)")
            }
        }
        
        return results
    }
}

// MARK: - Errors

nonisolated enum KimiQuotaError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case authenticationRequired
    case parseFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response from Kimi"
        case .httpError(let code): return "HTTP error: \(code)"
        case .authenticationRequired: return "Kimi authentication required"
        case .parseFailed(let msg): return "Failed to parse: \(msg)"
        }
    }
}
