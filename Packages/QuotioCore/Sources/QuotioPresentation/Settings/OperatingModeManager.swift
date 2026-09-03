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
import SwiftUI

// MARK: - Operating Mode Manager

/// Manager for operating mode state.
@MainActor
@Observable
public final class OperatingModeManager {
    @ObservationIgnored private let repository: any OperatingModePreferencesRepository
    @ObservationIgnored private var didChangeHandler: (@MainActor (OperatingModePreferences) -> Void)?
    
    // MARK: - Observable State
    
    /// Current operating mode
    public private(set) var currentMode: OperatingMode
    
    /// Whether onboarding has been completed
    public private(set) var hasCompletedOnboarding: Bool
    
    // MARK: - Computed Properties
    
    public var isMonitorMode: Bool { currentMode == .monitor }
    public var isLocalProxyMode: Bool { currentMode == .localProxy }
    
    /// Check if a page should be visible in current mode
    public func isPageVisible(_ page: NavigationPage, loggingEnabled: Bool = true) -> Bool {
        var pages = currentMode.visiblePages
        if !loggingEnabled {
            pages.removeAll { $0 == .logs }
        }
        return pages.contains(page)
    }
    
    // MARK: - Initialization
    
    public init(repository: any OperatingModePreferencesRepository) {
        self.repository = repository
        let preferences = repository.load()
        self.currentMode = preferences.mode
        self.hasCompletedOnboarding = preferences.hasCompletedOnboarding
    }
    
    // MARK: - Mode Management
    
    /// Set current mode and persist
    public func setMode(_ mode: OperatingMode) {
        currentMode = mode
        persist()
    }
    
    /// Complete onboarding with selected mode
    public func completeOnboarding(mode: OperatingMode) {
        setMode(mode)
        hasCompletedOnboarding = true
        persist()
    }
    
    /// Switch mode with cleanup actions
    public func switchMode(to mode: OperatingMode, stopProxyIfNeeded: @escaping () -> Void) {
        if currentMode == .localProxy && mode != .localProxy {
            stopProxyIfNeeded()
        }
        setMode(mode)
    }
    
    /// Reset onboarding (for debugging/testing)
    public func resetOnboarding() {
        hasCompletedOnboarding = false
        persist()
    }

    public func setDidChangeHandler(
        _ handler: (@MainActor (OperatingModePreferences) -> Void)?
    ) {
        didChangeHandler = handler
    }

    private func persist() {
        let preferences = OperatingModePreferences(
            mode: currentMode,
            hasCompletedOnboarding: hasCompletedOnboarding
        )
        repository.save(preferences)
        didChangeHandler?(preferences)
    }
}
