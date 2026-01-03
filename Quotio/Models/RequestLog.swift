//
//  RequestLog.swift
//  Quotio - Request History Data Model
//
//  This file defines the data model for tracking API request history,
//  including token usage, timing, and provider/model information.
//

import Foundation

// MARK: - Request Log Entry

/// Represents a single API request/response pair with associated metadata
nonisolated struct RequestLog: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    
    /// HTTP method (GET, POST, etc.)
    let method: String
    
    /// Request endpoint path (e.g., "/v1/messages")
    let endpoint: String
    
    /// AI provider (e.g., "claude", "gemini", "openai")
    let provider: String?
    
    /// Model used (e.g., "claude-sonnet-4", "gemini-2.0-flash")
    let model: String?
    
    /// Number of input tokens (from API response)
    let inputTokens: Int?
    
    /// Number of output tokens (from API response)
    let outputTokens: Int?
    
    /// Total tokens (input + output)
    var totalTokens: Int? {
        guard let input = inputTokens, let output = outputTokens else {
            return inputTokens ?? outputTokens
        }
        return input + output
    }
    
    /// Request duration in milliseconds
    let durationMs: Int
    
    /// HTTP status code from response
    let statusCode: Int?
    
    /// Request body size in bytes
    let requestSize: Int
    
    /// Response body size in bytes
    let responseSize: Int
    
    /// Error message if request failed
    let errorMessage: String?
    
    /// Whether the request was successful (2xx status)
    var isSuccess: Bool {
        guard let code = statusCode else { return false }
        return code >= 200 && code < 300
    }
    
    /// Default initializer
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        method: String,
        endpoint: String,
        provider: String? = nil,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        durationMs: Int,
        statusCode: Int? = nil,
        requestSize: Int = 0,
        responseSize: Int = 0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.endpoint = endpoint
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.durationMs = durationMs
        self.statusCode = statusCode
        self.requestSize = requestSize
        self.responseSize = responseSize
        self.errorMessage = errorMessage
    }
}

// MARK: - Aggregate Statistics

/// Aggregated statistics for request history
nonisolated struct RequestStats: Codable, Sendable {
    /// Total number of requests
    let totalRequests: Int
    
    /// Number of successful requests (2xx)
    let successfulRequests: Int
    
    /// Number of failed requests
    let failedRequests: Int
    
    /// Total input tokens across all requests
    let totalInputTokens: Int
    
    /// Total output tokens across all requests
    let totalOutputTokens: Int
    
    /// Total tokens (input + output)
    var totalTokens: Int {
        totalInputTokens + totalOutputTokens
    }
    
    /// Average request duration in milliseconds
    let averageDurationMs: Int
    
    /// Statistics by provider
    let byProvider: [String: ProviderStats]
    
    /// Statistics by model
    let byModel: [String: ModelStats]
    
    /// Success rate as percentage (0-100)
    var successRate: Double {
        guard totalRequests > 0 else { return 0 }
        return Double(successfulRequests) / Double(totalRequests) * 100
    }
    
    /// Create empty stats
    static var empty: RequestStats {
        RequestStats(
            totalRequests: 0,
            successfulRequests: 0,
            failedRequests: 0,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            averageDurationMs: 0,
            byProvider: [:],
            byModel: [:]
        )
    }
}

/// Statistics for a specific provider
struct ProviderStats: Codable, Sendable {
    let provider: String
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let averageDurationMs: Int
    
    var totalTokens: Int {
        inputTokens + outputTokens
    }
}

/// Statistics for a specific model
struct ModelStats: Codable, Sendable {
    let model: String
    let provider: String?
    let requestCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let averageDurationMs: Int
    
    var totalTokens: Int {
        inputTokens + outputTokens
    }
}

// MARK: - Request History Storage

