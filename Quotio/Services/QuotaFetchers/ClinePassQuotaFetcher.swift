//
//  ClinePassQuotaFetcher.swift
//  Quotio
//
//  Fetches ClinePass subscription usage using an API key stored by CustomProviderService.
//

import Foundation

nonisolated private struct ClinePassLimitsResponse: Decodable, Sendable {
    let data: ClinePassLimitsData
    let success: Bool
}

nonisolated private struct ClinePassLimitsData: Decodable, Sendable {
    let limits: [ClinePassLimit]
}

nonisolated private struct ClinePassLimit: Decodable, Sendable {
    let type: String
    let percentUsed: Double
    let resetsAt: String?
}

actor ClinePassQuotaFetcher {
    private let usageURL = URL(string: "https://api.cline.bot/api/v1/users/me/plan/usage-limits")!
    private var session: URLSession

    init() {
        let configuration = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: configuration)
    }

    func updateProxyConfiguration() {
        let configuration = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        self.session = URLSession(configuration: configuration)
    }

    func fetchQuota(apiKey: String) async throws -> ProviderQuotaData {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else {
            throw QuotaFetchError.forbidden
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuotaFetchError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseQuota(data)
        case 401, 403:
            return ProviderQuotaData(isForbidden: true)
        default:
            throw QuotaFetchError.httpError(httpResponse.statusCode)
        }
    }

    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        let providers = await MainActor.run {
            CustomProviderService.shared.providers.filter { $0.type == .clinePass && $0.isEnabled }
        }

        return await withTaskGroup(of: (String, ProviderQuotaData?).self) { group in
            for provider in providers {
                guard let apiKey = provider.apiKeys.first?.apiKey else { continue }

                group.addTask {
                    do {
                        return (provider.name, try await self.fetchQuota(apiKey: apiKey))
                    } catch {
                        Log.quota("Failed to fetch ClinePass quota for \(provider.name): \(error.localizedDescription)")
                        return (provider.name, nil)
                    }
                }
            }

            var quotas: [String: ProviderQuotaData] = [:]
            for await (name, quota) in group {
                if let quota {
                    quotas[name] = quota
                }
            }
            return quotas
        }
    }

    private func parseQuota(_ data: Data) throws -> ProviderQuotaData {
        let response = try JSONDecoder().decode(ClinePassLimitsResponse.self, from: data)
        guard response.success else {
            throw QuotaFetchError.invalidResponse
        }

        var modelsByName: [String: ModelQuota] = [:]
        for limit in response.data.limits {
            guard let name = modelName(for: limit.type) else { continue }

            let usedPercentage = min(100, max(0, limit.percentUsed))
            modelsByName[name] = ModelQuota(
                name: name,
                percentage: 100 - usedPercentage,
                resetTime: try normalizedResetTime(limit.resetsAt)
            )
        }

        let windowOrder = ["clinepass-five-hour", "clinepass-weekly", "clinepass-monthly"]
        let models = windowOrder.compactMap { modelsByName[$0] }
        return ProviderQuotaData(models: models, lastUpdated: Date())
    }

    private func modelName(for limitType: String) -> String? {
        switch limitType {
        case "five_hour": return "clinepass-five-hour"
        case "weekly": return "clinepass-weekly"
        case "monthly": return "clinepass-monthly"
        default: return nil
        }
    }

    private func normalizedResetTime(_ value: String?) throws -> String {
        guard let value else { return "" }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]

        guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
            throw QuotaFetchError.invalidResponse
        }
        return ISO8601DateFormatter().string(from: date)
    }
}
