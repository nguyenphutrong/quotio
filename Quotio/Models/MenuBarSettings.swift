//
//  MenuBarSettings.swift
//  Quotio
//
//  Menu bar quota display settings with persistence
//

import Foundation
import QuotioApplication
import QuotioDomain
import QuotioInfrastructure
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

// MARK: - Appearance Settings Manager

/// Manager for appearance settings with persistence
@MainActor
@Observable
final class AppearanceManager {
    static let shared = AppearanceManager(
        repository: UserDefaultsAppearancePreferencesRepository()
    )

    @ObservationIgnored private let repository: any AppearancePreferencesRepository
    @ObservationIgnored private var didChangeHandler: (@MainActor (AppearanceMode) -> Void)?
    
    /// Current appearance mode
    var appearanceMode: AppearanceMode {
        didSet {
            repository.save(AppearancePreferences(mode: appearanceMode))
            applyAppearance()
            didChangeHandler?(appearanceMode)
        }
    }
    
    init(repository: any AppearancePreferencesRepository) {
        self.repository = repository
        self.appearanceMode = repository.load().mode
    }
    
    /// Apply the current appearance mode to the app
    func applyAppearance() {
        NSApp.appearance = appearanceMode.appKitAppearance
    }

    func setDidChangeHandler(_ handler: (@MainActor (AppearanceMode) -> Void)?) {
        didChangeHandler = handler
    }
}

// MARK: - Usage Calculation Helpers

extension MenuBarSettingsManager {
    /// Compute total usage percentage using session/extra logic
    /// Treats extra-usage, codex-extra, on-demand as extra models; all others as session
    func totalUsagePercent(models: [(name: String, percentage: Double)]) -> Double {
        let extraModelNames: Set<String> = ["extra-usage", "codex-extra", "on-demand"]
        
        var sessionPercentages: [Double] = []
        var extraPercentages: [Double] = []
        
        for model in models {
            if extraModelNames.contains(model.name) {
                extraPercentages.append(model.percentage)
            } else {
                sessionPercentages.append(model.percentage)
            }
        }
        
        let sessionRemaining = aggregateModelPercentages(sessionPercentages)
        let extraRemaining = aggregateModelPercentages(extraPercentages)
        
        let hasExtraModels = !extraPercentages.isEmpty
        
        switch totalUsageMode {
        case .sessionOnly:
            if sessionRemaining >= 0 {
                return sessionRemaining
            }
            if hasExtraModels {
                return extraRemaining
            }
            return -1
            
        case .combined:
            let session = sessionRemaining >= 0 ? sessionRemaining : -1
            let extra = extraRemaining >= 0 ? extraRemaining : -1
            
            if session < 0 && extra < 0 {
                return -1
            }
            if session < 0 {
                return extra
            }
            if extra < 0 {
                return session
            }
            return max(session, extra)
        }
    }
    
    func calculateTotalUsagePercent(sessionPercent: Double?, extraPercent: Double?) -> Double {
        switch totalUsageMode {
        case .sessionOnly:
            if let session = sessionPercent {
                return session
            }
            return extraPercent ?? -1
            
        case .combined:
            let session = sessionPercent ?? -1
            let extra = extraPercent ?? -1
            
            if session < 0 && extra < 0 {
                return -1
            }
            if session < 0 {
                return extra
            }
            if extra < 0 {
                return session
            }
            return max(session, extra)
        }
    }
    
    func aggregateModelPercentages(_ percentages: [Double]) -> Double {
        let validPercentages = percentages.filter { $0 >= 0 }
        guard !validPercentages.isEmpty else { return -1 }
        
        switch modelAggregationMode {
        case .lowest:
            return validPercentages.min() ?? -1
        case .average:
            return validPercentages.reduce(0, +) / Double(validPercentages.count)
        }
    }
}

// MARK: - Refresh Settings Manager

/// Manager for refresh cadence settings with persistence
@MainActor
@Observable
final class RefreshSettingsManager {
    static let shared = RefreshSettingsManager(
        repository: UserDefaultsRefreshPreferencesRepository()
    )

    @ObservationIgnored private let repository: any RefreshPreferencesRepository
    
    /// Current refresh cadence
    var refreshCadence: RefreshCadence {
        didSet {
            repository.save(RefreshPreferences(cadence: refreshCadence))
            onRefreshCadenceChanged?(refreshCadence)
        }
    }
    
    /// Callback when refresh cadence changes (for ViewModel to restart timer)
    var onRefreshCadenceChanged: ((RefreshCadence) -> Void)?
    
    init(repository: any RefreshPreferencesRepository) {
        self.repository = repository
        self.refreshCadence = repository.load().cadence
    }
}

// MARK: - Menu Bar Quota Display Item

/// A semantic quota metric rendered as one row of a compact menu bar pair.
nonisolated struct MenuBarQuotaMetric: Equatable, Sendable {
    let labelKey: String
    let remainingPercentage: Double
}

