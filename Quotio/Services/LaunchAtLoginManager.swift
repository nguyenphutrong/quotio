//
//  LaunchAtLoginManager.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Manages "Launch at Login" functionality using SMAppService.
//  Implements best practices from Rectangle, Stats, and SwiftBar.
//

import AppKit
import Foundation
import ServiceManagement
import os.log

/// Error types for Launch at Login operations
enum LaunchAtLoginError: LocalizedError {
    case appNotInApplicationsFolder
    case registrationFailed(Error)
    case unregistrationFailed(Error)
    case requiresUserApproval
    case unknownStatus(SMAppService.Status)
    
    var errorDescription: String? {
        switch self {
        case .appNotInApplicationsFolder:
            return NSLocalizedString("launchAtLogin.error.notInApplicationsFolder", comment: "")
        case .registrationFailed(let error):
            return NSLocalizedString("launchAtLogin.error.registrationFailed", comment: "") + ": \(error.localizedDescription)"
        case .unregistrationFailed(let error):
            return NSLocalizedString("launchAtLogin.error.unregistrationFailed", comment: "") + ": \(error.localizedDescription)"
        case .requiresUserApproval:
            return NSLocalizedString("launchAtLogin.error.requiresApproval", comment: "")
        case .unknownStatus(let status):
            return NSLocalizedString("launchAtLogin.error.unknownStatus", comment: "") + ": \(status.rawValue)"
        }
    }
}

/// Manages Launch at Login state using SMAppService (macOS 13+)
/// 
/// Best practices implemented:
/// - Unregister before register to fix state inconsistencies
/// - Proper error logging for debugging
/// - App location validation
/// - Status refresh on app launch
/// - Handle .requiresApproval status
@MainActor
@Observable
final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Quotio", category: "LaunchAtLogin")
    
    /// Current enabled state - reflects SMAppService.mainApp.status
    private(set) var isEnabled: Bool = false
    
    /// Last error that occurred during registration/unregistration
    private(set) var lastError: LaunchAtLoginError?
    
    /// Whether the app is in a valid location for launch at login
    var isInValidLocation: Bool {
        guard let appPath = Bundle.main.bundlePath as NSString? else { return false }
        let applicationsPath = "/Applications"
        let userApplicationsPath = NSHomeDirectory() + "/Applications"
        
        return appPath.hasPrefix(applicationsPath) || appPath.hasPrefix(userApplicationsPath)
    }
    
    private init() {
        // Refresh status on initialization
        refreshStatus()
    }
    
    // MARK: - Public API
    
    /// Refresh the current status from system
    /// Call this on app launch to sync with any manual changes in System Settings
    func refreshStatus() {
        let status = SMAppService.mainApp.status
        let wasEnabled = isEnabled
        
        // Consider both .enabled and .requiresApproval as "enabled" states
        // .requiresApproval means user manually added app in System Settings
        isEnabled = (status == .enabled || status == .requiresApproval)
        
        if wasEnabled != isEnabled {
            logger.info("Launch at login status changed: \(self.isEnabled ? "enabled" : "disabled") [status=\(status.rawValue)]")
        }
        
        logger.debug("Launch at login status: \(status.rawValue), isEnabled: \(self.isEnabled)")
    }
    
    /// Enable launch at login
    /// - Throws: LaunchAtLoginError if registration fails
    func enable() throws {
        lastError = nil
        
        // Warn if app is not in /Applications (registration may fail or be non-persistent)
        if !isInValidLocation {
            logger.warning("App is not in /Applications folder. Launch at login may not work correctly.")
        }
        
        let currentStatus = SMAppService.mainApp.status
        
        // If already enabled (either via API or manually by user), don't re-register
        if currentStatus == .enabled || currentStatus == .requiresApproval {
            logger.info("Already enabled for launch at login, skipping registration")
            isEnabled = true
            return
        }
        
        do {
            try SMAppService.mainApp.register()
            isEnabled = true
            logger.info("Successfully registered for launch at login")
            
        } catch {
            let launchError = LaunchAtLoginError.registrationFailed(error)
            lastError = launchError
            logger.error("Failed to register for launch at login: \(error.localizedDescription)")
            throw launchError
        }
    }
    
    /// Disable launch at login
    /// - Throws: LaunchAtLoginError if unregistration fails
    func disable() throws {
        lastError = nil
        
        let currentStatus = SMAppService.mainApp.status
        
        // If already not registered, nothing to do
        if currentStatus == .notRegistered || currentStatus == .notFound {
            logger.info("Already disabled for launch at login, skipping unregistration")
            isEnabled = false
            return
        }
        
        do {
            try SMAppService.mainApp.unregister()
            isEnabled = false
            logger.info("Successfully unregistered from launch at login")
            
        } catch {
            let launchError = LaunchAtLoginError.unregistrationFailed(error)
            lastError = launchError
            logger.error("Failed to unregister from launch at login: \(error.localizedDescription)")
            throw launchError
        }
    }
    
    /// Toggle launch at login state
    /// - Parameter enabled: The desired state
    /// - Throws: LaunchAtLoginError if the operation fails
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }
    
    /// Open System Settings to Login Items page
    /// Use this when user needs to manually approve the app
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - SMAppService.Status Extension

extension SMAppService.Status {
    /// Human-readable description of the status
    var description: String {
        switch self {
        case .notRegistered:
            return "Not Registered"
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires Approval"
        case .notFound:
            return "Not Found"
        @unknown default:
            return "Unknown (\(rawValue))"
        }
    }
}
