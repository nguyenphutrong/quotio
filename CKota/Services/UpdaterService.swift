//
//  UpdaterService.swift
//  CKota
//
//  Auto-update service using Sparkle framework
//

import Foundation
import Sparkle

/// Manages application updates using Sparkle framework
@MainActor
@Observable
final class UpdaterService: NSObject {
    // MARK: - Properties

    private var updaterController: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { updaterController?.updater }

    /// Whether automatic update checks are enabled
    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? true }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// Last time updates were checked
    var lastUpdateCheckDate: Date? {
        updater?.lastUpdateCheckDate
    }

    /// Whether an update check is currently in progress
    private(set) var isCheckingForUpdates = false

    /// Whether the updater can check for updates
    var canCheckForUpdates: Bool {
        updater?.canCheckForUpdates ?? false
    }

    // MARK: - Singleton

    static let shared = UpdaterService()

    // MARK: - Initialization

    override init() {
        super.init()

        // Initialize Sparkle updater controller
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    // MARK: - Public Methods

    /// Manually check for updates
    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        isCheckingForUpdates = true
        updater?.checkForUpdates()
    }

    /// Check for updates in background (no UI if no update)
    func checkForUpdatesInBackground() {
        updater?.checkForUpdatesInBackground()
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterService: SPUUpdaterDelegate {
    nonisolated func feedURLString(for _: SPUUpdater) -> String? {
        // Use GitHub releases for appcast
        "https://github.com/synh/CKota/releases/latest/download/appcast.xml"
    }

    nonisolated func updaterDidFinishUpdateCycleForUpdateCheck(_: SPUUpdater) throws {
        Task { @MainActor in
            self.isCheckingForUpdates = false
        }
    }

    nonisolated func updater(_: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            self.isCheckingForUpdates = false
            print("[UpdaterService] Update check aborted: \(error.localizedDescription)")
        }
    }
}
