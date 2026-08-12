import XCTest
@testable import Quotio

final class AdaptiveRefreshPlannerTests: XCTestCase {

    private let oneMinute: TimeInterval = 60

    private func bounds(
        fast: TimeInterval = 60,
        grace: TimeInterval? = nil,
        multiplier: Double = 2,
        ceiling: TimeInterval = 1800
    ) -> AdaptiveRefreshBounds {
        AdaptiveRefreshBounds(
            fastInterval: fast,
            idleGrace: grace ?? fast * 2,
            multiplier: multiplier,
            maxInterval: ceiling
        )
    }

    private func quotas(used: Int) -> [AIProvider: [String: ProviderQuotaData]] {
        [
            .claude: [
                "user@example.com": ProviderQuotaData(
                    models: [ModelQuota(name: "sonnet", percentage: 50, resetTime: "", used: used, limit: 100)]
                )
            ]
        ]
    }

    // MARK: - Pure interval decision

    func testActivityKeepsFastInterval() {
        let bounds = self.bounds(fast: oneMinute)

        // Just refreshed after activity: still the chosen cadence.
        XCTAssertEqual(
            AdaptiveRefreshPlanner.nextInterval(current: oneMinute, timeSinceLastActivity: 0, bounds: bounds),
            oneMinute
        )
        // Inside the grace window: still the chosen cadence.
        XCTAssertEqual(
            AdaptiveRefreshPlanner.nextInterval(current: oneMinute, timeSinceLastActivity: 90, bounds: bounds),
            oneMinute
        )
    }

    func testIncreasingIdleBacksOffAndStopsAtCeiling() {
        let bounds = self.bounds(fast: oneMinute, ceiling: 1800)

        var interval = oneMinute
        var idle: TimeInterval = 0
        var sequence: [TimeInterval] = []

        // Simulate 10 consecutive refreshes that observe no activity.
        for _ in 0..<10 {
            idle += interval
            interval = AdaptiveRefreshPlanner.nextInterval(
                current: interval,
                timeSinceLastActivity: idle,
                bounds: bounds
            )
            sequence.append(interval)
        }

        // 60s cadence -> one grace poll at 60s, then doubling to the 1800s ceiling.
        XCTAssertEqual(sequence, [60, 120, 240, 480, 960, 1800, 1800, 1800, 1800, 1800])
        XCTAssertLessThanOrEqual(sequence.max() ?? 0, bounds.ceiling)
    }

    func testCeilingNeverDropsBelowChosenCadence() {
        // A 15 minute cadence with a 30 minute ceiling still backs off to 30 min.
        let bounds = AdaptiveRefreshBounds(cadenceInterval: 900)
        XCTAssertEqual(bounds.ceiling, 1800)

        let backedOff = AdaptiveRefreshPlanner.nextInterval(
            current: 900,
            timeSinceLastActivity: 100_000,
            bounds: bounds
        )
        XCTAssertEqual(backedOff, 1800)

        // A cadence longer than the default ceiling is never shortened by adaptive mode.
        let longBounds = AdaptiveRefreshBounds(cadenceInterval: 3600)
        XCTAssertEqual(
            AdaptiveRefreshPlanner.nextInterval(
                current: 3600,
                timeSinceLastActivity: 100_000,
                bounds: longBounds
            ),
            3600
        )
    }

    func testAdaptiveNeverRefreshesFasterThanChosenCadence() {
        let bounds = self.bounds(fast: 300)

        for idle in stride(from: 0.0, through: 7200.0, by: 60.0) {
            let next = AdaptiveRefreshPlanner.nextInterval(
                current: 300,
                timeSinceLastActivity: idle,
                bounds: bounds
            )
            XCTAssertGreaterThanOrEqual(next, 300, "idle=\(idle)")
        }
    }

    // MARK: - Tracker driven by quota snapshots

    func testTrackerBacksOffWhileUsageIsUnchanged() {
        let bounds = self.bounds(fast: oneMinute)
        let start = Date(timeIntervalSince1970: 0)
        var tracker = AdaptiveRefreshTracker(bounds: bounds, now: start)

        // Seed the baseline.
        XCTAssertTrue(tracker.observe(quotas: quotas(used: 10), at: start, bounds: bounds))
        XCTAssertEqual(tracker.interval, oneMinute)

        var now = start
        var observed: [TimeInterval] = []
        for _ in 0..<6 {
            now = now.addingTimeInterval(tracker.interval)
            XCTAssertFalse(tracker.observe(quotas: quotas(used: 10), at: now, bounds: bounds))
            observed.append(tracker.interval)
        }

        XCTAssertEqual(observed, [60, 120, 240, 480, 960, 1800])
    }

