//
//  TelemetrySettings.swift
//  Quotio
//
//  Stores the user's anonymous usage sharing preference.
//

import Foundation
import QuotioApplication
import QuotioDomain
import QuotioInfrastructure

@MainActor
@Observable
final class TelemetrySettings {
    static let shared = TelemetrySettings(
        repository: UserDefaultsTelemetryPreferencesRepository()
    )

    @ObservationIgnored private let repository: any TelemetryPreferencesRepository
    @ObservationIgnored private var sharingPreferenceChanged: () -> Void = {}

    var shareAnonymousUsage: Bool {
        didSet {
            persist()
            sharingPreferenceChanged()
        }
    }

    private(set) var anonymousInstallID: String?

    var hasSentFirstOptInLaunch: Bool {
        didSet { persist() }
    }

    init(repository: any TelemetryPreferencesRepository) {
        self.repository = repository
        let preferences = repository.load()
        self.shareAnonymousUsage = preferences.shareAnonymousUsage
        self.anonymousInstallID = preferences.anonymousInstallID
        self.hasSentFirstOptInLaunch = preferences.hasSentFirstOptInLaunch
    }

    func onSharingPreferenceChanged(_ action: @escaping () -> Void) {
        sharingPreferenceChanged = action
    }

    func ensureAnonymousInstallID() -> String {
        if let existing = anonymousInstallID, !existing.isEmpty {
            return existing
        }

        let newID = UUID().uuidString.lowercased()
        anonymousInstallID = newID
        persist()
        return newID
    }

    func resetAnonymousInstallID() {
        anonymousInstallID = nil
        hasSentFirstOptInLaunch = false
        persist()
    }

    private func persist() {
        repository.save(
            TelemetryPreferences(
                shareAnonymousUsage: shareAnonymousUsage,
                anonymousInstallID: anonymousInstallID,
                hasSentFirstOptInLaunch: hasSentFirstOptInLaunch
            )
        )
    }
}
