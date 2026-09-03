import Foundation
import QuotioDomain

@MainActor
public protocol ApplicationUpdateChecking: AnyObject, Sendable {
    var isInitialized: Bool { get }
    var isChecking: Bool { get }
    var canCheck: Bool { get }
    var lastCheckDate: Date? { get }
    var automaticallyChecksForUpdates: Bool { get set }

    func setAllowsPrereleaseUpdates(_ allowed: Bool)
    func initializeIfNeeded()
    func checkForUpdates()
    func checkForUpdatesInBackground()
    func resetUpdateCycle()
    func setDidChangeHandler(_ handler: (@MainActor () -> Void)?)
}

@MainActor
public protocol UpdaterIconApplying: AnyObject, Sendable {
    func applyUpdateChannel(_ channel: UpdateChannel)
}

@MainActor
public protocol ApplicationUpdateControlling: AnyObject, Sendable {
    var snapshot: ApplicationUpdateSnapshot { get }
    var automaticallyChecksForUpdates: Bool { get set }

    func initializeIfNeeded()
    func checkForUpdates()
    func checkForUpdatesInBackground()
    func setChannel(_ channel: UpdateChannel)
    func setDidChangeHandler(_ handler: (@MainActor (ApplicationUpdateSnapshot) -> Void)?)
}

@MainActor
public protocol NotificationDelivering: AnyObject, Sendable {
    func requestAuthorization() async -> NotificationAuthorizationStatus
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func deliver(_ notification: SemanticNotification)
    func removeAllPending()
    func removeAllDelivered()
}

@MainActor
public protocol NotificationRequesting: AnyObject, Sendable {
    var snapshot: NotificationSettingsSnapshot { get }

    func requestAuthorization() async
    func refreshAuthorizationStatus() async
    func submit(_ notification: SemanticNotification)
    func clearQuotaNotification(provider: String, account: String)
    func clearCoolingNotification(provider: String, account: String)
    func clearUpdateNotification(version: String)
    func suppressUpdateNotification(version: String)
    func clearAllTracking()
    func updatePreferences(_ preferences: NotificationPreferences)
    func setDidChangeHandler(_ handler: (@MainActor (NotificationSettingsSnapshot) -> Void)?)
}

public protocol ProxyUpdateNotificationRecording: Sendable {
    func lastNotifiedVersion() -> String?
    func saveLastNotifiedVersion(_ version: String)
}

@MainActor
public protocol TelemetryTracking: AnyObject, Sendable {
    func configure() -> Bool
    func identify(_ anonymousInstallID: String, properties: [String: String])
    func capture(_ payload: TelemetryPayload)
    func flush()
    func stopAndReset()
}

public protocol TelemetryRuntimeContextProviding: Sendable {
    func context(updateChannel: UpdateChannel) -> TelemetryRuntimeContext?
}

@MainActor
public protocol TelemetryControlling: AnyObject, Sendable {
    var preferences: TelemetryPreferences { get }

    func prepareForLaunch()
    func setConsent(_ consented: Bool)
    func setDidChangeHandler(_ handler: (@MainActor (TelemetryPreferences) -> Void)?)
}

@MainActor
public protocol LaunchAtLoginRegistering: AnyObject, Sendable {
    var status: LaunchAtLoginStatus { get }
    var isInApplicationsFolder: Bool { get }

    func register() throws
    func unregister() throws
}

@MainActor
public protocol LaunchAtLoginControlling: AnyObject, Sendable {
    var snapshot: LaunchAtLoginSnapshot { get }

    func refresh()
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
    func setDidChangeHandler(_ handler: (@MainActor (LaunchAtLoginSnapshot) -> Void)?)
}

@MainActor
public protocol ApplicationPlatformControlling: AnyObject, Sendable {
    func applyAppearance(_ mode: AppearanceMode)
    func setDockVisibility(_ visible: Bool)
    func activate()
    func terminate()
}
