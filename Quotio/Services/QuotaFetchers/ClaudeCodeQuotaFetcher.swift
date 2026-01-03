//
//  ClaudeCodeQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Claude auth files in ~/.cli-proxy-api/
//  Calls Anthropic OAuth API for usage data
//

import Foundation

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
    
    /// Cache for quota data to reduce API calls
    private var quotaCache: [String: CachedQuota] = [:]
    
    /// Cache TTL: 5 minutes
    private let cacheTTL: TimeInterval = 300
    
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

    /// Fetch usage data from Anthropic OAuth API
    private func fetchUsageFromAPI(accessToken: String, email: String?) async -> ClaudeCodeQuotaInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-s",
            "-H", "Accept: application/json",
            "-H", "Authorization: Bearer \(accessToken)",
            "-H", "anthropic-beta: oauth-2025-04-20",
            "https://api.anthropic.com/api/oauth/usage"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            
            // Check for API error response
            if json["type"] as? String == "error" {
                return nil
            }

            // API returns data directly (no wrapper)
            let fiveHour = parseQuotaUsage(from: json["five_hour"] as? [String: Any])
            let sevenDay = parseQuotaUsage(from: json["seven_day"] as? [String: Any])
            let sevenDaySonnet = parseQuotaUsage(from: json["seven_day_sonnet"] as? [String: Any])
            let sevenDayOpus = parseQuotaUsage(from: json["seven_day_opus"] as? [String: Any])
            let extraUsage = parseExtraUsage(from: json["extra_usage"] as? [String: Any])

            return ClaudeCodeQuotaInfo(
                accessToken: accessToken,
                email: email,
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                sevenDaySonnet: sevenDaySonnet,
                sevenDayOpus: sevenDayOpus,
                extraUsage: extraUsage
            )
        } catch {
            return nil
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
        
        guard let accessToken = json["access_token"] as? String,
              let email = json["email"] as? String else {
            return nil
        }
        
        // Check cache first (unless force refresh)
        if !forceRefresh, let cached = quotaCache[email], cached.isValid(ttl: cacheTTL) {
            return (email, cached.data)
        }
        
        // Fetch usage from API using the token
        guard let info = await fetchUsageFromAPI(accessToken: accessToken, email: email) else {
            // Return cached data if API fails
            if let cached = quotaCache[email] {
                return (email, cached.data)
            }
            return nil
        }
        
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
