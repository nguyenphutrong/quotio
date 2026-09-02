import Foundation

public enum ApplicationLogLevel: Sendable {
    case debug
    case info
    case warning
    case error
}

public protocol ApplicationLogging: Sendable {
    func write(_ level: ApplicationLogLevel, message: String) async
}

public protocol Sleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

public protocol DateProviding: Sendable {
    func now() -> Date
}

@MainActor
public protocol URLOpening: Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool
}

public protocol UserNotificationDelivering<Notification>: Sendable {
    associatedtype Notification: Sendable

    func deliver(_ notification: Notification) async throws
}

public protocol LifecycleCancelling: Sendable {
    func cancelForTermination() async
}
