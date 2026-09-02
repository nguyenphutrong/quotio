import QuotioDomain

public struct ProxyLogLoadResult: Sendable, Equatable {
    public let entries: [LogEntry]
    public let latestTimestamp: Int?

    public init(entries: [LogEntry], latestTimestamp: Int?) {
        self.entries = entries
        self.latestTimestamp = latestTimestamp
    }
}

public struct ProxyLogRetentionPolicy: Sendable {
    public let maximumEntryCount: Int

    public init(maximumEntryCount: Int = 50) {
        precondition(maximumEntryCount > 0)
        self.maximumEntryCount = maximumEntryCount
    }

    public func retainRecentEntries(_ entries: [LogEntry]) -> [LogEntry] {
        Array(entries.suffix(maximumEntryCount))
    }
}

public struct LoadProxyLogsUseCase: Sendable {
    private let repository: any ProxyLogRepository
    private let timeProvider: any DateProviding
    private let retentionPolicy: ProxyLogRetentionPolicy

    public init(
        repository: any ProxyLogRepository,
        timeProvider: any DateProviding,
        retentionPolicy: ProxyLogRetentionPolicy = ProxyLogRetentionPolicy()
    ) {
        self.repository = repository
        self.timeProvider = timeProvider
        self.retentionPolicy = retentionPolicy
    }

    public func execute(
        existingEntries: [LogEntry],
        after timestamp: Int?
    ) async throws -> ProxyLogLoadResult {
        try Task.checkCancellation()
        let page = try await repository.fetchLogs(after: timestamp)
        try Task.checkCancellation()

        let newEntries = page.lines.map { line in
            LogEntry(timestamp: timeProvider.now(), message: line)
        }
        return ProxyLogLoadResult(
            entries: retentionPolicy.retainRecentEntries(existingEntries + newEntries),
            latestTimestamp: page.latestTimestamp
        )
    }
}

public struct ClearProxyLogsUseCase: Sendable {
    private let repository: any ProxyLogRepository

    public init(repository: any ProxyLogRepository) {
        self.repository = repository
    }

    public func execute() async throws {
        try Task.checkCancellation()
        try await repository.clearLogs()
        try Task.checkCancellation()
    }
}