/// Two related quota metrics rendered together in the compact menu bar layout.
nonisolated struct MenuBarQuotaPair: Equatable, Sendable {
    let top: MenuBarQuotaMetric
    let bottom: MenuBarQuotaMetric

    static func resolve(for provider: AIProvider, from models: [ModelQuota]) -> MenuBarQuotaPair? {
        switch provider {
        case .claude:
            return makePair(
                from: models,
                topNames: ["five-hour-session"],
                topLabelKey: "quota.metric.fiveHour",
                bottomNames: ["seven-day-weekly", "seven-day-sonnet", "seven-day-opus"],
                bottomLabelKey: "quota.metric.weekly"
            )
        case .codex:
            let sessionNames: Set<String> = ["codex-session", "codex-spark"]
            guard let sessionPercentage = minimumPercentage(in: models, named: sessionNames),
                  sessionPercentage >= 0 else {
                return nil
            }
            return makePair(
                from: models,
                topNames: sessionNames,
                topLabelKey: "quota.metric.session",
                bottomNames: ["codex-weekly", "codex-spark-weekly"],
                bottomLabelKey: "quota.metric.weekly"
            )
        case .amp:
            return makePair(
                from: models,
                topNames: ["amp-agent-usage"],
                topLabelKey: "amp.quota.agent",
                bottomNames: ["amp-orb-usage"],
                bottomLabelKey: "amp.quota.orb",
                requiresBoth: true
            )
        case .antigravity:
            return makePair(
                from: models,
                topNames: ["antigravity-gemini-session", "antigravity-claude-gpt-session"],
                topLabelKey: "quota.metric.session",
                bottomNames: ["antigravity-gemini-weekly", "antigravity-claude-gpt-weekly"],
                bottomLabelKey: "quota.metric.weekly"
            )
        case .devin:
            return makePair(
                from: models,
                topNames: ["devin-daily"],
                topLabelKey: "quota.metric.daily",
                bottomNames: ["devin-weekly"],
                bottomLabelKey: "quota.metric.weekly",
                requiresBoth: true
            )
        case .cursor:
            guard models.contains(where: {
                $0.name == "on-demand"
                    && ($0.limit ?? 0) > 0
                    && $0.remaining != nil
                    && $0.percentage >= 0
            }) else {
                return nil
            }
            return makePair(
                from: models,
                topNames: ["plan-usage"],
                topLabelKey: "quota.metric.planUsage",
                bottomNames: ["on-demand"],
                bottomLabelKey: "quota.metric.onDemand",
                requiresBoth: true
            )
        default:
            return nil
        }
    }

    private static func makePair(
        from models: [ModelQuota],
        topNames: Set<String>,
        topLabelKey: String,
        bottomNames: Set<String>,
        bottomLabelKey: String,
        requiresBoth: Bool = false
    ) -> MenuBarQuotaPair? {
        let topPercentage = minimumPercentage(in: models, named: topNames)
        let bottomPercentage = minimumPercentage(in: models, named: bottomNames)

        if requiresBoth {
            guard topPercentage != nil, bottomPercentage != nil else { return nil }
        } else {
            guard topPercentage != nil || bottomPercentage != nil else { return nil }
        }

        return MenuBarQuotaPair(
            top: MenuBarQuotaMetric(
                labelKey: topLabelKey,
                remainingPercentage: topPercentage ?? -1
            ),
            bottom: MenuBarQuotaMetric(
                labelKey: bottomLabelKey,
                remainingPercentage: bottomPercentage ?? -1
            )
        )
    }

    private static func minimumPercentage(in models: [ModelQuota], named names: Set<String>) -> Double? {
        let matching = models.filter { names.contains($0.name) }
        guard !matching.isEmpty else { return nil }
        return matching.lazy.map(\.percentage).filter { $0 >= 0 }.min() ?? -1
    }
}

/// Data for displaying a single quota item in menu bar
struct MenuBarQuotaDisplayItem: Identifiable, Equatable {
    let id: String
    let providerSymbol: String
    let accountShort: String
    let percentage: Double
    let provider: AIProvider
    var isForbidden: Bool = false
    var quotaPair: MenuBarQuotaPair? = nil
    
    var statusColor: Color {
        statusColor(for: percentage)
    }

