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

// MARK: - Request Protocol

/// The wire protocol (API shape) a request was made in, derived from its endpoint path.
///
/// This is deliberately *not* the provider. `/v1/chat/completions` is the OpenAI-compatible
/// protocol, and Qwen, GLM, DeepSeek, Grok and every `openai-compatibility` custom provider
/// speak it too, so the path alone says nothing about which account served the request.
nonisolated enum RequestProtocol: String, Codable, Hashable, Sendable {
    case anthropic
    case openai
    case gemini

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    /// The provider label recorded when the protocol is the only available signal.
    /// These match the values historic logs already contain, so persisted rows keep rendering.
    var providerLabel: String {
        switch self {
        case .anthropic: return "claude"
        case .openai: return "openai"
        case .gemini: return "gemini"
        }
    }

    /// Detect the protocol from a request path.
    static func detect(fromPath path: String) -> RequestProtocol? {
        let lower = path.lowercased()

        // Gemini first: its markers are the most specific, and a Gemini path embeds the model
        // id (`/v1beta/models/claude-…:generateContent`), which would otherwise trip the
        // Anthropic check below.
        if lower.contains("/gemini/") || lower.contains("/google/")
            || lower.contains("/v1beta/") || lower.contains(":generatecontent") {
            return .gemini
        }
        if lower.contains("/anthropic/") || lower.contains("/claude") || lower.contains("/messages") {
            return .anthropic
        }
        if lower.contains("/openai/") || lower.contains("/chat/completions")
            || lower.contains("/responses") {
            return .openai
        }
        return nil
    }
}

// MARK: - Provider Derivation

