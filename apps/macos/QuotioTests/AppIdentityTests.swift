import XCTest
@testable import Quotio

final class AppIdentityTests: XCTestCase {
    func testProductionBundleIdentifierUsesByTrongDomain() {
        XCTAssertEqual(AppIdentity.productionBundleIdentifier, "app.bytrong.quotio")
    }

    func testApplicationBundleContainsExecutableQuotioCLIHelper() {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/quotio-cli")

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
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
