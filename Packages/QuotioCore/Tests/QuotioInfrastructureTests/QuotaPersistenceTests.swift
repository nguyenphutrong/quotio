import Foundation
import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioInfrastructure

final class QuotaPersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() {
        super.setUp()
        defaultsSuite = "QuotaPersistenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
        defaultsSuite = nil
        super.tearDown()
    }

    func testLocalProxyLoadsOnlyLegacyImportedIDEQuotas() async throws {
        let cursor = Self.quota(25)
        let codex = Self.quota(75)
        defaults.set(
            try JSONEncoder().encode([
                QuotaProvider.cursor.rawValue: ["cursor-user": cursor],
                QuotaProvider.codex.rawValue: ["codex-user": codex],
            ]),
            forKey: "persisted.ideQuotas"
        )
        let dataStore = MemorySnapshotDataStore(data: try Self.monitorData([
            .codex: ["monitor-user": codex],
        ]))
        let store = makeStore(dataStore: dataStore)

        let snapshot = await store.load(for: .localProxy)

        XCTAssertEqual(snapshot.quotas, [.cursor: ["cursor-user": cursor]])
    }

    func testMonitorLoadPreservesLegacySnapshotAndImportedMirror() async throws {
        let cursor = Self.quota(25)
        let codex = Self.quota(75)
        defaults.set(
            try JSONEncoder().encode([
                QuotaProvider.cursor.rawValue: ["cursor-user": cursor],
            ]),
            forKey: "persisted.ideQuotas"
        )
        let dataStore = MemorySnapshotDataStore(data: try Self.monitorData([
            .codex: ["codex-user": codex],
        ]))
        let store = makeStore(dataStore: dataStore)

        let snapshot = await store.load(for: .monitor)

        XCTAssertEqual(snapshot.quotas[.cursor], ["cursor-user": cursor])
        XCTAssertEqual(snapshot.quotas[.codex], ["codex-user": codex])
    }

    func testMonitorSaveKeepsExistingFileAndDefaultsSchemas() async throws {
        let cursor = Self.quota(25)
        let codex = Self.quota(75)
        let dataStore = MemorySnapshotDataStore()
        let store = makeStore(dataStore: dataStore)

        await store.save(QuotaSnapshot(quotas: [
            .cursor: ["cursor-user": cursor],
            .codex: ["codex-user": codex],
        ]), for: .monitor)

        let storedMonitorData = await dataStore.data
        let monitorData = try XCTUnwrap(storedMonitorData)
        let monitorObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: monitorData) as? [String: Any]
        )
        XCTAssertNotNil(monitorObject["quotas"])

        let importedData = try XCTUnwrap(defaults.data(forKey: "persisted.ideQuotas"))
        let imported = try JSONDecoder().decode(
            [String: [String: ProviderQuota]].self,
            from: importedData
        )
        XCTAssertEqual(imported, [
            QuotaProvider.cursor.rawValue: ["cursor-user": cursor],
        ])
    }

    func testLocalProxySaveRemovesDeletedImportedAccountFromMonitorSnapshot() async throws {
        let keptCursor = Self.quota(25)
        let deletedCursor = Self.quota(50)
        let trae = Self.quota(60)
        let codex = Self.quota(75)
        let dataStore = MemorySnapshotDataStore(data: try Self.monitorData([
            .cursor: ["kept": keptCursor, "deleted": deletedCursor],
            .trae: ["trae-user": trae],
            .codex: ["codex-user": codex],
        ]))
        let store = makeStore(dataStore: dataStore)

        await store.save(QuotaSnapshot(quotas: [
            .cursor: ["kept": keptCursor],
        ]), for: .localProxy)

        let monitorSnapshot = await store.load(for: .monitor)
        XCTAssertEqual(monitorSnapshot.quotas[.cursor], ["kept": keptCursor])
        XCTAssertNil(monitorSnapshot.quotas[.trae])
        XCTAssertEqual(monitorSnapshot.quotas[.codex], ["codex-user": codex])
    }

    func testCorruptImportedQuotaDataIsRemoved() async {
        defaults.set(Data("not-json".utf8), forKey: "persisted.ideQuotas")
        let store = makeStore(dataStore: MemorySnapshotDataStore())

        let snapshot = await store.load(for: .localProxy)

        XCTAssertTrue(snapshot.quotas.isEmpty)
        XCTAssertNil(defaults.data(forKey: "persisted.ideQuotas"))
    }

    func testFileSnapshotStoreRoundTripsWithPrivatePermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshots-v1.json")
        let store = FileAccountSnapshotDataStore(url: url)
        let payload = Data("snapshot".utf8)

        try await store.write(payload)

        let loaded = try await store.read()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(loaded, payload)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    private static func monitorData(
        _ quotas: [QuotaProvider: [String: ProviderQuota]]
    ) throws -> Data {
        let encoded = quotas.reduce(into: [String: [String: ProviderQuota]]()) {
            $0[$1.key.rawValue] = $1.value
        }
        return try JSONEncoder().encode(MonitorPayload(quotas: encoded))
    }

    private func makeStore(
        dataStore: any AccountSnapshotDataStore
    ) -> PersistentQuotaSnapshotStore {
        PersistentQuotaSnapshotStore(
            snapshotDataStore: dataStore,
            userDefaults: UserDefaults(suiteName: defaultsSuite)!
        )
    }

    private static func quota(_ percentage: Double) -> ProviderQuota {
        ProviderQuota(
            models: [QuotaMetric(name: "usage", percentage: percentage, resetTime: "")],
            lastUpdated: Date(timeIntervalSince1970: percentage)
        )
    }
}

private struct MonitorPayload: Codable {
    let quotas: [String: [String: ProviderQuota]]
}

private actor MemorySnapshotDataStore: AccountSnapshotDataStore {
    private(set) var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func read() -> Data? { data }
    func write(_ data: Data) { self.data = data }
}
