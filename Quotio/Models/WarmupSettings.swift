//
//  WarmupSettings.swift
//  Quotio
//

import Foundation
import Observation
import QuotioApplication
import QuotioDomain
import QuotioInfrastructure

@MainActor
@Observable
final class WarmupSettingsManager {
    static let shared = WarmupSettingsManager(
        repository: UserDefaultsWarmupPreferencesRepository()
    )

    @ObservationIgnored private let repository: any WarmupPreferencesRepository
    
    var enabledAccountIds: Set<String> {
        didSet {
            persist()
            onEnabledAccountsChanged?(enabledAccountIds)
        }
    }
    
    var warmupCadence: WarmupCadence {
        didSet {
            persist()
            onWarmupCadenceChanged?(warmupCadence)
        }
    }
    
    var warmupScheduleMode: WarmupScheduleMode {
        didSet {
            persist()
            onWarmupScheduleChanged?()
        }
    }
    
    var warmupDailyMinutes: Int {
        didSet {
            let clamped = min(max(warmupDailyMinutes, 0), 1439)
            if clamped != warmupDailyMinutes {
                warmupDailyMinutes = clamped
                return
            }
            persist()
            onWarmupScheduleChanged?()
        }
    }
    
    var selectedModelsByAccount: [String: [String]] {
        didSet {
            persistSelectedModels()
        }
    }

    var cadenceByAccount: [String: String] {
        didSet {
            persistCadenceByAccount()
        }
    }

    var scheduleModeByAccount: [String: String] {
        didSet {
            persistScheduleModeByAccount()
        }
    }

    var dailyMinutesByAccount: [String: Int] {
        didSet {
            persistDailyMinutesByAccount()
        }
    }
    
    var warmupDailyTime: Date {
        get {
            Self.dateFromMinutes(warmupDailyMinutes)
        }
        set {
            warmupDailyMinutes = Self.minutesFromDate(newValue)
        }
    }
    
    var onEnabledAccountsChanged: ((Set<String>) -> Void)?
    var onWarmupCadenceChanged: ((WarmupCadence) -> Void)?
    var onWarmupScheduleChanged: (() -> Void)?
    
    init(repository: any WarmupPreferencesRepository) {
        self.repository = repository
        let preferences = repository.load()
        self.enabledAccountIds = preferences.enabledAccountIds
        self.warmupCadence = preferences.cadence
        self.warmupScheduleMode = preferences.scheduleMode
        self.warmupDailyMinutes = preferences.dailyMinutes
        self.selectedModelsByAccount = preferences.selectedModelsByAccount
        self.cadenceByAccount = preferences.cadenceByAccount
        self.scheduleModeByAccount = preferences.scheduleModeByAccount
        self.dailyMinutesByAccount = preferences.dailyMinutesByAccount
    }
    
    func isEnabled(provider: AIProvider, accountKey: String) -> Bool {
        enabledAccountIds.contains(Self.makeAccountId(provider: provider, accountKey: accountKey))
    }
    
    func setEnabled(_ enabled: Bool, provider: AIProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if enabled {
            if enabledAccountIds.contains(id) { return }
            enabledAccountIds.insert(id)
        } else {
            if !enabledAccountIds.contains(id) { return }
            enabledAccountIds.remove(id)
        }
    }
    
    func toggle(provider: AIProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if enabledAccountIds.contains(id) {
            enabledAccountIds.remove(id)
        } else {
            enabledAccountIds.insert(id)
        }
    }
    
    func selectedModels(provider: AIProvider, accountKey: String) -> [String] {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        return selectedModelsByAccount[id] ?? []
    }

    func hasStoredSelection(provider: AIProvider, accountKey: String) -> Bool {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        return selectedModelsByAccount.keys.contains(id)
    }
    
    func setSelectedModels(_ models: [String], provider: AIProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        selectedModelsByAccount[id] = models
    }

    func warmupCadence(provider: AIProvider, accountKey: String) -> WarmupCadence {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if let raw = cadenceByAccount[id], let cadence = WarmupCadence(rawValue: raw) {
            return cadence
        }
        return warmupCadence
    }

    func setWarmupCadence(_ cadence: WarmupCadence, provider: AIProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        cadenceByAccount[id] = cadence.rawValue
        onWarmupScheduleChanged?()
    }

    func warmupScheduleMode(provider: AIProvider, accountKey: String) -> WarmupScheduleMode {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if let raw = scheduleModeByAccount[id], let mode = WarmupScheduleMode(rawValue: raw) {
            return mode
        }
        return warmupScheduleMode
    }

    func setWarmupScheduleMode(_ mode: WarmupScheduleMode, provider: AIProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        scheduleModeByAccount[id] = mode.rawValue
        onWarmupScheduleChanged?()
    }

    func warmupDailyMinutes(provider: AIProvider, accountKey: String) -> Int {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if let minutes = dailyMinutesByAccount[id] {
            return min(max(minutes, 0), 1439)
        }
        return warmupDailyMinutes
    }

    func setWarmupDailyMinutes(_ minutes: Int, provider: AIProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        dailyMinutesByAccount[id] = min(max(minutes, 0), 1439)
        onWarmupScheduleChanged?()
    }

    func warmupDailyTime(provider: AIProvider, accountKey: String) -> Date {
        Self.dateFromMinutes(warmupDailyMinutes(provider: provider, accountKey: accountKey))
    }

    func setWarmupDailyTime(_ date: Date, provider: AIProvider, accountKey: String) {
        setWarmupDailyMinutes(Self.minutesFromDate(date), provider: provider, accountKey: accountKey)
    }
    
    private func persist() {
        repository.save(preferences)
    }
    
    private func persistSelectedModels() {
        persist()
    }

    private func persistCadenceByAccount() {
        persist()
    }

    private func persistScheduleModeByAccount() {
        persist()
    }

    private func persistDailyMinutesByAccount() {
        persist()
    }

    private var preferences: WarmupPreferences {
        WarmupPreferences(
            enabledAccountIds: enabledAccountIds,
            cadence: warmupCadence,
            scheduleMode: warmupScheduleMode,
            dailyMinutes: warmupDailyMinutes,
            selectedModelsByAccount: selectedModelsByAccount,
            cadenceByAccount: cadenceByAccount,
            scheduleModeByAccount: scheduleModeByAccount,
            dailyMinutesByAccount: dailyMinutesByAccount
        )
    }
    
    nonisolated static func makeAccountId(provider: AIProvider, accountKey: String) -> String {
        "\(provider.rawValue)::\(accountKey)"
    }
    
    nonisolated static func parseAccountId(_ id: String) -> WarmupAccountKey? {
        guard let separator = id.range(of: "::") else { return nil }
        let providerRaw = String(id[..<separator.lowerBound])
        let accountKey = String(id[separator.upperBound...])
        guard let provider = AIProvider(rawValue: providerRaw), !accountKey.isEmpty else { return nil }
        return WarmupAccountKey(provider: provider, accountKey: accountKey)
    }
    
    nonisolated private static func minutesFromDate(_ date: Date) -> Int {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return (hour * 60) + minute
    }
    
    nonisolated private static func dateFromMinutes(_ minutes: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        let hour = max(0, min(23, minutes / 60))
        let minute = max(0, min(59, minutes % 60))
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    }
}

nonisolated struct WarmupAccountKey: Hashable, Sendable {
    let provider: AIProvider
    let accountKey: String
    
    var id: String {
        WarmupSettingsManager.makeAccountId(provider: provider, accountKey: accountKey)
    }
}
