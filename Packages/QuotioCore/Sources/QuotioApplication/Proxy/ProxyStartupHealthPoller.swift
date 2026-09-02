import Foundation

public struct ProxyStartupHealthPoller: Sendable {
    public enum Outcome: Equatable, Sendable {
        case ready
        case processExited
        case timedOut
    }

    public static let defaultTimeoutNanoseconds: UInt64 = 10_000_000_000
    public static let defaultRetryDelayNanoseconds: UInt64 = 250_000_000

    public let timeoutNanoseconds: UInt64
    public let retryDelayNanoseconds: UInt64

    public init(
        timeoutNanoseconds: UInt64 = Self.defaultTimeoutNanoseconds,
        retryDelayNanoseconds: UInt64 = Self.defaultRetryDelayNanoseconds
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.retryDelayNanoseconds = max(1, retryDelayNanoseconds)
    }

    public func waitUntilReady(
        isProcessRunning: () async -> Bool,
        checkHealth: () async -> Bool,
        sleep: (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) async throws -> Outcome {
        let startedAt = now()
        let (candidateDeadline, overflowed) = startedAt.addingReportingOverflow(timeoutNanoseconds)
        let deadline = overflowed ? UInt64.max : candidateDeadline
        var isFirstAttempt = true

        while true {
            guard await isProcessRunning() else {
                return .processExited
            }

            if !isFirstAttempt, now() >= deadline {
                return .timedOut
            }

            if await checkHealth() {
                return .ready
            }

            try Task.checkCancellation()

            guard await isProcessRunning() else {
                return .processExited
            }

            let currentTime = now()
            guard currentTime < deadline else {
                return .timedOut
            }

            try await sleep(min(retryDelayNanoseconds, deadline - currentTime))
            isFirstAttempt = false
        }
    }
}
