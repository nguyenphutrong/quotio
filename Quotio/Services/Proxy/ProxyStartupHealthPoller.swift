//
//  ProxyStartupHealthPoller.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation

/// Polls a newly launched proxy without assuming that every machine reaches
/// the management endpoint within a fixed startup delay.
@MainActor
struct ProxyStartupHealthPoller {
    enum Outcome: Equatable {
        case ready
        case processExited
        case timedOut
    }

    nonisolated static let defaultTimeoutNanoseconds: UInt64 = 10_000_000_000
    nonisolated static let defaultRetryDelayNanoseconds: UInt64 = 250_000_000

    let timeoutNanoseconds: UInt64
    let retryDelayNanoseconds: UInt64

    init(
        timeoutNanoseconds: UInt64 = Self.defaultTimeoutNanoseconds,
        retryDelayNanoseconds: UInt64 = Self.defaultRetryDelayNanoseconds
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.retryDelayNanoseconds = max(1, retryDelayNanoseconds)
    }

    func waitUntilReady(
        isProcessRunning: () -> Bool,
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
            guard isProcessRunning() else {
                return .processExited
            }

            if !isFirstAttempt, now() >= deadline {
                return .timedOut
            }

            if await checkHealth() {
                return .ready
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
