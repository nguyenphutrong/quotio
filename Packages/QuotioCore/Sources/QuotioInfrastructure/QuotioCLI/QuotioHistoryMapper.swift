import QuotioDomain
import QuotioHostClient

// Transport validation guarantees the state and confidence raw values below.
enum QuotioHistoryMapper {
    static func availability(_ host: QuotioHostSnapshot.Host?, connected: Bool) -> QuotaHistoryAvailability {
        let read = host?.capabilities["quota_history"]
        let failure: QuotaHistoryError?
        if read?.available == true {
            failure = nil
        } else {
            switch read?.reason {
            case "history_storage_unavailable": failure = .storage
            case "insufficient_scope": failure = .unauthorized
            default: failure = .unsupported
            }
        }
        return .init(hostID: host?.id, connected: connected, canRead: read?.available == true,
                     canWrite: host?.capabilities["quota_history_write"]?.available == true, readFailure: failure)
    }
    static func observation(_ value: QuotioHostHistoryObservation) -> QuotaHistoryObservation {
        .init(seriesID: value.seriesId, basisID: value.basisId, fetchedAt: value.fetchedAt, expiresAt: value.expiresAt,
              state: QuotaHistoryState(rawValue: value.quota.state)!, remainingPercent: value.quota.remainingPercent,
              amount: value.amounts?.remaining ?? value.quota.amount, limit: value.amounts?.limit, unit: value.amounts?.unit ?? value.quota.unit,
              resetsAt: value.resetsAt, resetDescription: value.resetDescription, source: value.provenance.source,
              confidence: QuotaHistoryConfidence(rawValue: value.provenance.confidence)!)
    }
    static func event(_ value: QuotioHostHistoryEvent) -> QuotaHistoryEvent {
        .init(id: value.id, kind: QuotaHistoryEventKind(rawValue: value.kind)!, fromAt: value.fromAt, toAt: value.toAt,
              beforeRemainingPercent: value.beforeRemainingPercent, afterRemainingPercent: value.afterRemainingPercent)
    }
    static func catalog(_ value: QuotioHostHistoryCatalog) -> QuotaHistoryCatalog {
        .init(hostID: value.hostId, accountID: value.accountId, revision: value.historyRevision, recordingEnabled: value.recordingEnabled,
              recordingError: value.recordingError, firstObservedAt: value.firstObservedAt, lastObservedAt: value.lastObservedAt,
              metrics: value.metrics.map { .init(id: $0.id, displayName: $0.displayName, group: $0.group, current: $0.current, hasPercentage: $0.hasPercentage) })
    }
    static func chart(_ value: QuotioHostHistoryChart) -> QuotaHistoryChart {
        .init(hostID: value.hostId, accountID: value.accountId, metricID: value.metricId, revision: value.historyRevision,
              range: QuotaHistoryRange(rawValue: value.range.rawValue)!, startAt: value.startAt, endAt: value.endAt, binSeconds: value.binSeconds,
              recordingEnabled: value.recordingEnabled, recordingError: value.recordingError,
              bins: value.bins.map { .init(id: $0.id, startAt: $0.startAt, endAt: $0.endAt, firstObservedAt: $0.firstObservedAt, lastObservedAt: $0.lastObservedAt,
                                         sampleCount: $0.sampleCount, latest: observation($0.latest), minRemainingPercent: $0.minRemainingPercent,
                                         maxRemainingPercent: $0.maxRemainingPercent, states: $0.states.map { QuotaHistoryState(rawValue: $0)! }) },
              events: value.events.map(event), nextCursor: value.nextCursor, latest: value.latest.map(observation), lowestRemainingPercent: value.lowestRemainingPercent)
    }
}
