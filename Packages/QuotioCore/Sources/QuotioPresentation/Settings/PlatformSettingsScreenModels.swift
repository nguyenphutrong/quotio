import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class ApplicationUpdateScreenModel {
    public private(set) var snapshot: ApplicationUpdateSnapshot
    private let controller: any ApplicationUpdateControlling

    public init(controller: any ApplicationUpdateControlling) {
        self.controller = controller
        self.snapshot = controller.snapshot
        controller.setDidChangeHandler { [weak self] snapshot in
            self?.snapshot = snapshot
        }
    }

    public var automaticallyChecksForUpdates: Bool {
        get { controller.automaticallyChecksForUpdates }
        set { controller.automaticallyChecksForUpdates = newValue }
    }

    public func initializeIfNeeded() {
        controller.initializeIfNeeded()
    }

    public func checkForUpdates() {
        controller.checkForUpdates()
    }

    public func checkForUpdatesInBackground() {
        controller.checkForUpdatesInBackground()
    }

    public func setChannel(_ channel: UpdateChannel) {
        controller.setChannel(channel)
    }
}

@MainActor
@Observable
public final class NotificationSettingsScreenModel {
    public private(set) var snapshot: NotificationSettingsSnapshot
    private let controller: any NotificationRequesting

    public init(controller: any NotificationRequesting) {
        self.controller = controller
        self.snapshot = controller.snapshot
        controller.setDidChangeHandler { [weak self] snapshot in
            self?.snapshot = snapshot
        }
    }

    public func requestAuthorization() async {
        await controller.requestAuthorization()
    }

    public func refreshAuthorizationStatus() async {
        await controller.refreshAuthorizationStatus()
    }

    public func update(_ change: (inout NotificationPreferences) -> Void) {
        var preferences = snapshot.preferences
        change(&preferences)
        controller.updatePreferences(preferences)
    }
}

@MainActor
@Observable
public final class TelemetryConsentScreenModel {
    public private(set) var preferences: TelemetryPreferences
    private let controller: any TelemetryControlling

    public init(controller: any TelemetryControlling) {
        self.controller = controller
        self.preferences = controller.preferences
        controller.setDidChangeHandler { [weak self] preferences in
            self?.preferences = preferences
        }
    }

    public func setConsent(_ consented: Bool) {
        controller.setConsent(consented)
    }
}

@MainActor
@Observable
public final class LaunchAtLoginScreenModel {
    public private(set) var snapshot: LaunchAtLoginSnapshot
    public private(set) var errorMessage: String?
    private let controller: any LaunchAtLoginControlling
    private let failureMessage: (LaunchAtLoginFailure) -> String

    public init(
        controller: any LaunchAtLoginControlling,
        failureMessage: @escaping (LaunchAtLoginFailure) -> String = { failure in
            switch failure {
            case .registrationFailed(let reason), .unregistrationFailed(let reason): reason
            }
        }
    ) {
        self.controller = controller
        self.failureMessage = failureMessage
        self.snapshot = controller.snapshot
        controller.setDidChangeHandler { [weak self] snapshot in
            self?.snapshot = snapshot
        }
    }

    public func refresh() {
        controller.refresh()
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        do {
            try controller.setEnabled(enabled)
            errorMessage = nil
            return true
        } catch let failure as LaunchAtLoginFailure {
            errorMessage = failureMessage(failure)
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func clearError() {
        errorMessage = nil
    }

    public func openSystemSettings() {
        controller.openSystemSettings()
    }
}

@MainActor
@Observable
public final class PlatformActionScreenModel: Sendable {
    private let urlOpener: any URLOpening

    public init(urlOpener: any URLOpening) {
        self.urlOpener = urlOpener
    }

    @discardableResult
    public func open(_ url: URL) -> Bool {
        urlOpener.open(url)
    }
}

@MainActor
@Observable
public final class PasteboardScreenModel: Sendable {
    private let writer: any PasteboardWriting

    public init(writer: any PasteboardWriting) {
        self.writer = writer
    }

    public func copy(_ value: String) {
        writer.copy(value)
    }
}
