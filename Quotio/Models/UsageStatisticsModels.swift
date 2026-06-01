//
//  UsageStatisticsModels.swift
//  Quotio
//

import Foundation

nonisolated struct UsageStatsStatus: Codable, Sendable {
    let enabled: Bool
    let open: Bool
    let path: String?
    let modelPricesCount: Int?
    let modelPricesLastSyncedAtMS: Int64?
    let modelPricesLastUpdatedAtMS: Int64?
    let modelPricesSyncing: Bool?
    let modelPricesSyncError: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case open
        case path
        case modelPricesCount = "model_prices_count"
        case modelPricesLastSyncedAtMS = "model_prices_last_synced_at_ms"
        case modelPricesLastUpdatedAtMS = "model_prices_last_updated_at_ms"
        case modelPricesSyncing = "model_prices_syncing"
        case modelPricesSyncError = "model_prices_sync_error"
    }
}

nonisolated struct UsageStatsFilter: Equatable, Sendable {
    var account: String = ""
    var model: String = ""
    var channel: String = ""
    var authIndex: String = ""
    var startMS: Int64?
    var endMS: Int64?

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        appendQueryItem(name: "account", value: account, to: &items)
        appendQueryItem(name: "model", value: model, to: &items)
        appendQueryItem(name: "channel", value: channel, to: &items)
        appendQueryItem(name: "auth_index", value: authIndex, to: &items)
        if let startMS {
            items.append(URLQueryItem(name: "start_ms", value: String(startMS)))
        }
        if let endMS {
            items.append(URLQueryItem(name: "end_ms", value: String(endMS)))
        }
        return items
    }

    private func appendQueryItem(name: String, value: String, to items: inout [URLQueryItem]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(URLQueryItem(name: name, value: trimmed))
    }
}

nonisolated struct UsageStatsEventsResponse: Decodable, Sendable {
    let events: [UsageStatsEvent]
    let limit: Int
    let offset: Int

    enum CodingKeys: String, CodingKey {
        case events
        case limit
        case offset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decodeIfPresent([UsageStatsEvent].self, forKey: .events) ?? []
        limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? 100
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? 0
    }
}

nonisolated struct UsageStatsSummaryResponse: Decodable, Sendable {
    let summary: UsageStatsSummary
}

