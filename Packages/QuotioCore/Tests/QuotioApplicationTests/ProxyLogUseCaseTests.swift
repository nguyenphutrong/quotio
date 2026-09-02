import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain

final class ProxyLogUseCaseTests: XCTestCase {
    func testLoadPassesCursorParsesEntriesAndKeepsFiftyMostRecent() async throws {
        let firstLines = (0..<30).map { "info \($0)" }
        let secondLines = (30..<60).map { "error \($0)" }
        let repository = StubProxyLogRepository(pages: [
            ProxyLogPage(lines: firstLines, latestTimestamp: 100),
            ProxyLogPage(lines: secondLines, latestTimestamp: 200),
        ])
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let useCase = LoadProxyLogsUseCase(
            repository: repository,
            timeProvider: FixedDateProvider(date: now)
        )

        let first = try await useCase.execute(existingEntries: [], after: nil)
        let second = try await useCase.execute(
            existingEntries: first.entries,
            after: first.latestTimestamp
        )

        let requestedCursors = await repository.requestedCursors
        XCTAssertEqual(requestedCursors, [nil, 100])
        XCTAssertEqual(second.latestTimestamp, 200)
        XCTAssertEqual(second.entries.count, 50)
        XCTAssertEqual(second.entries.first?.message, "info 10")
        XCTAssertEqual(second.entries.last?.message, "error 59")
        XCTAssertEqual(second.entries.last?.level, .error)
        XCTAssertTrue(second.entries.allSatisfy { $0.timestamp == now })
    }

    func testClearDelegatesToRepository() async throws {
        let repository = StubProxyLogRepository(pages: [])
        let useCase = ClearProxyLogsUseCase(repository: repository)

        try await useCase.execute()

        let clearCount = await repository.clearCount
        XCTAssertEqual(clearCount, 1)
    }
}

private struct FixedDateProvider: DateProviding {
    let date: Date

    func now() -> Date {
        date
    }
}

private actor StubProxyLogRepository: ProxyLogRepository {
    private var pages: [ProxyLogPage]
    private(set) var requestedCursors: [Int?] = []
    private(set) var clearCount = 0

    init(pages: [ProxyLogPage]) {
        self.pages = pages
    }

    func fetchLogs(after timestamp: Int?) throws -> ProxyLogPage {
        requestedCursors.append(timestamp)
        return pages.removeFirst()
    }

    func clearLogs() {
        clearCount += 1
    }
}
