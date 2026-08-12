import XCTest
@testable import Quotio

/// Regression tests for issue #219: a "no data" sentinel of -1 remaining percent
/// must never be converted into a fake display value (100 - (-1) = 101%).
@MainActor
final class QuotaDisplayModeTests: XCTestCase {
    // MARK: - No-data sentinel propagation

    /// The exact defect from issue #219: an unfetched quota item carries
    /// remaining = -1, and "used" mode displayed 100 - (-1) = 101%.
    func testUsedModePropagatesNoDataSentinelInsteadOf101() {
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: -1), -1)
    }

    func testRemainingModePropagatesNoDataSentinel() {
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: -1), -1)
    }

    func testAnyNegativeInputIsTreatedAsNoData() {
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: -0.5), -1)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: -100), -1)
    }

    // MARK: - Valid values are unchanged

    func testUsedModeConvertsRemainingToUsed() {
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 100), 0)
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 70), 30)
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 0), 100)
    }

    func testRemainingModePassesValueThrough() {
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 100), 100)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 25), 25)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 0), 0)
    }

    // MARK: - Out-of-range values are clamped at the display boundary

    func testOverOneHundredRemainingIsClamped() {
        XCTAssertEqual(QuotaDisplayMode.used.displayValue(from: 150), 0)
        XCTAssertEqual(QuotaDisplayMode.remaining.displayValue(from: 150), 100)
    }
}