    func testTrackerResetsToFastIntervalWhenUsageMovesAgain() {
        let bounds = self.bounds(fast: oneMinute)
        let start = Date(timeIntervalSince1970: 0)
        var tracker = AdaptiveRefreshTracker(bounds: bounds, now: start)

        tracker.observe(quotas: quotas(used: 10), at: start, bounds: bounds)

        var now = start
        for _ in 0..<5 {
            now = now.addingTimeInterval(tracker.interval)
            tracker.observe(quotas: quotas(used: 10), at: now, bounds: bounds)
        }
        XCTAssertGreaterThan(tracker.interval, oneMinute)

        // The user starts coding again: usage moves, cadence snaps back immediately.
        now = now.addingTimeInterval(tracker.interval)
        XCTAssertTrue(tracker.observe(quotas: quotas(used: 42), at: now, bounds: bounds))
        XCTAssertEqual(tracker.interval, oneMinute)
        XCTAssertEqual(tracker.lastActivityAt, now)
    }

    func testResetReturnsToFastInterval() {
        let bounds = self.bounds(fast: oneMinute)
        let start = Date(timeIntervalSince1970: 0)
        var tracker = AdaptiveRefreshTracker(bounds: bounds, now: start)

        tracker.observe(quotas: quotas(used: 10), at: start, bounds: bounds)
        var now = start
        for _ in 0..<4 {
            now = now.addingTimeInterval(tracker.interval)
            tracker.observe(quotas: quotas(used: 10), at: now, bounds: bounds)
        }
        XCTAssertGreaterThan(tracker.interval, oneMinute)

        tracker.reset(bounds: bounds, now: now)
        XCTAssertEqual(tracker.interval, oneMinute)
    }

    // MARK: - Signature

    func testSignatureIgnoresRefreshTimestamps() {
        let first = QuotaUsageSignature(quotas: [
            .claude: ["a@example.com": ProviderQuotaData(
                models: [ModelQuota(name: "sonnet", percentage: 50, resetTime: "", used: 10)],
                lastUpdated: Date(timeIntervalSince1970: 0)
            )]
        ])
        let second = QuotaUsageSignature(quotas: [
            .claude: ["a@example.com": ProviderQuotaData(
                models: [ModelQuota(name: "sonnet", percentage: 50, resetTime: "", used: 10)],
                lastUpdated: Date(timeIntervalSince1970: 9999)
            )]
        ])

        XCTAssertEqual(first, second)
    }

    func testSignatureTracksPercentageWhenUsedCountIsUnavailable() {
        let before = QuotaUsageSignature(quotas: [
            .codex: ["b@example.com": ProviderQuotaData(
                models: [ModelQuota(name: "gpt", percentage: 100, resetTime: "")]
            )]
        ])
        let after = QuotaUsageSignature(quotas: [
            .codex: ["b@example.com": ProviderQuotaData(
                models: [ModelQuota(name: "gpt", percentage: 0, resetTime: "")]
            )]
        ])

        // Remaining 100% -> 0% is the 0 -> 100% usage jump described in issue #172.
        XCTAssertNotEqual(before, after)
    }

    func testSignatureDetectsAccountAndModelChanges() {
        let single = QuotaUsageSignature(quotas: quotas(used: 10))
        var expanded = quotas(used: 10)
        expanded[.claude]?["second@example.com"] = ProviderQuotaData(
            models: [ModelQuota(name: "sonnet", percentage: 90, resetTime: "", used: 5)]
        )

        XCTAssertNotEqual(single, QuotaUsageSignature(quotas: expanded))
    }

    // MARK: - Opt-out parity

    @MainActor
    func testDisabledAdaptiveModeUsesExactlyTheFixedCadence() {
        // When adaptive refresh is off the view model sleeps on
        // `RefreshCadence.intervalNanoseconds`; assert those values are the
        // untouched fixed cadences.
        XCTAssertNil(RefreshCadence.manual.intervalSeconds)
        XCTAssertEqual(RefreshCadence.oneMinute.intervalSeconds, 60)
        XCTAssertEqual(RefreshCadence.twoMinutes.intervalSeconds, 120)
        XCTAssertEqual(RefreshCadence.fiveMinutes.intervalSeconds, 300)
        XCTAssertEqual(RefreshCadence.tenMinutes.intervalSeconds, 600)
        XCTAssertEqual(RefreshCadence.fifteenMinutes.intervalSeconds, 900)

        for cadence in RefreshCadence.allCases {
            guard let seconds = cadence.intervalSeconds else { continue }
            XCTAssertEqual(cadence.intervalNanoseconds, UInt64(seconds * 1_000_000_000))
        }
    }

    func testAdaptiveBoundsDerivedFromCadence() {
        let bounds = AdaptiveRefreshBounds(cadenceInterval: 120)
        XCTAssertEqual(bounds.fastInterval, 120)
        XCTAssertEqual(bounds.idleGrace, 240)
        XCTAssertEqual(bounds.multiplier, 2)
        XCTAssertEqual(bounds.maxInterval, 1800)
    }
}
