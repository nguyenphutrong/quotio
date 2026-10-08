import AppKit
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioPresentation

@MainActor
final class CompanionPopoverPresenterTests: XCTestCase {
    func testPopoverReopensWithoutCreatingCredentialsAndSettingsCanTakeOver() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 160, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSButton(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        let controller = PopoverCompanionStub()
        let model = CompanionScreenModel(controller: controller)
        let pasteboard = PasteboardScreenModel(writer: PopoverPasteboardStub())
        let presenter = CompanionPopoverPresenter()
        defer { presenter.close(); window.close() }

        presenter.show(relativeTo: anchor, model: model, pasteboard: pasteboard, locale: Locale(identifier: "en"))
        XCTAssertTrue(presenter.isShown)
        XCTAssertEqual(model.presentation, .menuBar)
        presenter.show(relativeTo: anchor, model: model, pasteboard: pasteboard, locale: .current)
        XCTAssertTrue(presenter.isShown)
        presenter.close()
        XCTAssertNil(model.presentation)
        presenter.show(relativeTo: anchor, model: model, pasteboard: pasteboard, locale: .current)
        XCTAssertTrue(presenter.isShown)
        try await Task.sleep(for: .milliseconds(100))
        model.presentPairing(in: .settings)
        let deadline = Date().addingTimeInterval(2)
        while presenter.isShown && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(presenter.isShown)
        XCTAssertEqual(model.presentation, .settings)
        XCTAssertEqual(controller.issueCount, 0)
    }
}

@MainActor
private final class PopoverCompanionStub: CompanionControlling {
    var issueCount = 0
    func status() async throws -> CompanionStatus { CompanionStatus(enabled: false, listen: nil, publicUrl: nil) }
    func configure(enabled: Bool, origin: String, port: Int, mode: CompanionConnectionMode, address: String) async throws -> CompanionStatus { throw CompanionFailure.requestFailed }
    func devices() async throws -> [CompanionDevice] { [] }
    func issue(label: String, origin: String) async throws -> CompanionPairing {
        issueCount += 1
        throw CompanionFailure.requestFailed
    }
    func revoke(id: String) async throws { XCTFail("Opening a popover must not revoke access") }
}

@MainActor
private struct PopoverPasteboardStub: PasteboardWriting {
    func copy(_ value: String) { XCTFail("Opening a popover must not copy credentials") }
}
