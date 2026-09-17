import Foundation
import QuotioDomain
import XCTest

@testable import QuotioPresentation

@MainActor
final class MusePresentationTests: XCTestCase {
    func testMuseWindowsReadTheSameAsEveryOtherProviderSessionAndWeeklyRow() {
        XCTAssertEqual(metric("muse-session").displayName, metric("zai-session").displayName)
        XCTAssertEqual(metric("muse-weekly").displayName, metric("grok-weekly").displayName)
    }

    func testAWindowOfAnotherDurationIsLabelledWithTheDurationMetaReported() {
        XCTAssertEqual(metric("muse-window-600").displayName, "10h")
        XCTAssertEqual(metric("muse-window-90").displayName, "90m")
        XCTAssertEqual(metric("muse-window-0").displayName, "0m")
    }

    func testAnInactiveSubscriptionRendersLocalizedCopyRatherThanTheRawStatus() {
        let status = QuotaMetric(
            name: "muse-subscription", percentage: -1, resetTime: "",
            presentation: .status(text: "muse-inactive")
        )

        XCTAssertEqual(status.formattedUsage, "muse.status.inactive".localizedStatic())
        XCTAssertNotEqual(status.formattedUsage, "muse-inactive")
    }

    func testProviderIdentityIsDistinctFromEveryOtherProvider() {
        XCTAssertEqual(QuotaProvider.muse.displayName, "Muse Code")
        XCTAssertEqual(QuotaProvider.muse.oauthEndpoint, "/meta-auth-url")
        XCTAssertNil(QuotaProvider.muse.menuBarIconAsset)
        for trait in [
            QuotaProvider.allCases.map(\.displayName),
            QuotaProvider.allCases.map(\.logoAssetName),
            QuotaProvider.allCases.map(\.menuBarSymbol),
        ] {
            XCTAssertEqual(Set(trait).count, trait.count, "duplicate provider trait: \(trait)")
        }
    }

    private func metric(_ name: String) -> QuotaMetric {
        QuotaMetric(name: name, percentage: 50, resetTime: "")
    }
}
