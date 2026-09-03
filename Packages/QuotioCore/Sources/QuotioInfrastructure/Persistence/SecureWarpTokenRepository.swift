import Foundation
import QuotioApplication
import QuotioDomain

public enum SecureWarpTokenRepositoryError: Error, Equatable, Sendable {
    case writeFailed
}

public final class SecureWarpTokenRepository: WarpTokenRepository, @unchecked Sendable {
    public static let accountID = "warp-tokens"

    private let dataStore: any CredentialDataStoring
    private let defaults: UserDefaults

    public init(
        dataStore: any CredentialDataStoring,
        defaults: UserDefaults = .standard
    ) {
        self.dataStore = dataStore
        self.defaults = defaults
    }

    public func load() async throws -> [WarpToken] {
        if let record = await dataStore.read(accountID: Self.accountID) {
            return try JSONDecoder().decode([WarpToken].self, from: record.data)
        }

        guard let legacyData = defaults.data(
            forKey: UserDefaultsWarpTokenRepository.storageKey
        ) else {
            return []
        }
        let tokens = try JSONDecoder().decode([WarpToken].self, from: legacyData)
        if await dataStore.save(legacyData, accountID: Self.accountID) != nil {
            defaults.removeObject(forKey: UserDefaultsWarpTokenRepository.storageKey)
        }
        return tokens
    }

    public func save(_ tokens: [WarpToken]) async throws {
        let data = try JSONEncoder().encode(tokens)
        guard await dataStore.save(data, accountID: Self.accountID) != nil else {
            throw SecureWarpTokenRepositoryError.writeFailed
        }
        defaults.removeObject(forKey: UserDefaultsWarpTokenRepository.storageKey)
    }
}
