//
//  MenuBarSettings.swift
//  Quotio
//
//  Menu bar quota display settings with persistence
//

import Foundation
import QuotioApplication
import QuotioDomain
import SwiftUI

// MARK: - Privacy String Extension

public extension String {
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

// MARK: - Appearance Settings Manager

/// Manager for appearance settings with persistence
@MainActor
@Observable
public final class AppearanceManager {
    @ObservationIgnored private let repository: any AppearancePreferencesRepository
    @ObservationIgnored private let platform: any ApplicationPlatformControlling
    @ObservationIgnored private var didChangeHandler: (@MainActor (AppearanceMode) -> Void)?
    
    /// Current appearance mode
    public var appearanceMode: AppearanceMode {
        didSet {
            repository.save(AppearancePreferences(mode: appearanceMode))
            applyAppearance()
            didChangeHandler?(appearanceMode)
        }
    }
    
    public init(
        repository: any AppearancePreferencesRepository,
        platform: any ApplicationPlatformControlling
    ) {
        self.repository = repository
        self.platform = platform
        self.appearanceMode = repository.load().mode
    }
    
    /// Apply the current appearance mode to the app
    public func applyAppearance() {
        platform.applyAppearance(appearanceMode)
    }

    public func setDidChangeHandler(_ handler: (@MainActor (AppearanceMode) -> Void)?) {
        didChangeHandler = handler
    }
}

// MARK: - Usage Calculation Helpers

public extension MenuBarSettingsManager {
    func totalUsagePercent(summary: QuotaSummary?) -> Double {
        guard let summary else { return -1 }
        let totals = totalUsageMode == .sessionOnly ? summary.sessionOnly : summary.combined
        return (modelAggregationMode == .lowest ? totals.lowest : totals.average) ?? -1
    }


}

// MARK: - Refresh Settings Manager

/// Manager for refresh cadence settings with persistence
@MainActor
@Observable
public final class RefreshSettingsManager {
    @ObservationIgnored private let repository: any RefreshPreferencesRepository
    @ObservationIgnored private var cadenceChangeHandlers: [(RefreshCadence) -> Void] = []
    
    /// Current refresh cadence
    public var refreshCadence: RefreshCadence {
        didSet {
            repository.save(RefreshPreferences(cadence: refreshCadence))
            cadenceChangeHandlers.forEach { $0(refreshCadence) }
        }
    }
    
    public init(repository: any RefreshPreferencesRepository) {
        self.repository = repository
        self.refreshCadence = repository.load().cadence
    }

    public func addCadenceChangeHandler(_ handler: @escaping (RefreshCadence) -> Void) {
        cadenceChangeHandlers.append(handler)
    }
}

// MARK: - Menu Bar Quota Display Item

/// A semantic quota metric rendered as one row of a compact menu bar pair.
public struct MenuBarQuotaMetric: Equatable, Sendable {
    public let labelKey: String
    public let remainingPercentage: Double

    public init(labelKey: String, remainingPercentage: Double) {
        self.labelKey = labelKey
        self.remainingPercentage = remainingPercentage
    }
}

/// Two related quota metrics rendered together in the compact menu bar layout.
public struct MenuBarQuotaPair: Equatable, Sendable {
    public let top: MenuBarQuotaMetric
    public let bottom: MenuBarQuotaMetric

    public init(top: MenuBarQuotaMetric, bottom: MenuBarQuotaMetric) {
        self.top = top
        self.bottom = bottom
    }

    public static func resolve(from summary: QuotaSummary?) -> MenuBarQuotaPair? {
        guard let pair = summary?.pair, pair.count == 2 else { return nil }
        return MenuBarQuotaPair(
            top: .init(labelKey: pair[0].displayName, remainingPercentage: pair[0].remainingPercent ?? -1),
            bottom: .init(labelKey: pair[1].displayName, remainingPercentage: pair[1].remainingPercent ?? -1)
        )
    }

}

/// Data for displaying a single quota item in menu bar
public struct MenuBarQuotaDisplayItem: Identifiable, Equatable {
    public let id: String
    public let providerSymbol: String
    public let accountShort: String
    public let percentage: Double
    public let provider: QuotaProvider
    public var isForbidden: Bool
    public var quotaPair: MenuBarQuotaPair?