nonisolated struct UsageStatsEvent: Identifiable, Decodable, Hashable, Sendable {
    let eventID: Int64
    let requestID: String
    let eventHash: String
    let timestampMS: Int64
    let provider: String
    let channel: String
    let model: String
    let requestedModel: String
    let resolvedModel: String
    let endpoint: String
    let method: String
    let path: String
    let authType: String
    let authIndex: String
    let account: String
    let accountHash: String
    let apiKeyHash: String
    let statusCode: Int
    let promptTokens: Int64
    let completionTokens: Int64
    let reasoningTokens: Int64
    let cachedTokens: Int64
    let cacheTokens: Int64
    let totalTokens: Int64
    let latencyMS: Int64?
    let failed: Bool
    let createdAtMS: Int64
    let estimatedCostUSD: Double?

    var id: Int64 { eventID }
    var timestampDate: Date { Date(timeIntervalSince1970: TimeInterval(timestampMS) / 1000) }

    var displayAccount: String {
        firstNonEmpty(account, accountHash, apiKeyHash)
    }

    var displayModel: String {
        firstNonEmpty(resolvedModel, model, requestedModel)
    }

    var displaySourceModel: String {
        firstNonEmpty(model, requestedModel, resolvedModel)
    }

    var displayChannel: String {
        firstNonEmpty(channel, provider)
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "ID"
        case eventIDAlias = "id"
        case requestID = "RequestID"
        case requestIDAlias = "request_id"
        case eventHash = "EventHash"
        case eventHashAlias = "event_hash"
        case timestampMS = "TimestampMS"
        case timestampMSAlias = "timestamp_ms"
        case provider = "Provider"
        case providerAlias = "provider"
        case channel = "Channel"
        case channelAlias = "channel"
        case model = "Model"
        case modelAlias = "model"
        case requestedModel = "RequestedModel"
        case requestedModelAlias = "requested_model"
        case resolvedModel = "ResolvedModel"
        case resolvedModelAlias = "resolved_model"
        case endpoint = "Endpoint"
        case endpointAlias = "endpoint"
        case method = "Method"
        case methodAlias = "method"
        case path = "Path"
        case pathAlias = "path"
        case authType = "AuthType"
        case authTypeAlias = "auth_type"
        case authIndex = "AuthIndex"
        case authIndexAlias = "auth_index"
        case account = "Account"
        case accountAlias = "account"
        case accountHash = "AccountHash"
        case accountHashAlias = "account_hash"
        case apiKeyHash = "APIKeyHash"
        case apiKeyHashAlias = "api_key_hash"
        case statusCode = "StatusCode"
        case statusCodeAlias = "status_code"
        case promptTokens = "PromptTokens"
        case promptTokensAlias = "prompt_tokens"
        case completionTokens = "CompletionTokens"
        case completionTokensAlias = "completion_tokens"
        case reasoningTokens = "ReasoningTokens"
        case reasoningTokensAlias = "reasoning_tokens"
        case cachedTokens = "CachedTokens"
        case cachedTokensAlias = "cached_tokens"
        case cacheTokens = "CacheTokens"
        case cacheTokensAlias = "cache_tokens"
        case totalTokens = "TotalTokens"
        case totalTokensAlias = "total_tokens"
        case latencyMS = "LatencyMS"
        case latencyMSAlias = "latency_ms"
        case failed = "Failed"
        case failedAlias = "failed"
        case createdAtMS = "CreatedAtMS"
        case createdAtMSAlias = "created_at_ms"
        case estimatedCostUSD = "EstimatedCostUSD"
        case estimatedCostUSDAlias = "estimated_cost_usd"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decodeInt64(keys: [.eventID, .eventIDAlias], defaultValue: 0)
        requestID = try container.decodeString(keys: [.requestID, .requestIDAlias])
        eventHash = try container.decodeString(keys: [.eventHash, .eventHashAlias])
        timestampMS = try container.decodeInt64(keys: [.timestampMS, .timestampMSAlias], defaultValue: 0)
        provider = try container.decodeString(keys: [.provider, .providerAlias])
        channel = try container.decodeString(keys: [.channel, .channelAlias])
        model = try container.decodeString(keys: [.model, .modelAlias])
        requestedModel = try container.decodeString(keys: [.requestedModel, .requestedModelAlias])
        resolvedModel = try container.decodeString(keys: [.resolvedModel, .resolvedModelAlias])
        endpoint = try container.decodeString(keys: [.endpoint, .endpointAlias])
        method = try container.decodeString(keys: [.method, .methodAlias])
        path = try container.decodeString(keys: [.path, .pathAlias])
        authType = try container.decodeString(keys: [.authType, .authTypeAlias])
        authIndex = try container.decodeString(keys: [.authIndex, .authIndexAlias])
        account = try container.decodeString(keys: [.account, .accountAlias])
        accountHash = try container.decodeString(keys: [.accountHash, .accountHashAlias])
        apiKeyHash = try container.decodeString(keys: [.apiKeyHash, .apiKeyHashAlias])
        statusCode = try container.decodeInt(keys: [.statusCode, .statusCodeAlias], defaultValue: 0)
        promptTokens = try container.decodeInt64(keys: [.promptTokens, .promptTokensAlias], defaultValue: 0)
        completionTokens = try container.decodeInt64(keys: [.completionTokens, .completionTokensAlias], defaultValue: 0)
        reasoningTokens = try container.decodeInt64(keys: [.reasoningTokens, .reasoningTokensAlias], defaultValue: 0)
        cachedTokens = try container.decodeInt64(keys: [.cachedTokens, .cachedTokensAlias], defaultValue: 0)
        cacheTokens = try container.decodeInt64(keys: [.cacheTokens, .cacheTokensAlias], defaultValue: 0)
        totalTokens = try container.decodeInt64(keys: [.totalTokens, .totalTokensAlias], defaultValue: 0)
        latencyMS = try container.decodeOptionalInt64(keys: [.latencyMS, .latencyMSAlias])
        failed = try container.decodeBool(keys: [.failed, .failedAlias], defaultValue: false)
        createdAtMS = try container.decodeInt64(keys: [.createdAtMS, .createdAtMSAlias], defaultValue: 0)
        estimatedCostUSD = try container.decodeOptionalDouble(keys: [.estimatedCostUSD, .estimatedCostUSDAlias])
    }

    private func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "-"
    }
}

