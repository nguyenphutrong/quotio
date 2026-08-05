import XCTest
@testable import Quotio

/// Covers the presentation boundaries that the Card and Ring styles share:
/// unknown data must not read as a measurement, an unlimited metric with usage
/// must not read as "unused", and rings must keep stable semantic columns.
@MainActor
final class RingSlotPresentationTests: XCTestCase {
    private func slot(
        name: String = "Session",
        rawName: String = "five-hour-session",
        percentage: Double,
        reset: String = "—",
        usage: String? = nil,
        isUnlimited: Bool = false,
        isStandalone: Bool = false
    ) -> RingSlotData {
        RingSlotData(
            name: name,
            rawName: rawName,
            percentage: percentage,
            formattedResetTime: reset,
            formattedUsage: usage,
            isUnlimited: isUnlimited,
            isStandalone: isStandalone
        )
    }

    // MARK: - Unknown data (issue 2)

    /// `ModelQuota` reports "no data" as a negative percentage. Clamping it
    /// produced a real-looking 0%/100% or an "off" label that asserted an
    /// enabled state nothing had signalled.
    func testUnknownQuotaIsUnavailableRatherThanMeasured() {
        let unknown = slot(percentage: -1)
        XCTAssertTrue(unknown.isUnknown)
        XCTAssertNil(unknown.heroText, "No hero value can be derived from absent data")
        XCTAssertEqual(unknown.captionText, "unavailable")
        XCTAssertNotEqual(unknown.captionText, "off")
    }

    func testOutOfRangePercentageIsAlsoUnknown() {
        XCTAssertTrue(slot(percentage: 101).isUnknown)
    }

    func testKnownZeroIsNotUnknown() {
        let empty = slot(percentage: 0)
        XCTAssertFalse(empty.isUnknown, "0% remaining is a measurement, not absence of one")
    }

    // MARK: - Unlimited metrics (issue 3)

    /// Cursor on-demand reports 100% remaining because there is no ceiling,
    /// while still carrying a used count. It must not read as "unused".
    func testUnlimitedMetricWithUsageShowsUsageNotUnused() {
        let onDemand = slot(
            name: "On-Demand",
            rawName: "on-demand",
            percentage: 100,
            usage: "123 used",
            isUnlimited: true
        )
        XCTAssertEqual(onDemand.heroText, "123 used")
        XCTAssertNotEqual(onDemand.heroText, "unused")
    }

    func testGenuinelyUnusedWindowStillReadsUnused() {
        let untouched = slot(percentage: 100, usage: nil)
        XCTAssertEqual(untouched.heroText, "unused")
    }

    func testResetCountdownOutranksOtherHeroValues() {
        let counting = slot(percentage: 42, reset: "3h 12m", usage: "10/100")
        XCTAssertEqual(counting.heroText, "3h 12m")
    }

    // MARK: - Window captions (issue 1)

    func testCaptionUsesRawIdentityNotDisplayName() {
        // Both render as "Session"; only the raw identity distinguishes them.
        XCTAssertEqual(slot(rawName: "five-hour-session", percentage: 50).windowCaption, "5h window")
        XCTAssertNil(slot(rawName: "codex-session", percentage: 50).windowCaption)
    }

    // MARK: - Semantic slots (issue 4)

    /// The regression: with positional layout, an account lacking a Session
    /// window put Weekly in the first column, so stacked cards compared unlike
    /// metrics side by side.
    func testWeeklyKeepsItsColumnWhenSessionIsAbsent() {
        XCTAssertEqual(RingSlotRole.role(forMetricNamed: "seven-day-weekly"), .weekly)
        XCTAssertEqual(RingSlotRole.role(forMetricNamed: "five-hour-session"), .session)
        XCTAssertEqual(RingSlotRole.weekly.rawValue, 1, "Weekly is pinned to the second column")
        XCTAssertEqual(RingSlotRole.session.rawValue, 0)
    }

    func testMetricsWithoutARoleAreLaidOutPositionally() {
        for name in ["copilot-chat", "copilot-completions", "extra-usage"] {
            XCTAssertNil(
                RingSlotRole.role(forMetricNamed: name),
                "\(name) has no recurring-window role and must not reserve a column"
            )
        }
    }

    // MARK: - The unlimited signal itself

    func testMetricWithUsageAndNoLimitIsUnlimited() {
        let onDemand = ModelQuota(name: "on-demand", percentage: 100, resetTime: "", used: 123, limit: nil)
        XCTAssertTrue(onDemand.isUnlimitedUsage)
        XCTAssertEqual(onDemand.formattedUsage, "123 used")
    }

    func testMetricWithARealLimitIsNotUnlimited() {
        let capped = ModelQuota(name: "plan-usage", percentage: 40, resetTime: "", used: 60, limit: 100)
        XCTAssertFalse(capped.isUnlimitedUsage)
    }