    func statusColor(for percentage: Double) -> Color {
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
final class MenuBarSettingsManager {
    static let shared = MenuBarSettingsManager(
        repository: UserDefaultsMenuBarPreferencesRepository()
    )

    @ObservationIgnored private let repository: any MenuBarPreferencesRepository
    @ObservationIgnored private var didChangeHandler: (@MainActor (MenuBarPreferences) -> Void)?

    static let minMenuBarItems = 1
    static let maxMenuBarItems = 10
    static let defaultMenuBarMaxItems = 3

    /// Whether to show menu bar icon at all
    var showMenuBarIcon: Bool {
        didSet { persist() }
    }

    /// Whether to show quota in menu bar (only effective when showMenuBarIcon is true)
    var showQuotaInMenuBar: Bool {
        didSet { persist() }
    }

    /// Maximum number of items to display in menu bar
    var menuBarMaxItems: Int {
        didSet {
            persist()
            enforceMaxItems()
        }
    }
    
    /// Selected items to display
    var selectedItems: [MenuBarQuotaItem] {
        didSet { persist() }
    }
    
    /// Color mode (colored vs monochrome)
    var colorMode: MenuBarColorMode {
        didSet { persist() }
    }
    
    /// Quota display mode (used vs remaining)
    var quotaDisplayMode: QuotaDisplayMode {
        didSet { persist() }
    }
    
    /// Visual style for quota display
    var quotaDisplayStyle: QuotaDisplayStyle {
        didSet { persist() }
    }

    /// Whether providers with a stable metric pair use the compact stacked layout.
    var stackPairedQuotaMetrics: Bool {
        didSet { persist() }
    }
    
    /// Whether to hide sensitive information (emails, account names)
    var hideSensitiveInfo: Bool {
        didSet { persist() }
    }
    
    /// Total usage calculation mode (session-only vs combined)
    var totalUsageMode: TotalUsageMode {
        didSet { persist() }
    }
    
    /// Model aggregation mode (lowest vs average)
    var modelAggregationMode: ModelAggregationMode {
        didSet { persist() }
    }

    /// Whether user has manually modified the menu bar selection
    /// When true, autoSelectNewAccounts will not add new items
    private(set) var hasUserModifiedMenuBar: Bool {
        didSet { persist() }
    }

    /// Check if adding another item would exceed the warning threshold
    /// Warning shows when approaching the limit (at maxItems - 1)
    var shouldWarnOnAdd: Bool {
        let threshold = max(menuBarMaxItems - 1, 1)
        return selectedItems.count >= threshold && selectedItems.count < menuBarMaxItems
    }

    /// Check if selection has reached the maximum items
    var isAtMaxItems: Bool {
        selectedItems.count >= menuBarMaxItems
    }

    var preferences: MenuBarPreferences {
        MenuBarPreferences(
            showMenuBarIcon: showMenuBarIcon,
            showQuotaInMenuBar: showQuotaInMenuBar,
            menuBarMaxItems: menuBarMaxItems,
            selectedItems: selectedItems,
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
    
    init(repository: any MenuBarPreferencesRepository) {
        self.repository = repository
        let preferences = repository.load()
        self.showMenuBarIcon = preferences.showMenuBarIcon
        self.showQuotaInMenuBar = preferences.showQuotaInMenuBar
        self.menuBarMaxItems = preferences.menuBarMaxItems
        self.selectedItems = preferences.selectedItems
        self.colorMode = preferences.colorMode
        self.quotaDisplayMode = preferences.quotaDisplayMode
        self.quotaDisplayStyle = preferences.quotaDisplayStyle
        self.stackPairedQuotaMetrics = preferences.stackPairedQuotaMetrics
        self.hideSensitiveInfo = preferences.hideSensitiveInfo
        self.totalUsageMode = preferences.totalUsageMode
        self.modelAggregationMode = preferences.modelAggregationMode
        self.hasUserModifiedMenuBar = preferences.hasUserModifiedMenuBar
    }

    func setDidChangeHandler(_ handler: (@MainActor (MenuBarPreferences) -> Void)?) {
        didChangeHandler = handler
    }
    
    func addItem(_ item: MenuBarQuotaItem) {
        guard !selectedItems.contains(item) else { return }
        guard selectedItems.count < menuBarMaxItems else { return }
        if !showQuotaInMenuBar {
            showQuotaInMenuBar = true
        }
        if !showMenuBarIcon {
            showMenuBarIcon = true
        }
        selectedItems.append(item)
    }
    
    /// Remove an item (marks as user-modified to prevent auto-add)
    func removeItem(_ item: MenuBarQuotaItem) {
        selectedItems.removeAll { $0.id == item.id }
        hasUserModifiedMenuBar = true
    }

    /// Check if item is selected
    func isSelected(_ item: MenuBarQuotaItem) -> Bool {
        selectedItems.contains(item)
    }

    /// Toggle item selection (marks as user-modified to prevent auto-add)
    func toggleItem(_ item: MenuBarQuotaItem) {
        hasUserModifiedMenuBar = true
        if isSelected(item) {
            selectedItems.removeAll { $0.id == item.id }
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
        // Don't auto-add if user has manually modified the menu bar selection
        guard !hasUserModifiedMenuBar else { return }

        enforceMaxItems()
        let existingIds = Set(selectedItems.map(\.id))
        let newItems = availableItems.filter { !existingIds.contains($0.id) }

        let remainingSlots = menuBarMaxItems - selectedItems.count
        if remainingSlots > 0 {
            let itemsToAdd = Array(newItems.prefix(remainingSlots))
            selectedItems.append(contentsOf: itemsToAdd)
        }
    }

    @discardableResult
    private func enforceMaxItems() -> Bool {
        guard selectedItems.count > menuBarMaxItems else { return false }
        selectedItems = Array(selectedItems.prefix(menuBarMaxItems))
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
