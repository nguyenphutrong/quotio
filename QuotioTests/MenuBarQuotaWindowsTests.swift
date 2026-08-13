import AppKit
import SwiftUI
import XCTest
@testable import Quotio

final class MenuBarQuotaWindowsTests: XCTestCase {
    func testClaudeWindowsUseFiveHourAndWeeklyModels() {
        let models = [
            ModelQuota(name: "five-hour-session", percentage: 81, resetTime: ""),
            ModelQuota(name: "seven-day-weekly", percentage: 63, resetTime: ""),
            ModelQuota(name: "seven-day-sonnet", percentage: 12, resetTime: ""),
        ]

        XCTAssertEqual(
            MenuBarQuotaWindows.claude(from: models),
            MenuBarQuotaWindows(fiveHourPercentage: 81, weeklyPercentage: 63)
        )
    }

    func testClaudeWindowsRepresentAMissingWindowAsUnknown() {
        let models = [
            ModelQuota(name: "five-hour-session", percentage: 42, resetTime: ""),
        ]

        XCTAssertEqual(
            MenuBarQuotaWindows.claude(from: models),
            MenuBarQuotaWindows(fiveHourPercentage: 42, weeklyPercentage: -1)
        )
    }

    func testClaudeWindowsAreAbsentForUnrelatedModels() {
        let models = [
            ModelQuota(name: "seven-day-sonnet", percentage: 70, resetTime: ""),
        ]

        XCTAssertNil(MenuBarQuotaWindows.claude(from: models))
    }

    @MainActor
    func testCompactClaudeQuotaViewFitsMenuBarHeight() {
        let item = MenuBarQuotaDisplayItem(
            id: "claude-test",
            providerSymbol: "C",
            accountShort: "test",
            percentage: 63,
            provider: .claude,
            quotaWindows: MenuBarQuotaWindows(
                fiveHourPercentage: 81,
                weeklyPercentage: 63
            )
        )
        let hostingView = NSHostingView(
            rootView: StatusBarQuotaItemView(item: item, colorMode: .monochrome)
        )

        hostingView.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(hostingView.fittingSize.height, 22)
        XCTAssertLessThan(hostingView.fittingSize.width, 40)
    }
}
