//
//  OperatingMode.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Unified operating mode: Monitor (Quota-Only), Local Proxy, Remote Proxy
//  Replaces the two-layer AppMode + ConnectionMode system
//

import Foundation
import SwiftUI

// MARK: - Operating Mode

/// Unified operating mode for Quotio
/// Replaces AppMode + ConnectionMode with a single, user-friendly enum
enum OperatingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case monitor = "monitor"        // Quota tracking only (no proxy)
    case localProxy = "local"       // Run local proxy server
    case remoteProxy = "remote"     // Connect to remote CLIProxyAPI
    
    var id: String { rawValue }
    
    // MARK: - Display Properties
    
    var displayName: String {
        switch self {
        case .monitor: return "onboarding.mode.monitor.title".localizedStatic()
        case .localProxy: return "onboarding.mode.localProxy.title".localizedStatic()
        case .remoteProxy: return "onboarding.mode.remoteProxy.title".localizedStatic()
        }
    }
    
    var description: String {
        switch self {
        case .monitor: return "onboarding.mode.monitor.description".localizedStatic()
        case .localProxy: return "onboarding.mode.localProxy.description".localizedStatic()
        case .remoteProxy: return "onboarding.mode.remoteProxy.description".localizedStatic()
        }
    }
    
    var icon: String {
        switch self {
        case .monitor: return "chart.bar.fill"
        case .localProxy: return "server.rack"
        case .remoteProxy: return "network"
        }
    }
    
    var color: Color {
        switch self {
        case .monitor: return .green
        case .localProxy: return .blue
        case .remoteProxy: return .purple
        }
    }
    
    var badge: String? {
        switch self {
        case .monitor: return "onboarding.mode.badge.default".localizedStatic()
        case .localProxy: return nil
        case .remoteProxy: return "onboarding.mode.badge.advanced".localizedStatic()
        }
    }
    
    // MARK: - Feature Lists
    
    var features: [String] {
        switch self {
        case .monitor:
            return [
                "onboarding.mode.monitor.feature1".localizedStatic(),
                "onboarding.mode.monitor.feature2".localizedStatic(),
                "onboarding.mode.monitor.feature3".localizedStatic()
            ]
        case .localProxy:
            return [
                "onboarding.mode.localProxy.feature1".localizedStatic(),
                "onboarding.mode.localProxy.feature2".localizedStatic(),
                "onboarding.mode.localProxy.feature3".localizedStatic()
            ]
        case .remoteProxy:
            return [
                "onboarding.mode.remoteProxy.feature1".localizedStatic(),
                "onboarding.mode.remoteProxy.feature2".localizedStatic(),
                "onboarding.mode.remoteProxy.feature3".localizedStatic()
            ]
        }
    }
    
    // MARK: - Capability Checks
    
    /// Whether proxy server functionality is available
    var supportsProxy: Bool {
        self != .monitor
    }
    
    /// Whether local proxy controls (start/stop) should be shown
    var supportsProxyControl: Bool {
        self == .localProxy
    }
    
    /// Whether binary upgrade UI should be shown
    var supportsBinaryUpgrade: Bool {
        self == .localProxy
    }
    
    /// Whether port configuration should be shown
    var supportsPortConfig: Bool {
        self == .localProxy
    }
    
    /// Whether CLI-based OAuth is available
    var supportsCLIBasedOAuth: Bool {
        self == .localProxy
    }
    
    /// Whether CLI agent configuration is available
    var supportsAgentConfig: Bool {
        self == .localProxy
    }
    
    /// Sidebar navigation pages visible in this mode
    var visiblePages: [NavigationPage] {
        switch self {
        case .monitor:
            return [.dashboard, .quota, .providers, .settings, .about]
        case .localProxy:
            return [.dashboard, .quota, .providers, .agents, .apiKeys, .logs, .settings, .about]
        case .remoteProxy:
            return [.dashboard, .quota, .providers, .apiKeys, .settings, .about]
        }
    }
    
    // MARK: - Migration Helpers
    
    /// Create from legacy AppMode + ConnectionMode
    static func fromLegacy(appMode: AppMode?, connectionMode: ConnectionMode?) -> OperatingMode {
        guard let appMode = appMode else { return .monitor }
        
        switch appMode {
        case .quotaOnly:
            return .monitor
        case .full:
            switch connectionMode {
            case .remote:
                return .remoteProxy
            default:
                return .localProxy
            }
        }
    }
}

// MARK: - Operating Mode Manager

/// Singleton manager for operating mode state
@MainActor
@Observable
final class OperatingModeManager {
    static let shared = OperatingModeManager()
    
    // MARK: - Observable State
    
    /// Current operating mode
    private(set) var currentMode: OperatingMode
    
    /// Whether onboarding has been completed
    private(set) var hasCompletedOnboarding: Bool
    
    /// Remote connection configuration (only used in remoteProxy mode)
    private(set) var remoteConfig: RemoteConnectionConfig?
    
    /// Remote connection status
    private(set) var connectionStatus: ConnectionStatus = .disconnected
    
    /// Last connection error
    private(set) var lastError: String?
    
    // MARK: - Computed Properties
    
    var isMonitorMode: Bool { currentMode == .monitor }
    var isLocalProxyMode: Bool { currentMode == .localProxy }
    var isRemoteProxyMode: Bool { currentMode == .remoteProxy }
    
    /// Whether any proxy mode is active
    var isProxyMode: Bool { currentMode != .monitor }
    
    /// Whether remote config is valid
    var hasValidRemoteConfig: Bool { remoteConfig?.isValid == true }
    
