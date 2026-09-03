import Foundation
import XCTest

@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class SecureWarpTokenRepositoryTests: XCTestCase {
    func testMigratesLegacyUserDefaultsDataAfterSuccessfulSecureWrite() async throws {
        let suite = "SecureWarpTokenRepositoryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = [WarpToken(name: "Work", token: "secret")]
        defaults.set(try JSONEncoder().encode(tokens), forKey: "warpTokens")
        let dataStore = InMemoryCredentialDataStore()
        let repository = SecureWarpTokenRepository(dataStore: dataStore, defaults: defaults)

        let loadedTokens = try await repository.load()
        XCTAssertEqual(loadedTokens, tokens)
        XCTAssertNil(defaults.data(forKey: "warpTokens"))
        let stored = await dataStore.read(accountID: "warp-tokens")
        XCTAssertEqual(try JSONDecoder().decode([WarpToken].self, from: stored!.data), tokens)
    }

    func testKeepsLegacyDataWhenSecureMigrationWriteFails() async throws {
        let suite = "SecureWarpTokenRepositoryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = [WarpToken(name: "Work", token: "secret")]
        let data = try JSONEncoder().encode(tokens)
        defaults.set(data, forKey: "warpTokens")
        let repository = SecureWarpTokenRepository(
            dataStore: InMemoryCredentialDataStore(allowsWrites: false),
            defaults: defaults
        )

        let loadedTokens = try await repository.load()
        XCTAssertEqual(loadedTokens, tokens)
        XCTAssertEqual(defaults.data(forKey: "warpTokens"), data)
    }

    func testSaveFailureDoesNotRemoveLegacyData() async throws {
        let suite = "SecureWarpTokenRepositoryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("legacy".utf8), forKey: "warpTokens")
        let repository = SecureWarpTokenRepository(
            dataStore: InMemoryCredentialDataStore(allowsWrites: false),
            defaults: defaults
        )

        do {
            try await repository.save([WarpToken(name: "Work", token: "secret")])
            XCTFail("Expected secure write to fail")
        } catch {
            XCTAssertEqual(error as? SecureWarpTokenRepositoryError, .writeFailed)
        }
        XCTAssertEqual(defaults.data(forKey: "warpTokens"), Data("legacy".utf8))
    }
}

private actor InMemoryCredentialDataStore: CredentialDataStoring {
    private let allowsWrites: Bool
    private var records: [String: CredentialDataRecord] = [:]

    init(allowsWrites: Bool = true) {
        self.allowsWrites = allowsWrites
    }

    func read(accountID: String) -> CredentialDataRecord? {
        records[accountID]
    }

    func save(_ data: Data, accountID: String) -> CredentialDataRecord? {
        guard allowsWrites else { return nil }
        let record = CredentialDataRecord(data: data, generation: UUID().uuidString)
        records[accountID] = record
        return record
    }

    func compareAndSwap(
        _ data: Data,
        accountID: String,
        expectedGeneration: String
    ) -> CredentialDataRecord? {
        guard records[accountID]?.generation == expectedGeneration else { return nil }
        return save(data, accountID: accountID)
    }

    func delete(accountID: String) {
        records[accountID] = nil
    }
}
