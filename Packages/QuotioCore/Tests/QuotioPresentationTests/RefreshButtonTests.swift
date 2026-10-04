import AppKit
import QuotioApplication
import QuotioDomain
import SwiftUI
import XCTest
@testable import QuotioPresentation

@MainActor
final class RefreshButtonTests: XCTestCase {
    func testClickShowsLoadingBlocksRepeatedClicksAndRestoresButton() async throws {
        _ = NSApplication.shared
        let gate = TestAsyncGate()
        var calls = 0
        let hosting = NSHostingView(rootView:
            RefreshButton(title: "Refresh") {
                calls += 1
                if calls == 1 { await gate.wait() }
            }
            .buttonStyle(.bordered)
            .padding(24)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 220, height: 90)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        defer { window.orderOut(nil) }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let idleSize = hosting.fittingSize

        try click(window)
        try click(window)
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(descendant(NSProgressIndicator.self, in: hosting))
        XCTAssertEqual(hosting.fittingSize, idleSize)

        await gate.resume()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertNil(descendant(NSProgressIndicator.self, in: hosting))
        XCTAssertEqual(hosting.fittingSize, idleSize)
        try click(window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls, 2)
    }

    func testMenuRefreshKeepsShortcutAndShowsLoading() throws {
        _ = NSApplication.shared
        let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
            refreshAll: {}, refreshProvider: { _ in }, refreshAccount: { _ in }, selectProvider: { _ in },
            pairIPhone: {}, openApp: {}, quit: {}, menuNeedsRebuild: {}
        ))
        for loading in [false, true] {
            let snapshot = StatusBarMenuSnapshotMapper.makeSnapshot(
                monitorAccounts: [],
                quota: QuotaSnapshot(canRefresh: true, refreshingProviders: loading ? [.codex] : []),
                menuBarPreferences: MenuBarPreferences(), language: .english
            )
            let menu = StatusBarMenuRenderer(snapshot: snapshot, commands: commands).buildMenu()
            let refresh = try XCTUnwrap(menu.items.first { $0.keyEquivalent == "r" })
            XCTAssertEqual(refresh.isEnabled, !loading)
            if loading {
                let view = try XCTUnwrap(refresh.view)
                view.layoutSubtreeIfNeeded()
                XCTAssertNotNil(descendant(NSProgressIndicator.self, in: view))
            } else {
                XCTAssertNil(refresh.view)
            }
        }
    }

    private func click(_ window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 110, y: 45), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
        }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
}
