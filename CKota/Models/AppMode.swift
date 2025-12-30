//
//  AppMode.swift
//  CKota - CLIProxyAPI GUI Wrapper
//
//  Dual-mode support: Full Mode (proxy + quota) vs Quota-Only Mode
//

import Foundation
import SwiftUI

// MARK: - App Mode

/// Represents the two primary operating modes of CKota
enum AppMode: String, Codable, CaseIterable, Identifiable {
    case full // Proxy server + Quota tracking (current behavior)
    case quotaOnly = "quota" // Quota tracking only (no proxy required)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full: "Full Mode"
        case .quotaOnly: "Quota Monitor"
        }
    }

    var description: String {
        switch self {
        case .full:
            "Run proxy server, manage multiple accounts, configure CLI agents"
        case .quotaOnly:
            "Track quota usage without running proxy server"
        }
    }

    var icon: String {
        switch self {
        case .full: "server.rack"
        case .quotaOnly: "chart.bar.fill"
        }
    }

    var features: [String] {
        switch self {
        case .full:
            [
                "Run local proxy server",
                "Manage multiple AI accounts",
                "Configure CLI agents (Claude Code, Codex, Gemini CLI)",
                "Track quota in menu bar",
                "API key management for clients",
            ]
        case .quotaOnly:
            [
                "Track quota in menu bar",
                "No proxy server required",
                "Lightweight, minimal UI",
                "Direct quota fetching",
                "Like CodexBar / ccusage",
            ]
        }
    }

    /// Sidebar pages visible in this mode
    var visiblePages: [NavigationPage] {
        switch self {
        case .full:
            [.home, .analytics, .providers, .settings, .about]
        case .quotaOnly:
            [.home, .analytics, .providers, .settings, .about]
        }
    }

    /// Whether proxy server should be available in this mode
    var supportsProxy: Bool {
        switch self {
        case .full: true
        case .quotaOnly: false
        }
    }
}

// MARK: - App Mode Manager

/// Singleton manager for app mode state
@Observable
final class AppModeManager {
    static let shared = AppModeManager()

    /// Current app mode - tracked for SwiftUI reactivity
    private(set) var currentMode: AppMode

    /// Whether onboarding has been completed
    private(set) var hasCompletedOnboarding: Bool

    /// Convenience check for quota-only mode
    var isQuotaOnlyMode: Bool { currentMode == .quotaOnly }

    /// Convenience check for full mode
    var isFullMode: Bool { currentMode == .full }

    /// Check if a page should be visible in current mode
    func isPageVisible(_ page: NavigationPage) -> Bool {
        currentMode.visiblePages.contains(page)
    }

    /// Set current mode and persist to UserDefaults
    func setMode(_ newMode: AppMode) {
        currentMode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: "appMode")
    }

    /// Set onboarding completed status
    func setOnboardingCompleted(_ completed: Bool) {
        hasCompletedOnboarding = completed
        UserDefaults.standard.set(completed, forKey: "hasCompletedOnboarding")
    }

    /// Switch mode with validation
    func switchMode(to newMode: AppMode, stopProxyIfNeeded: @escaping () -> Void) {
        if currentMode == .full, newMode == .quotaOnly {
            // Stop proxy when switching to quota-only mode
            stopProxyIfNeeded()
        }
        setMode(newMode)
    }

    private init() {
        // Load from UserDefaults on init
        if let stored = UserDefaults.standard.string(forKey: "appMode"),
           let mode = AppMode(rawValue: stored)
        {
            self.currentMode = mode
        } else {
            self.currentMode = .full
        }
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }
}
