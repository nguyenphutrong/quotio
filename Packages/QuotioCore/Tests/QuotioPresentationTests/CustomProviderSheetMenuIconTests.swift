import AppKit
import XCTest
@testable import QuotioPresentation

@MainActor
final class CustomProviderSheetMenuIconTests: XCTestCase {
    func testMenuIconCarriesItsOwnPointSize() {
        // The bundled menu bar icons are 9–18 pt vectors; the picker row wants 16 pt.
        let source = NSImage(size: NSSize(width: 12, height: 12))

        let icon = CustomProviderSheet.menuIcon(from: source, side: 16)

        XCTAssertEqual(icon.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(source.size, NSSize(width: 12, height: 12), "the shared named image must not be resized")
    }

    func testMenuIconKeepsAspectRatioAndTemplateFlag() {
        let source = NSImage(size: NSSize(width: 350, height: 400))
        source.isTemplate = true

        let icon = CustomProviderSheet.menuIcon(from: source, side: 16)

        XCTAssertEqual(icon.size.height, 16, accuracy: 0.001)
        XCTAssertEqual(icon.size.width, 14, accuracy: 0.001)
        XCTAssertTrue(icon.isTemplate)
    }

    func testMenuIconLeavesEmptyImageUntouched() {
        let icon = CustomProviderSheet.menuIcon(from: NSImage(size: .zero), side: 16)

        XCTAssertEqual(icon.size, .zero)
    }
}
