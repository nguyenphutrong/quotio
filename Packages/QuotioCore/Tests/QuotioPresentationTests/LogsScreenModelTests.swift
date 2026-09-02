import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class LogsScreenModelTests: XCTestCase {
    func testRefreshUsesTimestampCursorAndPublishesContent() async {
        let repository = StubRepository(pages: [
            .success(ProxyLogPage(lines: ["info first"], latestTimestamp: 10)),
            .success(ProxyLogPage(lines: ["warn second"], latestTimestamp: 20)),
        ])
        let model = makeModel(repository: repository)

        await model.refresh()
        await model.refresh()

        let requestedCursors = await repository.requestedCursors
        XCTAssertEqual(requestedCursors, [nil, 10])
        XCTAssertEqual(model.entries.map(\.message), ["info first", "warn second"])
        XCTAssertEqual(model.state, .content)
        XCTAssertNil(model.errorMessage)
    }

    func testRefreshPublishesErrorState() async {
        let repository = StubRepository(pages: [.failure(TestError.failed)])
        let model = makeModel(repository: repository)

        await model.refresh()

        XCTAssertEqual(model.state, .error(TestError.failed.localizedDescription))
        XCTAssertEqual(model.errorMessage, TestError.failed.localizedDescription)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testCancellationDoesNotPublishAnErrorOrStaleEntries() async {
        let repository = SuspendingRepository()
        let model = makeModel(repository: repository)
        let refreshTask = Task { @MainActor in
            await model.refresh()
        }

        while await repository.fetchCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(model.state, .loading)
        refreshTask.cancel()
        await refreshTask.value

        XCTAssertEqual(model.state, .empty)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isRefreshing)
    }

    func testClearRemovesEntriesAndResetsTimestampCursor() async {
        let repository = StubRepository(pages: [
            .success(ProxyLogPage(lines: ["first"], latestTimestamp: 10)),
            .success(ProxyLogPage(lines: ["after clear"], latestTimestamp: 20)),
        ])
        let model = makeModel(repository: repository)

        await model.refresh()
        await model.clear()
        XCTAssertEqual(model.state, .empty)
        XCTAssertTrue(model.entries.isEmpty)

        await model.refresh()

        let requestedCursors = await repository.requestedCursors
        let clearCount = await repository.clearCount
        XCTAssertEqual(requestedCursors, [nil, nil])
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(model.entries.map(\.message), ["after clear"])
    }

    private func makeModel(repository: any ProxyLogRepository) -> LogsScreenModel {
        LogsScreenModel(
            loadLogs: LoadProxyLogsUseCase(
                repository: repository,
                timeProvider: FixedDateProvider()
            ),
            clearLogs: ClearProxyLogsUseCase(repository: repository),
            sleeper: ImmediateSleeper()
        )
    }
}

private enum TestError: LocalizedError {
    case failed

    var errorDescription: String? { "Failed to load logs" }
}

private struct FixedDateProvider: DateProviding {
    func now() -> Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }
}

private struct ImmediateSleeper: Sleeping {
    func sleep(for duration: Duration) async throws {}
}

private actor StubRepository: ProxyLogRepository {
    private var pages: [Result<ProxyLogPage, Error>]
    private(set) var requestedCursors: [Int?] = []
    private(set) var clearCount = 0

    init(pages: [Result<ProxyLogPage, Error>]) {
        self.pages = pages
    }

    func fetchLogs(after timestamp: Int?) throws -> ProxyLogPage {
        requestedCursors.append(timestamp)
        return try pages.removeFirst().get()
    }

    func clearLogs() {
        clearCount += 1
    }
}

private actor SuspendingRepository: ProxyLogRepository {
    private(set) var fetchCount = 0

    func fetchLogs(after timestamp: Int?) async throws -> ProxyLogPage {
        fetchCount += 1
        try await Task.sleep(for: .seconds(60))
        return ProxyLogPage(lines: ["stale"], latestTimestamp: 1)
    }

    func clearLogs() {}
}
