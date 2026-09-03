import Foundation
import QuotioApplication

public actor ProxyManagementKeyVaultAdapter: ProxyManagementKeyVault {
    private static let accountID = "local-management-key"
    private static let legacyDefaultsKey = "managementKey"

    private let dataStore: any CredentialDataStoring
    private let defaultsSuiteName: String?

    public init(dataStore: any CredentialDataStoring, defaultsSuiteName: String? = nil) {
        self.dataStore = dataStore
        self.defaultsSuiteName = defaultsSuiteName
    }

    public func loadManagementKey() async -> String? {
        if let record = await dataStore.read(accountID: Self.accountID),
           let key = String(data: record.data, encoding: .utf8) {
            return key
        }

        let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        guard let key = defaults.string(forKey: Self.legacyDefaultsKey),
              !key.hasPrefix("$2a$") else { return nil }

        if await saveManagementKey(key) {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        }
        return key
    }

    public func saveManagementKey(_ key: String) async -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        return await dataStore.save(data, accountID: Self.accountID) != nil
    }
}
