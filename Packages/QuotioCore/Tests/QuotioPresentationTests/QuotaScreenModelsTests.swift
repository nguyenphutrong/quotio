import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class QuotaScreenModelsTests: XCTestCase {
    func testQuotaScreenModelBootstrapsAndRefreshesThroughCoordinator() async {
        let initial = Self.quota(20)
        let fresh = Self.quota(80)
        let store = PresentationQuotaStore(initial: QuotaSnapshot(quotas: [
            .codex: ["account": initial],
        ]))
        let coordinator = QuotaRefreshCoordinator(
            registry: QuotaProviderRegistry([
                PresentationQuotaFetcher(provider: .codex, quota: fresh),
            ]),
            snapshots: store,
            clock: PresentationClock()
        )
        let model = QuotaScreenModel(coordinator: coordinator)

        await model.bootstrap(mode: .monitor)
        await model.refresh(provider: .codex, mode: .monitor)

        XCTAssertEqual(model.providerQuotas[.codex]?["account"], fresh)
        XCTAssertEqual(model.lastRefreshTime, PresentationClock.date)
        XCTAssertFalse(model.isLoadingQuotas)
        await model.shutdown()
    }

    func testDashboardModelDerivesQuotaOverview() async {
        let store = PresentationQuotaStore(initial: QuotaSnapshot(quotas: [
            .codex: ["one": Self.quota(70)],
            .claude: ["two": Self.quota(30)],
        ]))
        let coordinator = QuotaRefreshCoordinator(
            registry: QuotaProviderRegistry([]),
            snapshots: store,
            clock: PresentationClock()
        )
        let quota = QuotaScreenModel(coordinator: coordinator)
        let accounts = AccountsScreenModel(
            accountService: EmptyAccountManager(),
            authFileRepository: EmptyAuthFileRepository()
        )
        let dashboard = DashboardScreenModel(quota: quota, accounts: accounts)

        await quota.bootstrap(mode: .monitor)

        XCTAssertEqual(dashboard.lowestQuotaPercentage, 30)
        await quota.shutdown()
    }

    private static func quota(_ percentage: Double) -> ProviderQuota {
        ProviderQuota(
            models: [QuotaMetric(name: "usage", percentage: percentage, resetTime: "")],
            lastUpdated: PresentationClock.date
        )
    }
}

private actor PresentationQuotaFetcher: QuotaFetching {
    nonisolated let provider: QuotaProvider
    private let quota: ProviderQuota

    init(provider: QuotaProvider, quota: ProviderQuota) {
        self.provider = provider
        self.quota = quota
    }

    func fetch(_ request: QuotaFetchRequest) -> QuotaProviderOutput {
        QuotaProviderOutput(quotas: ["account": quota])
    }
}

private actor PresentationQuotaStore: QuotaSnapshotStoring {
    private let initial: QuotaSnapshot

    init(initial: QuotaSnapshot) {
        self.initial = initial
    }

    func load(for mode: QuotaOperatingMode) -> QuotaSnapshot { initial }
    func save(_ snapshot: QuotaSnapshot, for mode: QuotaOperatingMode) {}
}

private struct PresentationClock: DateProviding {
    static let date = Date(timeIntervalSince1970: 2_000)
    func now() -> Date { Self.date }
}

private actor EmptyAccountManager: AccountManaging {
    func accounts() -> [Account] { [] }
    func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String?
    ) throws {}
    func setDisabled(_ disabled: Bool, accountID: String) {}
    func delete(accountID: String) throws {}
}

private actor EmptyAuthFileRepository: AuthFileRepository {
    func scanAllAuthFiles() -> [AuthFileDescriptor] { [] }
    func readCredential(from descriptor: AuthFileDescriptor) -> AuthFileCredential? { nil }
    func readAuthFileForImport(from url: URL) throws -> Data { Data() }
    func uploadAuthFile(name: String, content: Data) throws {}
    func downloadAuthFile(name: String) throws -> Data { Data() }
    func writeDownloadedAuthFile(_ content: Data, to url: URL) throws {}
    func deleteAuthFile(name: String) throws {}
}
