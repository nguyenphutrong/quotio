import XCTest
@testable import Quotio

/// Runtime integration coverage for adaptive refresh (issue #172).
///
/// The pure cadence maths lives in `AdaptiveRefreshPlannerTests`. What is
/// covered here is the part that has to be driven through `QuotaViewModel`:
/// that one iteration of the automatic refresh loop observes the quota refresh
/// it started — not the previous poll's numbers — and that with the feature off
/// (the default) the loop behaves exactly as it did before.
@MainActor
final class AdaptiveRefreshIntegrationTests: XCTestCase {

    private let settings = RefreshSettingsManager.shared
    private var savedCadence: RefreshCadence = .tenMinutes
    private var savedAdaptive = false

    override func setUp() {
        super.setUp()
        // `RefreshSettingsManager` is a singleton backed by UserDefaults.
        savedCadence = settings.refreshCadence
        savedAdaptive = settings.adaptiveRefreshEnabled
    }

    override func tearDown() {
        settings.refreshCadence = savedCadence
        settings.adaptiveRefreshEnabled = savedAdaptive
        super.tearDown()
    }

    private func quotas(used: Int) -> [AIProvider: [String: ProviderQuotaData]] {
        [
            .claude: ["user@example.com": ProviderQuotaData(
                models: [ModelQuota(name: "sonnet", percentage: 50, resetTime: "", used: used, limit: 100)]
            )]
        ]
    }

    /// Test-controlled clock, so the backoff curve can be driven without
    /// waiting on wall-clock time.
    private final class TestClock: @unchecked Sendable {
        private(set) var now: Date
        init(now: Date) { self.now = now }
        func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    /// A gate the test opens by hand, so the quota refresh can be held
    /// suspended while the test inspects what the loop has recorded so far.
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    // MARK: - Blocker 1: observe the refresh you started

    /// `refreshData()` schedules `refreshAllQuotas()` on a new unstructured
    /// `Task` and returns immediately, so recording the adaptive observation
    /// right after it snapshots the *previous* poll's quotas while the real
    /// refresh is still in flight — one poll late at best, and a false idle
    /// observation at worst.
    ///
    /// This test suspends inside the quota refresh to prove the ordering: while
    /// the fetch is held, nothing has been observed yet; once it completes and
    /// has written `providerQuotas`, the recorded signature is the *new* value.
    func testAutomaticRefreshObservesTheQuotaRefreshItStarted() async {
        settings.refreshCadence = .oneMinute
        settings.adaptiveRefreshEnabled = true

        let viewModel = QuotaViewModel()
        viewModel.providerQuotas = quotas(used: 10)
        viewModel.resetAdaptiveRefreshForTesting()

        let gate = Gate()
        let fetchStarted = expectation(description: "quota fetch started")

        // Stands in for refreshData(): schedules the quota refresh in the
        // background and returns without awaiting it, exactly as it does.
        viewModel.refreshDataHookForTesting = { @MainActor [weak viewModel] in
            viewModel?.scheduleBackgroundQuotaRefresh()
        }

        // Stands in for the provider round-trips inside refreshAllQuotas():
        // suspends mid-flight, then writes the fresh quota snapshot.
        viewModel.quotaRefreshHookForTesting = { @MainActor [weak viewModel] in
            fetchStarted.fulfill()
            await gate.wait()
            viewModel?.providerQuotas = self.quotas(used: 55)
            return .sample
        }

        let iteration = Task { @MainActor in await viewModel.performAutomaticRefresh() }

        await fulfillment(of: [fetchStarted], timeout: 5)

        // The refresh is suspended: the loop must still be waiting on it, so no
        // observation of the stale snapshot can have been recorded.
        XCTAssertNil(
            viewModel.adaptiveSignatureForTesting,
            "the observation must not be recorded while the quota refresh is still in flight"
        )
        XCTAssertEqual(viewModel.providerQuotas[.claude]?["user@example.com"]?.models.first?.used, 10)

        gate.open()
        let outcome = await iteration.value

        XCTAssertEqual(outcome, .sample)
        XCTAssertEqual(
            viewModel.adaptiveSignatureForTesting?.entries["claude|user@example.com|sonnet"],
            55,
            "the observation must snapshot the refresh that just completed, not the previous poll"
        )
    }

    // MARK: - Blocker 2: only a real sample is evidence

    /// `refreshAllQuotas()` returns early when another refresh already owns the
    /// providers. That poll fetched nothing, so it must leave the cadence and
    /// the baseline alone instead of counting as "usage did not change".
    func testCoalescedRefreshDoesNotBackOff() async {
        settings.refreshCadence = .oneMinute
        settings.adaptiveRefreshEnabled = true

        let clock = TestClock(now: Date(timeIntervalSince1970: 0))
        let viewModel = QuotaViewModel()
        viewModel.setAdaptiveClockForTesting { clock.now }
        viewModel.providerQuotas = quotas(used: 10)
        viewModel.resetAdaptiveRefreshForTesting()

        viewModel.refreshDataHookForTesting = { @MainActor [weak viewModel] in
            viewModel?.scheduleBackgroundQuotaRefresh()
        }
        viewModel.quotaRefreshHookForTesting = { .sample }
        await viewModel.performAutomaticRefresh()
        XCTAssertEqual(viewModel.adaptiveIntervalForTesting, 60)

        // Every following poll is coalesced away. The clock advances well past
        // the idle grace window, so identical `.sample` polls would have backed
        // off to the 30 minute ceiling by now.
        viewModel.quotaRefreshHookForTesting = { .skipped }
        for _ in 0..<8 {
            clock.advance(by: 600)
            let outcome = await viewModel.performAutomaticRefresh()
            XCTAssertEqual(outcome, .skipped)
        }

        XCTAssertEqual(
            viewModel.adaptiveIntervalForTesting,
            60,
            "a coalesced refresh proves nothing about activity and must not back off"
        )
    }