    public init(
        id: String,
        providerSymbol: String,
        accountShort: String,
        percentage: Double,
        provider: QuotaProvider,
        isForbidden: Bool = false,
        quotaPair: MenuBarQuotaPair? = nil
    ) {
        self.id = id
        self.providerSymbol = providerSymbol
        self.accountShort = accountShort
        self.percentage = percentage
        self.provider = provider
        self.isForbidden = isForbidden
        self.quotaPair = quotaPair
    }
    
    public var statusColor: Color {
        statusColor(for: percentage)
    }

    public func statusColor(for percentage: Double) -> Color {
        if isForbidden { return .orange }
        if percentage > 50 { return .green }
        if percentage > 20 { return .orange }
        return .red
    }
}

// MARK: - Settings Manager

/// Manager for menu bar display settings with persistence
@MainActor
@Observable
public final class MenuBarSettingsManager {
    public var currentHostID: String?
    public var currentItems: [MenuBarQuotaItem] { selectedItems.filter { $0.hostID == currentHostID } }

    @ObservationIgnored private let repository: any MenuBarPreferencesRepository
    @ObservationIgnored private var didChangeHandler: (@MainActor (MenuBarPreferences) -> Void)?

    public static let minMenuBarItems = 1
    public static let maxMenuBarItems = 10
    public static let defaultMenuBarMaxItems = 3

    /// Whether to show menu bar icon at all
    public var showMenuBarIcon: Bool {
        didSet { persist() }
    }

    /// Whether to show quota in menu bar (only effective when showMenuBarIcon is true)
    public var showQuotaInMenuBar: Bool {
        didSet { persist() }
    }

    /// Maximum number of items to display in menu bar
    public var menuBarMaxItems: Int {
        didSet {
            persist()
            enforceMaxItems()
        }
    }
    
    /// Selected items to display
    public var selectedItems: [MenuBarQuotaItem] {
        didSet { persist() }
    }

    /// Provider used to filter account cards in the expanded menu.
    public private(set) var selectedProvider: QuotaProvider?
    
    /// Color mode (colored vs monochrome)
    public var colorMode: MenuBarColorMode {
        didSet { persist() }
    }
    
    /// Quota display mode (used vs remaining)
    public var quotaDisplayMode: QuotaDisplayMode {
        didSet { persist() }
    }
    
    /// Visual style for quota display
    public var quotaDisplayStyle: QuotaDisplayStyle {
        didSet { persist() }
    }

    /// Whether providers with a stable metric pair use the compact stacked layout.
    public var stackPairedQuotaMetrics: Bool {
        didSet { persist() }
    }
    
    /// Whether to hide sensitive information (emails, account names)
    public var hideSensitiveInfo: Bool {
        didSet { persist() }
    }
    
    /// Total usage calculation mode (session-only vs combined)
    public var totalUsageMode: TotalUsageMode {
        didSet { persist() }
    }
    
    /// Model aggregation mode (lowest vs average)
    public var modelAggregationMode: ModelAggregationMode {
        didSet { persist() }
    }

    /// Whether user has manually modified the menu bar selection
    /// When true, autoSelectNewAccounts will not add new items
    public private(set) var hasUserModifiedMenuBar: Bool {
        didSet { persist() }
    }

    /// Check if adding another item would exceed the warning threshold
    /// Warning shows when approaching the limit (at maxItems - 1)
    public var shouldWarnOnAdd: Bool {
        let threshold = max(menuBarMaxItems - 1, 1)
        return currentItems.count >= threshold && currentItems.count < menuBarMaxItems
    }

    /// Check if selection has reached the maximum items
    public var isAtMaxItems: Bool {
        currentItems.count >= menuBarMaxItems
    }

    public var preferences: MenuBarPreferences {
        MenuBarPreferences(
            showMenuBarIcon: showMenuBarIcon,
            showQuotaInMenuBar: showQuotaInMenuBar,
            menuBarMaxItems: menuBarMaxItems,
            selectedItems: selectedItems,
            selectedProvider: selectedProvider,
            colorMode: colorMode,
            quotaDisplayMode: quotaDisplayMode,
            quotaDisplayStyle: quotaDisplayStyle,
            stackPairedQuotaMetrics: stackPairedQuotaMetrics,
            hideSensitiveInfo: hideSensitiveInfo,
            totalUsageMode: totalUsageMode,
            modelAggregationMode: modelAggregationMode,
            hasUserModifiedMenuBar: hasUserModifiedMenuBar
        )
    }
    
