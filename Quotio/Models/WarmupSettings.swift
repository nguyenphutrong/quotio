//
//  WarmupSettings.swift
//  Quotio
//

import Foundation
import Observation

// MARK: - Warmup Cadence

enum WarmupCadence: String, CaseIterable, Identifiable, Codable {
    case fifteenMinutes = "15min"
    case thirtyMinutes = "30min"
    case oneHour = "1h"
    case twoHours = "2h"
    case threeHours = "3h"
    case fourHours = "4h"
    
    var id: String { rawValue }
    
    var intervalSeconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 900
        case .thirtyMinutes: return 1800
        case .oneHour: return 3600
        case .twoHours: return 7200
        case .threeHours: return 10800
        case .fourHours: return 14400
        }
    }
    
    var intervalNanoseconds: UInt64 {
        UInt64(intervalSeconds * 1_000_000_000)
    }
    
    var localizationKey: String {
        switch self {
        case .fifteenMinutes: return "warmup.interval.15min"
        case .thirtyMinutes: return "warmup.interval.30min"
        case .oneHour: return "warmup.interval.1h"
        case .twoHours: return "warmup.interval.2h"
        case .threeHours: return "warmup.interval.3h"
        case .fourHours: return "warmup.interval.4h"
        }
    }
}

// MARK: - Warmup Schedule

enum WarmupScheduleMode: String, CaseIterable, Identifiable, Codable {
    case interval
    case daily
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .interval: return "warmup.schedule.interval"
        case .daily: return "warmup.schedule.daily"
        }
    }
}

@MainActor
@Observable
final class WarmupSettingsManager {
    static let shared = WarmupSettingsManager()
    
    private let defaults = UserDefaults.standard
    private let enabledAccountsKey = "warmupEnabledAccounts"
    private let warmupCadenceKey = "warmupCadence"
    private let warmupScheduleModeKey = "warmupScheduleMode"
    private let warmupDailyMinutesKey = "warmupDailyMinutes"
    private let warmupSelectedModelsKey = "warmupSelectedModels"
    private let warmupCadenceByAccountKey = "warmupCadenceByAccount"
    private let warmupScheduleModeByAccountKey = "warmupScheduleModeByAccount"
    private let warmupDailyMinutesByAccountKey = "warmupDailyMinutesByAccount"
    
    var enabledAccountIds: Set<String> {
        didSet {
            persist()
            onEnabledAccountsChanged?(enabledAccountIds)
        }
    }
    
    var warmupCadence: WarmupCadence {
        didSet {
            defaults.set(warmupCadence.rawValue, forKey: warmupCadenceKey)
            onWarmupCadenceChanged?(warmupCadence)
        }
    }
    
    var warmupScheduleMode: WarmupScheduleMode {
        didSet {
            defaults.set(warmupScheduleMode.rawValue, forKey: warmupScheduleModeKey)
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
            defaults.set(clamped, forKey: warmupDailyMinutesKey)
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
    
    private init() {
        let saved = defaults.stringArray(forKey: enabledAccountsKey) ?? []
        self.enabledAccountIds = Set(saved)
        let cadenceValue = defaults.string(forKey: warmupCadenceKey) ?? WarmupCadence.oneHour.rawValue
        self.warmupCadence = WarmupCadence(rawValue: cadenceValue) ?? .oneHour
        let modeValue = defaults.string(forKey: warmupScheduleModeKey) ?? WarmupScheduleMode.interval.rawValue
        self.warmupScheduleMode = WarmupScheduleMode(rawValue: modeValue) ?? .interval
        if defaults.object(forKey: warmupDailyMinutesKey) != nil {
            let storedMinutes = defaults.integer(forKey: warmupDailyMinutesKey)
            self.warmupDailyMinutes = min(max(storedMinutes, 0), 1439)
        } else {
            self.warmupDailyMinutes = 540
        }
        if let data = defaults.data(forKey: warmupSelectedModelsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            self.selectedModelsByAccount = decoded
        } else {
            self.selectedModelsByAccount = [:]
        }
        if let data = defaults.data(forKey: warmupCadenceByAccountKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.cadenceByAccount = decoded
        } else {
            self.cadenceByAccount = [:]
        }
        if let data = defaults.data(forKey: warmupScheduleModeByAccountKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.scheduleModeByAccount = decoded
        } else {
            self.scheduleModeByAccount = [:]
        }
        if let data = defaults.data(forKey: warmupDailyMinutesByAccountKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.dailyMinutesByAccount = decoded
        } else {
            self.dailyMinutesByAccount = [:]
        }
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
        let values = enabledAccountIds.sorted()
        defaults.set(values, forKey: enabledAccountsKey)
    }
    
    private func persistSelectedModels() {
        guard let data = try? JSONEncoder().encode(selectedModelsByAccount) else { return }
        defaults.set(data, forKey: warmupSelectedModelsKey)
    }

    private func persistCadenceByAccount() {
        guard let data = try? JSONEncoder().encode(cadenceByAccount) else { return }
        defaults.set(data, forKey: warmupCadenceByAccountKey)
    }

    private func persistScheduleModeByAccount() {
        guard let data = try? JSONEncoder().encode(scheduleModeByAccount) else { return }
        defaults.set(data, forKey: warmupScheduleModeByAccountKey)
    }

    private func persistDailyMinutesByAccount() {
        guard let data = try? JSONEncoder().encode(dailyMinutesByAccount) else { return }
        defaults.set(data, forKey: warmupDailyMinutesByAccountKey)
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
