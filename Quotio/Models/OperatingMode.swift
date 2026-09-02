//
//  OperatingMode.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Unified operating mode: Monitor (Quota-Only) or Local Proxy
//  Replaces the deprecated AppMode system
//

import Foundation
import QuotioApplication
import QuotioDomain
import QuotioInfrastructure
import SwiftUI

// MARK: - Operating Mode Manager

/// Singleton manager for operating mode state
@MainActor
@Observable
final class OperatingModeManager {
    static let shared = OperatingModeManager(
        repository: UserDefaultsOperatingModePreferencesRepository()
    )

    @ObservationIgnored private let repository: any OperatingModePreferencesRepository
    
    // MARK: - Observable State
    
    /// Current operating mode
    private(set) var currentMode: OperatingMode
    
    /// Whether onboarding has been completed
    private(set) var hasCompletedOnboarding: Bool
    
    // MARK: - Computed Properties
    
    var isMonitorMode: Bool { currentMode == .monitor }
    var isLocalProxyMode: Bool { currentMode == .localProxy }
    
    /// Check if a page should be visible in current mode
    func isPageVisible(_ page: NavigationPage, loggingEnabled: Bool = true) -> Bool {
        var pages = currentMode.visiblePages
        if !loggingEnabled {
            pages.removeAll { $0 == .logs }
        }
        return pages.contains(page)
    }
    
    // MARK: - Initialization
    
    init(repository: any OperatingModePreferencesRepository) {
        self.repository = repository
        let preferences = repository.load()
        self.currentMode = preferences.mode
        self.hasCompletedOnboarding = preferences.hasCompletedOnboarding
    }
    
    // MARK: - Mode Management
    
    /// Set current mode and persist
    func setMode(_ mode: OperatingMode) {
        currentMode = mode
        persist()
    }
    
    /// Complete onboarding with selected mode
    func completeOnboarding(mode: OperatingMode) {
        setMode(mode)
        hasCompletedOnboarding = true
        persist()
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
        persist()
    }

    private func persist() {
        repository.save(
            OperatingModePreferences(
                mode: currentMode,
                hasCompletedOnboarding: hasCompletedOnboarding
            )
        )
    }
}
