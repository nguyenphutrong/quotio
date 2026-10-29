import AppKit
import Foundation
import XCTest
@testable import Quotio

@MainActor
final class AppKitWindowPresenterTests: XCTestCase {
    func testMainWindowIDMatchesExpectedSceneIdentifier() {
        XCTAssertEqual(AppKitWindowPresenter.mainWindowID, "main")
    }

    func testShowMainWindowDefersExecutionToInjectedScheduler() {
        var scheduledWork: [@MainActor () -> Void] = []
        var openedScenes: [String] = []
        var didActivate = false

        let presenter = AppKitWindowPresenter(
            activate: { didActivate = true },
            schedule: { scheduledWork.append($0) }
        )
        presenter.registerSceneOpener { sceneID in
            openedScenes.append(sceneID)
        }

        presenter.showMainWindow()

        XCTAssertEqual(scheduledWork.count, 1)
        XCTAssertTrue(openedScenes.isEmpty)
        XCTAssertFalse(didActivate)

        scheduledWork.removeFirst()()

        XCTAssertEqual(openedScenes, [AppKitWindowPresenter.mainWindowID])
        XCTAssertTrue(didActivate)
    }

    func testShowMainWindowCallsSceneOpenerBeforeActivation() {
        var executionOrder: [String] = []

        let presenter = AppKitWindowPresenter(
            activate: { executionOrder.append("activate") },
            schedule: { $0() }
        )
        presenter.registerSceneOpener { sceneID in
            executionOrder.append("open:\(sceneID)")
        }

        presenter.showMainWindow()

        XCTAssertEqual(
            executionOrder,
            ["open:\(AppKitWindowPresenter.mainWindowID)", "activate"]
        )
    }

    func testRepeatedShowRequestsPassStableMainIDAndInvokeSceneOpenerEachTime() {
        var openedScenes: [String] = []
        var activationCount = 0

        let presenter = AppKitWindowPresenter(
            activate: { activationCount += 1 },
            schedule: { $0() }
        )
        presenter.registerSceneOpener { sceneID in
            openedScenes.append(sceneID)
        }

        presenter.showMainWindow()
        presenter.showMainWindow()
        presenter.showMainWindow()

        XCTAssertEqual(openedScenes, ["main", "main", "main"])
        XCTAssertTrue(openedScenes.allSatisfy { $0 == AppKitWindowPresenter.mainWindowID })
        XCTAssertEqual(activationCount, 3)
    }

    func testShowMainWindowBeforeRegistrationRetainsAndFlushesPendingRequestWhenRegistered() {
        var openedScenes: [String] = []
        var didActivate = false

        let presenter = AppKitWindowPresenter(
            activate: { didActivate = true },
            schedule: { $0() }
        )

        presenter.showMainWindow()

        XCTAssertTrue(openedScenes.isEmpty)
        XCTAssertFalse(didActivate)

        presenter.registerSceneOpener { sceneID in
            openedScenes.append(sceneID)
        }

        XCTAssertEqual(openedScenes, [AppKitWindowPresenter.mainWindowID])
        XCTAssertTrue(didActivate)
    }

    func testShowMainWindowWithDeferredScheduleBeforeRegistrationFlushesPendingRequestWhenRegistered() {
        var scheduledWork: [@MainActor () -> Void] = []
        var openedScenes: [String] = []
        var didActivate = false

        let presenter = AppKitWindowPresenter(
            activate: { didActivate = true },
            schedule: { scheduledWork.append($0) }
        )

        presenter.showMainWindow()

        XCTAssertTrue(scheduledWork.isEmpty)
        XCTAssertTrue(openedScenes.isEmpty)
        XCTAssertFalse(didActivate)

        presenter.registerSceneOpener { sceneID in
            openedScenes.append(sceneID)
        }

        XCTAssertEqual(scheduledWork.count, 1)
        XCTAssertTrue(openedScenes.isEmpty)
        XCTAssertFalse(didActivate)

        scheduledWork.removeFirst()()

        XCTAssertEqual(openedScenes, [AppKitWindowPresenter.mainWindowID])
        XCTAssertTrue(didActivate)
    }

    func testRegisterSceneOpenerAloneDoesNotOpenSceneOrActivate() {
        var openedScenes: [String] = []
        var didActivate = false

        let presenter = AppKitWindowPresenter(
            activate: { didActivate = true },
            schedule: { $0() }
        )

        presenter.registerSceneOpener { sceneID in
            openedScenes.append(sceneID)
        }

        XCTAssertTrue(openedScenes.isEmpty)
        XCTAssertFalse(didActivate)
    }

    func testTitleIndependenceAndRecreationWithoutExistingWindows() {
        var recordedSceneRequests: [String] = []

        let presenter = AppKitWindowPresenter(
            activate: {},
            schedule: { $0() }
        )
        presenter.registerSceneOpener { sceneID in
            recordedSceneRequests.append(sceneID)
        }

        presenter.showMainWindow()
        XCTAssertEqual(recordedSceneRequests, [AppKitWindowPresenter.mainWindowID])

        // Missing or closed window scenario: subsequent show requests invoke scene opener
        // without inspecting NSWindow titles or requiring an existing NSWindow
        presenter.showMainWindow()
        XCTAssertEqual(
            recordedSceneRequests,
            [AppKitWindowPresenter.mainWindowID, AppKitWindowPresenter.mainWindowID]
        )
    }

    func testDockPolicyRemainsInvariantWhenShowingMainWindow() {
        let initialPolicy = NSApplication.shared.activationPolicy()

        let presenter = AppKitWindowPresenter(
            activate: {},
            schedule: { $0() }
        )
        presenter.registerSceneOpener { _ in }

        presenter.showMainWindow()

        XCTAssertEqual(NSApplication.shared.activationPolicy(), initialPolicy)
    }
}
