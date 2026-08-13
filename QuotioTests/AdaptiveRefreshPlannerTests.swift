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
        XCTAssertTrue(tracker.observe(outcome: .sample, quotas: quotas(used: 10), at: start, bounds: bounds))
        XCTAssertEqual(tracker.interval, oneMinute)

        var now = start
        var observed: [TimeInterval] = []
        for _ in 0..<6 {
            now = now.addingTimeInterval(tracker.interval)
            XCTAssertFalse(tracker.observe(outcome: .sample, quotas: quotas(used: 10), at: now, bounds: bounds))
            observed.append(tracker.interval)
        }

        XCTAssertEqual(observed, [60, 120, 240, 480, 960, 1800])
    }

    func testTrackerResetsToFastIntervalWhenUsageMovesAgain() {
        let bounds = self.bounds(fast: oneMinute)
        let start = Date(timeIntervalSince1970: 0)
        var tracker = AdaptiveRefreshTracker(bounds: bounds, now: start)

        tracker.observe(outcome: .sample, quotas: quotas(used: 10), at: start, bounds: bounds)

        var now = start
        for _ in 0..<5 {
            now = now.addingTimeInterval(tracker.interval)
            tracker.observe(outcome: .sample, quotas: quotas(used: 10), at: now, bounds: bounds)
        }
        XCTAssertGreaterThan(tracker.interval, oneMinute)

        // The user starts coding again: usage moves, cadence snaps back immediately.
        now = now.addingTimeInterval(tracker.interval)
        XCTAssertTrue(tracker.observe(outcome: .sample, quotas: quotas(used: 42), at: now, bounds: bounds))
        XCTAssertEqual(tracker.interval, oneMinute)
        XCTAssertEqual(tracker.lastActivityAt, now)
    }

    func testResetReturnsToFastInterval() {
        let bounds = self.bounds(fast: oneMinute)
        let start = Date(timeIntervalSince1970: 0)
        var tracker = AdaptiveRefreshTracker(bounds: bounds, now: start)

        tracker.observe(outcome: .sample, quotas: quotas(used: 10), at: start, bounds: bounds)
        var now = start
        for _ in 0..<4 {
            now = now.addingTimeInterval(tracker.interval)
            tracker.observe(outcome: .sample, quotas: quotas(used: 10), at: now, bounds: bounds)
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

    // MARK: - Typed metric values (issue #172 review, blocker 3)

    private func amountQuota(_ value: Double) -> [AIProvider: [String: ProviderQuotaData]] {
        // Built exactly like AmpQuotaFetcher / OpenRouterQuotaFetcher /
        // DevinQuotaFetcher build a balance row: percentage -1, no legacy `used`.
        [
            .amp: ["key": ProviderQuotaData(
                models: [ModelQuota(
                    name: "amp-balance",
                    percentage: -1,
                    resetTime: "",
                    presentation: .amount(value: value, unit: .usd, semantics: .balance)
                )]
            )]
        ]
    }

    /// Regression: `.amount` rows carry `percentage == -1`, so reading only the
    /// legacy fields turned every balance into the constant `100 - (-1) == 101`
    /// and a user burning through credits looked permanently idle.
    func testSignatureTracksAmountMetricValues() {
        let before = QuotaUsageSignature(quotas: amountQuota(20))
        let after = QuotaUsageSignature(quotas: amountQuota(12.5))

        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.entries["amp|key|amp-balance"], 20)
        XCTAssertEqual(after.entries["amp|key|amp-balance"], 12.5)
        // The legacy path would have produced 101 for both.
        XCTAssertNotEqual(before.entries["amp|key|amp-balance"], 101)
    }

    /// A backed-off tracker must snap back when a `.amount` balance moves.
    func testTrackerReactsToAmountMetricMovement() {
        let bounds = self.bounds(fast: oneMinute)
        let start = Date(timeIntervalSince1970: 0)
        var tracker = AdaptiveRefreshTracker(bounds: bounds, now: start)

        tracker.observe(outcome: .sample, quotas: amountQuota(20), at: start, bounds: bounds)
        var now = start
        for _ in 0..<5 {
            now = now.addingTimeInterval(tracker.interval)
            tracker.observe(outcome: .sample, quotas: amountQuota(20), at: now, bounds: bounds)
        }
        XCTAssertGreaterThan(tracker.interval, oneMinute)

        now = now.addingTimeInterval(tracker.interval)
        XCTAssertTrue(tracker.observe(outcome: .sample, quotas: amountQuota(19), at: now, bounds: bounds))
        XCTAssertEqual(tracker.interval, oneMinute)
    }

    /// Regression: `.progress` rows carry Double-valued used/limit that the
    /// optional legacy `Int` does not mirror, so sub-unit spend (dollars for
    /// Amp/OpenRouter/GLM) has to come from the typed presentation.
    func testSignatureTracksProgressMetricValues() {
        func progressQuota(used: Double) -> [AIProvider: [String: ProviderQuotaData]] {
            [
                .openRouter: ["key": ProviderQuotaData(
                    models: [ModelQuota(
                        name: "openrouter-credits",
                        percentage: 50,
                        resetTime: "",
                        presentation: .progress(used: used, limit: 10, unit: .usd)
                    )]
                )]
            ]
        }

        let before = QuotaUsageSignature(quotas: progressQuota(used: 4.25))
        let after = QuotaUsageSignature(quotas: progressQuota(used: 4.75))

        XCTAssertEqual(before.entries["openrouter|key|openrouter-credits"], 4.25)
        XCTAssertEqual(after.entries["openrouter|key|openrouter-credits"], 4.75)
        // Both rows report percentage 50, so the legacy path saw no movement.
        XCTAssertNotEqual(before, after)
    }

    // MARK: - Outcome gating (issue #172 review, blocker 2)

    /// A refresh that never ran (coalesced against an in-flight refresh, not
    /// due, or a mode with no local quota source) must leave the cadence and
    /// the comparison baseline exactly as they were.
    func testSkippedRefreshChangesNothing() {
        let bounds = self.bounds(fast: oneMinute)
        let start = Date(timeIntervalSince1970: 0)
        var tracker = AdaptiveRefreshTracker(bounds: bounds, now: start)

        tracker.observe(outcome: .sample, quotas: quotas(used: 10), at: start, bounds: bounds)
        let baseline = tracker.observedSignature

        var now = start
        for _ in 0..<10 {
            now = now.addingTimeInterval(oneMinute)
            XCTAssertFalse(tracker.observe(outcome: .skipped, quotas: [:], at: now, bounds: bounds))
        }

        XCTAssertEqual(tracker.interval, oneMinute, "a skipped poll must not back off")
        XCTAssertEqual(tracker.lastActivityAt, start)
        XCTAssertEqual(tracker.observedSignature, baseline, "baseline must survive a skipped poll")
    }

    /// Skipped polls must not be able to hide real activity: the next sample is
    /// compared against the last *sample*, not against an empty snapshot.
    func testSkippedRefreshDoesNotCorruptTheBaseline() {
        let bounds = self.bounds(fast: oneMinute)
        let start = Date(timeIntervalSince1970: 0)
        var tracker = AdaptiveRefreshTracker(bounds: bounds, now: start)

        tracker.observe(outcome: .sample, quotas: quotas(used: 10), at: start, bounds: bounds)
        tracker.observe(outcome: .skipped, quotas: [:], at: start.addingTimeInterval(60), bounds: bounds)

        // Same usage as the last real sample: still idle, despite the empty
        // snapshot that the skipped poll carried.
        XCTAssertFalse(tracker.observe(
            outcome: .sample,
            quotas: quotas(used: 10),
            at: start.addingTimeInterval(120),
            bounds: bounds
        ))
    }

    /// A failed refresh keeps the previous snapshot on screen, which looks
    /// exactly like "unchanged usage". It must not back off, and it must pull a
    /// previously backed-off cadence back to the user's interval so the app
    /// retries promptly.
    func testFailedRefreshRecoversToTheFastCadence() {
        let bounds = self.bounds(fast: oneMinute)
        let start = Date(timeIntervalSince1970: 0)
        var tracker = AdaptiveRefreshTracker(bounds: bounds, now: start)

        tracker.observe(outcome: .sample, quotas: quotas(used: 10), at: start, bounds: bounds)
        var now = start
        for _ in 0..<6 {
            now = now.addingTimeInterval(tracker.interval)
            tracker.observe(outcome: .sample, quotas: quotas(used: 10), at: now, bounds: bounds)
        }
        XCTAssertEqual(tracker.interval, 1800, "precondition: backed off to the ceiling")

        now = now.addingTimeInterval(tracker.interval)
        XCTAssertFalse(tracker.observe(outcome: .failed, quotas: quotas(used: 10), at: now, bounds: bounds))
        XCTAssertEqual(tracker.interval, oneMinute, "a failure must not keep the 30 minute delay")

        // Repeated failures stay at the retry cadence rather than growing.
        for _ in 0..<5 {
            now = now.addingTimeInterval(tracker.interval)
            tracker.observe(outcome: .failed, quotas: [:], at: now, bounds: bounds)
            XCTAssertEqual(tracker.interval, oneMinute)
        }
    }

    /// A failure must not overwrite the baseline with data that was never
    /// refreshed, or the first sample after it would look like a change.
    func testFailedRefreshKeepsTheComparisonBaseline() {
        let bounds = self.bounds(fast: oneMinute)
        let start = Date(timeIntervalSince1970: 0)
        var tracker = AdaptiveRefreshTracker(bounds: bounds, now: start)

        tracker.observe(outcome: .sample, quotas: quotas(used: 10), at: start, bounds: bounds)
        tracker.observe(outcome: .failed, quotas: [:], at: start.addingTimeInterval(60), bounds: bounds)

        XCTAssertFalse(tracker.observe(
            outcome: .sample,
            quotas: quotas(used: 10),
            at: start.addingTimeInterval(120),
            bounds: bounds
        ))
        XCTAssertTrue(tracker.observe(
            outcome: .sample,
            quotas: quotas(used: 11),
            at: start.addingTimeInterval(180),
            bounds: bounds
        ))
    }

    // MARK: - Opt-out parity

    /// The fixed cadences themselves are untouched by this feature.
    @MainActor
    func testFixedCadenceConstantsAreUnchanged() {
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
