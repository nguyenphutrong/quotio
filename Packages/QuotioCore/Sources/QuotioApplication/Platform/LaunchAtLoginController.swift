import Foundation
import QuotioDomain

@MainActor
public final class LaunchAtLoginController: LaunchAtLoginControlling {
    private static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    )!

    private let registration: any LaunchAtLoginRegistering
    private let urlOpener: any URLOpening
    private var didChangeHandler: (@MainActor (LaunchAtLoginSnapshot) -> Void)?

    public private(set) var snapshot: LaunchAtLoginSnapshot

    public init(
        registration: any LaunchAtLoginRegistering,
        urlOpener: any URLOpening
    ) {
        self.registration = registration
        self.urlOpener = urlOpener
        self.snapshot = LaunchAtLoginSnapshot(
            status: registration.status,
            isInApplicationsFolder: registration.isInApplicationsFolder
        )
    }

    public func refresh() {
        snapshot = LaunchAtLoginSnapshot(
            status: registration.status,
            isInApplicationsFolder: registration.isInApplicationsFolder
        )
        didChangeHandler?(snapshot)
    }

    public func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                if !registration.status.isEnabled {
                    try registration.register()
                }
            } else if registration.status != .notRegistered && registration.status != .notFound {
                try registration.unregister()
            }
            refresh()
        } catch {
            refresh()
            throw enabled
                ? LaunchAtLoginFailure.registrationFailed(error.localizedDescription)
                : LaunchAtLoginFailure.unregistrationFailed(error.localizedDescription)
        }
    }

    public func openSystemSettings() {
        urlOpener.open(Self.systemSettingsURL)
    }

    public func setDidChangeHandler(
        _ handler: (@MainActor (LaunchAtLoginSnapshot) -> Void)?
    ) {
        didChangeHandler = handler
        handler?(snapshot)
    }
}
