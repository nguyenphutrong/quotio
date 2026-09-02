import Observation
import QuotioApplication
import QuotioDomain

public enum LogsScreenState: Sendable, Equatable {
    case loading
    case empty
    case content
    case error(String)
}

@MainActor
@Observable
public final class LogsScreenModel {
    public private(set) var entries: [LogEntry] = []
    public private(set) var state: LogsScreenState = .empty
    public private(set) var errorMessage: String?
    public private(set) var isRefreshing = false
    public private(set) var isClearing = false

    @ObservationIgnored private let loadLogs: LoadProxyLogsUseCase
    @ObservationIgnored private let clearLogs: ClearProxyLogsUseCase
    @ObservationIgnored private let sleeper: any Sleeping
    @ObservationIgnored private var latestTimestamp: Int?

    public init(
        loadLogs: LoadProxyLogsUseCase,
        clearLogs: ClearProxyLogsUseCase,
        sleeper: any Sleeping
    ) {
        self.loadLogs = loadLogs
        self.clearLogs = clearLogs
        self.sleeper = sleeper
    }

    public func poll(interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await sleeper.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    public func refresh() async {
        guard !isRefreshing, !isClearing else { return }
        isRefreshing = true
        if entries.isEmpty {
            state = .loading
        }
        defer { isRefreshing = false }

        do {
            let result = try await loadLogs.execute(
                existingEntries: entries,
                after: latestTimestamp
            )
            entries = result.entries
            latestTimestamp = result.latestTimestamp
            errorMessage = nil
            state = entries.isEmpty ? .empty : .content
        } catch is CancellationError {
            state = entries.isEmpty ? .empty : .content
        } catch {
            errorMessage = error.localizedDescription
            state = entries.isEmpty ? .error(error.localizedDescription) : .content
        }
    }

    public func clear() async {
        guard !isClearing, !isRefreshing else { return }
        isClearing = true
        defer { isClearing = false }

        do {
            try await clearLogs.execute()
            entries.removeAll()
            latestTimestamp = nil
            errorMessage = nil
            state = .empty
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            state = entries.isEmpty ? .error(error.localizedDescription) : .content
        }
    }

    public func dismissError() {
        errorMessage = nil
        state = entries.isEmpty ? .empty : .content
    }
}
