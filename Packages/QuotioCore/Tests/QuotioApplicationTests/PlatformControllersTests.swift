import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain

@MainActor
final class PlatformControllersTests: XCTestCase {
    func testApplicationUpdateControllerLoadsChannelAndAppliesChanges() {
        let checker = UpdateCheckerFake()
        let preferences = PlatformPreferencesFake(update: UpdatePreferences(channel: .beta))
        let icon = UpdaterIconFake()
        let controller = ApplicationUpdateController(
            checker: checker,
            preferencesRepository: preferences,
            icon: icon
        )

        XCTAssertEqual(controller.snapshot.channel, .beta)
        XCTAssertEqual(checker.allowsPrereleaseUpdates, true)
        XCTAssertEqual(icon.channels, [.beta])

        controller.setChannel(.stable)

        XCTAssertEqual(preferences.update, UpdatePreferences(channel: .stable))
        XCTAssertEqual(checker.allowsPrereleaseUpdates, false)
        XCTAssertEqual(checker.resetCount, 1)
        XCTAssertEqual(icon.channels, [.beta, .stable])
    }

    func testApplicationUpdateControllerPublishesCheckerState() {
        let checker = UpdateCheckerFake()
        let controller = ApplicationUpdateController(
            checker: checker,
            preferencesRepository: PlatformPreferencesFake(),
            icon: UpdaterIconFake()
        )
        var snapshots: [ApplicationUpdateSnapshot] = []
        controller.setDidChangeHandler { snapshots.append($0) }

        controller.initializeIfNeeded()
        checker.isChecking = true
        checker.publish()

        XCTAssertEqual(snapshots.last?.isInitialized, true)
        XCTAssertEqual(snapshots.last?.isChecking, true)
    }

    func testTelemetryDoesNotTouchTrackerWithoutExplicitConsent() {
        let preferences = PlatformPreferencesFake(telemetry: TelemetryPreferences(
            shareAnonymousUsage: false,
            anonymousInstallID: "00000000-0000-0000-0000-000000000001",
            hasSentFirstOptInLaunch: true
        ))
        let tracker = TelemetryTrackerFake()
        let controller = TelemetryController(
            repository: preferences,
            tracker: tracker,
            contextProvider: TelemetryContextProviderFake(),
            updatePreferencesRepository: preferences
        )

        controller.prepareForLaunch()

        XCTAssertEqual(tracker.operations, [])
        XCTAssertNil(preferences.telemetry.anonymousInstallID)
        XCTAssertFalse(preferences.telemetry.hasSentFirstOptInLaunch)
    }

    func testTelemetryConsentConfiguresBeforeIdentifyCaptureAndFlush() {
        let installID = "00000000-0000-0000-0000-000000000001"
        let preferences = PlatformPreferencesFake(telemetry: TelemetryPreferences(
            shareAnonymousUsage: false,
            anonymousInstallID: installID
        ))
        let tracker = TelemetryTrackerFake()
        let controller = TelemetryController(
            repository: preferences,
            tracker: tracker,
            contextProvider: TelemetryContextProviderFake(),
            updatePreferencesRepository: preferences
        )

        controller.setConsent(true)

        XCTAssertEqual(tracker.operations, [
            "configure",
            "identify:\(installID)",
            "capture:first_opted_in_launch",
            "capture:app_started",
            "capture:app_version_active",
            "flush",
        ])
        XCTAssertTrue(preferences.telemetry.shareAnonymousUsage)
        XCTAssertTrue(preferences.telemetry.hasSentFirstOptInLaunch)

        controller.setConsent(false)

        XCTAssertEqual(tracker.operations.last, "stopAndReset")
        XCTAssertNil(preferences.telemetry.anonymousInstallID)
        XCTAssertFalse(preferences.telemetry.hasSentFirstOptInLaunch)
    }

    func testTelemetryDoesNotCreateInstallIdentifierWhenTrackerCannotConfigure() {
        let preferences = PlatformPreferencesFake(telemetry: TelemetryPreferences(
            shareAnonymousUsage: true
        ))
        let tracker = TelemetryTrackerFake()
        tracker.configureResult = false
        let controller = TelemetryController(
            repository: preferences,
            tracker: tracker,
            contextProvider: TelemetryContextProviderFake(),
            updatePreferencesRepository: preferences
        )

        controller.prepareForLaunch()

        XCTAssertEqual(tracker.operations, ["configure"])
        XCTAssertNil(preferences.telemetry.anonymousInstallID)
        XCTAssertFalse(preferences.telemetry.hasSentFirstOptInLaunch)
    }

