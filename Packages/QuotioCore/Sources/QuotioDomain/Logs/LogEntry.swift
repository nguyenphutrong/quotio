import Foundation

public struct LogEntry: Identifiable, Sendable, Equatable {
    public enum Level: String, CaseIterable, Sendable {
        case info
        case warn
        case error
        case debug

        public init(message: String) {
            let normalizedMessage = message.lowercased()
            if normalizedMessage.contains("error") {
                self = .error
            } else if normalizedMessage.contains("warn") {
                self = .warn
            } else if normalizedMessage.contains("debug") {
                self = .debug
            } else {
                self = .info
            }
        }
    }

    public let id: UUID
    public let timestamp: Date
    public let level: Level
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        level: Level,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }

    public init(id: UUID = UUID(), timestamp: Date, message: String) {
        self.init(
            id: id,
            timestamp: timestamp,
            level: Level(message: message),
            message: message
        )
    }
}
