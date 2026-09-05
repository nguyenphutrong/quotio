//
//  WarmupSettings.swift
//  Quotio
//

import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class WarmupSettingsManager {
    @ObservationIgnored private let repository: any WarmupPreferencesRepository
    
    public var enabledAccountIds: Set<String> {
        didSet {
            persist()
            onEnabledAccountsChanged?(enabledAccountIds)
        }
    }
    
    public var warmupCadence: WarmupCadence {
        didSet {
            persist()
            onWarmupCadenceChanged?(warmupCadence)
        }
    }
    
    public var warmupScheduleMode: WarmupScheduleMode {
        didSet {
            persist()
            onWarmupScheduleChanged?()
        }
    }
    
    public var warmupDailyMinutes: Int {
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
    
    public var selectedModelsByAccount: [String: [String]] {
        didSet {
            persistSelectedModels()
            onWarmupScheduleChanged?()
        }
    }

    public var cadenceByAccount: [String: String] {
        didSet {
            persistCadenceByAccount()
        }
    }

    public var scheduleModeByAccount: [String: String] {
        didSet {
            persistScheduleModeByAccount()
        }
    }

    public var dailyMinutesByAccount: [String: Int] {
        didSet {
            persistDailyMinutesByAccount()
        }
    }
    
    public var warmupDailyTime: Date {
        get {
            Self.dateFromMinutes(warmupDailyMinutes)
        }
        set {
            warmupDailyMinutes = Self.minutesFromDate(newValue)
        }
    }
    
    public var onEnabledAccountsChanged: ((Set<String>) -> Void)?
    public var onWarmupCadenceChanged: ((WarmupCadence) -> Void)?
    public var onWarmupScheduleChanged: (() -> Void)?
    
    public init(repository: any WarmupPreferencesRepository) {
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
    
    public func isEnabled(provider: QuotaProvider, accountKey: String) -> Bool {
        enabledAccountIds.contains(Self.makeAccountId(provider: provider, accountKey: accountKey))
    }
    
    public func setEnabled(_ enabled: Bool, provider: QuotaProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if enabled {
            if enabledAccountIds.contains(id) { return }
            enabledAccountIds.insert(id)
        } else {
            if !enabledAccountIds.contains(id) { return }
            enabledAccountIds.remove(id)
        }
    }
    
    public func toggle(provider: QuotaProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if enabledAccountIds.contains(id) {
            enabledAccountIds.remove(id)
        } else {
            enabledAccountIds.insert(id)
        }
    }
    
    public func selectedModels(provider: QuotaProvider, accountKey: String) -> [String] {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        return selectedModelsByAccount[id] ?? []
    }

    public func hasStoredSelection(provider: QuotaProvider, accountKey: String) -> Bool {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        return selectedModelsByAccount.keys.contains(id)
    }
    
    public func setSelectedModels(_ models: [String], provider: QuotaProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        selectedModelsByAccount[id] = models
    }

    public func warmupCadence(provider: QuotaProvider, accountKey: String) -> WarmupCadence {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if let raw = cadenceByAccount[id], let cadence = WarmupCadence(rawValue: raw) {
            return cadence
        }
        return warmupCadence
    }

    public func setWarmupCadence(_ cadence: WarmupCadence, provider: QuotaProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        cadenceByAccount[id] = cadence.rawValue
        onWarmupScheduleChanged?()
    }

    public func warmupScheduleMode(provider: QuotaProvider, accountKey: String) -> WarmupScheduleMode {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if let raw = scheduleModeByAccount[id], let mode = WarmupScheduleMode(rawValue: raw) {
            return mode
        }
        return warmupScheduleMode
    }

    public func setWarmupScheduleMode(_ mode: WarmupScheduleMode, provider: QuotaProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        scheduleModeByAccount[id] = mode.rawValue
        onWarmupScheduleChanged?()
    }

    public func warmupDailyMinutes(provider: QuotaProvider, accountKey: String) -> Int {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if let minutes = dailyMinutesByAccount[id] {
            return min(max(minutes, 0), 1439)
        }
        return warmupDailyMinutes
    }

    public func setWarmupDailyMinutes(_ minutes: Int, provider: QuotaProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        dailyMinutesByAccount[id] = min(max(minutes, 0), 1439)
        onWarmupScheduleChanged?()
    }

    public func warmupDailyTime(provider: QuotaProvider, accountKey: String) -> Date {
        Self.dateFromMinutes(warmupDailyMinutes(provider: provider, accountKey: accountKey))
    }

    public func setWarmupDailyTime(_ date: Date, provider: QuotaProvider, accountKey: String) {
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
    
    public nonisolated static func makeAccountId(provider: QuotaProvider, accountKey: String) -> String {
        "\(provider.rawValue)::\(accountKey)"
    }
    
    public nonisolated static func parseAccountId(_ id: String) -> WarmupAccountKey? {
        guard let separator = id.range(of: "::") else { return nil }
        let providerRaw = String(id[..<separator.lowerBound])
        let accountKey = String(id[separator.upperBound...])
        guard let provider = QuotaProvider(rawValue: providerRaw), !accountKey.isEmpty else { return nil }
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

public struct WarmupAccountKey: Hashable, Sendable {
    public let provider: QuotaProvider
    public let accountKey: String
    
    public var id: String {
        WarmupSettingsManager.makeAccountId(provider: provider, accountKey: accountKey)
    }

    public init(provider: QuotaProvider, accountKey: String) {
        self.provider = provider
        self.accountKey = accountKey
    }
}
