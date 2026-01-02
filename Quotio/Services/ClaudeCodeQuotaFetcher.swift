//
//  ClaudeCodeQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Claude auth files in ~/.cli-proxy-api/
//  Calls Anthropic OAuth API for usage data
//

import Foundation

/// Quota data from Claude Code OAuth API
struct ClaudeCodeQuotaInfo: Sendable {
    let accessToken: String?
    let email: String?

    /// Usage quotas from OAuth API
    let fiveHour: QuotaUsage?
    let sevenDay: QuotaUsage?
    let sevenDaySonnet: QuotaUsage?
    let sevenDayOpus: QuotaUsage?

    struct QuotaUsage: Sendable {
        let utilization: Double  // Percentage used (0-100)
        let resetsAt: String     // ISO8601 date string

        /// Remaining percentage (100 - utilization)
        var remaining: Double {
            max(0, 100 - utilization)
        }
    }
}

/// Fetches quota from Claude auth files using OAuth API
actor ClaudeCodeQuotaFetcher {

    /// Auth directory for CLI Proxy API
    private let authDir = "~/.cli-proxy-api"

    /// Parse a quota usage object from JSON
    private func parseQuotaUsage(from json: [String: Any]?) -> ClaudeCodeQuotaInfo.QuotaUsage? {
        guard let json = json else { return nil }
        
        guard let utilization = json["utilization"] as? Double else {
            return nil
        }
        
        // resets_at can be null
        let resetsAt = json["resets_at"] as? String ?? ""
        
        return ClaudeCodeQuotaInfo.QuotaUsage(utilization: utilization, resetsAt: resetsAt)
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

            // Parse the usage response - handle {"result": {...}} wrapper
            let usageData: [String: Any]
            if let result = json["result"] as? [String: Any] {
                usageData = result
            } else {
                usageData = json
            }

            let fiveHour = parseQuotaUsage(from: usageData["five_hour"] as? [String: Any])
            let sevenDay = parseQuotaUsage(from: usageData["seven_day"] as? [String: Any])
            let sevenDaySonnet = parseQuotaUsage(from: usageData["seven_day_sonnet"] as? [String: Any])
            let sevenDayOpus = parseQuotaUsage(from: usageData["seven_day_opus"] as? [String: Any])

            return ClaudeCodeQuotaInfo(
                accessToken: accessToken,
                email: email,
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                sevenDaySonnet: sevenDaySonnet,
                sevenDayOpus: sevenDayOpus
            )
        } catch {
            return nil
        }
    }

    /// Fetch quota for all Claude accounts from auth files in ~/.cli-proxy-api/
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
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
                    guard let quota = await self.fetchQuotaFromAuthFile(at: filePath) else {
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
    private func fetchQuotaFromAuthFile(at path: String) async -> (email: String, data: ProviderQuotaData)? {
        let fileManager = FileManager.default
        
        guard let data = fileManager.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        guard let accessToken = json["access_token"] as? String,
              let email = json["email"] as? String else {
            return nil
        }
        
        // Fetch usage from API using the token
        guard let info = await fetchUsageFromAPI(accessToken: accessToken, email: email) else {
            return nil
        }
        
        // Convert to ProviderQuotaData
        var models: [ModelQuota] = []
        
        if let fiveHour = info.fiveHour {
            models.append(ModelQuota(
                name: "Session",
                percentage: fiveHour.remaining,
                resetTime: fiveHour.resetsAt
            ))
        }
        
        if let sevenDay = info.sevenDay {
            models.append(ModelQuota(
                name: "Weekly",
                percentage: sevenDay.remaining,
                resetTime: sevenDay.resetsAt
            ))
        }
        
        if let sonnet = info.sevenDaySonnet {
            models.append(ModelQuota(
                name: "Sonnet",
                percentage: sonnet.remaining,
                resetTime: sonnet.resetsAt
            ))
        }
        
        if let opus = info.sevenDayOpus {
            models.append(ModelQuota(
                name: "Opus",
                percentage: opus.remaining,
                resetTime: opus.resetsAt
            ))
        }
        
        guard !models.isEmpty else { return nil }
        
        let quotaData = ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: nil
        )
        
        return (email, quotaData)
    }
}
