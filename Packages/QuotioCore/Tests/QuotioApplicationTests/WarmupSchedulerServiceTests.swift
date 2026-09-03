import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain

final class WarmupSchedulerServiceTests: XCTestCase {
    func testIntervalTargetRunsImmediatelyAndContinuesAfterModelFailure() async {
        let executor = StubWarmupExecutor(
            models: ["model-a", "model-b", "unselected"],
            failingModels: ["model-a"]
        )
        let service = makeService(executor: executor)
        let target = Self.target(selectedModels: ["model-a", "model-b"])
        await service.configure(targets: [target])

        await service.runDueCycle()

        let warmed = await executor.warmedModels
        let status = await service.status(for: target.account)
        XCTAssertEqual(warmed, ["model-a", "model-b"])
        XCTAssertEqual(status.modelStates["model-a"], .failed)
        XCTAssertEqual(status.modelStates["model-b"], .succeeded)
        XCTAssertEqual(status.progressCompleted, 2)
        XCTAssertEqual(status.lastRun, Self.now)
        XCTAssertEqual(status.nextRun, Self.now.addingTimeInterval(3_600))
        XCTAssertNil(status.lastFailure)
        await service.cancelForTermination()
    }

    func testModelFailurePublishesSemanticFailureState() async {
        let executor = StubWarmupExecutor(models: ["model"], failingModels: ["model"])
        let service = makeService(executor: executor)
        let target = Self.target(selectedModels: ["model"])
        await service.configure(targets: [target])
        let snapshots = await service.states()
        let observedFailure = Task {
            for await snapshot in snapshots {
                if snapshot.statuses[target.account]?.lastFailure == .failed {
                    return true
                }
            }
            return false
        }

        await service.runDueCycle()
        await service.cancelForTermination()

        let didObserveFailure = await observedFailure.value
        XCTAssertTrue(didObserveFailure)
    }

    func testUnavailableExecutionAdvancesIntervalWithoutFetchingModels() async {
        let executor = StubWarmupExecutor(models: ["model"])
        let availability = StubWarmupAvailability(isAvailable: false)
        let service = makeService(executor: executor, availability: availability)
        let target = Self.target(selectedModels: ["model"], cadence: .thirtyMinutes)
        await service.configure(targets: [target])

        await service.runDueCycle()

        let status = await service.status(for: target.account)
        let fetchCount = await executor.fetchCount
        XCTAssertEqual(fetchCount, 0)
        XCTAssertEqual(status.nextRun, Self.now.addingTimeInterval(1_800))
        await service.cancelForTermination()
    }

    func testAvailableModelsUseEightHourAccountCache() async {
        let executor = StubWarmupExecutor(models: ["zeta", "Alpha"])
        let service = makeService(executor: executor)
        let target = Self.target()

        let first = await service.availableModels(for: target)
        let second = await service.availableModels(for: target)

        let fetchCount = await executor.fetchCount
        XCTAssertEqual(first, ["Alpha", "zeta"])
        XCTAssertEqual(second, first)
        XCTAssertEqual(fetchCount, 1)
        await service.cancelForTermination()
    }

    func testConfigureIgnoresUnsupportedProvider() async {
        let service = makeService(executor: StubWarmupExecutor(models: ["model"]))
        let account = QuotaAccountID(provider: .codex, accountKey: "person@example.com")
        await service.configure(targets: [WarmupTarget(account: account)])

        let snapshot = await service.snapshot

        XCTAssertTrue(snapshot.statuses.isEmpty)
        await service.cancelForTermination()
    }

    private func makeService(
        executor: StubWarmupExecutor,
        availability: StubWarmupAvailability = StubWarmupAvailability(isAvailable: true)
    ) -> WarmupSchedulerService {
        WarmupSchedulerService(
            executor: executor,
            availability: availability,
            clock: FixedWarmupClock(now: Self.now),
            sleeper: SuspendedWarmupSleeper(),
            calendar: Calendar(identifier: .gregorian)
        )
    }

    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    private static func target(
        selectedModels: [String] = [],
        cadence: WarmupCadence = .oneHour
    ) -> WarmupTarget {
        WarmupTarget(
            account: QuotaAccountID(provider: .antigravity, accountKey: "person@example.com"),
            authIndex: "auth-index",
            authFileName: "antigravity.json",
            selectedModels: selectedModels,
            scheduleMode: .interval,
            cadence: cadence
        )
    }
}

private actor StubWarmupExecutor: WarmupExecuting {
    private let models: [String]
    private let failingModels: Set<String>
    private(set) var fetchCount = 0
    private(set) var warmedModels: [String] = []

    init(models: [String], failingModels: Set<String> = []) {
        self.models = models
        self.failingModels = failingModels
    }

    func fetchModels(authFileName: String) throws -> [String] {
        fetchCount += 1
        return models
    }

    func warmup(authIndex: String, model: String) throws {
        warmedModels.append(model)
        if failingModels.contains(model) {
            throw WarmupTestError.failed
        }
    }
}

private actor StubWarmupAvailability: WarmupExecutionAvailabilityChecking {
    private let isAvailable: Bool

    init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    func isWarmupExecutionAvailable() -> Bool { isAvailable }
}

private struct FixedWarmupClock: DateProviding {
    let current: Date

    init(now: Date) {
        current = now
    }

    func now() -> Date { current }
}

private actor SuspendedWarmupSleeper: Sleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

private enum WarmupTestError: LocalizedError {
    case failed

    var errorDescription: String? { "failed" }
}
