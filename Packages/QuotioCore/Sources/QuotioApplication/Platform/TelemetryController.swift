import Foundation
import QuotioDomain

@MainActor
public final class TelemetryController: TelemetryControlling {
    private let repository: any TelemetryPreferencesRepository
    private let tracker: any TelemetryTracking
    private let contextProvider: any TelemetryRuntimeContextProviding
    private let updatePreferencesRepository: any UpdatePreferencesRepository
    private var didChangeHandler: (@MainActor (TelemetryPreferences) -> Void)?
    private var isStarted = false

    public private(set) var preferences: TelemetryPreferences

    public init(
        repository: any TelemetryPreferencesRepository,
        tracker: any TelemetryTracking,
        contextProvider: any TelemetryRuntimeContextProviding,
        updatePreferencesRepository: any UpdatePreferencesRepository
    ) {
        self.repository = repository
        self.tracker = tracker
        self.contextProvider = contextProvider
        self.updatePreferencesRepository = updatePreferencesRepository
        self.preferences = repository.load()
    }

    public func prepareForLaunch() {
        guard preferences.shareAnonymousUsage else {
            resetIdentity()
            return
        }
        startIfPossible()
    }

    public func setConsent(_ consented: Bool) {
        guard preferences.shareAnonymousUsage != consented else { return }
        preferences.shareAnonymousUsage = consented
        persist()

        if consented {
            startIfPossible()
        } else {
            if isStarted {
                tracker.stopAndReset()
            }
            isStarted = false
            resetIdentity()
        }
        publish()
    }

    public func setDidChangeHandler(
        _ handler: (@MainActor (TelemetryPreferences) -> Void)?
    ) {
        didChangeHandler = handler
        handler?(preferences)
    }

    private func startIfPossible() {
        guard preferences.shareAnonymousUsage else { return }
        guard let context = contextProvider.context(
            updateChannel: updatePreferencesRepository.load().channel
        ), tracker.configure() else {
            return
        }
        let installID = validatedInstallID()
        guard let firstLaunch = TelemetryPayload(
            event: .firstOptedInLaunch,
            anonymousInstallID: installID,
            context: context
        ),
        let appStarted = TelemetryPayload(
            event: .appStarted,
            anonymousInstallID: installID,
            context: context
        ),
        let versionActive = TelemetryPayload(
            event: .appVersionActive,
            anonymousInstallID: installID,
            context: context
        ) else {
            return
        }

        isStarted = true
        tracker.identify(installID, properties: appStarted.properties)
        if !preferences.hasSentFirstOptInLaunch {
            tracker.capture(firstLaunch)
            preferences.hasSentFirstOptInLaunch = true
            persist()
        }
        tracker.capture(appStarted)
        tracker.capture(versionActive)
        tracker.flush()
        publish()
    }

    private func validatedInstallID() -> String {
        if let existing = preferences.anonymousInstallID,
           UUID(uuidString: existing) != nil {
            return existing.lowercased()
        }
        let created = UUID().uuidString.lowercased()
        preferences.anonymousInstallID = created
        persist()
        return created
    }

    private func resetIdentity() {
        preferences.anonymousInstallID = nil
        preferences.hasSentFirstOptInLaunch = false
        persist()
        publish()
    }

    private func persist() {
        repository.save(preferences)
    }

    private func publish() {
        didChangeHandler?(preferences)
    }
}