    /// A failing refresh keeps the previous snapshot on screen, which looks
    /// identical to unchanged usage. It must pull the cadence back to the
    /// user's interval instead of sitting on a backed-off delay.
    func testFailedRefreshRecoversTheRetryCadence() async {
        settings.refreshCadence = .oneMinute
        settings.adaptiveRefreshEnabled = true

        let clock = TestClock(now: Date(timeIntervalSince1970: 0))
        let viewModel = QuotaViewModel()
        viewModel.setAdaptiveClockForTesting { clock.now }
        viewModel.providerQuotas = quotas(used: 10)
        viewModel.resetAdaptiveRefreshForTesting()

        viewModel.refreshDataHookForTesting = { @MainActor [weak viewModel] in
            viewModel?.scheduleBackgroundQuotaRefresh()
        }
        // Idle: back off to the ceiling, advancing the clock by whatever the
        // loop would have slept for between iterations.
        viewModel.quotaRefreshHookForTesting = { .sample }
        for _ in 0..<8 {
            await viewModel.performAutomaticRefresh()
            clock.advance(by: viewModel.adaptiveIntervalForTesting ?? 0)
        }
        XCTAssertEqual(viewModel.adaptiveIntervalForTesting, 1800)

        viewModel.quotaRefreshHookForTesting = { .failed }
        let outcome = await viewModel.performAutomaticRefresh()

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(
            viewModel.adaptiveIntervalForTesting,
            60,
            "a failure must recover to the retry cadence, not keep the 30 minute delay"
        )
    }

    /// With no quota refresh scheduled and no error, the poll is `.skipped`:
    /// `refreshData()` gates the quota refresh on it being due, and a poll that
    /// deliberately fetched no quotas is not evidence of idleness either.
    func testRefreshWithoutScheduledQuotaRefreshIsSkipped() async {
        settings.refreshCadence = .oneMinute
        settings.adaptiveRefreshEnabled = true

        let viewModel = QuotaViewModel()
        viewModel.providerQuotas = quotas(used: 10)
        viewModel.resetAdaptiveRefreshForTesting()

        viewModel.refreshDataHookForTesting = { }
        let outcome = await viewModel.performAutomaticRefresh()

        XCTAssertEqual(outcome, .skipped)
        XCTAssertNil(viewModel.adaptiveSignatureForTesting)
        XCTAssertEqual(viewModel.adaptiveIntervalForTesting, 60)
    }

    // MARK: - Opt-out parity (adaptive refresh is off by default)

    /// With adaptive refresh off — the default — no tracker is armed and the
    /// loop sleeps on exactly the fixed cadence, for every cadence value.
    func testDisabledAdaptiveRefreshSleepsOnTheFixedCadence() async {
        settings.adaptiveRefreshEnabled = false

        let viewModel = QuotaViewModel()
        viewModel.providerQuotas = quotas(used: 10)

        for cadence in RefreshCadence.allCases {
            settings.refreshCadence = cadence
            viewModel.resetAdaptiveRefreshForTesting()

            XCTAssertNil(
                viewModel.adaptiveIntervalForTesting,
                "no tracker may be armed while adaptive refresh is off (\(cadence))"
            )
            guard let fixed = cadence.intervalNanoseconds else { continue }
            XCTAssertEqual(
                viewModel.nextRefreshSleepNanosecondsForTesting(fixedNanoseconds: fixed),
                fixed,
                "disabled adaptive refresh must sleep the fixed cadence (\(cadence))"
            )
        }
    }

    /// Even after refreshes that would have backed a tracker off, the disabled
    /// loop keeps sleeping on the fixed cadence and arms no tracker.
    func testDisabledAdaptiveRefreshNeverBacksOff() async {
        settings.refreshCadence = .oneMinute
        settings.adaptiveRefreshEnabled = false

        let viewModel = QuotaViewModel()
        viewModel.providerQuotas = quotas(used: 10)
        viewModel.resetAdaptiveRefreshForTesting()

        viewModel.refreshDataHookForTesting = { @MainActor [weak viewModel] in
            viewModel?.scheduleBackgroundQuotaRefresh()
        }
        viewModel.quotaRefreshHookForTesting = { .sample }

        let fixed = RefreshCadence.oneMinute.intervalNanoseconds!
        for _ in 0..<10 {
            await viewModel.performAutomaticRefresh()
            XCTAssertNil(viewModel.adaptiveIntervalForTesting)
            XCTAssertEqual(viewModel.nextRefreshSleepNanosecondsForTesting(fixedNanoseconds: fixed), fixed)
        }
    }
}
