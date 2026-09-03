import Foundation
import QuotioApplication
import QuotioDomain

public actor PersistentQuotaSnapshotStore: QuotaSnapshotStoring {
    private struct MonitorPayload: Codable {
        var quotas: [String: [String: ProviderQuota]]
    }

    private static let importedProviders: Set<QuotaProvider> = [.cursor, .trae]

    private let snapshotDataStore: any AccountSnapshotDataStore
    private let userDefaults: UserDefaults
    private let importedQuotasKey: String

    public init(
        snapshotDataStore: any AccountSnapshotDataStore = FileAccountSnapshotDataStore(),
        userDefaults: UserDefaults = .standard,
        importedQuotasKey: String = "persisted.ideQuotas"
    ) {
        self.snapshotDataStore = snapshotDataStore
        self.userDefaults = userDefaults
        self.importedQuotasKey = importedQuotasKey
    }

    public func load(for mode: QuotaOperatingMode) async -> QuotaSnapshot {
        let imported = loadImportedQuotas()
        guard mode == .monitor else {
            return QuotaSnapshot(quotas: imported)
        }

        var quotas = imported
        if let data = try? await snapshotDataStore.read(),
           let payload = try? JSONDecoder().decode(MonitorPayload.self, from: data) {
            for (provider, accountQuotas) in decode(payload.quotas) {
                quotas[provider, default: [:]].merge(accountQuotas) { _, monitor in monitor }
            }
        }
        return QuotaSnapshot(quotas: quotas)
    }

    public func save(_ snapshot: QuotaSnapshot, for mode: QuotaOperatingMode) async {
        saveImportedQuotas(from: snapshot.quotas)
        guard mode == .monitor else {
            await reconcileImportedQuotasInMonitorSnapshot(with: snapshot.quotas)
            return
        }

        let payload = MonitorPayload(quotas: encode(snapshot.quotas))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? await snapshotDataStore.write(data)
    }

    private func reconcileImportedQuotasInMonitorSnapshot(
        with quotas: [QuotaProvider: [String: ProviderQuota]]
    ) async {
        guard let data = try? await snapshotDataStore.read(),
              var payload = try? JSONDecoder().decode(MonitorPayload.self, from: data) else {
            return
        }

        let imported = quotas.filter {
            Self.importedProviders.contains($0.key) && !$0.value.isEmpty
        }
        var monitorQuotas = decode(payload.quotas)
        let previousImported = monitorQuotas.filter { Self.importedProviders.contains($0.key) }
        guard previousImported != imported else { return }

        for provider in Self.importedProviders {
            monitorQuotas.removeValue(forKey: provider)
        }
        monitorQuotas.merge(imported) { _, current in current }
        payload.quotas = encode(monitorQuotas)
        guard let reconciled = try? JSONEncoder().encode(payload) else { return }
        try? await snapshotDataStore.write(reconciled)
    }

    private func loadImportedQuotas() -> [QuotaProvider: [String: ProviderQuota]] {
        guard let data = userDefaults.data(forKey: importedQuotasKey) else { return [:] }
        guard let stored = try? JSONDecoder().decode(
            [String: [String: ProviderQuota]].self,
            from: data
        ) else {
            userDefaults.removeObject(forKey: importedQuotasKey)
            return [:]
        }

        return decode(stored).filter { Self.importedProviders.contains($0.key) }
    }

    private func saveImportedQuotas(
        from quotas: [QuotaProvider: [String: ProviderQuota]]
    ) {
        let imported = quotas.filter {
            Self.importedProviders.contains($0.key) && !$0.value.isEmpty
        }
        guard !imported.isEmpty else {
            userDefaults.removeObject(forKey: importedQuotasKey)
            return
        }
        guard let data = try? JSONEncoder().encode(encode(imported)) else { return }
        userDefaults.set(data, forKey: importedQuotasKey)
    }

    private func decode(
        _ stored: [String: [String: ProviderQuota]]
    ) -> [QuotaProvider: [String: ProviderQuota]] {
        stored.reduce(into: [:]) { result, entry in
            guard let provider = QuotaProvider(rawValue: entry.key) else { return }
            result[provider] = entry.value
        }
    }

    private func encode(
        _ quotas: [QuotaProvider: [String: ProviderQuota]]
    ) -> [String: [String: ProviderQuota]] {
        quotas.reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
    }
}
