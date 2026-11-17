import QuotioDomain
import SwiftUI
import XCTest
@testable import QuotioPresentation

final class MenuBarPaceColorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 86_400

    /// A weekly limit `elapsedDays` into its window with `remaining` percent left.
    private func weekly(_ name: String = "Weekly", remaining: Double, elapsedDays: Double) -> QuotaMetric {
        let reset = now.addingTimeInterval(week - elapsedDays * 86_400)
        return QuotaMetric(
            name: name,
            percentage: remaining,
            resetTime: ISO8601DateFormatter().string(from: reset),
            windowDuration: week
        )
    }

    private func item(forbidden: Bool = false) -> MenuBarQuotaDisplayItem {
        MenuBarQuotaDisplayItem(id: "claude-test", providerSymbol: "C", accountShort: "test", percentage: 70, provider: .claude, isForbidden: forbidden)
    }

    func testResolverReportsBehindWhenSpendingFasterThanTheWindow() {
        XCTAssertEqual(MenuBarPaceResolver.worstStatus(of: [weekly(remaining: 50, elapsedDays: 2)], now: now), .behind)
        XCTAssertEqual(MenuBarPaceResolver.worstStatus(of: [weekly(remaining: 80, elapsedDays: 2)], now: now), .onPace)
    }

    func testResolverTakesTheWorstLimitAndIgnoresLimitsWithoutWindow() {
        let noWindow = QuotaMetric(name: "Credits", percentage: 10, resetTime: "")
        let metrics = [weekly("Session", remaining: 90, elapsedDays: 2), weekly(remaining: 50, elapsedDays: 2), noWindow]
        XCTAssertEqual(MenuBarPaceResolver.worstStatus(of: metrics, now: now), .behind)
        XCTAssertNil(MenuBarPaceResolver.worstStatus(of: [noWindow], now: now))
    }

    func testPairValuesFindTheirLimitByValuePreferringTheName() {
        let metrics = [
            weekly("Session", remaining: 60, elapsedDays: 3.5),
            weekly("Weekly", remaining: 60, elapsedDays: 1),
        ]
        XCTAssertEqual(MenuBarPaceResolver.status(forPairValue: 60, label: "Session", in: metrics, now: now), .onPace)
        XCTAssertEqual(MenuBarPaceResolver.status(forPairValue: 60, label: "Weekly", in: metrics, now: now), .behind)
        XCTAssertNil(MenuBarPaceResolver.status(forPairValue: 42, label: "Weekly", in: metrics, now: now))
        XCTAssertNil(MenuBarPaceResolver.status(forPairValue: -1, label: "Weekly", in: metrics, now: now))
    }

    func testPairCarriesPaceOfEachLimit() throws {
        let summary = QuotaSummary(sessionOnly: .init(lowest: 70, average: 80), combined: .init(lowest: 70, average: 80), pair: [
            .init(displayName: "Session", remainingPercent: 90),
            .init(displayName: "Weekly", remainingPercent: 50),
        ])
        let metrics = [weekly("Session", remaining: 90, elapsedDays: 1), weekly(remaining: 50, elapsedDays: 2)]
        let pair = try XCTUnwrap(MenuBarQuotaPair.resolve(from: summary, metrics: metrics, now: now))
        XCTAssertEqual(pair.top.paceStatus, .onPace)
        XCTAssertEqual(pair.bottom.paceStatus, .behind)
        XCTAssertNil(try XCTUnwrap(MenuBarQuotaPair.resolve(from: summary)).bottom.paceStatus)
    }

    func testPaceBasisColorsByPace() {
        let item = item()
        XCTAssertEqual(item.statusColor(for: 70, paceStatus: .onPace, basis: .pace), .green)
        XCTAssertEqual(item.statusColor(for: 70, paceStatus: .behind, basis: .pace), .orange)
        XCTAssertEqual(item.statusColor(for: 15, paceStatus: .onPace, basis: .pace), .green)
        XCTAssertEqual(item.statusColor(for: 0, paceStatus: .exhausted, basis: .pace), .red)
    }

    func testRemainingBasisAndMissingPaceKeepTheThresholds() {
        let item = item()
        XCTAssertEqual(item.statusColor(for: 70, paceStatus: .behind, basis: .remaining), .green)
        XCTAssertEqual(item.statusColor(for: 70, paceStatus: nil, basis: .pace), .green)
        XCTAssertEqual(item.statusColor(for: 30, paceStatus: nil, basis: .pace), .orange)
        XCTAssertEqual(item.statusColor(for: 10, paceStatus: nil, basis: .pace), .red)
    }

    func testForbiddenStaysOrange() {
        XCTAssertEqual(item(forbidden: true).statusColor(for: 70, paceStatus: .onPace, basis: .pace), .orange)
    }
}