    /// Management key for remote config (from Keychain)
    var remoteManagementKey: String? {
        guard let config = remoteConfig else { return nil }
        return KeychainHelper.getManagementKey(for: config.id)
    }
    
    /// Check if a page should be visible in current mode
    func isPageVisible(_ page: NavigationPage, loggingEnabled: Bool = true) -> Bool {
        var pages = currentMode.visiblePages
        if !loggingEnabled {
            pages.removeAll { $0 == .logs }
        }
        return pages.contains(page)
    }
    
    // MARK: - Initialization
    
    private init() {
        // Check for migration from legacy modes first
        let needsMigration = Self.checkNeedsMigration()
        
        if needsMigration {
            let migratedMode = Self.performMigration()
            self.currentMode = migratedMode
            self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        } else if let stored = UserDefaults.standard.string(forKey: "operatingMode"),
                  let mode = OperatingMode(rawValue: stored) {
            self.currentMode = mode
            self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        } else {
            // New installation - default to monitor mode
            self.currentMode = .monitor
            self.hasCompletedOnboarding = false
        }
        
        // Load remote config if in remote mode
        if currentMode == .remoteProxy {
            loadRemoteConfig()
        }
    }
    
    // MARK: - Mode Management
    
    /// Set current mode and persist
    func setMode(_ mode: OperatingMode) {
        currentMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "operatingMode")
        
        // Reset connection status when switching modes
        if mode != .remoteProxy {
            connectionStatus = .disconnected
        }
    }
    
    /// Complete onboarding with selected mode
    func completeOnboarding(mode: OperatingMode) {
        setMode(mode)
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }
    
    /// Switch mode with cleanup actions
    func switchMode(to mode: OperatingMode, stopProxyIfNeeded: @escaping () -> Void) {
        if currentMode == .localProxy && mode != .localProxy {
            stopProxyIfNeeded()
        }
        setMode(mode)
    }
    
    /// Reset onboarding (for debugging/testing)
    func resetOnboarding() {
        hasCompletedOnboarding = false
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }
    
    // MARK: - Remote Configuration
    
    /// Switch to remote mode with config
    func switchToRemote(config: RemoteConnectionConfig, managementKey: String, fromOnboarding: Bool = false) {
        saveRemoteConfig(config)
        KeychainHelper.saveManagementKey(managementKey, for: config.id)
        setMode(.remoteProxy)
        
        if fromOnboarding {
            hasCompletedOnboarding = true
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }
    }
    
    /// Save remote config
    func saveRemoteConfig(_ config: RemoteConnectionConfig) {
        remoteConfig = config
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "remoteConnectionConfig")
        }
    }
    
    /// Load remote config from storage
    private func loadRemoteConfig() {
        if let data = UserDefaults.standard.data(forKey: "remoteConnectionConfig"),
           let config = try? JSONDecoder().decode(RemoteConnectionConfig.self, from: data) {
            remoteConfig = config
        }
    }
    
    /// Clear remote config
    func clearRemoteConfig() {
        if let config = remoteConfig {
            KeychainHelper.deleteManagementKey(for: config.id)
        }
        remoteConfig = nil
        UserDefaults.standard.removeObject(forKey: "remoteConnectionConfig")
        
        if isRemoteProxyMode {
            setMode(.monitor)
        }
    }
    
    /// Update connection status
    func setConnectionStatus(_ status: ConnectionStatus) {
        connectionStatus = status
        if case .error(let message) = status {
            lastError = message
        } else if case .connected = status {
            lastError = nil
            markConnected()
        }
    }
    
    /// Mark successful connection
    func markConnected() {
        connectionStatus = .connected
        lastError = nil
        
        // Update lastConnected timestamp
        if var config = remoteConfig {
            config = RemoteConnectionConfig(
                endpointURL: config.endpointURL,
                displayName: config.displayName,
                verifySSL: config.verifySSL,
                timeoutSeconds: config.timeoutSeconds,
                lastConnected: Date(),
                id: config.id
            )
            saveRemoteConfig(config)
        }
    }
    
    // MARK: - Migration from Legacy
    
    private static func checkNeedsMigration() -> Bool {
        // Check if old keys exist but new key doesn't
        let hasOldAppMode = UserDefaults.standard.string(forKey: "appMode") != nil
        let hasNewOperatingMode = UserDefaults.standard.string(forKey: "operatingMode") != nil
        return hasOldAppMode && !hasNewOperatingMode
    }
    
    private static func performMigration() -> OperatingMode {
        // Read legacy values
        let legacyAppModeRaw = UserDefaults.standard.string(forKey: "appMode")
        let legacyAppMode = legacyAppModeRaw.flatMap { AppMode(rawValue: $0) }
        
        let legacyConnectionModeRaw = UserDefaults.standard.string(forKey: "connectionMode")
        let legacyConnectionMode = legacyConnectionModeRaw.flatMap { ConnectionMode(rawValue: $0) }
        
        // Convert to new mode
        let newMode = OperatingMode.fromLegacy(appMode: legacyAppMode, connectionMode: legacyConnectionMode)
        
        // Persist new mode
        UserDefaults.standard.set(newMode.rawValue, forKey: "operatingMode")
        
        // Mark migration complete (keep old keys for safety)
        UserDefaults.standard.set(true, forKey: "migratedToOperatingMode")
        
        print("[OperatingModeManager] Migrated from AppMode.\(legacyAppModeRaw ?? "nil") + ConnectionMode.\(legacyConnectionModeRaw ?? "nil") -> OperatingMode.\(newMode.rawValue)")
        
        return newMode
    }
}