    func testUntouchedMetricIsNotUnlimited() {
        let untouched = ModelQuota(name: "on-demand", percentage: 100, resetTime: "", used: 0, limit: nil)
        XCTAssertFalse(untouched.isUnlimitedUsage, "Nothing used means \"unused\" is still the honest label")
    }

    // MARK: - Standalone metrics keep their value

    /// Amp/OpenRouter balances and Grok status set `percentage` to -1 on
    /// purpose and put the real value in `formattedUsage`. Treating that
    /// sentinel as "no data" replaced valid values with a placeholder.
    func testStandaloneMetricShowsItsValueDespiteTheSentinel() {
        let balance = slot(
            name: "Balance",
            rawName: "amp-balance",
            percentage: -1,
            usage: "$12.34",
            isStandalone: true
        )
        XCTAssertEqual(balance.heroText, "$12.34")
        XCTAssertNotEqual(balance.captionText, "unavailable")
    }

    func testNonStandaloneSentinelIsStillUnavailable() {
        let noData = slot(percentage: -1, usage: nil)
        XCTAssertNil(noData.heroText)
        XCTAssertEqual(noData.captionText, "unavailable")
    }

    func testStandaloneMetricIsRecognisedFromPresentation() {
        let status = ModelQuota(
            name: "grok-status",
            percentage: -1,
            resetTime: "",
            presentation: .status(text: "Active")
        )
        XCTAssertTrue(status.isStandaloneMetric)
        XCTAssertEqual(status.formattedUsage, "Active")
    }

    // MARK: - Wrapping rather than truncating

    /// The grid renders a fixed column count, so without wrapping a provider
    /// reporting more than four metrics (Kiro appends a bonus and a base metric
    /// per breakdown entry) silently lost the extras.
    func testMoreThanFourMetricsWrapInsteadOfDisappearing() {
        let names = ["a", "b", "c", "d", "e", "f"]
        let arranged = RingSlotArrangement.arrange(names, rawName: { $0 })
        let rows = RingSlotArrangement.rows(arranged)

        XCTAssertEqual(rows.count, 2)
        let rendered = rows.flatMap { $0 }.compactMap { $0 }
        XCTAssertEqual(rendered, names, "Every metric must survive the layout")
    }

    func testRowsAreCappedAtFourColumns() {
        for row in RingSlotArrangement.rows(RingSlotArrangement.arrange(Array(1...9), rawName: { _ in "" })) {
            XCTAssertLessThanOrEqual(row.count, RingSlotArrangement.maxColumns)
        }
    }

    func testShortRowsStillReserveTheMinimumColumns() {
        let row = RingSlotArrangement.rows(RingSlotArrangement.arrange(["only"], rawName: { $0 })).first
        XCTAssertEqual(RingSlotArrangement.columnCount(for: try! XCTUnwrap(row)), 3)
    }

    // MARK: - Shared arrangement (dashboard and menu must agree)

    func testWeeklyWithoutSessionLeavesTheSessionColumnEmpty() {
        let arranged = RingSlotArrangement.arrange(["seven-day-weekly", "extra-usage"], rawName: { $0 })
        XCTAssertNil(arranged[0], "The Session column stays empty rather than being filled by Weekly")
        XCTAssertEqual(arranged[1], "seven-day-weekly")
        XCTAssertEqual(arranged[2], "extra-usage")
    }

    func testProvidersWithoutRolesAreNotPaddedWithEmptyColumns() {
        let arranged = RingSlotArrangement.arrange(["copilot-chat", "copilot-premium"], rawName: { $0 })
        XCTAssertEqual(arranged.compactMap { $0 }, ["copilot-chat", "copilot-premium"])
        XCTAssertFalse(arranged.contains(where: { $0 == nil }))
    }

    // MARK: - Accessibility (issue 4)

    /// The menu ring dropped metric names entirely, leaving rings unidentifiable.
    func testAccessibilityDescriptionIdentifiesTheRing() {
        let described = slot(percentage: 40, reset: "2h 5m")
        let description = described.accessibilityDescription
        XCTAssertTrue(description.contains("Session"), "Ring must be identifiable: \(description)")
        XCTAssertTrue(description.contains("40%"), description)
        XCTAssertTrue(description.contains("2h 5m"), description)
    }

    func testStandaloneAccessibilityLabelDoesNotRepeatTheValue() {
        let balance = slot(
            name: "Balance",
            rawName: "amp-balance",
            percentage: -1,
            usage: "$12.34",
            isStandalone: true
        )
        XCTAssertEqual(balance.accessibilityDescription, "Balance, $12.34")
    }

    func testAccessibilityDescriptionReportsUnavailableRatherThanZero() {
        let description = slot(percentage: -1).accessibilityDescription
        XCTAssertTrue(description.contains("unavailable"), description)
        XCTAssertFalse(description.contains("0%"), description)
    }
}
