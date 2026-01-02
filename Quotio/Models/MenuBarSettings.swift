//
//  MenuBarSettings.swift
//  Quotio
//
//  Menu bar quota display settings with persistence
//

import Foundation
import SwiftUI

// MARK: - Privacy String Extension

extension String {
    /// Masks sensitive information with asterisks (*)
    /// Email: `john.doe@gmail.com` → `********@*****.com`
    /// Other: `account-name` → `************`
    func masked() -> String {
        // Check if it's an email
        if self.contains("@") {
            let components = self.split(separator: "@", maxSplits: 1)
            if components.count == 2 {
                let localPart = String(repeating: "*", count: min(components[0].count, 8))
                let domainParts = components[1].split(separator: ".", maxSplits: 1)
                if domainParts.count == 2 {
                    let domainName = String(repeating: "*", count: min(domainParts[0].count, 5))
                    return "\(localPart)@\(domainName).\(domainParts[1])"
                }
                return "\(localPart)@\(String(repeating: "*", count: 5))"
            }
        }
        
        // For non-email strings, mask entirely but keep reasonable length
        let maskedLength = min(self.count, 12)
        return String(repeating: "*", count: max(maskedLength, 4))
    }
    
    /// Conditionally masks the string based on a flag
    func masked(if shouldMask: Bool) -> String {
        shouldMask ? masked() : self
    }
}

// MARK: - Menu Bar Quota Item

/// Represents a single item selected for menu bar display
struct MenuBarQuotaItem: Codable, Identifiable, Hashable {
    let provider: String      // AIProvider.rawValue
    let accountKey: String    // email or account identifier
    
    var id: String { "\(provider)_\(accountKey)" }
    
    /// Get the AIProvider enum value
    var aiProvider: AIProvider? {
        // Handle "copilot" alias
        if provider == "copilot" {
            return .copilot
        }
        return AIProvider(rawValue: provider)
    }
    
    /// Short display symbol for the provider
    var providerSymbol: String {
        aiProvider?.menuBarSymbol ?? "?"
    }
}

// MARK: - Appearance Mode

/// Appearance mode for the app (light/dark/system)
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .system: return "settings.appearance.system"
        case .light: return "settings.appearance.light"
        case .dark: return "settings.appearance.dark"
        }
    }
    
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

// MARK: - Appearance Settings Manager

/// Manager for appearance settings with persistence
@MainActor
@Observable
final class AppearanceManager {
    static let shared = AppearanceManager()
    
    private let defaults = UserDefaults.standard
    private let appearanceModeKey = "appearanceMode"
    
    /// Current appearance mode
    var appearanceMode: AppearanceMode {
        didSet {
            defaults.set(appearanceMode.rawValue, forKey: appearanceModeKey)
            applyAppearance()
        }
    }
    
    private init() {
        let saved = defaults.string(forKey: appearanceModeKey) ?? AppearanceMode.system.rawValue
        self.appearanceMode = AppearanceMode(rawValue: saved) ?? .system
    }
    
    /// Apply the current appearance mode to the app
    func applyAppearance() {
        switch appearanceMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Color Mode

/// Color mode for menu bar quota display
enum MenuBarColorMode: String, Codable, CaseIterable, Identifiable {
    case colored = "colored"       // Green/Yellow/Red based on quota %
    case monochrome = "monochrome" // White/Gray only
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .colored: return "settings.menubar.colored"
        case .monochrome: return "settings.menubar.monochrome"
        }
    }
}

// MARK: - Quota Display Mode

/// Display mode for quota percentage (used vs remaining)
enum QuotaDisplayMode: String, Codable, CaseIterable, Identifiable {
    case used = "used"           // Show percentage used (e.g., "75% used")
    case remaining = "remaining" // Show percentage remaining (e.g., "25% left")
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .used: return "settings.quota.displayMode.used"
        case .remaining: return "settings.quota.displayMode.remaining"
        }
    }
    
    /// Convert a remaining percentage to the display value based on mode
    func displayValue(from remainingPercent: Double) -> Double {
        switch self {
        case .used: return 100 - remainingPercent
        case .remaining: return remainingPercent
        }
    }
    
    var suffixKey: String {
        switch self {
        case .used: return "settings.quota.used"
        case .remaining: return "settings.quota.left"
        }
    }
}

