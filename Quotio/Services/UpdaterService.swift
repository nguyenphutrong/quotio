//
//  UpdaterService.swift
//  Quotio
//
//  Auto-update service using Sparkle framework
//

import AppKit
import Foundation
import Sparkle

// MARK: - Update Channel

enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case beta
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .stable: return "settings.updateChannel.stable".localizedStatic()
        case .beta: return "settings.updateChannel.beta".localizedStatic()
        }
    }
    
    var icon: String {
        switch self {
        case .stable: return "checkmark.shield"
        case .beta: return "flask.fill"
        }
    }
}

// MARK: - UpdaterService

/// Manages application updates using Sparkle framework
@MainActor
@Observable
final class UpdaterService: NSObject {
    
    // MARK: - Properties
    
    private var updaterController: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { updaterController?.updater }
    
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
        get {
            let rawValue = UserDefaults.standard.string(forKey: "updateChannel") ?? "stable"
            return UpdateChannel(rawValue: rawValue) ?? .stable
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "updateChannel")
            updater?.resetUpdateCycle()
            updateAppIcon()
        }
    }
    
    // MARK: - Singleton
    
    static let shared = UpdaterService()
    
    // MARK: - Initialization
    
    override init() {
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
        let iconName = updateChannel == .beta ? "AppIconBetaImage" : "AppIconImage"
        
        guard let iconImage = NSImage(named: iconName) else { return }
        
        let displaySize = NSSize(width: 256, height: 256)
        let roundedIcon = NSImage(size: displaySize, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.height * 0.22)
            path.addClip()
            iconImage.draw(in: rect)
            return true
        }
        
        self.currentAppIcon = roundedIcon
        NSApplication.shared.applicationIconImage = roundedIcon
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterService: SPUUpdaterDelegate {
    
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        return "https://github.com/nguyenphutrong/quotio/releases/latest/download/appcast.xml"
    }
    
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let channel = UserDefaults.standard.string(forKey: "updateChannel") ?? "stable"
        return channel == "beta" ? Set(["beta"]) : Set()
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
