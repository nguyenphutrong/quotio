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
        successCount: Int,
        failureCount: Int,
        totalTokens: Int,
        inputTokens: Int,
        outputTokens: Int
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

        _ = aggregator.record(makeStats(totalRequests: 10, successCount: 9, failureCount: 1, totalTokens: 1000, inputTokens: 600, outputTokens: 400))
        _ = aggregator.record(makeStats(totalRequests: 15, successCount: 13, failureCount: 2, totalTokens: 1500, inputTokens: 900, outputTokens: 600))
        let result = aggregator.record(makeStats(totalRequests: 20, successCount: 17, failureCount: 3, totalTokens: 2000, inputTokens: 1200, outputTokens: 800))

        XCTAssertEqual(result.usage?.totalRequests, 20)
        XCTAssertEqual(result.usage?.successCount, 17)
        XCTAssertEqual(result.usage?.failureCount, 3)
        XCTAssertEqual(result.usage?.totalTokens, 2000)
        XCTAssertEqual(result.usage?.inputTokens, 1200)
        XCTAssertEqual(result.usage?.outputTokens, 800)
    }

    func testProxyRestartFoldsPreviousSessionIntoBaseline() {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)

        // First proxy session
        _ = aggregator.record(makeStats(totalRequests: 100, successCount: 90, failureCount: 10, totalTokens: 5000, inputTokens: 3000, outputTokens: 2000))

        // Proxy restarted (or CLIProxyAPI upgraded): counters start over
        let afterRestart = aggregator.record(makeStats(totalRequests: 5, successCount: 5, failureCount: 0, totalTokens: 250, inputTokens: 150, outputTokens: 100))

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

        _ = aggregator.record(makeStats(totalRequests: 42, successCount: 40, failureCount: 2, totalTokens: 900, inputTokens: 500, outputTokens: 400))

        // Fresh proxy, no traffic yet
        let afterRestart = aggregator.record(makeStats(totalRequests: 0, successCount: 0, failureCount: 0, totalTokens: 0, inputTokens: 0, outputTokens: 0))

        XCTAssertEqual(afterRestart.usage?.totalRequests, 42)
        XCTAssertEqual(afterRestart.usage?.totalTokens, 900)
    }

    // MARK: - Persistence across app relaunch

    func testTotalsSurviveAppRelaunch() {
        let first = UsageStatsAggregator(storageURL: storageURL)
        _ = first.record(makeStats(totalRequests: 100, successCount: 90, failureCount: 10, totalTokens: 5000, inputTokens: 3000, outputTokens: 2000))

        // Simulate app relaunch: new aggregator instance reads the same file
        let second = UsageStatsAggregator(storageURL: storageURL)
        let restored = second.restoredStats()
        XCTAssertEqual(restored?.usage?.totalRequests, 100)
        XCTAssertEqual(restored?.usage?.totalTokens, 5000)

        // Proxy also restarted while the app was closed: counters reset
        let afterRestart = second.record(makeStats(totalRequests: 3, successCount: 3, failureCount: 0, totalTokens: 90, inputTokens: 60, outputTokens: 30))
        XCTAssertEqual(afterRestart.usage?.totalRequests, 103)
        XCTAssertEqual(afterRestart.usage?.totalTokens, 5090)
    }

    func testRestoredStatsIsNilForFreshInstall() {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        XCTAssertNil(aggregator.restoredStats())
    }

    // MARK: - Bounded storage

    func testPersistedFileStaysBoundedAggregatesOnly() throws {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)

        for i in 1...500 {
            _ = aggregator.record(makeStats(totalRequests: i, successCount: i, failureCount: 0, totalTokens: i * 100, inputTokens: i * 60, outputTokens: i * 40))
        }

        let data = try Data(contentsOf: storageURL)
        // Fixed-size aggregate counters only, never per-request entries
        let decoded = try JSONDecoder().decode(UsageTotalsStore.self, from: data)
        XCTAssertEqual(decoded.lastSample.totalRequests, 500)
        XCTAssertLessThan(data.count, 2048, "usage-stats.json must stay a small fixed-size aggregate file")
    }

    // MARK: - Corruption handling

    func testCorruptFileStartsFresh() throws {
        try Data("not json {{{".utf8).write(to: storageURL)

        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        XCTAssertNil(aggregator.restoredStats())

        // Aggregation still works after recovery
        let result = aggregator.record(makeStats(totalRequests: 7, successCount: 7, failureCount: 0, totalTokens: 70, inputTokens: 40, outputTokens: 30))
        XCTAssertEqual(result.usage?.totalRequests, 7)
    }

    // MARK: - Reset

    func testResetClearsTotalsAndPersists() {
        let aggregator = UsageStatsAggregator(storageURL: storageURL)
        _ = aggregator.record(makeStats(totalRequests: 12, successCount: 12, failureCount: 0, totalTokens: 300, inputTokens: 200, outputTokens: 100))

        aggregator.reset()
        XCTAssertNil(aggregator.restoredStats())

        let relaunched = UsageStatsAggregator(storageURL: storageURL)
        XCTAssertNil(relaunched.restoredStats())
    }
}