    func testNotificationAuthorizationPreferenceThresholdAndDeduplication() async {
        let preferences = PlatformPreferencesFake()
        let delivery = NotificationDeliveryFake(authorizationStatus: .authorized)
        let controller = NotificationController(repository: preferences, delivery: delivery)

        controller.submit(.quotaLow(provider: "Claude", account: "work", remainingPercent: 10))
        XCTAssertEqual(delivery.delivered, [])

        await controller.refreshAuthorizationStatus()
        controller.submit(.quotaLow(provider: "Claude", account: "work", remainingPercent: 21))
        XCTAssertEqual(delivery.delivered, [])

        let notification = SemanticNotification.quotaLow(
            provider: "Claude",
            account: "work",
            remainingPercent: 20
        )
        controller.submit(notification)
        controller.submit(notification)
        XCTAssertEqual(delivery.delivered, [notification])

        controller.clearQuotaNotification(provider: "Claude", account: "work")
        controller.submit(notification)
        XCTAssertEqual(delivery.delivered, [notification, notification])

        var disabled = controller.snapshot.preferences
        disabled.notifyOnQuotaLow = false
        controller.updatePreferences(disabled)
        controller.clearQuotaNotification(provider: "Claude", account: "work")
        controller.submit(notification)
        XCTAssertEqual(delivery.delivered, [notification, notification])
        XCTAssertEqual(preferences.notification, disabled)
    }

    func testNotificationAuthorizationRequestPublishesResult() async {
        let delivery = NotificationDeliveryFake(authorizationStatus: .denied)
        let controller = NotificationController(
            repository: PlatformPreferencesFake(),
            delivery: delivery
        )

        await controller.requestAuthorization()

        XCTAssertEqual(controller.snapshot.authorizationStatus, .denied)
        XCTAssertEqual(delivery.authorizationRequestCount, 1)
    }

    func testProxyNotificationRelayPreservesSemanticUpgradeFailure() async {
        let notifications = PollingNotificationFake()
        let relay = ProxyNotificationRelay(notifications: notifications)
        let failure = ProxyFailure.checksumMismatch(expected: "expected", actual: "actual")

        await relay.deliver(.upgradeFailed(version: "2.0.0", failure: failure))

        XCTAssertEqual(
            notifications.submitted,
            [.proxyUpdateFailed(version: "2.0.0", failure: failure)]
        )
    }

    func testLaunchAtLoginControllerSkipsRedundantRegistrationAndSurfacesFailures() {
        let registration = LaunchAtLoginRegistrationFake(status: .enabled)
        let controller = LaunchAtLoginController(
            registration: registration,
            urlOpener: URLOpenerFake()
        )

        XCTAssertNoThrow(try controller.setEnabled(true))
        XCTAssertEqual(registration.registerCount, 0)

        registration.status = .notRegistered
        registration.registerError = TestFailure.expected
        XCTAssertThrowsError(try controller.setEnabled(true)) { error in
            guard case .registrationFailed = error as? LaunchAtLoginFailure else {
                return XCTFail("Expected registration failure")
            }
        }
        XCTAssertEqual(controller.snapshot.status, .notRegistered)
    }

    func testProxyUpdatePollingPersistsAndDeduplicatesAvailableVersionNotifications() async {
        let proxy = PollingProxyFake(version: "2.0.0")
        let notifications = PollingNotificationFake()
        let record = ProxyUpdateNotificationRecordFake()
        let sleeper = ControlledPollingSleeper()
        let controller = ProxyUpdatePollingController(
            proxy: proxy,
            notifications: notifications,
            notificationRecord: record,
            sleeper: sleeper,
            initialDelay: .seconds(1),
            pollingInterval: .seconds(2)
        )

        await controller.start()
        let didBeginInitialDelay = await eventually {
            await sleeper.waitingCount(for: .seconds(1)) == 1
        }
        XCTAssertTrue(didBeginInitialDelay)

        await sleeper.resumeFirst(for: .seconds(1))
        let didSubmitNotification = await eventually { notifications.submitted.count == 1 }
        XCTAssertTrue(didSubmitNotification)
        XCTAssertEqual(record.lastNotifiedVersion(), "2.0.0")
        XCTAssertEqual(
            notifications.submitted,
            [.proxyUpdateAvailable(version: "2.0.0")]
        )

        let didBeginPollingDelay = await eventually {
            await sleeper.waitingCount(for: .seconds(2)) == 1
        }
        XCTAssertTrue(didBeginPollingDelay)
        await sleeper.resumeFirst(for: .seconds(2))
        let didCheckAgain = await eventually { await proxy.checkCount == 2 }
        XCTAssertTrue(didCheckAgain)
        XCTAssertEqual(notifications.submitted.count, 1)

        await controller.stop()
    }

