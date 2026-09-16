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
        let initialSnapshot = QuotaSnapshot(quotas: [
            .codex: ["account": initial],
        ])
        let coordinator = TestQuotaCoordinator(
            snapshot: initialSnapshot,
            refreshedSnapshot: QuotaSnapshot(
                quotas: [.codex: ["account": fresh]],
                lastUpdated: PresentationClock.date
            )
        )
        let model = QuotaScreenModel(coordinator: coordinator)
        var observedStates: [QuotaSnapshot] = []
        model.setDidChangeHandler { observedStates.append($0) }

        await model.bootstrap(mode: .monitor)
        observedStates.removeAll()
        await model.refresh(provider: .codex, mode: .monitor)

        XCTAssertEqual(model.providerQuotas[.codex]?["account"], fresh)
        XCTAssertEqual(model.lastRefreshTime, PresentationClock.date)
        XCTAssertFalse(model.isLoadingQuotas)
        XCTAssertEqual(observedStates.last, model.state)
        await model.shutdown()
    }

    func testDashboardModelDerivesQuotaOverview() async {
        let coordinator = TestQuotaCoordinator(snapshot: QuotaSnapshot(quotas: [
            .codex: ["one": Self.quota(70)],
            .claude: ["two": Self.quota(30)],
        ]))
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

    func testShutdownPreventsSuspendedRefreshFromRestartingObservation() async {
        let gate = TestAsyncGate()
        let coordinator = TestQuotaCoordinator(refreshGate: gate)
        let model = QuotaScreenModel(coordinator: coordinator)
        await model.bootstrap(mode: .monitor)

        let refresh = Task {
            await model.refresh(provider: .codex, mode: .monitor, force: true)
        }
        await coordinator.waitUntilRefreshStarts()
        await model.shutdown()
        await gate.resume()
        await refresh.value

        await coordinator.replaceQuotas(
            ["late": Self.quota(90)], for: .codex, mode: .monitor)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertNil(model.providerQuotas[.codex]?["late"])
    }

    private static func quota(_ percentage: Double) -> ProviderQuota {
        ProviderQuota(
            models: [QuotaMetric(name: "usage", percentage: percentage, resetTime: "")],
            lastUpdated: PresentationClock.date
        )
    }
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
