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
    }
    
    func isEnabled(provider: AIProvider, accountKey: String) -> Bool {
        enabledAccountIds.contains(Self.makeAccountId(provider: provider, accountKey: accountKey))
    }
    
    func setEnabled(_ enabled: Bool, provider: AIProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if enabled {
            enabledAccountIds.insert(id)
        } else {
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
    
    func setSelectedModels(_ models: [String], provider: AIProvider, accountKey: String) {
        let id = Self.makeAccountId(provider: provider, accountKey: accountKey)
        if models.isEmpty {
            selectedModelsByAccount.removeValue(forKey: id)
        } else {
            selectedModelsByAccount[id] = models
        }
    }
    
    private func persist() {
        let values = enabledAccountIds.sorted()
        defaults.set(values, forKey: enabledAccountsKey)
    }
    
    private func persistSelectedModels() {
        guard let data = try? JSONEncoder().encode(selectedModelsByAccount) else { return }
        defaults.set(data, forKey: warmupSelectedModelsKey)
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
