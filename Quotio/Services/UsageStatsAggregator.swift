//
//  UsageStatsAggregator.swift
//  Quotio - Persistent Traffic Statistics
//
//  CLIProxyAPI keeps its /v0/management/usage counters in memory, so every
//  proxy restart (or CLIProxyAPI upgrade) resets them to zero. This service
//  accumulates those counters on the Quotio side and persists them to disk,
//  so the dashboard traffic statistics survive proxy restarts and upgrades.
//
//  Correctness relies on two mechanisms, in this order:
//
//  1. Explicit session boundaries driven by the managed proxy lifecycle.
//     `CLIProxyManager` owns a `ProxyUsageSessionRecorder` and calls it on
//     every managed teardown path (stop, config restart, upgrade promote,
//     rollback, health recovery). Where the path can await, a final counter
//     sample is fetched and folded first, so requests served between the last
//     poll and the shutdown are not lost.
//  2. A counter-decrease fallback inside `record(_:source:)`, which only
//     covers restarts Quotio did not perform (proxy crash, external kill,
//     power loss). That fallback is inherently lossy and is not what the
//     managed paths depend on.
//

import Foundation

// MARK: - Proxy Identity

/// Identifies which proxy a set of usage counters belongs to.
///
/// Persisted totals are scoped by this value, so counters from the local
/// managed proxy are never merged into a remote CLIProxyAPI instance's totals
/// (and two different remote servers never share a bucket either).
nonisolated enum UsageStatsSource: Sendable, Equatable, Hashable {
    /// The CLIProxyAPI process Quotio starts and manages on this machine.
    case localProxy

    /// A remote CLIProxyAPI instance, identified by its management base URL.
    case remote(endpoint: String)

    /// Stable key used for on-disk storage.
    var storageKey: String {
        switch self {
        case .localProxy:
            return "local"
        case .remote(let endpoint):
            let normalized = endpoint
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return "remote:\(normalized)"
        }
    }
}

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

    /// Component-wise maximum with another sample from the *same* proxy session.
    ///
    /// CLIProxyAPI counters only ever grow within a session, so taking the
    /// maximum keeps whichever sample is newer without ever double counting.
    /// Used when a final shutdown snapshot and a concurrent poll race.
    func mergingSameSession(_ other: UsageTotals) -> UsageTotals {
        UsageTotals(
            totalRequests: max(totalRequests, other.totalRequests),
            successCount: max(successCount, other.successCount),
            failureCount: max(failureCount, other.failureCount),
            totalTokens: max(totalTokens, other.totalTokens),
            inputTokens: max(inputTokens, other.inputTokens),
            outputTokens: max(outputTokens, other.outputTokens)
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

/// Accumulated state for a single proxy identity.
nonisolated struct UsageSessionState: Codable, Sendable, Equatable {
    /// Totals folded in from proxy sessions that have already ended.
    var baseline: UsageTotals

    /// Latest raw counter sample from the proxy session currently in progress.
    /// Zero once the session has been closed by the lifecycle hook.
    var lastSample: UsageTotals

    static let empty = UsageSessionState(baseline: .zero, lastSample: .zero)

    var cumulative: UsageTotals {
        baseline + lastSample
    }
}

/// On-disk container for accumulated usage statistics, scoped per proxy identity.
nonisolated struct UsageTotalsStore: Codable, Sendable, Equatable {
    /// Version for migration support
    var version: Int

    /// State keyed by `UsageStatsSource.storageKey`.
    var sources: [String: UsageSessionState]

    static let currentVersion = 2

    static var empty: UsageTotalsStore {
        UsageTotalsStore(version: currentVersion, sources: [:])
    }

    func state(for source: UsageStatsSource) -> UsageSessionState {
        sources[source.storageKey] ?? .empty
    }

    mutating func setState(_ state: UsageSessionState, for source: UsageStatsSource) {
        sources[source.storageKey] = state
    }
}

/// Version 1 layout: one unscoped bucket. Migrated onto `.localProxy`, which is
/// the only proxy the previous implementation could meaningfully have tracked.
private struct LegacyUsageTotalsStoreV1: Decodable {
    var version: Int
    var baseline: UsageTotals
    var lastSample: UsageTotals
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

    // MARK: - Sampling

    /// Record a fresh counter sample from `source` and return the cumulative
    /// statistics to display for that source.
    ///
    /// Restarts Quotio performs itself are handled by `endSession(source:)`,
    /// which is driven from the proxy lifecycle before the process goes down.
    /// The counter-decrease check below is only a fallback for restarts Quotio
    /// did not perform (crash, external kill, machine power loss); it cannot
    /// recover traffic served between the last poll and such a restart.
    @discardableResult
    func record(_ sample: UsageStats, source: UsageStatsSource) -> UsageStats {
        var state = store.state(for: source)
        let sampleTotals = UsageTotals(stats: sample)

        if sampleTotals.totalRequests < state.lastSample.totalRequests {
            // Counters went backwards without a managed teardown: preserve
            // whatever the finished session had reported.
            state.baseline = state.baseline + state.lastSample
        }
        state.lastSample = sampleTotals

        store.setState(state, for: source)
        saveToDisk()

        return state.cumulative.asUsageStats
    }

    /// Fold a final counter sample taken immediately before a managed shutdown.
    ///
    /// Callers reach this after an `await`, so the state is re-read here rather
    /// than captured beforehand, and the sample is merged component-wise with
    /// whatever the auto-refresh loop may have recorded in the meantime instead
    /// of overwriting it.
    func foldFinalSample(_ sample: UsageStats, source: UsageStatsSource) {
        var state = store.state(for: source)
        state.lastSample = state.lastSample.mergingSameSession(UsageTotals(stats: sample))
        store.setState(state, for: source)
        saveToDisk()
    }

    /// Close the current proxy session for `source`: the session's counters are
    /// folded into the persistent baseline, so the next process may start from
    /// zero (or from any value at all) without discarding what was served.
    ///
    /// Idempotent — closing an already closed session is a no-op.
    func endSession(source: UsageStatsSource) {
        var state = store.state(for: source)
        guard !state.lastSample.isZero else { return }

        state.baseline = state.baseline + state.lastSample
        state.lastSample = .zero
        store.setState(state, for: source)
        saveToDisk()
    }

    /// Cumulative statistics restored from disk for `source`, or nil when
    /// nothing has been recorded yet (fresh install keeps showing the empty
    /// dashboard).
    func restoredStats(for source: UsageStatsSource) -> UsageStats? {
        let cumulative = store.state(for: source).cumulative
        return cumulative.isZero ? nil : cumulative.asUsageStats
    }

    /// Clear all accumulated statistics for every source.
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
            let decoder = JSONDecoder()

            if let current = try? decoder.decode(UsageTotalsStore.self, from: data),
               current.version >= UsageTotalsStore.currentVersion {
                store = current
                return
            }

            // Migrate the single-bucket v1 file onto the local proxy.
            let legacy = try decoder.decode(LegacyUsageTotalsStoreV1.self, from: data)
            var migrated = UsageTotalsStore.empty
            migrated.setState(
                UsageSessionState(baseline: legacy.baseline, lastSample: legacy.lastSample),
                for: .localProxy
            )
            store = migrated
            saveToDisk()
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

// MARK: - Proxy Lifecycle Bridge

/// Bridges the managed CLIProxyAPI lifecycle to persistent usage statistics.
///
/// `CLIProxyManager` owns one instance and drives it from every managed
/// teardown path, so a stop / restart / upgrade closes the statistics session
/// explicitly instead of it being inferred later from a counter decrease.
///
/// Only `.localProxy` is handled here: `CLIProxyManager` manages exactly one
/// proxy, the local one. A remote CLIProxyAPI instance has no lifecycle Quotio
/// can observe, so its bucket falls back to the counter-decrease heuristic.
@MainActor
final class ProxyUsageSessionRecorder {

    /// Fetches one last `/v0/management/usage` sample from the proxy that is
    /// about to go down. Installed by `QuotaViewModel`, which owns the
    /// management API client. Returns nil when the proxy is already unreachable.
    typealias FinalSampleProvider = @MainActor () async -> UsageStats?

    private let aggregator: UsageStatsAggregator

    var finalSampleProvider: FinalSampleProvider?

    init(aggregator: UsageStatsAggregator = .shared) {
        self.aggregator = aggregator
    }

    /// Called before the managed proxy process is signalled, on teardown paths
    /// that can await. Folds a final counter sample so requests served since
    /// the last poll survive, then closes the session.
    func proxyWillStop() async {
        if let provider = finalSampleProvider, let sample = await provider() {
            aggregator.foldFinalSample(sample, source: .localProxy)
        }
        aggregator.endSession(source: .localProxy)
    }

    /// Called as the managed proxy process goes down, including from the
    /// synchronous `stop()` path where no final sample can be fetched.
    ///
    /// Idempotent: a session already closed by `proxyWillStop()` is untouched,
    /// so paths that call both still fold exactly once.
    func proxyDidStop() {
        aggregator.endSession(source: .localProxy)
    }
}
