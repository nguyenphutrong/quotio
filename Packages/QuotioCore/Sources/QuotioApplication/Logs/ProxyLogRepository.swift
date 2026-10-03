public struct ProxyLogPage: Sendable, Equatable {
    public let lines: [String]
    public let latestTimestamp: Int?

    public init(lines: [String], latestTimestamp: Int?) {
        self.lines = lines
        self.latestTimestamp = latestTimestamp
    }
}

public enum ProxyLogFailure: Error, Sendable, Equatable {
    case loggingDisabled
}

public protocol ProxyLogRepository: Sendable {
    func fetchLogs(after timestamp: Int?) async throws -> ProxyLogPage
    func clearLogs() async throws
}
