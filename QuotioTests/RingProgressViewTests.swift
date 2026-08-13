import XCTest
@testable import Quotio

/// Regression tests for the ring display paths of issue #219.
///
/// The `-1` "no data" sentinel used to be clamped to zero by `RingProgressView`,
/// so an unknown quota rendered as an empty 0% ring and VoiceOver announced
/// "0 percent". The ring must expose the same unknown-value contract as the
/// text/card paths.
@MainActor
final class RingProgressViewTests: XCTestCase {
    // MARK: - Unknown detection

    func testNegativeSentinelIsUnknown() {
        XCTAssertTrue(RingProgressView.isUnknown(RingProgressView.unknownPercent))
        XCTAssertTrue(RingProgressView.isUnknown(-1))
        XCTAssertTrue(RingProgressView.isUnknown(-0.5))
    }

    func testRealValuesAreNotUnknown() {
        XCTAssertFalse(RingProgressView.isUnknown(0))
        XCTAssertFalse(RingProgressView.isUnknown(42))
        XCTAssertFalse(RingProgressView.isUnknown(100))
    }

    /// The value the menu bar actually hands to the ring: an unfetched quota
    /// carries remaining = -1, which `displayValue(from:)` propagates.
    func testSentinelFromDisplayModeReachesRingAsUnknown() {
        XCTAssertTrue(RingProgressView.isUnknown(QuotaDisplayMode.used.displayValue(from: -1)))
        XCTAssertTrue(RingProgressView.isUnknown(QuotaDisplayMode.remaining.displayValue(from: -1)))
    }

    // MARK: - Visible label

    func testUnknownRendersPlaceholderLabel() {
        XCTAssertEqual(RingProgressView.labelText(for: RingProgressView.unknownPercent), "—")
    }

    func testKnownValuesRenderPercentLabel() {
        XCTAssertEqual(RingProgressView.labelText(for: 0), "0%")
        XCTAssertEqual(RingProgressView.labelText(for: 42.6), "42%")
        XCTAssertEqual(RingProgressView.labelText(for: 100), "100%")
    }

    func testLabelClampsOutOfRangeValues() {
        XCTAssertEqual(RingProgressView.labelText(for: 150), "100%")
    }

    // MARK: - Accessibility value

    /// The exact complaint from review: an unknown quota must not be announced
    /// the same way as a real 0% quota.
    func testUnknownAccessibilityValueDiffersFromZeroPercent() {
        let unknown = RingProgressView.accessibilityValueText(for: RingProgressView.unknownPercent)
        let zero = RingProgressView.accessibilityValueText(for: 0)

        XCTAssertNotEqual(unknown, zero)
        XCTAssertEqual(unknown, "quota.noDataYet".localized())
    }

    func testKnownAccessibilityValueAnnouncesPercent() {
        XCTAssertEqual(
            RingProgressView.accessibilityValueText(for: 42),
            String(format: "%lld percent".localized(), Int64(42))
        )
    }

    func testAccessibilityValueClampsOutOfRangeValues() {
        XCTAssertEqual(
            RingProgressView.accessibilityValueText(for: 150),
            String(format: "%lld percent".localized(), Int64(100))
        )
    }
}
