//
//  UsageStatsAggregator.swift
//  Quotio - Persistent Traffic Statistics
//
//  CLIProxyAPI keeps its /v0/management/usage counters in memory, so every
//  proxy restart (or CLIProxyAPI upgrade) resets them to zero. This service
//  accumulates those counters on the Quotio side and persists them to disk,
//  so the dashboard traffic statistics survive proxy restarts and upgrades.
//

import Foundation

// MARK: - Persisted Totals

/// Fixed-size aggregate usage counters (no per-request entries, so the
/// persisted file never grows with traffic).
nonisolated struct UsageTotals: Codable, Sendable, Equatable {
    var totalRequests: Int
    var successCount: Int
    var failureCount: Int
    var totalTokens: Int
    var inputTokens: Int
    var outputTokens: Int

    static let zero = UsageTotals(
        totalRequests: 0,
        successCount: 0,
        failureCount: 0,
        totalTokens: 0,
        inputTokens: 0,
        outputTokens: 0
    )

    init(
        totalRequests: Int,
        successCount: Int,
        failureCount: Int,
        totalTokens: Int,
        inputTokens: Int,
        outputTokens: Int
    ) {
        self.totalRequests = totalRequests
        self.successCount = successCount
        self.failureCount = failureCount
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// Snapshot the counters reported by CLIProxyAPI.
    init(stats: UsageStats) {
        let usage = stats.usage
        self.init(
            totalRequests: usage?.totalRequests ?? 0,
            successCount: usage?.successCount ?? 0,
            failureCount: usage?.failureCount ?? 0,
            totalTokens: usage?.totalTokens ?? 0,
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0
        )
    }

    static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        UsageTotals(
            totalRequests: lhs.totalRequests + rhs.totalRequests,
            successCount: lhs.successCount + rhs.successCount,
            failureCount: lhs.failureCount + rhs.failureCount,
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }

    var isZero: Bool {
        self == .zero
    }

    /// Convert to the DTO the dashboard already consumes.
    var asUsageStats: UsageStats {
        UsageStats(
            usage: UsageData(
                totalRequests: totalRequests,
                successCount: successCount,
                failureCount: failureCount,
                totalTokens: totalTokens,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            ),
            failedRequests: failureCount
        )
    }
}

/// On-disk container for accumulated usage statistics.
nonisolated struct UsageTotalsStore: Codable, Sendable, Equatable {
    /// Version for migration support
    var version: Int

    /// Totals folded in from previous proxy sessions.
    var baseline: UsageTotals

    /// Latest raw counter sample from the current proxy session.
    var lastSample: UsageTotals

    static let currentVersion = 1

    static var empty: UsageTotalsStore {
        UsageTotalsStore(version: currentVersion, baseline: .zero, lastSample: .zero)
    }

    var cumulative: UsageTotals {
        baseline + lastSample
    }
}

// MARK: - Aggregator

/// Accumulates CLIProxyAPI usage counters across proxy restarts and persists
/// them to Application Support so traffic statistics are retained.
@MainActor
@Observable
final class UsageStatsAggregator {

    static let shared = UsageStatsAggregator()

    // MARK: - Properties

    private(set) var store: UsageTotalsStore = .empty

    /// Storage file URL
    private let storageURL: URL

    // MARK: - Initialization

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        loadFromDisk()
    }

    private static func defaultStorageURL() -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory not found")
        }
        let quotioDir = appSupport.appendingPathComponent("Quotio")
        try? FileManager.default.createDirectory(at: quotioDir, withIntermediateDirectories: true)
        return quotioDir.appendingPathComponent("usage-stats.json")
    }

    // MARK: - Public Methods

    /// Record a fresh counter sample from CLIProxyAPI and return the
    /// cumulative statistics to display.
    ///
    /// When the proxy restarts (manual restart or CLIProxyAPI upgrade) its
    /// in-memory counters start over from zero. A sample whose request count
    /// is lower than the previous one signals that reset, so the previous
    /// session's totals are folded into the persistent baseline before the
    /// new sample is stored.
    @discardableResult
    func record(_ sample: UsageStats) -> UsageStats {
        let sampleTotals = UsageTotals(stats: sample)

        if sampleTotals.totalRequests < store.lastSample.totalRequests {
            // Proxy counters reset: preserve the finished session's totals.
            store.baseline = store.baseline + store.lastSample
        }
        store.lastSample = sampleTotals
        saveToDisk()

        return store.cumulative.asUsageStats
    }

    /// Cumulative statistics restored from disk, or nil when nothing has been
    /// recorded yet (fresh install keeps showing the empty dashboard).
    func restoredStats() -> UsageStats? {
        let cumulative = store.cumulative
        return cumulative.isZero ? nil : cumulative.asUsageStats
    }

    /// Clear all accumulated statistics.
    func reset() {
        store = .empty
        saveToDisk()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: storageURL)
            store = try JSONDecoder().decode(UsageTotalsStore.self, from: data)
        } catch {
            NSLog("[UsageStatsAggregator] Failed to load usage totals: \(error)")
            // If decoding fails due to corruption or format mismatch, start fresh
            try? FileManager.default.removeItem(at: storageURL)
            store = .empty
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(store)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("[UsageStatsAggregator] Failed to save usage totals: \(error)")
        }
    }
}
