import Foundation

public enum QuotioHostHistoryRange: String, Decodable, Sendable, CaseIterable {
    case day = "24h", week = "7d", month = "30d"
    public var duration: TimeInterval { switch self { case .day: 86400; case .week: 604800; case .month: 2592000 } }
    public var binSeconds: Int { switch self { case .day: 240; case .week: 1680; case .month: 7200 } }
}

public struct QuotioHostHistoryCatalog: Decodable, Sendable {
    public struct Metric: Decodable, Sendable {
        public let id: String
        public let displayName: String
        public let group: String?
        public let current: Bool
        public let hasPercentage: Bool
    }
    public let schemaVersion: Int
    public let hostId: String
    public let accountId: String
    public let historyRevision: UInt64
    public let recordingEnabled: Bool
    public let recordingError: String?
    public let firstObservedAt: Date?
    public let lastObservedAt: Date?
    public let metrics: [Metric]

    public func validate() throws {
        try HistoryValidation.identity(schemaVersion, hostId, accountId)
        guard Set(metrics.map(\.id)).count == metrics.count,
              metrics.allSatisfy({ HistoryValidation.id($0.id) && HistoryValidation.text($0.displayName) && ($0.group.map(HistoryValidation.text) ?? true) }),
              firstObservedAt == nil || lastObservedAt == nil || firstObservedAt! <= lastObservedAt! else { throw QuotioHostClientError.incompatible }
        try HistoryValidation.code(recordingError)
    }
}

public struct QuotioHostHistoryObservation: Decodable, Sendable {
    public struct Provenance: Decodable, Sendable {
        public let source: String
        public let confidence: String
    }
    public let seriesId: String
    public let basisId: String
    public let fetchedAt: Date
    public let expiresAt: Date?
    public let quota: QuotioHostSnapshot.Quota
    public let amounts: QuotioHostSnapshot.Amounts?
    public let resetsAt: Date?
    public let resetDescription: String?
    public let provenance: Provenance

    func validate() throws {
        guard HistoryValidation.id(seriesId), HistoryValidation.id(basisId),
              ["available", "exhausted", "unknown", "unlimited", "disabled", "limit"].contains(quota.state),
              HistoryValidation.text(provenance.source), ["exact", "estimated", "unknown"].contains(provenance.confidence),
              resetDescription.map(HistoryValidation.text) ?? true else { throw QuotioHostClientError.incompatible }
        try HistoryValidation.percent(quota.remainingPercent)
        guard ["available", "exhausted"].contains(quota.state) == (quota.remainingPercent != nil),
              quota.amount.map({ $0.isFinite && $0 >= 0 }) ?? true,
              quota.unit.map(HistoryValidation.text) ?? true else { throw QuotioHostClientError.incompatible }
        if quota.state == "limit" {
            guard let amount = quota.amount, amount > 0, quota.unit != nil else { throw QuotioHostClientError.incompatible }
        }
        if let amounts {
            guard amounts.remaining.isFinite, amounts.remaining >= 0,
                  amounts.limit.map({ $0.isFinite && $0 > 0 }) ?? true,
                  HistoryValidation.text(amounts.unit) else { throw QuotioHostClientError.incompatible }
        }
    }
}

public struct QuotioHostHistoryEvent: Decodable, Sendable {
    public let id: String
    public let kind: String
    public let fromAt: Date
    public let toAt: Date
    public let beforeRemainingPercent: Double?
    public let afterRemainingPercent: Double?

    func validate() throws {
        guard HistoryValidation.id(id), ["reset_inferred", "quota_increased", "basis_changed", "clock_changed"].contains(kind),
              kind == "clock_changed" || fromAt <= toAt else { throw QuotioHostClientError.incompatible }
        try HistoryValidation.percent(beforeRemainingPercent)
        try HistoryValidation.percent(afterRemainingPercent)
    }
}

public struct QuotioHostHistoryChart: Decodable, Sendable {
    public struct Bin: Decodable, Sendable {
        public let id: Int
        public let startAt: Date
        public let endAt: Date
        public let firstObservedAt: Date
        public let lastObservedAt: Date
        public let sampleCount: Int
        public let latest: QuotioHostHistoryObservation
        public let minRemainingPercent: Double?
        public let maxRemainingPercent: Double?
        public let states: [String]
    }
    public let schemaVersion: Int
    public let hostId: String
    public let accountId: String
    public let metricId: String
    public let historyRevision: UInt64
    public let range: QuotioHostHistoryRange
    public let startAt: Date
    public let endAt: Date
    public let binSeconds: Int
    public let recordingEnabled: Bool
    public let recordingError: String?
    public let bins: [Bin]
    public let events: [QuotioHostHistoryEvent]
    public let nextCursor: String?
    public let latest: QuotioHostHistoryObservation?
    public let lowestRemainingPercent: Double?

