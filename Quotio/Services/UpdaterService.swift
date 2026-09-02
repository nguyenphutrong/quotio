//
//  UpdaterService.swift
//  Quotio
//
//  Auto-update service using Sparkle framework
//

import AppKit
import Foundation
import QuotioApplication
import QuotioDomain
import QuotioInfrastructure
import Sparkle

// MARK: - UpdaterService

/// Manages application updates using Sparkle framework
@MainActor
@Observable
final class UpdaterService: NSObject {
    
    // MARK: - Properties
    
    private var updaterController: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { updaterController?.updater }
    @ObservationIgnored private let preferencesRepository: any UpdatePreferencesRepository
    
    private(set) var isInitialized = false
    
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
        guard isInitialized else { return false }
        return updater?.canCheckForUpdates ?? false
    }
    
    /// Current app icon (observable for SwiftUI views)
    private(set) var currentAppIcon: NSImage?
    
    var updateChannel: UpdateChannel {
        didSet {
            preferencesRepository.save(UpdatePreferences(channel: updateChannel))
            updater?.resetUpdateCycle()
            updateAppIcon()
        }
    }
    
    // MARK: - Singleton
    
    static let shared = UpdaterService(
        preferencesRepository: UserDefaultsUpdatePreferencesRepository()
    )
    
    // MARK: - Initialization
    
    init(preferencesRepository: any UpdatePreferencesRepository) {
        self.preferencesRepository = preferencesRepository
        self.updateChannel = preferencesRepository.load().channel
        super.init()
        updateAppIcon()
    }
    
    /// Initialize Sparkle updater on-demand (memory optimization)
    func initializeIfNeeded() {
        guard !isInitialized else { return }
        
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        isInitialized = true
    }
    
    // MARK: - Public Methods
    
    /// Manually check for updates
    func checkForUpdates() {
        initializeIfNeeded()
        guard canCheckForUpdates else { return }
        isCheckingForUpdates = true
        updater?.checkForUpdates()
    }
    
    /// Check for updates in background (no UI if no update)
    func checkForUpdatesInBackground() {
        initializeIfNeeded()
        updater?.checkForUpdatesInBackground()
    }
    
    // MARK: - Icon Management
    
    func updateAppIcon() {
        let channel = updateChannel
        let iconName = channel == .beta ? "AppIconBetaImage" : "AppIconImage"
        
        guard let iconImage = NSImage(named: iconName) else {
            NSApplication.shared.applicationIconImage = nil
            currentAppIcon = NSApplication.shared.applicationIconImage
                ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            return
        }
        
        let displaySize = NSSize(width: 256, height: 256)
        let roundedIcon = NSImage(size: displaySize, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.height * 0.22)
            path.addClip()
            iconImage.draw(in: rect)
            return true
        }
        
        self.currentAppIcon = roundedIcon

        if channel == .beta {
            NSApplication.shared.applicationIconImage = roundedIcon
        } else {
            // Restore the bundle icon so macOS can apply the system icon appearance.
            NSApplication.shared.applicationIconImage = nil
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterService: SPUUpdaterDelegate {
    
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        return "https://github.com/nguyenphutrong/quotio/releases/latest/download/appcast.xml"
    }
    
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let channel = preferencesRepository.load().channel
        return channel == .beta ? Set(["beta"]) : Set()
    }
    
    nonisolated func updaterDidFinishUpdateCycleForUpdateCheck(_ updater: SPUUpdater) throws {
        Task { @MainActor in
            self.isCheckingForUpdates = false
        }
    }
    
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            self.isCheckingForUpdates = false
            Log.update("Update check aborted: \\(error.localizedDescription)")
        }
    }
}