nonisolated extension RequestLog {
    /// Provider labels that only identify the request *protocol*, not who served it.
    ///
    /// `ProxyBridge` derives these from the endpoint path, so a stored `openai` may really be
    /// Qwen, GLM, DeepSeek, Grok or any `openai-compatibility` provider sharing
    /// `/v1/chat/completions`. Every other label (`kiro`, `github-copilot`, `antigravity`, …)
    /// names a real provider and outranks model-name inference.
    static let protocolOnlyProviderLabels: Set<String> = ["claude", "openai", "gemini"]

    /// The protocol this request was made in, derived from its endpoint.
    var requestProtocol: RequestProtocol? {
        RequestProtocol.detect(fromPath: endpoint)
    }

    /// The provider that ultimately served the request.
    ///
    /// Precedence, applied identically here and in `ProxyBridge.extractMetadata` via
    /// `deriveProvider(path:model:)`:
    /// 1. A stored label that names a real provider or hosting aggregator. Copilot, Kiro and
    ///    Antigravity serve other vendors' model families, so a model name cannot override them.
    /// 2. The model family, the only signal that separates Qwen/GLM/DeepSeek/Grok from plain
    ///    OpenAI on a shared `/v1/chat/completions` endpoint.
    /// 3. The stored protocol label, so unclassifiable models still read as they did before.
    var effectiveProvider: String? {
        let stored = provider.map(Self.canonicalProviderID).flatMap { $0.isEmpty ? nil : $0 }

        if let stored, !Self.protocolOnlyProviderLabels.contains(stored) {
            return stored
        }
        if let inferred = Self.inferProvider(fromModel: model) {
            return inferred
        }
        return stored
    }

    /// The provider recorded at capture time for a request, from its path and body model.
    /// Single source of truth shared with `ProxyBridge.extractMetadata`.
    static func deriveProvider(path: String, model: String?) -> String? {
        // A provider-scoped path segment names the host outright; a model name cannot
        // contradict it because aggregators serve other vendors' model families.
        if let hosted = hostingProvider(fromPath: path) {
            return hosted
        }
        if let inferred = inferProvider(fromModel: model) {
            return inferred
        }
        // Nothing better than the protocol the endpoint speaks.
        return RequestProtocol.detect(fromPath: path)?.providerLabel
    }

    /// Providers that can be identified from the path itself rather than from the API shape.
    private static func hostingProvider(fromPath path: String) -> String? {
        let lower = path.lowercased()
        if lower.contains("/copilot/") {
            return AIProvider.copilot.rawValue
        }
        if lower.contains("codewhisperer") || lower.contains("/kiro") {
            return AIProvider.kiro.rawValue
        }
        return nil
    }

    /// Collapse the two vocabularies this field has historically carried — path labels such as
    /// `copilot` and `AIProvider` raw values such as `github-copilot` — onto one identifier so
    /// badge, filter, search and stats group the same requests together.
    static func canonicalProviderID(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "copilot", "github-copilot": return AIProvider.copilot.rawValue
        case "anthropic": return "claude"
        case "google": return "gemini"
        case "cline-pass", "clinepass": return AIProvider.clinePass.rawValue
        case "factory-droid", "factorydroid": return AIProvider.factoryDroid.rawValue
        default: return lower
        }
    }

    /// Compact display label for a provider identifier.
    static func displayName(forProvider provider: String) -> String {
        let id = canonicalProviderID(provider)
        switch id {
        case "claude": return "Claude"
        case "openai": return "OpenAI"
        case "gemini": return "Gemini"
        case "github-copilot": return "Copilot"
        case "kiro": return "Kiro"
        case "antigravity": return "Antigravity"
        case "qwen": return "Qwen"
        case "glm": return "GLM"
        case "grok": return "Grok"
        case "deepseek": return "DeepSeek"
        case "kimi": return "Kimi"
        case "minimax": return "MiniMax"
        case "mimo": return "MiMo"
        case "clinepass": return "ClinePass"
        case "factory-droid": return "Factory"
        default: return AIProvider(rawValue: id)?.displayName ?? id.capitalized
        }
    }

    /// Infer the serving provider from a model id (e.g. "qwen3-coder-plus" → "qwen").
    /// Returns nil when the model family is unknown — a guess would be worse than "Unknown".
    static func inferProvider(fromModel model: String?) -> String? {
        guard let model else { return nil }
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }

        // 1. Hosting aggregators first — they serve other vendors' families under their own
        //    prefix, so the family suffix must not win. Prefixes verified against the model
        //    ids this app actually emits: CustomProviderSheet.clinePassModels ("cline-pass/…"),
        //    plus Kiro and Antigravity model prefixes ("kiro-claude-…",
        //    "gemini-claude-…" = Antigravity-hosted Claude).
        if lower.hasPrefix("cline-pass/") || lower.hasPrefix("clinepass/") {
            return AIProvider.clinePass.rawValue
        }
        if lower.contains("codewhisperer") {
            return AIProvider.kiro.rawValue
        }
        if lower.hasPrefix("gemini-claude") {
            return AIProvider.antigravity.rawValue
        }

        // 2. Explicit provider prefix (e.g. "kiro-claude-opus-4-6-agentic" → kiro,
        //    "claude-sonnet-4-5" → claude).
        for provider in AIProvider.allCases {
            let key = provider.rawValue
            if lower.hasPrefix(key + "-") || lower.hasPrefix(key + "_") || lower.hasPrefix(key + "/") {
                return key
            }
        }

        // 3. Model families. Anthropic and Gemini names, then the OpenAI-compatible families
        //    that share `/v1/chat/completions` and are indistinguishable by endpoint.
        if ["claude", "opus", "sonnet", "haiku"].contains(where: lower.contains) {
            return "claude"
        }
        if lower.hasPrefix("gemini") || lower.hasPrefix("models/gemini") {
            return "gemini"
        }
        if lower.hasPrefix("gpt") || lower.hasPrefix("o1") || lower.hasPrefix("o3")
            || lower.hasPrefix("o4") || lower.contains("codex") {
            return "openai"
        }
        // Families seen in AvailableModel / CustomProviderSheet model lists.
        for family in ["qwen", "glm", "grok", "deepseek", "kimi", "minimax", "mimo"]
        where lower.hasPrefix(family) {
            return family
        }
        return nil
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
    
    /// Maximum entries to keep (memory-optimized)
    static let maxEntries = 50
    
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
            if let provider = entry.effectiveProvider {
                var data = providerData[provider] ?? (0, 0, 0, 0)
                data.count += 1
                data.input += entry.inputTokens ?? 0
                data.output += entry.outputTokens ?? 0
                data.duration += entry.durationMs
                providerData[provider] = data
            }
            
            // Aggregate by model
            if let model = entry.model {
                var data = modelData[model] ?? (entry.effectiveProvider, 0, 0, 0, 0)
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
