import Foundation
import XCTest
import QuotioApplication
import QuotioDomain
@testable import QuotioPresentation

@MainActor
final class QuotaHistoryScreenModelTests: XCTestCase {
    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<2000 { if await predicate() { return }; await Task.yield() }
        XCTFail("Expected transition did not occur")
    }
    private func screen(_ reader: ControlledHistory) -> QuotaHistoryScreenModel {
        .init(accountID: "account", useCases: .init(reader: reader, manager: reader))
    }
    func testOlderRangeFailureCannotOverwriteNewerSuccessfulSelection() async throws {
        let reader = ControlledHistory(); let model = screen(reader)
        model.start()
        try await waitUntil { await reader.pending(.day) }
        model.select(range: .week)
        try await waitUntil { await reader.pending(.week) }
        await reader.complete(.week, .success(reader.result(.week)))
        try await waitUntil { model.chart?.range == .week }
        await reader.complete(.day, .failure(QuotaHistoryError.storage))
        await Task.yield()
        XCTAssertEqual(model.chart?.range, .week)
        XCTAssertNil(model.error)
        model.stop()
    }
    func testDismissalRejectsLateResultEvenWhenReaderIgnoresCancellation() async throws {
        let reader = ControlledHistory(); let model = screen(reader)
        model.start(); try await waitUntil { await reader.pending(.day) }
        model.stop()
        await reader.complete(.day, .success(reader.result(.day)))
        await Task.yield()
        XCTAssertNil(model.chart)
        XCTAssertFalse(model.isLoading)
    }
    func testCatalogSelectsFirstCurrentPercentageWithoutMergingHistoricalMetric() async throws {
        let reader = ControlledHistory(); let model = screen(reader)
        model.start(); try await waitUntil { await reader.pending(.day) }
        XCTAssertEqual(model.metricID, "session")
        XCTAssertEqual(model.catalog?.metrics.map(\.id), ["balance", "session", "old_weekly"])
        await reader.complete(.day, .success(reader.result(.day)))
        try await waitUntil { model.chart != nil }
        model.stop()
    }
    func testRetryReadsHistoryWithoutProviderRefreshAndFailureKeepsReadableChart() async throws {
        let reader = ControlledHistory(); let model = screen(reader)
        model.start(); try await waitUntil { await reader.pending(.day) }
        await reader.complete(.day, .success(reader.result(.day)))
        try await waitUntil { model.chart != nil }
        let chart = model.chart
        model.reload(); try await waitUntil { await reader.pending(.day) }
        await reader.complete(.day, .failure(QuotaHistoryError.storage))
        try await waitUntil { model.error != nil }
        XCTAssertEqual(model.chart, chart)
        XCTAssertEqual(model.error, .storage)
        let count = await reader.requestCount()
        XCTAssertEqual(count, 2)
        model.stop()
    }
    func testOfflineAndUnsupportedAreDistinctAndDoNotReadCatalog() async throws {
        for state in [QuotaHistoryAvailability(hostID: "host", connected: false, canRead: true, canWrite: true),
                      QuotaHistoryAvailability(hostID: "host", connected: true, canRead: false, canWrite: false)] {
            let reader = ControlledHistory(availability: state); let model = screen(reader)
            model.start(); try await waitUntil { model.error != nil }
            XCTAssertEqual(model.error, state.connected ? .unsupported : .offline)
            let count = await reader.catalogCount()
            XCTAssertEqual(count, 0)
            model.stop()
        }
    }
    func testStorageAndAuthorizationCapabilitiesKeepSpecificFailureWithoutReadingHistory() async throws {
        for failure in [QuotaHistoryError.storage, .unauthorized] {
            let reader = ControlledHistory(availability: .init(hostID: "host", connected: true, canRead: false, canWrite: false, readFailure: failure))
            let model = screen(reader)
            model.start(); try await waitUntil { model.error != nil }
            XCTAssertEqual(model.error, failure)
            let service = QuotaHistoryServiceModel(useCases: .init(reader: reader, manager: reader), coordinator: TestQuotaCoordinator())
            await service.loadSettings()
            XCTAssertEqual(service.error, failure)
            XCTAssertNil(service.recordingEnabled)
            let count = await reader.catalogCount()
            XCTAssertEqual(count, 0)
            model.stop()
        }
    }
    func testMetricChangeRejectsOldSuccessfulMetric() async throws {
        let reader = ControlledHistory(); let model = screen(reader)
        model.start(); try await waitUntil { await reader.pending(.day) }
        model.select(metricID: "old_weekly")
        try await waitUntil { await reader.pending(.day, metricID: "old_weekly") }
        await reader.complete(.day, .success(reader.result(.day, metricID: "old_weekly")), metricID: "old_weekly")
        try await waitUntil { model.chart?.metricID == "old_weekly" }
        await reader.complete(.day, .success(reader.result(.day)))
        await Task.yield()
        XCTAssertEqual(model.chart?.metricID, "old_weekly")
        XCTAssertEqual(model.selectedMetric?.current, false)
        model.stop()
    }
    func testHostChangeClearsPreviouslyReadableHistoryAndRejectsPendingResult() async throws {
        let reader = ControlledHistory(); let model = screen(reader)
        model.start(); try await waitUntil { await reader.pending(.day) }
        await reader.complete(.day, .success(reader.result(.day)))
        try await waitUntil { model.chart != nil }
        model.select(range: .week); try await waitUntil { await reader.pending(.week) }
        await reader.setAvailability(.init(hostID: "other_host", connected: true, canRead: true, canWrite: true))
        model.reload(); try await waitUntil { model.error == .hostChanged }
        await reader.complete(.week, .success(reader.result(.week)))
        await Task.yield()
        XCTAssertNil(model.chart)
        XCTAssertNil(model.catalog)
        XCTAssertEqual(model.error, .hostChanged)
        XCTAssertFalse(model.availability.canWrite)
        await model.clearAccount()
        let clears = await reader.clearCount()
        XCTAssertEqual(clears, 0)
        model.stop()
    }
    func testAmountOnlyCatalogDoesNotSelectAnUnrelatedBalanceAsPercentage() async throws {
        let reader = ControlledHistory(percentageMetrics: false); let model = screen(reader)
        model.start(); try await waitUntil { model.catalog != nil && !model.isLoading }
        XCTAssertNil(model.metricID)
        XCTAssertNil(model.chart)
        let count = await reader.requestCount()
        XCTAssertEqual(count, 0)
        model.stop()
    }
    func testKeyboardSelectionSkipsGapsAndZeroIsSelectable() async throws {
        let reader = ControlledHistory(); let model = screen(reader)
        model.start(); try await waitUntil { await reader.pending(.day) }
        let base = Date(timeIntervalSince1970: 0)
        func bin(_ id: Int, _ remaining: Double) -> QuotaHistoryBin {
            let start = base.addingTimeInterval(Double(id * 240))
            let observation = QuotaHistoryObservation(seriesID: "series", basisID: "basis", fetchedAt: start.addingTimeInterval(60), expiresAt: nil,
                state: remaining == 0 ? .exhausted : .available, remainingPercent: remaining, amount: nil, limit: nil, unit: nil,
                resetsAt: nil, resetDescription: nil, source: "provider", confidence: .estimated)
            return .init(id: id, startAt: start, endAt: start.addingTimeInterval(240), firstObservedAt: observation.fetchedAt,
                lastObservedAt: observation.fetchedAt, sampleCount: 1, latest: observation, minRemainingPercent: remaining,
                maxRemainingPercent: remaining, states: [observation.state])
        }
        let bins = [bin(0, 100), bin(8, 0)]
        let result = QuotaHistoryChart(hostID: "host", accountID: "account", metricID: "session", revision: 1, range: .day,
            startAt: base, endAt: base.addingTimeInterval(86400), binSeconds: 240, recordingEnabled: true, recordingError: nil,
            bins: bins, events: [], nextCursor: nil, latest: bins[1].latest, lowestRemainingPercent: 0)
        await reader.complete(.day, .success(result)); try await waitUntil { model.chart != nil }
        XCTAssertEqual(model.selectedBin?.latest.remainingPercent, 0)
        model.moveSelection(by: -1); XCTAssertEqual(model.selectedBinID, 0)
        model.moveSelection(by: 1); XCTAssertEqual(model.selectedBinID, 8)
        model.select(at: base.addingTimeInterval(1000)); XCTAssertNil(model.selectedBin)
        XCTAssertEqual(model.chart?.latest?.remainingPercent, 0)
        model.stop()
    }
    func testEventPaginationAppendsAllDistinctEventsAndPreservesRevision() async throws {
        let reader = ControlledHistory(); let model = screen(reader)
        model.start(); try await waitUntil { await reader.pending(.day) }
        await reader.complete(.day, .success(reader.result(.day, nextCursor: "next")))
        try await waitUntil { model.chart != nil }
        let date = Date(timeIntervalSince1970: 0)
        let events = [QuotaHistoryEvent(id: "one", kind: .basisChanged, fromAt: date, toAt: date, beforeRemainingPercent: nil, afterRemainingPercent: nil),
                      QuotaHistoryEvent(id: "two", kind: .quotaIncreased, fromAt: date, toAt: date, beforeRemainingPercent: 10, afterRemainingPercent: 20)]
        await reader.setPage(.init(hostID: "host", accountID: "account", metricID: "session", revision: 1, events: events, nextCursor: nil))
        model.loadMoreEvents(); try await waitUntil { !model.isLoadingEvents }
        XCTAssertEqual(model.events.map(\.id), ["one", "two"])
        XCTAssertNil(model.nextCursor)
        XCTAssertNil(model.eventError)
        model.stop()
    }
    func testOfflineSettingFailurePreservesValueAndDisablesFurtherMutations() async {
        let reader = ControlledHistory()
        let service = QuotaHistoryServiceModel(useCases: .init(reader: reader, manager: reader), coordinator: TestQuotaCoordinator())
        await service.loadSettings()
        XCTAssertEqual(service.recordingEnabled, true)
        await reader.setMutationFailure(.offline)
        await service.setRecording(false)
        XCTAssertEqual(service.recordingEnabled, true)
        XCTAssertEqual(service.error, .offline)
        XCTAssertFalse(service.availability.connected)
        await service.clearAll()
        let clears = await reader.clearCount()
        XCTAssertEqual(clears, 0)
    }
    func testClearFailureKeepsPreviouslyReadableHistory() async throws {
        let reader = ControlledHistory(); let model = screen(reader)
        model.start(); try await waitUntil { await reader.pending(.day) }
        await reader.complete(.day, .success(reader.result(.day)))
        try await waitUntil { model.chart != nil }
        let chart = model.chart
        await reader.setMutationFailure(.storage)
        await model.clearAccount()
        XCTAssertEqual(model.mutationError, .storage)
        XCTAssertEqual(model.chart, chart)
        XCTAssertFalse(model.isClearing)
        model.stop()
    }

}