/// Container for persisted request history
nonisolated struct RequestHistoryStore: Codable, Sendable {
    /// Version for migration support
    let version: Int
    
    /// Request log entries
    var entries: [RequestLog]
    
    /// Maximum number of entries to keep
    static let maxEntries = 500
    
    /// Current storage version
    static let currentVersion = 1
    
    /// Create empty store
    static var empty: RequestHistoryStore {
        RequestHistoryStore(version: currentVersion, entries: [])
    }
    
    /// Add entry and trim if needed
    mutating func addEntry(_ entry: RequestLog) {
        entries.insert(entry, at: 0)
        
        // Trim oldest entries if exceeding max
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
    }
    
    /// Calculate aggregate statistics
    func calculateStats() -> RequestStats {
        guard !entries.isEmpty else { return .empty }
        
        var totalInput = 0
        var totalOutput = 0
        var totalDuration = 0
        var successCount = 0
        var providerData: [String: (count: Int, input: Int, output: Int, duration: Int)] = [:]
        var modelData: [String: (provider: String?, count: Int, input: Int, output: Int, duration: Int)] = [:]
        
        for entry in entries {
            totalInput += entry.inputTokens ?? 0
            totalOutput += entry.outputTokens ?? 0
            totalDuration += entry.durationMs
            
            if entry.isSuccess {
                successCount += 1
            }
            
            // Aggregate by provider
            if let provider = entry.provider {
                var data = providerData[provider] ?? (0, 0, 0, 0)
                data.count += 1
                data.input += entry.inputTokens ?? 0
                data.output += entry.outputTokens ?? 0
                data.duration += entry.durationMs
                providerData[provider] = data
            }
            
            // Aggregate by model
            if let model = entry.model {
                var data = modelData[model] ?? (entry.provider, 0, 0, 0, 0)
                data.count += 1
                data.input += entry.inputTokens ?? 0
                data.output += entry.outputTokens ?? 0
                data.duration += entry.durationMs
                modelData[model] = data
            }
        }
        
        let byProvider = providerData.mapValues { data in
            ProviderStats(
                provider: "",  // Will be set by key
                requestCount: data.count,
                inputTokens: data.input,
                outputTokens: data.output,
                averageDurationMs: data.count > 0 ? data.duration / data.count : 0
            )
        }
        
        let byModel = modelData.mapValues { data in
            ModelStats(
                model: "",  // Will be set by key
                provider: data.provider,
                requestCount: data.count,
                inputTokens: data.input,
                outputTokens: data.output,
                averageDurationMs: data.count > 0 ? data.duration / data.count : 0
            )
        }
        
        return RequestStats(
            totalRequests: entries.count,
            successfulRequests: successCount,
            failedRequests: entries.count - successCount,
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            averageDurationMs: entries.count > 0 ? totalDuration / entries.count : 0,
            byProvider: byProvider.reduce(into: [:]) { result, pair in
                result[pair.key] = ProviderStats(
                    provider: pair.key,
                    requestCount: pair.value.requestCount,
                    inputTokens: pair.value.inputTokens,
                    outputTokens: pair.value.outputTokens,
                    averageDurationMs: pair.value.averageDurationMs
                )
            },
            byModel: byModel.reduce(into: [:]) { result, pair in
                result[pair.key] = ModelStats(
                    model: pair.key,
                    provider: pair.value.provider,
                    requestCount: pair.value.requestCount,
                    inputTokens: pair.value.inputTokens,
                    outputTokens: pair.value.outputTokens,
                    averageDurationMs: pair.value.averageDurationMs
                )
            }
        )
    }
}

// MARK: - Formatting Helpers

extension RequestLog {
    /// Static formatters for performance (avoid recreating on every call)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Formatted timestamp for display
    var formattedTimestamp: String {
        Self.timeFormatter.string(from: timestamp)
    }

    /// Formatted date for grouping
    var formattedDate: String {
        Self.dateFormatter.string(from: timestamp)
    }
    
    /// Formatted duration for display
    var formattedDuration: String {
        if durationMs < 1000 {
            return "\(durationMs)ms"
        } else {
            let seconds = Double(durationMs) / 1000.0
            return String(format: "%.1fs", seconds)
        }
    }
    
    /// Formatted token count
    var formattedTokens: String? {
        guard let total = totalTokens else { return nil }
        if total >= 1000 {
            return String(format: "%.1fK", Double(total) / 1000.0)
        }
        return "\(total)"
    }
    
    /// Status badge text
    var statusBadge: String {
        guard let code = statusCode else { return "?" }
        return "\(code)"
    }
}

extension Int {
    /// Format large numbers with K/M suffix
    var formattedTokenCount: String {
        if self >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000.0)
        } else if self >= 1000 {
            return String(format: "%.1fK", Double(self) / 1000.0)
        }
        return "\(self)"
    }
}
