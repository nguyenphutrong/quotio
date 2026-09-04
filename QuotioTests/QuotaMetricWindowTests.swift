import XCTest
@testable import Quotio

/// A window caption must come from the metric's own identity, never its display
/// name. `five-hour-session`, `codex-session` and `zai-session` all render as
/// "Session" while describing different windows, so a name-derived caption is
/// wrong for all but one of them.
final class QuotaMetricWindowTests: XCTestCase {
    func testExplicitDurationsAreDerivedFromRawIdentity() {
        XCTAssertEqual(QuotaMetricWindow.forMetric(named: "five-hour-session"), .hours(5))
        XCTAssertEqual(QuotaMetricWindow.forMetric(named: "clinepass-five-hour"), .hours(5))
        XCTAssertEqual(QuotaMetricWindow.forMetric(named: "seven-day-weekly"), .days(7))
        XCTAssertEqual(QuotaMetricWindow.forMetric(named: "seven-day-opus"), .days(7))
        XCTAssertEqual(QuotaMetricWindow.forMetric(named: "codex-weekly"), .days(7))
        XCTAssertEqual(QuotaMetricWindow.forMetric(named: "zai-daily"), .hours(24))
    }

    /// The regression this guards: Codex classifies variable windows of up to
    /// 24 hours as "Session", so no fixed duration is correct for it.
    func testAmbiguousSessionsHaveNoCaption() {
        for name in ["codex-session", "zai-session", "antigravity-gemini-session", "cursor-usage"] {
            XCTAssertNil(
                QuotaMetricWindow.forMetric(named: name),
                "\(name) does not state a window; a caption would be a guess"
            )
            XCTAssertNil(QuotaMetricWindow.caption(forMetricNamed: name))
        }
    }

    /// Calendar months vary in length, so "monthly" states a period without
    /// stating a duration.
    func testMonthlyIsDeliberatelyUncaptioned() {
        XCTAssertNil(QuotaMetricWindow.forMetric(named: "clinepass-monthly"))
    }

    func testCaptionIsRenderedForKnownWindows() {
        XCTAssertEqual(QuotaMetricWindow.hours(5).caption, "5h window")
        XCTAssertEqual(QuotaMetricWindow.days(7).caption, "7d window")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(QuotaMetricWindow.forMetric(named: "Seven-Day-Weekly"), .days(7))
    }
}
