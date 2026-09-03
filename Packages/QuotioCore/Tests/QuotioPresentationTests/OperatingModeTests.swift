import QuotioDomain
import XCTest
@testable import QuotioPresentation

@MainActor
final class OperatingModeTests: XCTestCase {
    func testRemoteModeIsNoLongerAvailable() {
        XCTAssertNil(OperatingMode(rawValue: "remote"))
    }

    func testLegacyRemoteModeMigratesToMonitor() {
        XCTAssertEqual(
            OperatingMode.fromLegacy(appModeRaw: "full", connectionModeRaw: "remote"),
            .monitor
        )
    }

    func testLegacyLocalModeMigratesToLocalProxy() {
        XCTAssertEqual(
            OperatingMode.fromLegacy(appModeRaw: "full", connectionModeRaw: "local"),
            .localProxy
        )
    }
}