nonisolated struct UsageStatsTokens: Codable, Hashable, Sendable {
    let promptTokens: Int64
    let completionTokens: Int64
    let reasoningTokens: Int64
    let cachedTokens: Int64
    let cacheTokens: Int64
    let totalTokens: Int64

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case reasoningTokens = "reasoning_tokens"
        case cachedTokens = "cached_tokens"
        case cacheTokens = "cache_tokens"
        case totalTokens = "total_tokens"
    }
}

nonisolated struct UsageStatsSummary: Codable, Hashable, Sendable {
    let totalRequests: Int64
    let successCount: Int64
    let failureCount: Int64
    let tokens: UsageStatsTokens
    let latencySumMS: Int64?
    let latencyCount: Int64?
    let estimatedCostUSD: Double?

    var averageLatencyMS: Int64? {
        guard let latencySumMS, let latencyCount, latencyCount > 0 else { return nil }
        return latencySumMS / latencyCount
    }

    enum CodingKeys: String, CodingKey {
        case totalRequests = "total_requests"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case tokens
        case latencySumMS = "latency_sum_ms"
        case latencyCount = "latency_count"
        case estimatedCostUSD = "estimated_cost_usd"
    }
}

nonisolated struct UsageStatsModelPrice: Codable, Hashable, Sendable {
    var prompt: Double
    var completion: Double
    var cache: Double
    var source: String?
    var sourceModelID: String?
    var rawJSON: String?
    var updatedAtMS: Int64?
    var syncedAtMS: Int64?

    enum CodingKeys: String, CodingKey {
        case prompt
        case completion
        case cache
        case source
        case sourceModelID = "source_model_id"
        case rawJSON = "raw_json"
        case updatedAtMS = "updated_at_ms"
        case syncedAtMS = "synced_at_ms"
    }
}

nonisolated struct UsageStatsModelPricesSyncRequest: Codable, Sendable {
    let models: [String]
    let includePrices: Bool

    enum CodingKeys: String, CodingKey {
        case models
        case includePrices = "include_prices"
    }
}

nonisolated struct UsageStatsModelPricesSyncResult: Codable, Sendable {
    let source: String
    let imported: Int
    let skipped: Int
    let unmatched: [String]?
    let prices: [String: UsageStatsModelPrice]?
}

private extension KeyedDecodingContainer where K == UsageStatsEvent.CodingKeys {
    nonisolated func decodeString(keys: [K]) throws -> String {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return ""
    }

    nonisolated func decodeInt(keys: [K], defaultValue: Int) throws -> Int {
        for key in keys {
            if let value = try decodeIfPresent(Int.self, forKey: key) {
                return value
            }
        }
        return defaultValue
    }

    nonisolated func decodeInt64(keys: [K], defaultValue: Int64) throws -> Int64 {
        for key in keys {
            if let value = try decodeIfPresent(Int64.self, forKey: key) {
                return value
            }
        }
        return defaultValue
    }

    nonisolated func decodeOptionalInt64(keys: [K]) throws -> Int64? {
        for key in keys {
            if let value = try decodeIfPresent(Int64.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    nonisolated func decodeOptionalDouble(keys: [K]) throws -> Double? {
        for key in keys {
            if let value = try decodeIfPresent(Double.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    nonisolated func decodeBool(keys: [K], defaultValue: Bool) throws -> Bool {
        for key in keys {
            if let value = try decodeIfPresent(Bool.self, forKey: key) {
                return value
            }
        }
        return defaultValue
    }
}