// MARK: - Refresh Cadence

/// Refresh cadence options for quota auto-refresh
enum RefreshCadence: String, CaseIterable, Identifiable, Codable {
    case manual = "manual"
    case oneMinute = "1min"
    case twoMinutes = "2min"
    case fiveMinutes = "5min"
    case tenMinutes = "10min"
    case fifteenMinutes = "15min"
    
    var id: String { rawValue }
    
    /// Interval in seconds (nil for manual = no auto-refresh)
    var intervalSeconds: TimeInterval? {
        switch self {
        case .manual: return nil
        case .oneMinute: return 60
        case .twoMinutes: return 120
        case .fiveMinutes: return 300
        case .tenMinutes: return 600
        case .fifteenMinutes: return 900
        }
    }
    
    /// Interval in nanoseconds for Task.sleep
    var intervalNanoseconds: UInt64? {
        guard let seconds = intervalSeconds else { return nil }
        return UInt64(seconds * 1_000_000_000)
    }
    
    var localizationKey: String {
        switch self {
        case .manual: return "settings.refresh.manual"
        case .oneMinute: return "settings.refresh.1min"
        case .twoMinutes: return "settings.refresh.2min"
        case .fiveMinutes: return "settings.refresh.5min"
        case .tenMinutes: return "settings.refresh.10min"
        case .fifteenMinutes: return "settings.refresh.15min"
        }
    }
}

// MARK: - Refresh Settings Manager

/// Manager for refresh cadence settings with persistence
@MainActor
@Observable
final class RefreshSettingsManager {
    static let shared = RefreshSettingsManager()
    
    private let defaults = UserDefaults.standard
    private let refreshCadenceKey = "refreshCadence"
    
    /// Current refresh cadence
    var refreshCadence: RefreshCadence {
        didSet {
            defaults.set(refreshCadence.rawValue, forKey: refreshCadenceKey)
            onRefreshCadenceChanged?(refreshCadence)
        }
    }
    
    /// Callback when refresh cadence changes (for ViewModel to restart timer)
    var onRefreshCadenceChanged: ((RefreshCadence) -> Void)?
    
    private init() {
        let saved = defaults.string(forKey: refreshCadenceKey) ?? RefreshCadence.tenMinutes.rawValue
        self.refreshCadence = RefreshCadence(rawValue: saved) ?? .tenMinutes
    }
}

// MARK: - Menu Bar Quota Display Item

/// Data for displaying a single quota item in menu bar
struct MenuBarQuotaDisplayItem: Identifiable {
    let id: String
    let providerSymbol: String
    let accountShort: String
    let percentage: Double
    let provider: AIProvider
    
    var statusColor: Color {
        if percentage > 50 { return .green }
        if percentage > 20 { return .orange }
        return .red
    }
}

// MARK: - Settings Manager

/// Manager for menu bar display settings with persistence
@MainActor
@Observable
final class MenuBarSettingsManager {
    static let shared = MenuBarSettingsManager()
    
    private let defaults = UserDefaults.standard
    private let selectedItemsKey = "menuBarSelectedQuotaItems"
    private let colorModeKey = "menuBarColorMode"
    private let showMenuBarIconKey = "showMenuBarIcon"
    private let showQuotaKey = "menuBarShowQuota"
    private let quotaDisplayModeKey = "quotaDisplayMode"
    private let hideSensitiveInfoKey = "hideSensitiveInfo"
    
