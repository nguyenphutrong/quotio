import QuotioDomain

public protocol QuotaHistoryReading: Sendable {
    func historyAvailability() async -> QuotaHistoryAvailability
    func historyCatalog(accountID: String) async throws -> QuotaHistoryCatalog
    func historyChart(accountID: String, metricID: String, range: QuotaHistoryRange) async throws -> QuotaHistoryChart
    func historyEvents(accountID: String, metricID: String, range: QuotaHistoryRange, cursor: String) async throws -> QuotaHistoryEventsPage
}
public protocol QuotaHistoryManaging: Sendable {
    func clearHistory(accountID: String?) async throws
    func setHistoryRecording(enabled: Bool) async throws -> Bool
    func historyRecordingEnabled() async throws -> Bool
}
public struct QuotaHistoryUseCases: Sendable {
    public let reader: any QuotaHistoryReading
    public let manager: any QuotaHistoryManaging
    public init(reader: any QuotaHistoryReading, manager: any QuotaHistoryManaging) {
        self.reader = reader
        self.manager = manager
    }
    public func clear(accountID: String? = nil) async throws { try await manager.clearHistory(accountID: accountID) }
    public func setRecording(enabled: Bool) async throws -> Bool { try await manager.setHistoryRecording(enabled: enabled) }
}
