//
//  WarpQuotaFetcher.swift
//  Quotio
//
//  Fetches quota information from Warp AI Terminal GraphQL API.
//

import Foundation

struct WarpQuotaResponse: Codable, Sendable {
    let data: WarpDataWrapper?
    
    struct WarpDataWrapper: Codable, Sendable {
        let user: WarpUserOutput?
    }
    
    struct WarpUserOutput: Codable, Sendable {
        let user: WarpUser?
    }
    
    struct WarpUser: Codable, Sendable {
        let requestLimitInfo: WarpRequestLimitInfo?
    }
    
    struct WarpRequestLimitInfo: Codable, Sendable {
        let isUnlimited: Bool?
        let nextRefreshTime: String?
        let requestLimit: Int?
        let requestsUsedSinceLastRefresh: Int?
    }
}

actor WarpQuotaFetcher {
    private let apiURL = "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo"
    private var session: URLSession

    init() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        config.httpAdditionalHeaders = [
            "Content-Type": "application/json",
            "x-warp-client-id": "warp-app",
            "x-warp-client-version": "v0.2026.01.07.08.13.stable_01"
        ]
        self.session = URLSession(configuration: config)
    }

    func updateProxyConfiguration() {
        let config = ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15)
        config.httpAdditionalHeaders = [
            "Content-Type": "application/json",
            "x-warp-client-id": "warp-app",
            "x-warp-client-version": "v0.2026.01.07.08.13.stable_01"
        ]
        self.session = URLSession(configuration: config)
    }

    func fetchQuota(apiKey: String) async throws -> ProviderQuotaData {
        var request = URLRequest(url: URL(string: apiURL)!)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let query = """
        query GetRequestLimitInfo($requestContext: RequestContext!) {
          user(requestContext: $requestContext) {
            __typename
            ... on UserOutput {
              user {
                requestLimitInfo {
                  isUnlimited
                  nextRefreshTime
                  requestLimit
                  requestsUsedSinceLastRefresh
                }
              }
            }
          }
        }
        """
        
        let variables: [String: Any] = [
            "requestContext": [
                "clientContext": [:],
                "osContext": [
                    "category": "macOS",
                    "name": "macOS",
                    "version": "26.2"
                ]
            ]
        ]
        
        let body: [String: Any] = [
            "query": query,
            "variables": variables,
            "operationName": "GetRequestLimitInfo"
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
        let warpResponse = try await MainActor.run {
            try decoder.decode(WarpQuotaResponse.self, from: data)
        }

        guard let info = warpResponse.data?.user?.user?.requestLimitInfo else {
            throw QuotaFetchError.invalidResponse
        }

        return await MainActor.run {
            var models: [ModelQuota] = []
            
            let used = info.requestsUsedSinceLastRefresh ?? 0
            let limit = info.requestLimit ?? 0
            let remaining = max(0, limit - used)
            let isUnlimited = info.isUnlimited ?? false
            
            let percentage: Double
            if isUnlimited {
                percentage = 100
            } else if limit > 0 {
                percentage = Double(remaining) / Double(limit) * 100
            } else {
                percentage = 0
            }
            
            models.append(ModelQuota(
                name: "warp-usage",
                percentage: percentage,
                resetTime: stripMilliseconds(from: info.nextRefreshTime) ?? "",
                used: used,
                limit: limit,
                remaining: remaining
            ))

            return ProviderQuotaData(models: models, lastUpdated: Date())
        }
    }

    private nonisolated func stripMilliseconds(from timeString: String?) -> String? {
        guard let timeString = timeString else { return nil }
        let pattern = #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.\d+Z$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: timeString, range: NSRange(timeString.startIndex..., in: timeString)),
              let range = Range(match.range(at: 1), in: timeString) else {
            return timeString
        }
        return String(timeString[range]) + "Z"
    }
}
