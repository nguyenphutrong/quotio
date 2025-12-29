//
//  ClaudeCodeQuotaFetcher.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Fetches quota from Claude Code using Anthropic OAuth API
//  Used in Quota-Only mode
//

import Foundation

/// Quota data from Claude Code OAuth API
struct ClaudeCodeQuotaInfo: Sendable {
    let accessToken: String?

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

/// Fetches quota from Claude Code using OAuth API
actor ClaudeCodeQuotaFetcher {

    /// Keychain service names to try (Claude Code may use different names)
    private let keychainServiceNames = [
        "Claude Code-credentials",
        "claude-credentials",
        "Claude-credentials",
        "claudecode-credentials"
    ]

    /// Check if Claude Code credentials exist in Keychain
    func hasCredentials() async -> Bool {
        return getAccessToken() != nil
    }

    /// Get OAuth access token from macOS Keychain
    private func getAccessToken() -> String? {
        for serviceName in keychainServiceNames {
            if let token = getTokenFromKeychain(serviceName: serviceName) {
                return token
            }
        }
        return nil
    }

    /// Extract token from Keychain for a specific service name
    private func getTokenFromKeychain(serviceName: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", serviceName, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty,
                  let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let claudeAiOauth = json["claudeAiOauth"] as? [String: Any],
                  let accessToken = claudeAiOauth["accessToken"] as? String else {
                return nil
            }

            return accessToken
        } catch {
            return nil
        }
    }

    /// Fetch quota info from Anthropic OAuth API
    func fetchQuota() async -> ClaudeCodeQuotaInfo? {
        guard let accessToken = getAccessToken() else {
            return nil
        }

        // Call Anthropic OAuth usage API
        return await fetchUsageFromAPI(accessToken: accessToken)
    }

    /// Parse a quota usage object from JSON
    private func parseQuotaUsage(from json: [String: Any]?) -> ClaudeCodeQuotaInfo.QuotaUsage? {
        guard let json = json,
              let utilization = json["utilization"] as? Double,
              let resetsAt = json["resets_at"] as? String else {
            return nil
        }
        return ClaudeCodeQuotaInfo.QuotaUsage(utilization: utilization, resetsAt: resetsAt)
    }

    /// Fetch usage data from Anthropic OAuth API
    private func fetchUsageFromAPI(accessToken: String) async -> ClaudeCodeQuotaInfo? {
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

            // Parse the usage response
            // Format: { "five_hour": { "utilization": 74.0, "resets_at": "..." }, ... }
            let fiveHour = parseQuotaUsage(from: json["five_hour"] as? [String: Any])
            let sevenDay = parseQuotaUsage(from: json["seven_day"] as? [String: Any])
            let sevenDaySonnet = parseQuotaUsage(from: json["seven_day_sonnet"] as? [String: Any])
            let sevenDayOpus = parseQuotaUsage(from: json["seven_day_opus"] as? [String: Any])

            return ClaudeCodeQuotaInfo(
                accessToken: accessToken,
                fiveHour: fiveHour,
                sevenDay: sevenDay,
                sevenDaySonnet: sevenDaySonnet,
                sevenDayOpus: sevenDayOpus
            )
        } catch {
            return nil
        }
    }

    /// Convert ClaudeCodeQuotaInfo to ProviderQuotaData for unified display
    func fetchAsProviderQuota() async -> [String: ProviderQuotaData] {
        guard let info = await fetchQuota() else { return [:] }

        var models: [ModelQuota] = []

        // Add 5-hour quota
        if let fiveHour = info.fiveHour {
            models.append(ModelQuota(
                name: "5-hour",
                percentage: fiveHour.remaining,
                resetTime: fiveHour.resetsAt
            ))
        }

        // Add 7-day quota (main quota)
        if let sevenDay = info.sevenDay {
            models.append(ModelQuota(
                name: "7-day",
                percentage: sevenDay.remaining,
                resetTime: sevenDay.resetsAt
            ))
        }

        // Add Sonnet-specific quota if available
        if let sonnet = info.sevenDaySonnet {
            models.append(ModelQuota(
                name: "sonnet",
                percentage: sonnet.remaining,
                resetTime: sonnet.resetsAt
            ))
        }

        // Add Opus-specific quota if available
        if let opus = info.sevenDayOpus {
            models.append(ModelQuota(
                name: "opus",
                percentage: opus.remaining,
                resetTime: opus.resetsAt
            ))
        }

        guard !models.isEmpty else { return [:] }

        let quotaData = ProviderQuotaData(
            models: models,
            lastUpdated: Date(),
            isForbidden: false,
            planType: nil
        )

        return ["Claude Code User": quotaData]
    }
}