    func testStoppingProxyUpdatePollingCancelsPendingInitialDelay() async {
        let proxy = PollingProxyFake(version: "2.0.0")
        let notifications = PollingNotificationFake()
        let sleeper = ControlledPollingSleeper()
        let controller = ProxyUpdatePollingController(
            proxy: proxy,
            notifications: notifications,
            notificationRecord: ProxyUpdateNotificationRecordFake(),
            sleeper: sleeper,
            initialDelay: .seconds(1),
            pollingInterval: .seconds(2)
        )

        await controller.start()
        let didBeginInitialDelay = await eventually {
            await sleeper.waitingCount(for: .seconds(1)) == 1
        }
        XCTAssertTrue(didBeginInitialDelay)

        await controller.stop()

        let didCancelInitialDelay = await eventually {
            await sleeper.waitingCount(for: .seconds(1)) == 0
        }
        XCTAssertTrue(didCancelInitialDelay)
        let checkCount = await proxy.checkCount
        XCTAssertEqual(checkCount, 0)
        XCTAssertTrue(notifications.submitted.isEmpty)
    }

    private func eventually(
        attempts: Int = 500,
        condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }
}

@MainActor
private final class UpdateCheckerFake: ApplicationUpdateChecking {
    var isInitialized = false
    var isChecking = false
    var canCheck = true
    var lastCheckDate: Date?
    var automaticallyChecksForUpdates = true
    var allowsPrereleaseUpdates = false
    var resetCount = 0
    private var handler: (@MainActor () -> Void)?

    func setAllowsPrereleaseUpdates(_ allowed: Bool) { allowsPrereleaseUpdates = allowed }
    func initializeIfNeeded() { isInitialized = true; publish() }
    func checkForUpdates() { isChecking = true; publish() }
    func checkForUpdatesInBackground() { publish() }
    func resetUpdateCycle() { resetCount += 1 }
    func setDidChangeHandler(_ handler: (@MainActor () -> Void)?) { self.handler = handler }
    func publish() { handler?() }
}

@MainActor
private final class UpdaterIconFake: UpdaterIconApplying {
    private(set) var channels: [UpdateChannel] = []
    func applyUpdateChannel(_ channel: UpdateChannel) { channels.append(channel) }
}

private final class PlatformPreferencesFake:
    UpdatePreferencesRepository,
    TelemetryPreferencesRepository,
    NotificationPreferencesRepository,
    @unchecked Sendable
{
    var update: UpdatePreferences
    var telemetry: TelemetryPreferences
    var notification: NotificationPreferences

    init(
        update: UpdatePreferences = UpdatePreferences(),
        telemetry: TelemetryPreferences = TelemetryPreferences(),
        notification: NotificationPreferences = NotificationPreferences()
    ) {
        self.update = update
        self.telemetry = telemetry
        self.notification = notification
    }

    func load() -> UpdatePreferences { update }
    func save(_ preferences: UpdatePreferences) { update = preferences }
    func load() -> TelemetryPreferences { telemetry }
    func save(_ preferences: TelemetryPreferences) { telemetry = preferences }
    func load() -> NotificationPreferences { notification }
    func save(_ preferences: NotificationPreferences) { notification = preferences }
}

@MainActor
private final class TelemetryTrackerFake: TelemetryTracking {
    private(set) var operations: [String] = []
    var configureResult = true

    func configure() -> Bool { operations.append("configure"); return configureResult }
    func identify(_ anonymousInstallID: String, properties: [String: String]) {
        operations.append("identify:\(anonymousInstallID)")
    }
    func capture(_ payload: TelemetryPayload) {
        operations.append("capture:\(payload.event.rawValue)")
    }
    func flush() { operations.append("flush") }
    func stopAndReset() { operations.append("stopAndReset") }
}

