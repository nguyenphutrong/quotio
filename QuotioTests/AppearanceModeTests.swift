import AppKit
import XCTest
@testable import Quotio

@MainActor
final class AppearanceModeTests: XCTestCase {
    func testSystemAppearanceInheritsFromTheMenuBar() {
        XCTAssertNil(AppearanceMode.system.appKitAppearance)
    }

    func testLightAppearanceUsesAqua() throws {
        let appearance = try XCTUnwrap(AppearanceMode.light.appKitAppearance)

        XCTAssertEqual(appearance.name, .aqua)
    }

    func testDarkAppearanceUsesDarkAqua() throws {
        let appearance = try XCTUnwrap(AppearanceMode.dark.appKitAppearance)

        XCTAssertEqual(appearance.name, .darkAqua)
    }
}
