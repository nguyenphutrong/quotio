//
//  DaemonStatsService.swift
//  Quotio
//

import Foundation
import Observation

/// Error types for DaemonStatsService operations
enum DaemonStatsError: LocalizedError {
    case daemonNotRunning
    case fetchFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .daemonNotRunning:
            return "Daemon is not running"
        case .fetchFailed(let reason):
            return "Failed to fetch stats: \(reason)"
        }
    }
}

@MainActor @Observable
final class DaemonStatsService {
    static let shared = DaemonStatsService()
    
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var cachedStats: UsageStats?
    
    private let ipcClient = DaemonIPCClient.shared
    private let daemonManager = DaemonManager.shared
    
    private init() {}
    
    private var isDaemonReady: Bool {
        get async {
            if daemonManager.isRunning { return true }
            return await daemonManager.checkHealth()
        }
    }
    
    func fetchUsageStats() async -> UsageStats? {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return nil
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.fetchStats()
            let stats = convertToUsageStats(result.stats)
            cachedStats = stats
            return stats
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
    
    func fetchRequestStats() async -> RequestStats? {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return nil
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.fetchStats()
            return convertToRequestStats(result.stats)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
    
    func fetchRequestLogs(provider: String? = nil, minutes: Int? = nil) async -> [RequestLog]? {
        guard await isDaemonReady else {
            lastError = "Daemon not running"
            return nil
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.listRequestStats(provider: provider, minutes: minutes)
            return result.entries.map { convertToRequestLog($0) }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
    
    func clearRequestStats() async throws -> Bool {
        guard await isDaemonReady else {
            throw DaemonStatsError.daemonNotRunning
        }
        
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        
        do {
            let result = try await ipcClient.clearRequestStats()
            return result.success
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
    
    private func convertToUsageStats(_ ipcStats: IPCRequestStats) -> UsageStats {
        let usageData = UsageData(
            totalRequests: ipcStats.totalRequests,
            successCount: ipcStats.successfulRequests,
            failureCount: ipcStats.failedRequests,
            totalTokens: ipcStats.totalInputTokens + ipcStats.totalOutputTokens,
            inputTokens: ipcStats.totalInputTokens,
            outputTokens: ipcStats.totalOutputTokens
        )
        
        return UsageStats(
            usage: usageData,
            failedRequests: ipcStats.failedRequests
        )
    }
    
    private func convertToRequestStats(_ ipcStats: IPCRequestStats) -> RequestStats {
        let providerStats: [String: ProviderStats]
        if let providers = ipcStats.byProvider {
            providerStats = providers.reduce(into: [:]) { result, pair in
                result[pair.key] = ProviderStats(
                    provider: pair.key,
                    requestCount: pair.value.totalRequests,
                    inputTokens: pair.value.totalInputTokens,
                    outputTokens: pair.value.totalOutputTokens,
                    averageDurationMs: Int(pair.value.averageDurationMs)
                )
            }
        } else {
            providerStats = [:]
        }
        
        let modelStats: [String: ModelStats]
        if let models = ipcStats.byModel {
            modelStats = models.reduce(into: [:]) { result, pair in
                result[pair.key] = ModelStats(
                    model: pair.key,
                    provider: nil,
                    requestCount: pair.value.totalRequests,
                    inputTokens: pair.value.totalInputTokens,
                    outputTokens: pair.value.totalOutputTokens,
                    averageDurationMs: Int(pair.value.averageDurationMs)
                )
            }
        } else {
            modelStats = [:]
        }
        
        return RequestStats(
            totalRequests: ipcStats.totalRequests,
            successfulRequests: ipcStats.successfulRequests,
            failedRequests: ipcStats.failedRequests,
            totalInputTokens: ipcStats.totalInputTokens,
            totalOutputTokens: ipcStats.totalOutputTokens,
            averageDurationMs: Int(ipcStats.averageDurationMs),
            byProvider: providerStats,
            byModel: modelStats
        )
    }
    
    private func convertToRequestLog(_ entry: IPCRequestLog) -> RequestLog {
        let timestamp = parseTimestamp(entry.timestamp) ?? Date()
        return RequestLog(
            id: UUID(uuidString: entry.id) ?? UUID(),
            timestamp: timestamp,
            method: entry.method,
            endpoint: entry.endpoint,
            provider: entry.provider,
            model: entry.model,
            inputTokens: entry.inputTokens,
            outputTokens: entry.outputTokens,
            durationMs: entry.durationMs,
            statusCode: entry.statusCode,
            requestSize: entry.requestSize,
            responseSize: entry.responseSize,
            errorMessage: entry.errorMessage
        )
    }
    
    private func parseTimestamp(_ isoString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }
    
    func reset() {
        cachedStats = nil
        lastError = nil
    }
}
