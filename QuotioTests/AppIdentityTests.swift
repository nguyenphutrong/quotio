import XCTest
@testable import Quotio

final class AppIdentityTests: XCTestCase {
    func testProductionIdentityUsesByTrongDomain() {
        XCTAssertEqual(AppIdentity.productionBundleIdentifier, "app.bytrong.quotio")
        XCTAssertEqual(
            AppIdentity.keychainService(suffix: "remote-management"),
            "app.bytrong.quotio.remote-management"
        )
        XCTAssertEqual(
            AppIdentity.legacyKeychainServices(suffix: "remote-management").first,
            "dev.quotio.desktop.remote-management"
        )
    }

    func testLegacyDefaultsMergePreservesCurrentValuesAndNewestLegacyDomain() {
        let merged = AppIdentity.mergingUserDefaults(
            current: ["existing": "current"],
            legacyDomains: [
                ["existing": "legacy", "legacyOnly": "newest"],
                ["legacyOnly": "oldest", "oldestOnly": true],
            ]
        )

        XCTAssertEqual(merged["existing"] as? String, "current")
        XCTAssertEqual(merged["legacyOnly"] as? String, "newest")
        XCTAssertEqual(merged["oldestOnly"] as? Bool, true)
    }
}