    public init(repository: any MenuBarPreferencesRepository) {
        self.repository = repository
        let preferences = repository.load()
        self.showMenuBarIcon = preferences.showMenuBarIcon
        self.showQuotaInMenuBar = preferences.showQuotaInMenuBar
        self.menuBarMaxItems = preferences.menuBarMaxItems
        self.selectedItems = preferences.selectedItems
        self.selectedProvider = preferences.selectedProvider
        self.colorMode = preferences.colorMode
        self.quotaDisplayMode = preferences.quotaDisplayMode
        self.quotaDisplayStyle = preferences.quotaDisplayStyle
        self.stackPairedQuotaMetrics = preferences.stackPairedQuotaMetrics
        self.hideSensitiveInfo = preferences.hideSensitiveInfo
        self.totalUsageMode = preferences.totalUsageMode
        self.modelAggregationMode = preferences.modelAggregationMode
        self.hasUserModifiedMenuBar = preferences.hasUserModifiedMenuBar
    }

    public func setDidChangeHandler(_ handler: (@MainActor (MenuBarPreferences) -> Void)?) {
        didChangeHandler = handler
    }

    public func selectProvider(_ provider: QuotaProvider?) {
        selectedProvider = provider
        repository.save(preferences)
    }
    
    public func addItem(_ item: MenuBarQuotaItem) {
        guard !selectedItems.contains(item) else { return }
        guard selectedItems.filter({ $0.hostID == item.hostID }).count < menuBarMaxItems else { return }
        if !showQuotaInMenuBar {
            showQuotaInMenuBar = true
        }
        if !showMenuBarIcon {
            showMenuBarIcon = true
        }
        selectedItems.append(item)
    }
    
    /// Remove an item (marks as user-modified to prevent auto-add)
    public func removeItem(_ item: MenuBarQuotaItem) {
        selectedItems.removeAll { $0.id == item.id }
        hasUserModifiedMenuBar = true
    }

    public func replaceItem(_ item: MenuBarQuotaItem, with replacement: MenuBarQuotaItem) {
        guard item.hostID == replacement.hostID,
              !isSelected(replacement),
              let index = selectedItems.firstIndex(of: item) else { return }
        hasUserModifiedMenuBar = true
        showMenuBarIcon = true
        showQuotaInMenuBar = true
        selectedItems[index] = replacement
    }

    /// Check if item is selected
    public func isSelected(_ item: MenuBarQuotaItem) -> Bool {
        selectedItems.contains(item)
    }

    /// Toggle item selection (marks as user-modified to prevent auto-add)
    public func toggleItem(_ item: MenuBarQuotaItem) {
        hasUserModifiedMenuBar = true
        if isSelected(item) {
            selectedItems.removeAll { $0.id == item.id }
        } else {
            addItem(item)
        }
    }
    
    public func autoSelectNewAccounts(availableItems: [MenuBarQuotaItem]) {
        // Don't auto-add if user has manually modified the menu bar selection
        guard !hasUserModifiedMenuBar else { return }

        enforceMaxItems()
        let existingIds = Set(selectedItems.map(\.id))
        let newItems = availableItems.filter { !existingIds.contains($0.id) }

        let remainingSlots = menuBarMaxItems - currentItems.count
        if remainingSlots > 0 {
            let itemsToAdd = Array(newItems.prefix(remainingSlots))
            selectedItems.append(contentsOf: itemsToAdd)
        }
    }

    @discardableResult
    private func enforceMaxItems() -> Bool {
        let limited = MenuBarQuotaItem.limited(selectedItems, perHost: menuBarMaxItems)
        guard limited != selectedItems else { return false }
        selectedItems = limited
        return true
    }

    private static func clampedMenuBarMax(_ value: Int) -> Int {
        min(max(value, minMenuBarItems), maxMenuBarItems)
    }

    private func persist() {
        let preferences = preferences
        repository.save(preferences)
        didChangeHandler?(preferences)
    }
}
