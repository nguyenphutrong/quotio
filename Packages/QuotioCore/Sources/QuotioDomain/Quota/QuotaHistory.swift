import Foundation

public enum QuotaHistoryRange: String, CaseIterable, Sendable, Identifiable {
    case day = "24h", week = "7d", month = "30d"
    public var id: String { rawValue }
}
public enum QuotaHistoryState: String, Sendable {
    case available, exhausted, unknown, unlimited, disabled, limit
}
public enum QuotaHistoryConfidence: String, Sendable { case exact, estimated, unknown }
public enum QuotaHistoryEventKind: String, Sendable {
    case resetInferred = "reset_inferred", quotaIncreased = "quota_increased", basisChanged = "basis_changed", clockChanged = "clock_changed"
}
public enum QuotaHistoryError: Error, Equatable, Sendable {
    case offline, unsupported, unauthorized, invalidResponse, storage, requestFailed, hostChanged
}
public struct QuotaHistoryAvailability: Equatable, Sendable {
    public let hostID: String?
    public let connected: Bool
    public let canRead: Bool
    public let canWrite: Bool
    public let readFailure: QuotaHistoryError?
    public init(hostID: String?, connected: Bool, canRead: Bool, canWrite: Bool, readFailure: QuotaHistoryError? = nil) {
        self.hostID = hostID; self.connected = connected; self.canRead = canRead; self.canWrite = canWrite; self.readFailure = readFailure
    }
}

public struct QuotaHistoryMetric: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let group: String?
    public let current: Bool
    public let hasPercentage: Bool
    public init(id: String, displayName: String, group: String?, current: Bool, hasPercentage: Bool) {
        self.id = id
        self.displayName = displayName
        self.group = group
        self.current = current
        self.hasPercentage = hasPercentage
    }
}

public struct QuotaHistoryObservation: Equatable, Sendable {
    public let seriesID: String
    public let basisID: String
    public let fetchedAt: Date
    public let expiresAt: Date?
    public let state: QuotaHistoryState
    public let remainingPercent: Double?
    public let amount: Double?
    public let limit: Double?
    public let unit: String?
    public let resetsAt: Date?
    public let resetDescription: String?
    public let source: String
    public let confidence: QuotaHistoryConfidence
    public init(seriesID: String, basisID: String, fetchedAt: Date, expiresAt: Date?, state: QuotaHistoryState, remainingPercent: Double?, amount: Double?, limit: Double?, unit: String?, resetsAt: Date?, resetDescription: String?, source: String, confidence: QuotaHistoryConfidence) {
        self.seriesID = seriesID
        self.basisID = basisID
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.state = state
        self.remainingPercent = remainingPercent
        self.amount = amount
        self.limit = limit
        self.unit = unit
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.source = source
        self.confidence = confidence
    }
}

public struct QuotaHistoryBin: Equatable, Sendable, Identifiable {
    public let id: Int
    public let startAt: Date
    public let endAt: Date
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let sampleCount: Int
    public let latest: QuotaHistoryObservation
    public let minRemainingPercent: Double?
    public let maxRemainingPercent: Double?
    public let states: [QuotaHistoryState]
    public init(id: Int, startAt: Date, endAt: Date, firstObservedAt: Date, lastObservedAt: Date, sampleCount: Int, latest: QuotaHistoryObservation, minRemainingPercent: Double?, maxRemainingPercent: Double?, states: [QuotaHistoryState]) {
        self.id = id
        self.startAt = startAt
        self.endAt = endAt
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.sampleCount = sampleCount
        self.latest = latest
        self.minRemainingPercent = minRemainingPercent
        self.maxRemainingPercent = maxRemainingPercent
        self.states = states
    }
}

public struct QuotaHistoryEvent: Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: QuotaHistoryEventKind
    public let fromAt: Date
    public let toAt: Date
    public let beforeRemainingPercent: Double?
    public let afterRemainingPercent: Double?
    public init(id: String, kind: QuotaHistoryEventKind, fromAt: Date, toAt: Date, beforeRemainingPercent: Double?, afterRemainingPercent: Double?) {
        self.id = id
        self.kind = kind
        self.fromAt = fromAt
        self.toAt = toAt
        self.beforeRemainingPercent = beforeRemainingPercent
        self.afterRemainingPercent = afterRemainingPercent
    }
}

public struct QuotaHistoryCatalog: Equatable, Sendable {
    public let hostID: String
    public let accountID: String
    public let revision: UInt64
    public let recordingEnabled: Bool
    public let recordingError: String?
    public let firstObservedAt: Date?
    public let lastObservedAt: Date?
    public let metrics: [QuotaHistoryMetric]
    public init(hostID: String, accountID: String, revision: UInt64, recordingEnabled: Bool, recordingError: String?, firstObservedAt: Date?, lastObservedAt: Date?, metrics: [QuotaHistoryMetric]) {
        self.hostID = hostID
        self.accountID = accountID
        self.revision = revision
        self.recordingEnabled = recordingEnabled
        self.recordingError = recordingError
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.metrics = metrics
    }
}

public struct QuotaHistoryChart: Equatable, Sendable {
    public let hostID: String
    public let accountID: String
    public let metricID: String
    public let revision: UInt64
    public let range: QuotaHistoryRange
    public let startAt: Date
    public let endAt: Date
    public let binSeconds: Int
    public let recordingEnabled: Bool
    public let recordingError: String?
    public let bins: [QuotaHistoryBin]
    public let events: [QuotaHistoryEvent]
    public let nextCursor: String?
    public let latest: QuotaHistoryObservation?
    public let lowestRemainingPercent: Double?
    public init(hostID: String, accountID: String, metricID: String, revision: UInt64, range: QuotaHistoryRange, startAt: Date, endAt: Date, binSeconds: Int, recordingEnabled: Bool, recordingError: String?, bins: [QuotaHistoryBin], events: [QuotaHistoryEvent], nextCursor: String?, latest: QuotaHistoryObservation?, lowestRemainingPercent: Double?) {
        self.hostID = hostID
        self.accountID = accountID
        self.metricID = metricID
        self.revision = revision
        self.range = range
        self.startAt = startAt
        self.endAt = endAt
        self.binSeconds = binSeconds
        self.recordingEnabled = recordingEnabled
        self.recordingError = recordingError
        self.bins = bins
        self.events = events
        self.nextCursor = nextCursor
        self.latest = latest
        self.lowestRemainingPercent = lowestRemainingPercent
    }
}

public struct QuotaHistoryEventsPage: Equatable, Sendable {
    public let hostID: String
    public let accountID: String
    public let metricID: String
    public let revision: UInt64
    public let events: [QuotaHistoryEvent]
    public let nextCursor: String?
    public init(hostID: String, accountID: String, metricID: String, revision: UInt64, events: [QuotaHistoryEvent], nextCursor: String?) {
        self.hostID = hostID
        self.accountID = accountID
        self.metricID = metricID
        self.revision = revision
        self.events = events
        self.nextCursor = nextCursor
    }
}

