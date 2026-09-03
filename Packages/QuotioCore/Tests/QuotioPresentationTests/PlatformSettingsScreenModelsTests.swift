import AppKit
import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class PlatformSettingsScreenModelsTests: XCTestCase {
    func testUpdateScreenModelReflectsSnapshotsAndForwardsIntents() {
        let controller = ApplicationUpdateControllerFake()
        let model = ApplicationUpdateScreenModel(controller: controller)

        controller.snapshot = ApplicationUpdateSnapshot(
            isInitialized: true,
            isChecking: true,
            canCheck: true,
            channel: .beta
        )
        controller.publish()
        model.checkForUpdates()
        model.setChannel(.stable)

        XCTAssertEqual(model.snapshot.channel, .beta)
        XCTAssertTrue(model.snapshot.isChecking)
        XCTAssertEqual(controller.checkCount, 1)
        XCTAssertEqual(controller.channels, [.stable])
    }

    func testNotificationScreenModelPersistsUpdatedPreferenceSnapshot() {
        let controller = NotificationControllerFake()
        let model = NotificationSettingsScreenModel(controller: controller)

        model.update { $0.notifyOnCooling = false }

        XCTAssertFalse(model.snapshot.preferences.notifyOnCooling)
        XCTAssertFalse(controller.snapshot.preferences.notifyOnCooling)
    }

    func testTelemetryAndLaunchAtLoginModelsForwardUserIntent() {
        let telemetry = TelemetryControllerFake()
        let telemetryModel = TelemetryConsentScreenModel(controller: telemetry)
        telemetryModel.setConsent(true)

        let launch = LaunchAtLoginControllerFake()
        let launchModel = LaunchAtLoginScreenModel(controller: launch)
        XCTAssertTrue(launchModel.setEnabled(true))

        XCTAssertTrue(telemetry.preferences.shareAnonymousUsage)
        XCTAssertEqual(launch.snapshot.status, .enabled)
    }

    func testProviderImageScreenModelDelegatesImageLoading() {
        let expectedImage = NSImage(size: NSSize(width: 24, height: 24))
        var requestedName: String?
        var requestedSize: CGFloat?
        let model = ProviderImageScreenModel { name, size in
            requestedName = name
            requestedSize = size
            return expectedImage
        }

        let image = model.image(named: "ClaudeLogo", size: 24)

        XCTAssertTrue(image === expectedImage)
        XCTAssertEqual(requestedName, "ClaudeLogo")
        XCTAssertEqual(requestedSize, 24)
    }
}

@MainActor
private final class ApplicationUpdateControllerFake: ApplicationUpdateControlling {
    var snapshot = ApplicationUpdateSnapshot()
    var automaticallyChecksForUpdates = true
    private(set) var checkCount = 0
    private(set) var channels: [UpdateChannel] = []
    private var handler: (@MainActor (ApplicationUpdateSnapshot) -> Void)?

    func initializeIfNeeded() {}
    func checkForUpdates() { checkCount += 1 }
    func checkForUpdatesInBackground() {}
    func setChannel(_ channel: UpdateChannel) { channels.append(channel) }
    func setDidChangeHandler(
        _ handler: (@MainActor (ApplicationUpdateSnapshot) -> Void)?
    ) { self.handler = handler }
    func publish() { handler?(snapshot) }
}

@MainActor
private final class NotificationControllerFake: NotificationRequesting {
    var snapshot = NotificationSettingsSnapshot(preferences: NotificationPreferences())
    private var handler: (@MainActor (NotificationSettingsSnapshot) -> Void)?

    func requestAuthorization() async {}
    func refreshAuthorizationStatus() async {}
    func submit(_ notification: SemanticNotification) {}
    func clearQuotaNotification(provider: String, account: String) {}
    func clearCoolingNotification(provider: String, account: String) {}
    func clearUpdateNotification(version: String) {}
    func suppressUpdateNotification(version: String) {}
    func clearAllTracking() {}
    func updatePreferences(_ preferences: NotificationPreferences) {
        snapshot.preferences = preferences
        handler?(snapshot)
    }
    func setDidChangeHandler(
        _ handler: (@MainActor (NotificationSettingsSnapshot) -> Void)?
    ) { self.handler = handler }
}

@MainActor
private final class TelemetryControllerFake: TelemetryControlling {
    var preferences = TelemetryPreferences()
    private var handler: (@MainActor (TelemetryPreferences) -> Void)?

    func prepareForLaunch() {}
    func setConsent(_ consented: Bool) {
        preferences.shareAnonymousUsage = consented
        handler?(preferences)
    }
    func setDidChangeHandler(
        _ handler: (@MainActor (TelemetryPreferences) -> Void)?
    ) { self.handler = handler }
}

@MainActor
private final class LaunchAtLoginControllerFake: LaunchAtLoginControlling {
    var snapshot = LaunchAtLoginSnapshot(status: .notRegistered, isInApplicationsFolder: true)
    private var handler: (@MainActor (LaunchAtLoginSnapshot) -> Void)?

    func refresh() {}
    func setEnabled(_ enabled: Bool) throws {
        snapshot.status = enabled ? .enabled : .notRegistered
        handler?(snapshot)
    }
    func openSystemSettings() {}
    func setDidChangeHandler(
        _ handler: (@MainActor (LaunchAtLoginSnapshot) -> Void)?
    ) { self.handler = handler }
}
