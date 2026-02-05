//
//  GLMQuotaFetcher.swift
//  Quotio
//
//  Fetches quota information from GLM (BigModel) API.
//  Uses API key authentication stored in CustomProviderService.
//

import Foundation

// MARK: - API Response Models

struct GLMQuotaResponse: Codable, Sendable {
    let code: Int
    let msg: String
    let data: GLMQuotaData?
    let success: Bool
}

struct GLMQuotaData: Codable, Sendable {
    let limits: [GLMLimit]
}

struct GLMLimit: Codable, Sendable {
    let type: String
    let unit: Int
    let number: Int
    let usage: Int
    let currentValue: Int
    let remaining: Int
    let percentage: Double
    let usageDetails: [GLMUsageDetail]?
    let nextResetTime: Int64?

    enum CodingKeys: String, CodingKey {
        case type, unit, number, usage
        case currentValue = "currentValue"
        case remaining, percentage
        case usageDetails = "usageDetails"
        case nextResetTime = "nextResetTime"
    }
}

struct GLMUsageDetail: Codable, Sendable {
    let modelCode: String
    let usage: Int

    enum CodingKeys: String, CodingKey {
        case modelCode = "modelCode"
        case usage
    }
}

// MARK: - Quota Fetcher

actor GLMQuotaFetcher {
    private let quotaAPIURL = "https://bigmodel.cn/api/monitor/usage/quota/limit"

    private var session: URLSession

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    /// Update the URLSession with current proxy settings
    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: config)
    }

    /// Fetch quota for a single API key
    func fetchQuota(apiKey: String) async throws -> ProviderQuotaData {
        guard let url = URL(string: quotaAPIURL) else {
            throw QuotaFetchError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuotaFetchError.invalidResponse
        }

        guard 200...299 ~= httpResponse.statusCode else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return await MainActor.run { ProviderQuotaData(isForbidden: true) }
            }
            throw QuotaFetchError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let quotaResponse = try await MainActor.run {
            try decoder.decode(GLMQuotaResponse.self, from: data)
        }

        guard quotaResponse.success, quotaResponse.code == 200, let responseData = quotaResponse.data else {
            throw QuotaFetchError.apiErrorMessage(quotaResponse.msg)
        }

        return await MainActor.run {
            var models: [ModelQuota] = []

            // Parse limits - GLM has TOKENS_LIMIT (main quota) and TIME_LIMIT (MCP quota)
            for limit in responseData.limits {
                if limit.type == "TOKENS_LIMIT" {
                    // Token limit - show as main quota on dashboard
                    let resetTime: String
                    if let nextReset = limit.nextResetTime {
                        resetTime = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(nextReset / 1000)))
                    } else {
                        resetTime = ""
                    }

                    // currentValue is used, usage is total limit
                    // API returns percentage as "used", so convert to "remaining" for ModelQuota
                    models.append(ModelQuota(
                        name: "Tokens",
                        percentage: 100 - limit.percentage,
                        resetTime: resetTime,
                        used: limit.currentValue,
                        limit: limit.usage,
                        remaining: limit.remaining
                    ))
                } else if limit.type == "TIME_LIMIT" {
                    // MCP quota (monthly, no reset time)
                    // currentValue is used, usage is total
                    // API returns percentage as "used", so convert to "remaining" for ModelQuota
                    models.append(ModelQuota(
                        name: "MCP Usage",
                        percentage: 100 - limit.percentage,
                        resetTime: "",
                        used: limit.currentValue,
                        limit: limit.usage,
                        remaining: limit.remaining
                    ))
                }
            }

            return ProviderQuotaData(models: models, lastUpdated: Date())
        }
    }

    /// Fetch quota for all configured GLM API keys
    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        // Get providers from CustomProviderService
        let providers = await getGlmProviders()

        var results: [String: ProviderQuotaData] = [:]

        await withTaskGroup(of: (String, ProviderQuotaData?).self) { group in
            for provider in providers {
                for apiKeyEntry in provider.apiKeys {
                    group.addTask {
                        do {
                            let quota = try await self.fetchQuota(apiKey: apiKeyEntry.apiKey)
                            // Use provider name as identifier
                            return (provider.name, quota)
                        } catch {
                            return ("", nil)
                        }
                    }
                }
            }

            for await (key, quota) in group {
                if !key.isEmpty, let quota = quota {
                    results[key] = quota
                }
            }
        }

        return results
    }

    /// Get GLM providers from CustomProviderService
    private func getGlmProviders() async -> [CustomProvider] {
        // Access CustomProviderService on main actor
        await MainActor.run {
            CustomProviderService.shared.providers
                .filter { $0.type == .glmCompatibility && $0.isEnabled }
        }
    }
}
