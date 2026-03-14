//
//  KimiQuotaFetcher.swift
//  Quotio
//

import Foundation

// MARK: - Kimi Response Models

nonisolated struct KimiUsageResponse: Decodable, Sendable {
    let user: KimiUser?
    let usage: KimiUsageDetail
    let limits: [KimiRateLimit]?
    
    struct KimiUser: Decodable, Sendable {
        let userId: String?
        let region: String?
        let membership: KimiMembership?
    }
    
    struct KimiMembership: Decodable, Sendable {
        let level: String?
    }
    
    struct KimiUsageDetail: Decodable, Sendable {
        let limit: String
        let used: String?
        let remaining: String?
        let resetTime: String?
    }
    
    struct KimiRateLimit: Decodable, Sendable {
        let window: KimiRateWindow
        let detail: KimiUsageDetail
        
        struct KimiRateWindow: Decodable, Sendable {
            let duration: Int
            let timeUnit: String
        }
    }
}

nonisolated struct KimiTokenRefreshResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int?
    let scope: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

// MARK: - Kimi Quota Fetcher

actor KimiQuotaFetcher {
    private let usageURL = "https://api.kimi.com/coding/v1/usages"
    private let refreshURL = "https://auth.kimi.com/api/oauth/token"
    private let clientId = "17e5f671-d194-4dfb-9706-5516cb48c098"
    
    private var session: URLSession
    private let deviceId: String
    
    private static let tierByLevel: [String: String] = [
        "LEVEL_BEGINNER": "Beginner",
        "LEVEL_INTERMEDIATE": "Intermediate",
        "LEVEL_ADVANCED": "Advanced",
    ]
    
    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 30)
        self.session = URLSession(configuration: config)
        self.deviceId = Self.getOrCreateDeviceId()
    }
    
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 30)
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - Device Headers (Required by Kimi OAuth API)
    
    /// Generate required device headers for Kimi OAuth API
    /// Based on kimi-cli KLIP-14 specification
    private func commonHeaders() -> [String: String] {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let deviceModel = Self.deviceModel()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        
        return [
            "X-Msh-Platform": "quotio",
            "X-Msh-Version": appVersion,
            "X-Msh-Device-Name": Self.asciiSafe(deviceName),
            "X-Msh-Device-Model": Self.asciiSafe(deviceModel),
            "X-Msh-Os-Version": Self.asciiSafe(osVersion),
            "X-Msh-Device-Id": deviceId
        ]
    }
    
    /// Get device model string (e.g., "macOS 15.1.1 arm64")
    private static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
        
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        
        return "macOS \(versionString) \(machine)"
    }
    
    /// Ensure header value is ASCII-safe
    private static func asciiSafe(_ value: String) -> String {
        let ascii = value.unicodeScalars.filter { $0.isASCII }
        let result = String(String.UnicodeScalarView(ascii)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "unknown" : result
    }
    
    /// Stable device ID persisted to ~/.cli-proxy-api/kimi-device-id (required by Kimi OAuth)
    private static func getOrCreateDeviceId() -> String {
        let authDir = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
        let deviceIdPath = (authDir as NSString).appendingPathComponent("kimi-device-id")
        
        if let existingId = try? String(contentsOfFile: deviceIdPath, encoding: .utf8) {
            let trimmed = existingId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        
        let newId = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        
        do {
            try FileManager.default.createDirectory(atPath: authDir, withIntermediateDirectories: true)
            try newId.write(toFile: deviceIdPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: deviceIdPath)
        } catch {
            Log.quota("Failed to persist Kimi device ID: \(error)")
        }
        
        return newId
    }
    
    private func applyCommonHeaders(to request: inout URLRequest) {
        for (key, value) in commonHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
    
    // MARK: - Token Refresh
    
    private func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, newRefreshToken: String, expiresIn: Int?) {
        guard let url = URL(string: refreshURL) else {
            throw KimiQuotaError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyCommonHeaders(to: &request)
        
        let body = "client_id=\(clientId)&grant_type=refresh_token&refresh_token=\(refreshToken)"
        request.httpBody = body.data(using: .utf8)
        
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
        
        let tokenResponse = try JSONDecoder().decode(KimiTokenRefreshResponse.self, from: data)
        return (tokenResponse.accessToken, tokenResponse.refreshToken, tokenResponse.expiresIn)
    }
    
    private func updateAuthFile(at path: String, newRefreshToken: String, accessToken: String, expiresIn: Int?) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        json["refresh_token"] = newRefreshToken
        json["access_token"] = accessToken
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        
        if let expiresIn = expiresIn, expiresIn > 0 {
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
            json["expired"] = ISO8601DateFormatter().string(from: expiry)
        }
        
        json.removeValue(forKey: "kimi_auth_cookie")
        json.removeValue(forKey: "kimi-auth")
        
        if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? updatedData.write(to: URL(fileURLWithPath: path))
            Log.quota("Updated Kimi auth file with refreshed tokens")
        }
    }
    
    // MARK: - Quota Fetching
    
    private func fetchQuotaWithAccessToken(_ accessToken: String) async throws -> ProviderQuotaData {
        guard let url = URL(string: usageURL) else {
            throw KimiQuotaError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyCommonHeaders(to: &request)
        
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
    
    /// Fetch quota using refresh token (refreshes access token first)
    /// - Parameters:
    ///   - refreshToken: The refresh token
    ///   - filePath: Optional path to auth file for persisting new refresh token
    /// - Returns: Quota data
    func fetchQuotaWithRefresh(refreshToken: String, filePath: String? = nil) async throws -> ProviderQuotaData {
        let (accessToken, newRefreshToken, expiresIn) = try await refreshAccessToken(refreshToken: refreshToken)
        
        if let path = filePath {
            updateAuthFile(at: path, newRefreshToken: newRefreshToken, accessToken: accessToken, expiresIn: expiresIn)
        }
        
        // Step 3: Fetch quota with access token
        return try await fetchQuotaWithAccessToken(accessToken)
    }
    
    private func parseResponse(_ data: Data) throws -> ProviderQuotaData {
        let decoded: KimiUsageResponse
        do {
            decoded = try JSONDecoder().decode(KimiUsageResponse.self, from: data)
        } catch {
            throw KimiQuotaError.parseFailed(error.localizedDescription)
        }
        
        var models: [ModelQuota] = []
        
        let weekly = parseUsageNumbers(detail: decoded.usage)
        let weeklyPercentRemaining: Double = weekly.limit > 0
            ? (Double(weekly.remaining) / Double(weekly.limit)) * 100.0
            : 100.0
        
        let weeklyResetDate = parseISO8601(decoded.usage.resetTime)
        let weeklyResetStr = weeklyResetDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        
        models.append(ModelQuota(
            name: "kimi-weekly",
            percentage: weeklyPercentRemaining,
            resetTime: weeklyResetStr,
            used: weekly.used,
            limit: weekly.limit,
            remaining: weekly.remaining
        ))
        
        let fiveHourRate = decoded.limits?.first(where: {
            $0.window.duration == 300 && $0.window.timeUnit == "TIME_UNIT_MINUTE"
        }) ?? decoded.limits?.first
        
        if let rateLimit = fiveHourRate {
            let rate = parseUsageNumbers(detail: rateLimit.detail)
            let ratePercentRemaining: Double = rate.limit > 0
                ? (Double(rate.remaining) / Double(rate.limit)) * 100.0
                : 100.0
            
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
        
        let planType = decoded.user?.membership?.level.flatMap { Self.tierByLevel[$0] }
        
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
    
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        let authDir = NSString(string: "~/.cli-proxy-api").expandingTildeInPath
        let fileManager = FileManager.default
        
        guard let files = try? fileManager.contentsOfDirectory(atPath: authDir) else {
            return [:]
        }
        
        let kimiFiles = files.filter { $0.hasPrefix("kimi-") && $0.hasSuffix(".json") }
        
        return await withTaskGroup(of: (String, ProviderQuotaData?).self) { group in
            for file in kimiFiles {
                group.addTask { [self] in
                    let filePath = (authDir as NSString).appendingPathComponent(file)
                    
                    do {
                        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
                        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            return ("", nil)
                        }
                        
                        let email = file
                            .replacingOccurrences(of: "kimi-", with: "")
                            .replacingOccurrences(of: ".json", with: "")
                        
                        if let accessToken = json["access_token"] as? String, !accessToken.isEmpty {
                            do {
                                let quota = try await self.fetchQuotaWithAccessToken(accessToken)
                                return (email, quota)
                            } catch KimiQuotaError.authenticationRequired {
                                Log.quota("Kimi access_token expired for \(file), attempting refresh")
                            } catch {
                                Log.quota("Kimi access_token failed for \(file): \(error)")
                            }
                        }
                        
                        guard let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty else {
                            Log.quota("No valid tokens in \(file)")
                            return ("", nil)
                        }
                        
                        let quota = try await self.fetchQuotaWithRefresh(refreshToken: refreshToken, filePath: filePath)
                        return (email, quota)
                    } catch {
                        Log.quota("Failed to fetch Kimi quota for \(file): \(error)")
                        return ("", nil)
                    }
                }
            }
            
            var results: [String: ProviderQuotaData] = [:]
            for await (key, quota) in group {
                if let quota = quota, !key.isEmpty {
                    results[key] = quota
                }
            }
            return results
        }
    }
}

// MARK: - Errors

enum KimiQuotaError: LocalizedError, Sendable {
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
