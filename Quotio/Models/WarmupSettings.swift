//
//  WarmupSettings.swift
//  Quotio
//

import Foundation
import Observation

@MainActor
@Observable
final class WarmupSettingsManager {
    static let shared = WarmupSettingsManager()
    
    private let defaults = UserDefaults.standard
    private let enabledAccountsKey = "warmupEnabledAccounts"
    
    var enabledAccountIds: Set<String> {
        didSet {
            persist()
            onEnabledAccountsChanged?(enabledAccountIds)
        }
    }
    
    var onEnabledAccountsChanged: ((Set<String>) -> Void)?
    
    private init() {
        let saved = defaults.stringArray(forKey: enabledAccountsKey) ?? []
        self.enabledAccountIds = Set(saved)
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
    
    private func persist() {
        let values = enabledAccountIds.sorted()
        defaults.set(values, forKey: enabledAccountsKey)
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
}

nonisolated struct WarmupAccountKey: Hashable, Sendable {
    let provider: AIProvider
    let accountKey: String
    
    var id: String {
        WarmupSettingsManager.makeAccountId(provider: provider, accountKey: accountKey)
    }
}
