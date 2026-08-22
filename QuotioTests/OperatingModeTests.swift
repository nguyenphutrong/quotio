import XCTest
@testable import Quotio

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