    /// Whether to show menu bar icon at all
    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: showMenuBarIconKey) }
    }
    
    /// Whether to show quota in menu bar (only effective when showMenuBarIcon is true)
    var showQuotaInMenuBar: Bool {
        didSet { defaults.set(showQuotaInMenuBar, forKey: showQuotaKey) }
    }
    
    /// Selected items to display
    var selectedItems: [MenuBarQuotaItem] {
        didSet { saveSelectedItems() }
    }
    
    /// Color mode (colored vs monochrome)
    var colorMode: MenuBarColorMode {
        didSet { defaults.set(colorMode.rawValue, forKey: colorModeKey) }
    }
    
    /// Quota display mode (used vs remaining)
    var quotaDisplayMode: QuotaDisplayMode {
        didSet { defaults.set(quotaDisplayMode.rawValue, forKey: quotaDisplayModeKey) }
    }
    
    /// Whether to hide sensitive information (emails, account names)
    var hideSensitiveInfo: Bool {
        didSet { defaults.set(hideSensitiveInfo, forKey: hideSensitiveInfoKey) }
    }
    
    /// Threshold for warning when adding more items
    let warningThreshold = 3
    
    /// Check if adding another item would exceed the warning threshold
    var shouldWarnOnAdd: Bool {
        selectedItems.count >= warningThreshold
    }
    
    private init() {
        // Show menu bar icon - default true if not set
        if defaults.object(forKey: showMenuBarIconKey) == nil {
            defaults.set(true, forKey: showMenuBarIconKey)
        }
        self.showMenuBarIcon = defaults.bool(forKey: showMenuBarIconKey)
        
        // Show quota in menu bar - default true if not set
        if defaults.object(forKey: showQuotaKey) == nil {
            defaults.set(true, forKey: showQuotaKey)
        }
        self.showQuotaInMenuBar = defaults.bool(forKey: showQuotaKey)
        
        self.colorMode = MenuBarColorMode(rawValue: defaults.string(forKey: colorModeKey) ?? "") ?? .colored
        self.quotaDisplayMode = QuotaDisplayMode(rawValue: defaults.string(forKey: quotaDisplayModeKey) ?? "") ?? .used
        self.selectedItems = Self.loadSelectedItems(from: defaults, key: selectedItemsKey)
        self.hideSensitiveInfo = defaults.bool(forKey: hideSensitiveInfoKey)
    }
    
    private func saveSelectedItems() {
        if let data = try? JSONEncoder().encode(selectedItems) {
            defaults.set(data, forKey: selectedItemsKey)
        }
    }
    
    private static func loadSelectedItems(from defaults: UserDefaults, key: String) -> [MenuBarQuotaItem] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([MenuBarQuotaItem].self, from: data) else {
            return []
        }
        return items
    }
    
    func addItem(_ item: MenuBarQuotaItem) {
        guard !selectedItems.contains(item) else { return }
        if !showQuotaInMenuBar {
            showQuotaInMenuBar = true
        }
        if !showMenuBarIcon {
            showMenuBarIcon = true
        }
        selectedItems.append(item)
    }
    
    /// Remove an item
    func removeItem(_ item: MenuBarQuotaItem) {
        selectedItems.removeAll { $0.id == item.id }
    }
    
    /// Check if item is selected
    func isSelected(_ item: MenuBarQuotaItem) -> Bool {
        selectedItems.contains(item)
    }
    
    /// Toggle item selection
    func toggleItem(_ item: MenuBarQuotaItem) {
        if isSelected(item) {
            removeItem(item)
        } else {
            addItem(item)
        }
    }
    
    /// Remove items that no longer exist in quota data
    func pruneInvalidItems(validItems: [MenuBarQuotaItem]) {
        let validIds = Set(validItems.map(\.id))
        selectedItems.removeAll { !validIds.contains($0.id) }
    }
    
    func autoSelectNewAccounts(availableItems: [MenuBarQuotaItem]) {
        let existingIds = Set(selectedItems.map(\.id))
        let newItems = availableItems.filter { !existingIds.contains($0.id) }
        
        let remainingSlots = warningThreshold - selectedItems.count
        if remainingSlots > 0 {
            let itemsToAdd = Array(newItems.prefix(remainingSlots))
            selectedItems.append(contentsOf: itemsToAdd)
        }
    }
}
