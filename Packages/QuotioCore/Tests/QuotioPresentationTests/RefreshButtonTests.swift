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
            let view = try XCTUnwrap(refresh.view)
            view.layoutSubtreeIfNeeded()
            if loading {
                XCTAssertNotNil(descendant(NSProgressIndicator.self, in: view))
            } else {
                XCTAssertNil(descendant(NSProgressIndicator.self, in: view))
            }
        }
    }

    func testMenuRefreshActionsKeepLoadingUntilCompletionAndUpdateExistingItems() async throws {
        _ = NSApplication.shared
        for scope in ["all", "provider", "account"] {
            let gate = TestAsyncGate()
            let manager = StatusBarManager()
            var calls: [String] = []
            var refreshing = false
            func snapshot() -> StatusBarMenuSnapshot {
                StatusBarMenuSnapshotMapper.makeSnapshot(
                    monitorAccounts: [],
                    quota: QuotaSnapshot(canRefresh: true, quotas: [
                        .claude: ["Account": ProviderQuota()], .codex: ["Other": ProviderQuota()]
                    ], refreshingProviders: refreshing ? [.claude] : []),
                    menuBarPreferences: MenuBarPreferences(), language: .english
                )
            }
            let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
                refreshAll: { calls.append("all"); await gate.wait() },
                refreshProvider: { calls.append("provider:\($0.rawValue)"); await gate.wait() },
                refreshAccount: { calls.append("account:\($0.provider.rawValue):\($0.accountKey)"); await gate.wait() },
                selectProvider: { _ in }, pairIPhone: {}, openApp: {}, quit: {},
                menuNeedsRebuild: { manager.rebuildMenuInPlace() }
            ))
            manager.configureMenu(snapshotProvider: snapshot, commandDispatcher: commands)
            let menu = NSMenu()
            menu.autoenablesItems = false
            manager.menuWillOpen(menu)
            defer { manager.menuDidClose(menu) }
            let item = try XCTUnwrap(menu.items.first {
                switch scope {
                case "all": $0.keyEquivalent == "r"
                case "provider": $0.title == QuotaProvider.claude.displayName
                default: $0.title == "Account"
                }
            })
            let view = try XCTUnwrap(item.view)
            let originalItems = menu.items.map(ObjectIdentifier.init)
            let originalViews = menu.items.compactMap(\.view).map(ObjectIdentifier.init)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            defer { window.orderOut(nil) }
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            let location = NSPoint(
                x: scope == "all" ? 60 : view.bounds.width - 26,
                y: scope == "account" ? (view.isFlipped ? 18 : view.bounds.height - 18) : view.bounds.midY
            )
            let point = view.convert(location, to: nil)
            try click(window, at: point)
            try click(window, at: point)
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(calls, [scope == "provider" ? "provider:claude" : scope == "account" ? "account:claude:Account" : "all"])
            XCTAssertNotNil(descendant(NSProgressIndicator.self, in: view), scope)

            refreshing = true
            manager.rebuildMenuInPlace()
            try await Task.sleep(for: .milliseconds(100))
            for title in ["Account", QuotaProvider.claude.displayName] {
                let affected = try XCTUnwrap(menu.items.first { $0.title == title }?.view)
                affected.layoutSubtreeIfNeeded()
                XCTAssertNotNil(descendant(NSProgressIndicator.self, in: affected), title)
            }
            let unaffected = try XCTUnwrap(menu.items.first { $0.title == "Other" }?.view)
            unaffected.layoutSubtreeIfNeeded()
            XCTAssertNil(descendant(NSProgressIndicator.self, in: unaffected))
            XCTAssertEqual(menu.items.map(ObjectIdentifier.init), originalItems)
            XCTAssertEqual(menu.items.compactMap(\.view).map(ObjectIdentifier.init), originalViews)
            XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.keyEquivalent == "r" }).isEnabled)

            refreshing = false
            manager.rebuildMenuInPlace()
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            XCTAssertNotNil(descendant(NSProgressIndicator.self, in: view), "Action must still be awaited")
            await gate.resume()
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
            XCTAssertNil(descendant(NSProgressIndicator.self, in: view), scope)
            XCTAssertTrue(item.isEnabled)
        }
    }

    func testRefreshClicksKeepNativeMenuOpen() throws {
        _ = NSApplication.shared
        guard ProcessInfo.processInfo.environment["QUOTIO_MENU_TRACKING_TESTS"] == "1" else {
            throw XCTSkip("Set QUOTIO_MENU_TRACKING_TESTS=1 in a logged-in macOS session")
        }
        @MainActor final class Result {
            var commands: [String] = []
            var items: [ObjectIdentifier] = []
            var sawLoading = false
            var sawCompletion = false
        }
        for scope in ["all", "provider", "account"] {
            let result = Result()
            let manager = StatusBarManager()
            var refreshing = false
            let refresh: @MainActor @Sendable (String) async -> Void = { command in
                result.commands.append(command)
                refreshing = true
                manager.rebuildMenuInPlace()
                try? await Task.sleep(for: .milliseconds(200))
                refreshing = false
                manager.rebuildMenuInPlace()
            }
            let commands = StatusBarCommandDispatcher(handlers: StatusBarCommandHandlers(
                refreshAll: { await refresh("all") },
                refreshProvider: { await refresh("provider:\($0.rawValue)") },
                refreshAccount: { await refresh("account:\($0.provider.rawValue):\($0.accountKey)") },
                selectProvider: { _ in }, pairIPhone: {}, openApp: {}, quit: {},
                menuNeedsRebuild: { manager.rebuildMenuInPlace() }
            ))
            manager.configureMenu(snapshotProvider: {
                StatusBarMenuSnapshotMapper.makeSnapshot(
                    monitorAccounts: [],
                    quota: QuotaSnapshot(canRefresh: true, quotas: [.claude: ["Account": ProviderQuota()]],
                                         refreshingProviders: refreshing ? [.claude] : []),
                    menuBarPreferences: MenuBarPreferences(), language: .english
                )
            }, commandDispatcher: commands)
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = manager
            manager.menuWillOpen(menu)
            let targetView: @MainActor () -> NSView? = {
                menu.items.first {
                    switch scope {
                    case "all": $0.keyEquivalent == "r"
                    case "provider": $0.title == QuotaProvider.claude.displayName
                    default: $0.title == "Account"
                    }
                }?.view
            }
            let tick: @MainActor @Sendable (Int) -> Void = { stage in
                switch stage {
                case 0:
                    result.items = menu.items.map(ObjectIdentifier.init)
                    guard let view = targetView(), let window = view.window else {
                        XCTFail("Missing tracked view: \(scope)")
                        return
                    }
                    let point = NSPoint(x: scope == "all" ? 60 : view.bounds.width - 26,
                                        y: scope == "account" ? (view.isFlipped ? 18 : view.bounds.height - 18) : view.bounds.midY)
                    try? self.click(window, at: view.convert(point, to: nil))
                case 1:
                    guard let view = targetView() else { return }
                    view.layoutSubtreeIfNeeded()
                    result.sawLoading = self.descendant(NSProgressIndicator.self, in: view) != nil
                    XCTAssertEqual(menu.items.map(ObjectIdentifier.init), result.items)
                default:
                    if let view = targetView() {
                        view.layoutSubtreeIfNeeded()
                        result.sawCompletion = !result.commands.isEmpty && self.descendant(NSProgressIndicator.self, in: view) == nil
                        XCTAssertEqual(menu.items.map(ObjectIdentifier.init), result.items)
                    }
                    menu.cancelTracking()
                }
            }
            let timers = [0.1, 0.2, 0.5].enumerated().map { stage, delay in
                Timer(timeInterval: delay, repeats: false) { _ in
                    MainActor.assumeIsolated { tick(stage) }
                }
            }
            timers.forEach { RunLoop.main.add($0, forMode: .eventTracking) }
            menu.popUp(positioning: nil, at: NSPoint(x: 400, y: 400), in: nil)
            timers.forEach { $0.invalidate() }
            XCTAssertEqual(result.commands, [scope == "provider" ? "provider:claude" : scope == "account" ? "account:claude:Account" : "all"])
            XCTAssertTrue(result.sawLoading, scope)
            XCTAssertTrue(result.sawCompletion, "Menu must stay open through completion: \(scope)")
        }
    }

    private func click(_ window: NSWindow, at point: NSPoint = NSPoint(x: 110, y: 45)) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
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