private actor ControlledHistory: QuotaHistoryReading, QuotaHistoryManaging {
    private var availability: QuotaHistoryAvailability
    private let percentageMetrics: Bool
    private var page: QuotaHistoryEventsPage?
    private var requests: [String: CheckedContinuation<QuotaHistoryChart, any Error>] = [:]
    private var chartReads = 0
    private var catalogReads = 0
    private var mutationFailure: QuotaHistoryError?
    private var clears = 0
    init(availability: QuotaHistoryAvailability = .init(hostID: "host", connected: true, canRead: true, canWrite: true), percentageMetrics: Bool = true) { self.availability = availability; self.percentageMetrics = percentageMetrics }
    func historyAvailability() -> QuotaHistoryAvailability { availability }
    func setAvailability(_ value: QuotaHistoryAvailability) { availability = value }
    func setPage(_ value: QuotaHistoryEventsPage) { page = value }
    func historyCatalog(accountID: String) -> QuotaHistoryCatalog {
        catalogReads += 1
        let metrics: [QuotaHistoryMetric] = [
            .init(id: "balance", displayName: "Balance", group: nil, current: true, hasPercentage: false),
            .init(id: "session", displayName: "Session", group: nil, current: true, hasPercentage: true),
            .init(id: "old_weekly", displayName: "Weekly", group: nil, current: false, hasPercentage: true)]
        return .init(hostID: "host", accountID: accountID, revision: 1, recordingEnabled: true, recordingError: nil,
            firstObservedAt: nil, lastObservedAt: nil, metrics: percentageMetrics ? metrics : [metrics[0]])
    }
    func historyChart(accountID: String, metricID: String, range: QuotaHistoryRange) async throws -> QuotaHistoryChart {
        chartReads += 1
        return try await withCheckedThrowingContinuation { requests[metricID + range.rawValue] = $0 }
    }
    func historyEvents(accountID: String, metricID: String, range: QuotaHistoryRange, cursor: String) throws -> QuotaHistoryEventsPage {
        guard let page else { throw QuotaHistoryError.requestFailed }
        return page
    }
    func pending(_ range: QuotaHistoryRange, metricID: String = "session") -> Bool { requests[metricID + range.rawValue] != nil }
    func complete(_ range: QuotaHistoryRange, _ result: Result<QuotaHistoryChart, any Error>, metricID: String = "session") { requests.removeValue(forKey: metricID + range.rawValue)?.resume(with: result) }
    nonisolated func result(_ range: QuotaHistoryRange, metricID: String = "session", nextCursor: String? = nil) -> QuotaHistoryChart {
        .init(hostID: "host", accountID: "account", metricID: metricID, revision: 1, range: range,
            startAt: Date(timeIntervalSince1970: 0), endAt: Date(timeIntervalSince1970: 86400), binSeconds: 240,
            recordingEnabled: true, recordingError: nil, bins: [], events: [], nextCursor: nextCursor, latest: nil, lowestRemainingPercent: nil)
    }
    func requestCount() -> Int { chartReads }
    func catalogCount() -> Int { catalogReads }
    func setMutationFailure(_ value: QuotaHistoryError) { mutationFailure = value }
    func clearCount() -> Int { clears }
    func clearHistory(accountID: String?) throws { clears += 1; if let mutationFailure { throw mutationFailure } }
    func setHistoryRecording(enabled: Bool) throws -> Bool { if let mutationFailure { throw mutationFailure }; return enabled }
    func historyRecordingEnabled() -> Bool { true }
}
