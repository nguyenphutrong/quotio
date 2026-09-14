import XCTest

@testable import QuotioPresentation

final class QuotaResetMomentTests: XCTestCase {
    private let locale = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-09-14T10:00:00Z is a Monday.
    private let now = Date(timeIntervalSince1970: 1_789_380_000)

    func testResetWithinTwentyFourHoursShowsTimeOnly() {
        let label = QuotaResetMoment.label(for: "2026-09-14T14:30:00Z", now: now, locale: locale, timeZone: utc)
        XCTAssertEqual(label, "14:30")
    }

    func testResetLaterThanTwentyFourHoursIncludesWeekday() {
        let label = QuotaResetMoment.label(for: "2026-09-17T09:05:00.000Z", now: now, locale: locale, timeZone: utc)
        XCTAssertEqual(label, "Thu 09:05")
    }

    func testResetRespectsTimeZone() {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let label = QuotaResetMoment.label(for: "2026-09-14T14:30:00Z", now: now, locale: locale, timeZone: berlin)
        XCTAssertEqual(label, "16:30")
    }

    func testPastEmptyAndInvalidValuesYieldNil() {
        XCTAssertNil(QuotaResetMoment.label(for: "2026-09-14T09:00:00Z", now: now, locale: locale, timeZone: utc))
        XCTAssertNil(QuotaResetMoment.label(for: "", now: now, locale: locale, timeZone: utc))
        XCTAssertNil(QuotaResetMoment.label(for: "soon", now: now, locale: locale, timeZone: utc))
    }

    func testSummaryJoinsAvailableParts() {
        XCTAssertEqual(QuotaResetMoment.summary(countdown: "2h 13m", moment: "14:30"), "2h 13m · 14:30")
        XCTAssertEqual(QuotaResetMoment.summary(countdown: "2h 13m", moment: nil), "2h 13m")
        XCTAssertEqual(QuotaResetMoment.summary(countdown: nil, moment: "14:30"), "14:30")
        XCTAssertNil(QuotaResetMoment.summary(countdown: nil, moment: nil))
    }
}
