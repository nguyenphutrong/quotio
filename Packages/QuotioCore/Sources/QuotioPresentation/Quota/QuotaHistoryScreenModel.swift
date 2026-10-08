import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class QuotaHistoryScreenModel: Identifiable {
    public let id = UUID()
    public let accountID: String
    public private(set) var availability = QuotaHistoryAvailability(hostID: nil, connected: false, canRead: false, canWrite: false)
    public private(set) var catalog: QuotaHistoryCatalog?
    public private(set) var chart: QuotaHistoryChart?
    public private(set) var events: [QuotaHistoryEvent] = []
    public private(set) var nextCursor: String?
    public private(set) var isLoading = false
    public private(set) var isLoadingEvents = false
    public private(set) var error: QuotaHistoryError?
    public private(set) var eventError: QuotaHistoryError?
    public private(set) var mutationError: QuotaHistoryError?
    public private(set) var isClearing = false
    public private(set) var metricID: String?
    public private(set) var range: QuotaHistoryRange = .day
    public var selectedBinID: Int?
    @ObservationIgnored private let useCases: QuotaHistoryUseCases
    @ObservationIgnored private let coordinator: (any QuotaCoordinating)?
    @ObservationIgnored private let provider: QuotaProvider?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var pageRequest: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var lastQuota: ProviderQuota?
    @ObservationIgnored private var boundHostID: String?
    @ObservationIgnored private var lastHostRevision: UInt64?

    public init(accountID: String, useCases: QuotaHistoryUseCases, coordinator: (any QuotaCoordinating)? = nil, provider: QuotaProvider? = nil) {
        self.accountID = accountID
        self.useCases = useCases
        self.coordinator = coordinator
        self.provider = provider
    }
    deinit { request?.cancel(); pageRequest?.cancel(); observation?.cancel() }

    public var selectedMetric: QuotaHistoryMetric? { catalog?.metrics.first { $0.id == metricID } }
    public var selectedBin: QuotaHistoryBin? { chart?.bins.first { $0.id == selectedBinID } }
    public var selectedEvents: [QuotaHistoryEvent] {
        guard let bin = selectedBin else { return [] }
        return events.filter { event in
            let lower = min(event.fromAt, event.toAt)
            let upper = max(event.fromAt, event.toAt)
            return lower < bin.endAt && upper >= bin.startAt
        }
    }

    public func start() {
        guard !isActive else { return }
        isActive = true
        reload()
        if let coordinator {
            observation = Task { [weak self] in
                let states = await coordinator.states()
                for await state in states {
                    guard !Task.isCancelled, let self, self.isActive else { return }
                    let next = state.historyAvailability
                    let hostChanged = self.availability.hostID != nil && self.availability.hostID != next.hostID
                    let connectionChanged = self.availability != next
                    if hostChanged {
                        self.cancelReads()
                        self.catalog = nil; self.chart = nil; self.events = []; self.nextCursor = nil
                        self.metricID = nil; self.selectedBinID = nil; self.lastQuota = nil
                    }
                    self.availability = next
                    if let boundHostID = self.boundHostID, let hostID = next.hostID, boundHostID != hostID {
                        self.availability = .init(hostID: hostID, connected: next.connected, canRead: false, canWrite: false)
                        self.error = .hostChanged
                        continue
                    }
                    if !next.connected { self.cancelReads(); self.error = .offline; continue }
                    if !next.canRead { self.cancelReads(); self.error = next.readFailure ?? .unsupported; continue }
                    if let provider = self.provider {
                        let key = QuotaAccountID(provider: provider, accountKey: self.accountID)
                        if state.accountStates[key] == nil {
                            self.cancelReads(); self.catalog = nil; self.chart = nil; self.events = []; self.error = .requestFailed
                            continue
                        }
                        let quota = state.quotas[provider]?[self.accountID]
                        if self.lastQuota != quota || connectionChanged || self.lastHostRevision != state.hostRevision {
                            self.lastQuota = quota
                            self.lastHostRevision = state.hostRevision
                            self.reload()
                        }
                    } else if connectionChanged { self.reload() }
                }
            }
        }
    }
    public func stop() {
        isActive = false
        cancelReads()
        observation?.cancel(); observation = nil
    }
    private func cancelReads() {
        generation = UUID()
        request?.cancel(); request = nil
        pageRequest?.cancel(); pageRequest = nil
        isLoading = false; isLoadingEvents = false
    }
    public func select(metricID: String) {
        guard self.metricID != metricID else { return }
        self.metricID = metricID
        chart = nil; events = []; selectedBinID = nil
        reload()
    }
    public func select(range: QuotaHistoryRange) {
        guard self.range != range else { return }
        self.range = range
        chart = nil; events = []; selectedBinID = nil
        reload()
    }
    public func reload() {
        guard isActive else { return }
        cancelReads()
        let token = generation
        isLoading = true; error = nil; eventError = nil
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let availability = await useCases.reader.historyAvailability()
                guard accepts(token) else { return }
                self.availability = availability
                guard availability.connected else { throw QuotaHistoryError.offline }
                guard availability.canRead else { throw availability.readFailure ?? QuotaHistoryError.unsupported }
                if let boundHostID, boundHostID != availability.hostID {
                    catalog = nil; chart = nil; events = []; nextCursor = nil
                    self.availability = .init(hostID: availability.hostID, connected: availability.connected, canRead: false, canWrite: false)
                    throw QuotaHistoryError.hostChanged
                }
                boundHostID = availability.hostID
                let catalog = try await useCases.reader.historyCatalog(accountID: accountID)
                guard accepts(token) else { return }
                guard catalog.hostID == availability.hostID, catalog.accountID == accountID else { throw QuotaHistoryError.invalidResponse }
                self.catalog = catalog
                if !catalog.metrics.contains(where: { $0.id == metricID }) {
                    metricID = catalog.metrics.first(where: { $0.current && $0.hasPercentage })?.id
                        ?? catalog.metrics.first(where: { $0.hasPercentage })?.id
                    chart = nil; events = []; selectedBinID = nil; nextCursor = nil
                }
                guard let metricID else { self.chart = nil; self.isLoading = false; return }
                let result = try await useCases.reader.historyChart(accountID: accountID, metricID: metricID, range: range)
                guard accepts(token) else { return }
                guard result.hostID == catalog.hostID, result.accountID == accountID, result.metricID == metricID,
                      result.range == range, result.revision >= catalog.revision else { throw QuotaHistoryError.invalidResponse }
                chart = result; events = result.events; nextCursor = result.nextCursor
                if !result.bins.contains(where: { $0.id == selectedBinID }) { selectedBinID = result.bins.last?.id }
                isLoading = false
            } catch {
                guard accepts(token), !(error is CancellationError) else { return }
                self.error = error as? QuotaHistoryError ?? .requestFailed
                if self.error == .offline {
                    self.availability = .init(hostID: self.availability.hostID, connected: false, canRead: self.availability.canRead, canWrite: self.availability.canWrite)
                }
                self.isLoading = false
            }
        }
    }
    private func accepts(_ token: UUID) -> Bool { isActive && generation == token && !Task.isCancelled }

    public func loadMoreEvents() {
        guard isActive, availability.connected, !isLoadingEvents, let cursor = nextCursor, let chart else { return }
        let token = generation
        isLoadingEvents = true; eventError = nil
        pageRequest = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await useCases.reader.historyEvents(accountID: accountID, metricID: chart.metricID, range: chart.range, cursor: cursor)
                guard accepts(token) else { return }
                guard page.hostID == chart.hostID, page.accountID == accountID, page.metricID == chart.metricID,
                      page.revision == chart.revision, page.nextCursor != cursor,
                      Set(events.map(\.id)).isDisjoint(with: page.events.map(\.id)) else { throw QuotaHistoryError.invalidResponse }
                events.append(contentsOf: page.events); nextCursor = page.nextCursor; isLoadingEvents = false
            } catch {
                guard accepts(token), !(error is CancellationError) else { return }
                eventError = error as? QuotaHistoryError ?? .requestFailed; isLoadingEvents = false
            }
        }
    }
    public func moveSelection(by offset: Int) {
        guard let bins = chart?.bins, !bins.isEmpty else { return }
        let current = bins.firstIndex { $0.id == selectedBinID } ?? (offset > 0 ? -1 : bins.count)
        selectedBinID = bins[max(0, min(bins.count - 1, current + offset))].id
    }
    public func select(at time: Date) {
        selectedBinID = chart?.bins.first { time >= $0.startAt && time < $0.endAt }?.id
    }
    public func clearAccount() async {
        guard isActive, availability.connected, availability.canWrite, availability.hostID == boundHostID, !isClearing else { return }
        isClearing = true; mutationError = nil
        cancelReads()
        let host = availability.hostID
        do {
            try await useCases.clear(accountID: accountID)
            guard isActive, availability.hostID == host else { isClearing = false; return }
            chart = nil; events = []; catalog = nil; nextCursor = nil; selectedBinID = nil
            isClearing = false
            reload()
        } catch {
            guard isActive, availability.hostID == host else { isClearing = false; return }
            mutationError = error as? QuotaHistoryError ?? .requestFailed; isClearing = false
        }
    }
}