    public func validate() throws {
        try HistoryValidation.identity(schemaVersion, hostId, accountId)
        guard HistoryValidation.id(metricId), binSeconds == range.binSeconds,
              abs(endAt.timeIntervalSince(startAt) - range.duration) < 1,
              bins.count <= 360, Set(bins.map(\.id)).count == bins.count,
              bins.map(\.id) == bins.map(\.id).sorted() else { throw QuotioHostClientError.incompatible }
        try HistoryValidation.code(recordingError)
        try HistoryValidation.cursor(nextCursor)
        try HistoryValidation.percent(lowestRemainingPercent)
        try latest?.validate()
        for bin in bins {
            try bin.latest.validate()
            try HistoryValidation.percent(bin.minRemainingPercent)
            try HistoryValidation.percent(bin.maxRemainingPercent)
            guard (0..<360).contains(bin.id) else { throw QuotioHostClientError.incompatible }
            let expectedStart = startAt.addingTimeInterval(Double(bin.id * binSeconds))
            guard bin.sampleCount > 0,
                  abs(bin.startAt.timeIntervalSince(expectedStart)) < 1,
                  abs(bin.endAt.timeIntervalSince(bin.startAt) - Double(binSeconds)) < 1,
                  bin.startAt >= startAt, bin.endAt <= endAt,
                  bin.firstObservedAt >= bin.startAt, bin.lastObservedAt <= bin.endAt,
                  bin.firstObservedAt <= bin.lastObservedAt, bin.latest.fetchedAt == bin.lastObservedAt,
                  !bin.states.isEmpty, Set(bin.states).count == bin.states.count,
                  bin.states.contains(bin.latest.quota.state),
                  bin.states.allSatisfy({ ["available", "exhausted", "unknown", "unlimited", "disabled", "limit"].contains($0) }),
                  (bin.minRemainingPercent == nil) == (bin.maxRemainingPercent == nil),
                  bin.minRemainingPercent == nil || bin.minRemainingPercent! <= bin.maxRemainingPercent! else { throw QuotioHostClientError.incompatible }
        }
        try HistoryValidation.events(events)
    }
}

public struct QuotioHostHistoryEventsPage: Decodable, Sendable {
    public let schemaVersion: Int
    public let hostId: String
    public let accountId: String
    public let metricId: String
    public let historyRevision: UInt64
    public let events: [QuotioHostHistoryEvent]
    public let nextCursor: String?
    public func validate() throws {
        try HistoryValidation.identity(schemaVersion, hostId, accountId)
        guard HistoryValidation.id(metricId) else { throw QuotioHostClientError.incompatible }
        try HistoryValidation.events(events)
        try HistoryValidation.cursor(nextCursor)
    }
}

enum HistoryValidation {
    static func id(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    static func text(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 512 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    static func identity(_ version: Int, _ host: String, _ account: String) throws {
        guard version == 2, id(host), id(account) else { throw QuotioHostClientError.incompatible }
    }
    static func percent(_ value: Double?) throws {
        guard value.map({ $0.isFinite && (0...100).contains($0) }) ?? true else { throw QuotioHostClientError.incompatible }
    }
    static func code(_ value: String?) throws {
        guard value.map(id) ?? true else { throw QuotioHostClientError.incompatible }
    }
    static func cursor(_ value: String?) throws { try code(value) }
    static func events(_ values: [QuotioHostHistoryEvent]) throws {
        guard values.count <= 128, Set(values.map(\.id)).count == values.count else { throw QuotioHostClientError.incompatible }
        for value in values { try value.validate() }
    }
}

extension QuotioHostHTTPClient {
    public func historyCatalog(accountID: String) async throws -> QuotioHostHistoryCatalog {
        guard HistoryValidation.id(accountID) else { throw QuotioHostClientError.incompatible }
        let value: QuotioHostHistoryCatalog = try await request("v2/accounts/\(accountID)/quota-history")
        try value.validate()
        guard value.accountId == accountID else { throw QuotioHostClientError.incompatible }
        return value
    }
    public func historyChart(accountID: String, metricID: String, range: QuotioHostHistoryRange) async throws -> QuotioHostHistoryChart {
        guard HistoryValidation.id(accountID), HistoryValidation.id(metricID) else { throw QuotioHostClientError.incompatible }
        let value: QuotioHostHistoryChart = try await request("v2/accounts/\(accountID)/quota-history/\(metricID)/\(range.rawValue)")
        try value.validate()
        guard value.accountId == accountID, value.metricId == metricID, value.range == range else { throw QuotioHostClientError.incompatible }
        return value
    }
    public func historyEvents(accountID: String, metricID: String, range: QuotioHostHistoryRange, cursor: String) async throws -> QuotioHostHistoryEventsPage {
        guard HistoryValidation.id(accountID), HistoryValidation.id(metricID), HistoryValidation.id(cursor) else { throw QuotioHostClientError.incompatible }
        let value: QuotioHostHistoryEventsPage = try await request("v2/accounts/\(accountID)/quota-history/\(metricID)/\(range.rawValue)/events/\(cursor)")
        try value.validate()
        guard value.accountId == accountID, value.metricId == metricID else { throw QuotioHostClientError.incompatible }
        return value
    }
    public func clearHistory(accountID: String? = nil) async throws {
        if let accountID {
            guard HistoryValidation.id(accountID) else { throw QuotioHostClientError.incompatible }
            try await delete("v2/accounts/\(accountID)/quota-history")
        } else {
            try await delete("v2/quota-history")
        }
    }
}
