import XCTest
@testable import Quotio

@MainActor
final class UsageStatsAggregatorTests: XCTestCase {

    private var storageURL: URL!

    override func setUp() {
        super.setUp()
        storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-stats-tests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storageURL)
        storageURL = nil
        super.tearDown()
    }

    private func makeStats(
        totalRequests: Int,
        successCount: Int = 0,
        failureCount: Int = 0,
        totalTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) -> UsageStats {
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

    // MARK: - Accumulation

    func testMonotonicSamplesAreNotDoubleCounted() {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)

        _ = aggregator.record(makeStats(totalRequests: 10, successCount: 9, failureCount: 1, totalTokens: 1000, inputTokens: 600, outputTokens: 400), source: .localProxy)
        _ = aggregator.record(makeStats(totalRequests: 15, successCount: 13, failureCount: 2, totalTokens: 1500, inputTokens: 900, outputTokens: 600), source: .localProxy)
        let result = aggregator.record(makeStats(totalRequests: 20, successCount: 17, failureCount: 3, totalTokens: 2000, inputTokens: 1200, outputTokens: 800), source: .localProxy)

        XCTAssertEqual(result.usage?.totalRequests, 20)
        XCTAssertEqual(result.usage?.successCount, 17)
        XCTAssertEqual(result.usage?.failureCount, 3)
        XCTAssertEqual(result.usage?.totalTokens, 2000)
        XCTAssertEqual(result.usage?.inputTokens, 1200)
        XCTAssertEqual(result.usage?.outputTokens, 800)
    }

    /// Fallback path for restarts Quotio did not perform (crash / external kill),
    /// where the only signal is the counters going backwards.
    func testUnmanagedRestartFoldsPreviousSessionIntoBaseline() {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)

        _ = aggregator.record(makeStats(totalRequests: 100, successCount: 90, failureCount: 10, totalTokens: 5000, inputTokens: 3000, outputTokens: 2000), source: .localProxy)

        // Proxy died and came back on its own: counters start over.
        let afterRestart = aggregator.record(makeStats(totalRequests: 5, successCount: 5, failureCount: 0, totalTokens: 250, inputTokens: 150, outputTokens: 100), source: .localProxy)

        XCTAssertEqual(afterRestart.usage?.totalRequests, 105)
        XCTAssertEqual(afterRestart.usage?.successCount, 95)
        XCTAssertEqual(afterRestart.usage?.failureCount, 10)
        XCTAssertEqual(afterRestart.usage?.totalTokens, 5250)
        XCTAssertEqual(afterRestart.usage?.inputTokens, 3150)
        XCTAssertEqual(afterRestart.usage?.outputTokens, 2100)
        XCTAssertEqual(afterRestart.failedRequests, 10)
    }

    func testRestartToZeroSampleKeepsPreviousTotals() {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)

        _ = aggregator.record(makeStats(totalRequests: 42, successCount: 40, failureCount: 2, totalTokens: 900, inputTokens: 500, outputTokens: 400), source: .localProxy)

        // Fresh proxy, no traffic yet
        let afterRestart = aggregator.record(makeStats(totalRequests: 0), source: .localProxy)

        XCTAssertEqual(afterRestart.usage?.totalRequests, 42)
        XCTAssertEqual(afterRestart.usage?.totalTokens, 900)
    }

    // MARK: - Managed lifecycle session boundary (review blocker 1)

    /// Reviewer scenario 1: last poll stored 100, nine more requests complete,
    /// then the proxy restarts and the first new sample is 1.
    /// The final snapshot taken at teardown must make this 110, not 101.
    func testManagedRestartFoldsFinalSnapshotTakenAtTeardown() async {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        let recorder = ProxyUsageSessionRecorder(aggregator: aggregator)

        _ = aggregator.record(makeStats(totalRequests: 100, successCount: 100, totalTokens: 1000), source: .localProxy)

        // Nine more requests are served without an intervening poll; the
        // shutdown snapshot is the only place they can still be observed.
        let finalSample = makeStats(totalRequests: 109, successCount: 109, totalTokens: 1090)
        recorder.finalSampleProvider = { finalSample }

        // Managed teardown: CLIProxyManager awaits this before signalling the
        // process, then calls proxyDidStop() from stop().
        await recorder.proxyWillStop()
        recorder.proxyDidStop()

        let afterRestart = aggregator.record(makeStats(totalRequests: 1, successCount: 1, totalTokens: 10), source: .localProxy)

        XCTAssertEqual(afterRestart.usage?.totalRequests, 110)
        XCTAssertEqual(afterRestart.usage?.successCount, 110)
        XCTAssertEqual(afterRestart.usage?.totalTokens, 1100)
    }

    /// Reviewer scenario 2: last poll stored 5, and the restarted proxy is
    /// already at 10 by the next poll, so no counter decrease is ever observed.
    /// The explicit session boundary must keep the first five.
    func testManagedRestartRetainsTotalsWhenNoDecreaseIsEverObserved() async {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        let recorder = ProxyUsageSessionRecorder(aggregator: aggregator)

        _ = aggregator.record(makeStats(totalRequests: 5, successCount: 5, totalTokens: 50), source: .localProxy)

        // Proxy already unreachable at teardown: no final sample available.
        recorder.finalSampleProvider = { nil }
        await recorder.proxyWillStop()
        recorder.proxyDidStop()

        // Next poll only ever sees a value larger than the previous one.
        let afterRestart = aggregator.record(makeStats(totalRequests: 10, successCount: 10, totalTokens: 100), source: .localProxy)

        XCTAssertEqual(afterRestart.usage?.totalRequests, 15)
        XCTAssertEqual(afterRestart.usage?.successCount, 15)
        XCTAssertEqual(afterRestart.usage?.totalTokens, 150)
    }

    /// stop() calls proxyDidStop() on every teardown, including on paths that
    /// already awaited proxyWillStop(). Folding must happen exactly once.
    func testSessionBoundaryIsIdempotent() async {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        let recorder = ProxyUsageSessionRecorder(aggregator: aggregator)

        _ = aggregator.record(makeStats(totalRequests: 30, totalTokens: 300), source: .localProxy)

        recorder.finalSampleProvider = { nil }
        await recorder.proxyWillStop()
        recorder.proxyDidStop()
        recorder.proxyDidStop()
        await recorder.proxyWillStop()

        XCTAssertEqual(aggregator.restoredStats(for: .localProxy)?.usage?.totalRequests, 30)
        XCTAssertEqual(aggregator.restoredStats(for: .localProxy)?.usage?.totalTokens, 300)
    }

    /// The final snapshot is fetched across an await, so the auto-refresh loop
    /// can record a newer sample in between. Merging must not double count, and
    /// must not discard whichever sample is newer.
    func testConcurrentPollDuringFinalSnapshotIsMergedNotDoubleCounted() async {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        let recorder = ProxyUsageSessionRecorder(aggregator: aggregator)

        _ = aggregator.record(makeStats(totalRequests: 100, totalTokens: 1000), source: .localProxy)

        let concurrentSample = makeStats(totalRequests: 112, totalTokens: 1120)
        let shutdownSample = makeStats(totalRequests: 109, totalTokens: 1090)

        // While the final fetch is suspended, a scheduled refresh records 112;
        // the shutdown fetch itself observed a slightly older value.
        recorder.finalSampleProvider = { [aggregator] in
            _ = aggregator.record(concurrentSample, source: .localProxy)
            return shutdownSample
        }

        await recorder.proxyWillStop()

        XCTAssertEqual(aggregator.restoredStats(for: .localProxy)?.usage?.totalRequests, 112)
        XCTAssertEqual(aggregator.restoredStats(for: .localProxy)?.usage?.totalTokens, 1120)
    }

    // MARK: - Source scoping (review blocker 2)

    func testLocalAndRemoteTotalsAreNeverMerged() {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        let remote = UsageStatsSource.remote(endpoint: "https://proxy.example.com:8317/v0/management")

        let local = aggregator.record(makeStats(totalRequests: 100, totalTokens: 1000), source: .localProxy)
        XCTAssertEqual(local.usage?.totalRequests, 100)

        // Switching to a remote endpoint reporting 20 must show 20, not 120.
        let afterSwitch = aggregator.record(makeStats(totalRequests: 20, totalTokens: 200), source: remote)
        XCTAssertEqual(afterSwitch.usage?.totalRequests, 20)
        XCTAssertEqual(afterSwitch.usage?.totalTokens, 200)

        // Switching back to the still-running local proxy must show 100, not 200.
        let backToLocal = aggregator.record(makeStats(totalRequests: 100, totalTokens: 1000), source: .localProxy)
        XCTAssertEqual(backToLocal.usage?.totalRequests, 100)
        XCTAssertEqual(backToLocal.usage?.totalTokens, 1000)
    }

    func testDistinctRemoteServersKeepSeparateTotals() {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        let first = UsageStatsSource.remote(endpoint: "https://a.example.com/v0/management")
        let second = UsageStatsSource.remote(endpoint: "https://b.example.com/v0/management")

        _ = aggregator.record(makeStats(totalRequests: 500), source: first)
        let onSecond = aggregator.record(makeStats(totalRequests: 7), source: second)

        XCTAssertEqual(onSecond.usage?.totalRequests, 7)
        XCTAssertEqual(aggregator.restoredStats(for: first)?.usage?.totalRequests, 500)
    }

    func testMixedSourceTotalsStaySeparateAcrossRelaunch() {
        let remote = UsageStatsSource.remote(endpoint: "https://proxy.example.com/v0/management")

        let first = UsageStatsAggregator(storageURL: storageURL)
        _ = first.record(makeStats(totalRequests: 100), source: .localProxy)
        _ = first.record(makeStats(totalRequests: 20), source: remote)

        let relaunched = UsageStatsAggregator(storageURL: storageURL)
        XCTAssertEqual(relaunched.restoredStats(for: .localProxy)?.usage?.totalRequests, 100)
        XCTAssertEqual(relaunched.restoredStats(for: remote)?.usage?.totalRequests, 20)
    }

    /// The proxy lifecycle only ever closes the local proxy's session; a remote
    /// server's bucket must be untouched by a local stop/restart.
    func testLifecycleBoundaryOnlyClosesLocalProxySession() async {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        let recorder = ProxyUsageSessionRecorder(aggregator: aggregator)
        let remote = UsageStatsSource.remote(endpoint: "https://proxy.example.com/v0/management")

        _ = aggregator.record(makeStats(totalRequests: 8), source: remote)

        recorder.finalSampleProvider = { nil }
        await recorder.proxyWillStop()

        XCTAssertEqual(aggregator.store.state(for: remote).lastSample.totalRequests, 8)
        XCTAssertEqual(aggregator.store.state(for: remote).baseline.totalRequests, 0)
    }

    func testRemoteEndpointKeyIsNormalized() {
        XCTAssertEqual(
            UsageStatsSource.remote(endpoint: " https://Proxy.Example.com/v0/management ").storageKey,
            UsageStatsSource.remote(endpoint: "https://proxy.example.com/v0/management").storageKey
        )
        XCTAssertNotEqual(
            UsageStatsSource.remote(endpoint: "https://proxy.example.com/v0/management").storageKey,
            UsageStatsSource.localProxy.storageKey
        )
    }

    // MARK: - Persistence across app relaunch

    func testTotalsSurviveAppRelaunch() {
        let first = UsageStatsAggregator(storageURL: storageURL)
        _ = first.record(makeStats(totalRequests: 100, successCount: 90, failureCount: 10, totalTokens: 5000, inputTokens: 3000, outputTokens: 2000), source: .localProxy)

        // Simulate app relaunch: new aggregator instance reads the same file
        let second = UsageStatsAggregator(storageURL: storageURL)
        let restored = second.restoredStats(for: .localProxy)
        XCTAssertEqual(restored?.usage?.totalRequests, 100)
        XCTAssertEqual(restored?.usage?.totalTokens, 5000)

        // Proxy also restarted while the app was closed: counters reset
        let afterRestart = second.record(makeStats(totalRequests: 3, successCount: 3, failureCount: 0, totalTokens: 90, inputTokens: 60, outputTokens: 30), source: .localProxy)
        XCTAssertEqual(afterRestart.usage?.totalRequests, 103)
        XCTAssertEqual(afterRestart.usage?.totalTokens, 5090)
    }

    func testRestoredStatsIsNilForFreshInstall() {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        XCTAssertNil(aggregator.restoredStats(for: .localProxy))
    }

    func testVersion1FileMigratesOntoLocalProxy() throws {
        let legacy = """
        {"version":1,\
        "baseline":{"totalRequests":40,"successCount":38,"failureCount":2,"totalTokens":400,"inputTokens":250,"outputTokens":150},\
        "lastSample":{"totalRequests":10,"successCount":10,"failureCount":0,"totalTokens":100,"inputTokens":60,"outputTokens":40}}
        """
        try Data(legacy.utf8).write(to: storageURL)

        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        XCTAssertEqual(aggregator.restoredStats(for: .localProxy)?.usage?.totalRequests, 50)
        XCTAssertEqual(aggregator.restoredStats(for: .localProxy)?.usage?.totalTokens, 500)

        // The migrated file is rewritten in the current format.
        let reloaded = UsageStatsAggregator(storageURL: storageURL)
        XCTAssertEqual(reloaded.store.version, UsageTotalsStore.currentVersion)
        XCTAssertEqual(reloaded.restoredStats(for: .localProxy)?.usage?.totalRequests, 50)
    }

    // MARK: - Bounded storage

    func testPersistedFileStaysBoundedAggregatesOnly() throws {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)

        for i in 1...500 {
            _ = aggregator.record(makeStats(totalRequests: i, successCount: i, failureCount: 0, totalTokens: i * 100, inputTokens: i * 60, outputTokens: i * 40), source: .localProxy)
        }

        let data = try Data(contentsOf: storageURL)
        // Fixed-size aggregate counters only, never per-request entries
        let decoded = try JSONDecoder().decode(UsageTotalsStore.self, from: data)
        XCTAssertEqual(decoded.state(for: .localProxy).lastSample.totalRequests, 500)
        XCTAssertLessThan(data.count, 2048, "usage-stats.json must stay a small fixed-size aggregate file")
    }

    // MARK: - Corruption handling

    func testCorruptFileStartsFresh() throws {
        try Data("not json {{{".utf8).write(to: storageURL)

        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        XCTAssertNil(aggregator.restoredStats(for: .localProxy))

        // Aggregation still works after recovery
        let result = aggregator.record(makeStats(totalRequests: 7, successCount: 7, failureCount: 0, totalTokens: 70, inputTokens: 40, outputTokens: 30), source: .localProxy)
        XCTAssertEqual(result.usage?.totalRequests, 7)
    }

    // MARK: - Reset

    func testResetClearsTotalsAndPersists() {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        let remote = UsageStatsSource.remote(endpoint: "https://proxy.example.com/v0/management")
        _ = aggregator.record(makeStats(totalRequests: 12, successCount: 12, failureCount: 0, totalTokens: 300, inputTokens: 200, outputTokens: 100), source: .localProxy)
        _ = aggregator.record(makeStats(totalRequests: 4), source: remote)

        aggregator.reset()
        XCTAssertNil(aggregator.restoredStats(for: .localProxy))
        XCTAssertNil(aggregator.restoredStats(for: remote))

        let relaunched = UsageStatsAggregator(storageURL: storageURL)
        XCTAssertNil(relaunched.restoredStats(for: .localProxy))
        XCTAssertNil(relaunched.restoredStats(for: remote))
    }
}