private struct TelemetryContextProviderFake: TelemetryRuntimeContextProviding {
    func context(updateChannel: UpdateChannel) -> TelemetryRuntimeContext? {
        TelemetryRuntimeContext(
            appVersion: "1.2.3",
            buildNumber: "45",
            bundleIdentifier: "com.example.quotio",
            macOSVersion: "Version 26.0",
            updateChannel: updateChannel
        )
    }
}

@MainActor
private final class NotificationDeliveryFake: NotificationDelivering {
    var authorizationStatusValue: NotificationAuthorizationStatus
    private(set) var authorizationRequestCount = 0
    private(set) var delivered: [SemanticNotification] = []

    init(authorizationStatus: NotificationAuthorizationStatus) {
        self.authorizationStatusValue = authorizationStatus
    }

    func requestAuthorization() async -> NotificationAuthorizationStatus {
        authorizationRequestCount += 1
        return authorizationStatusValue
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        authorizationStatusValue
    }

    func deliver(_ notification: SemanticNotification) { delivered.append(notification) }
    func removeAllPending() {}
    func removeAllDelivered() {}
}

@MainActor
private final class LaunchAtLoginRegistrationFake: LaunchAtLoginRegistering {
    var status: LaunchAtLoginStatus
    var isInApplicationsFolder = true
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

private actor PollingProxyFake: ProxyControlling {
    private let paths = ProxyPaths(
        legacyBinaryPath: "/legacy",
        configPath: "/config",
        authDirectoryPath: "/auth",
        expectedBinaryPath: "/current"
    )
    private let version: String
    private(set) var checkCount = 0

    init(version: String) {
        self.version = version
    }

    func snapshots() -> AsyncStream<ProxySnapshot> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func snapshot() -> ProxySnapshot {
        ProxySnapshot(
            paths: paths,
            availableUpgrade: ProxyVersionInfo(version: version, sha256: "checksum")
        )
    }

    func checkForUpgrade() { checkCount += 1 }
    func initialize() {}
    func start() throws {}
    func stop() {}
    func stopAndWait() {}
    func restart() throws {}
    func shutdown() {}
    func installLatest() throws {}
    func availableVersions(limit: Int) throws -> [ProxyVersionInfo] { [] }
    func install(_ version: ProxyVersionInfo) throws {}
    func activate(version: String) throws {}
    func delete(version: String) throws {}
    func rollback() throws {}
    func versionsToDeleteAfterInstalling(keeping count: Int) -> [String] { [] }
    func setPort(_ port: UInt16) {}
    func setNetworkAccess(_ enabled: Bool) {}
    func setRemoteAccess(_ enabled: Bool) {}
    func setLogging(_ enabled: Bool) {}
    func setRoutingStrategy(_ strategy: String) {}
    func setProxyURL(_ url: String?) {}
    func regenerateManagementKey() throws {}
}

@MainActor
private final class PollingNotificationFake: NotificationRequesting {
    private(set) var submitted: [SemanticNotification] = []
    var snapshot = NotificationSettingsSnapshot(preferences: NotificationPreferences())

    func requestAuthorization() async {}
    func refreshAuthorizationStatus() async {}
    func submit(_ notification: SemanticNotification) { submitted.append(notification) }
    func clearQuotaNotification(provider: String, account: String) {}
    func clearCoolingNotification(provider: String, account: String) {}
    func clearUpdateNotification(version: String) {}
    func suppressUpdateNotification(version: String) {}
    func clearAllTracking() {}
    func updatePreferences(_ preferences: NotificationPreferences) {}
    func setDidChangeHandler(_ handler: (@MainActor (NotificationSettingsSnapshot) -> Void)?) {}
}

private final class ProxyUpdateNotificationRecordFake: ProxyUpdateNotificationRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var version: String?

    func lastNotifiedVersion() -> String? {
        lock.withLock { version }
    }

    func saveLastNotifiedVersion(_ version: String) {
        lock.withLock { self.version = version }
    }
}

private actor ControlledPollingSleeper: Sleeping {
    private struct Waiter {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(
                        id: id,
                        duration: duration,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitingCount(for duration: Duration) -> Int {
        waiters.count { $0.duration == duration }
    }

    func resumeFirst(for duration: Duration) {
        guard let index = waiters.firstIndex(where: { $0.duration == duration }) else {
            return
        }
        waiters.remove(at: index).continuation.resume()
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private final class URLOpenerFake: URLOpening {
    func open(_ url: URL) -> Bool { true }
}

private enum TestFailure: Error {
    case expected
}
