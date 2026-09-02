import XCTest
@testable import QuotioApplication

final class ProxyStartupHealthPollerTests: XCTestCase {
    func testRetriesUntilDelayedProxyBecomesHealthy() async throws {
        let poller = ProxyStartupHealthPoller(timeoutNanoseconds: 100, retryDelayNanoseconds: 25)
        var healthChecks = 0
        var sleeps: [UInt64] = []
        var currentTime: UInt64 = 0

        let outcome = try await poller.waitUntilReady(
            isProcessRunning: { true },
            checkHealth: {
                healthChecks += 1
                return healthChecks == 3
            },
            sleep: {
                sleeps.append($0)
                currentTime += $0
            },
            now: { currentTime }
        )

        XCTAssertEqual(outcome, .ready)
        XCTAssertEqual(healthChecks, 3)
        XCTAssertEqual(sleeps, [25, 25])
    }

    func testStopsBeforeAnotherHealthCheckWhenProcessExits() async throws {
        let poller = ProxyStartupHealthPoller(timeoutNanoseconds: 100, retryDelayNanoseconds: 25)
        var processChecks = 0
        var healthChecks = 0
        var sleeps = 0
        var currentTime: UInt64 = 0

        let outcome = try await poller.waitUntilReady(
            isProcessRunning: {
                processChecks += 1
                return processChecks == 1
            },
            checkHealth: {
                healthChecks += 1
                return false
            },
            sleep: {
                sleeps += 1
                currentTime += $0
            },
            now: { currentTime }
        )

        XCTAssertEqual(outcome, .processExited)
        XCTAssertEqual(processChecks, 2)
        XCTAssertEqual(healthChecks, 1)
        XCTAssertEqual(sleeps, 0)
    }

    func testReportsProcessExitDuringFinalHealthCheck() async throws {
        let poller = ProxyStartupHealthPoller(timeoutNanoseconds: 100, retryDelayNanoseconds: 25)
        var isProcessRunning = true
        var currentTime: UInt64 = 0

        let outcome = try await poller.waitUntilReady(
            isProcessRunning: { isProcessRunning },
            checkHealth: {
                isProcessRunning = false
                currentTime = 100
                return false
            },
            sleep: { _ in XCTFail("An exited process must not sleep") },
            now: { currentTime }
        )

        XCTAssertEqual(outcome, .processExited)
    }

    func testTimesOutAtDeadlineAndTruncatesFinalSleep() async throws {
        let poller = ProxyStartupHealthPoller(timeoutNanoseconds: 60, retryDelayNanoseconds: 25)
        var healthChecks = 0
        var sleeps: [UInt64] = []
        var currentTime: UInt64 = 0

        let outcome = try await poller.waitUntilReady(
            isProcessRunning: { true },
            checkHealth: {
                healthChecks += 1
                return false
            },
            sleep: {
                sleeps.append($0)
                currentTime += $0
            },
            now: { currentTime }
        )

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(healthChecks, 3)
        XCTAssertEqual(sleeps, [25, 25, 10])
    }

    func testCancellationFromRetryDelayPropagates() async {
        let poller = ProxyStartupHealthPoller(timeoutNanoseconds: 100, retryDelayNanoseconds: 25)

        do {
            _ = try await poller.waitUntilReady(
                isProcessRunning: { true },
                checkHealth: { false },
                sleep: { _ in throw CancellationError() },
                now: { 0 }
            )
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationDuringFinalHealthCheckPropagates() async {
        let poller = ProxyStartupHealthPoller(timeoutNanoseconds: 100, retryDelayNanoseconds: 25)
        var currentTime: UInt64 = 0

        let task = Task {
            try await poller.waitUntilReady(
                isProcessRunning: { true },
                checkHealth: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    currentTime = 100
                    return false
                },
                sleep: { _ in XCTFail("A cancelled task must not sleep") },
                now: { currentTime }
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testZeroTimeoutStillPerformsInitialProbe() async throws {
        let poller = ProxyStartupHealthPoller(timeoutNanoseconds: 0, retryDelayNanoseconds: 25)
        var healthChecks = 0

        let outcome = try await poller.waitUntilReady(
            isProcessRunning: { true },
            checkHealth: {
                healthChecks += 1
                return true
            },
            sleep: { _ in XCTFail("A successful first probe must not sleep") },
            now: { 0 }
        )

        XCTAssertEqual(outcome, .ready)
        XCTAssertEqual(healthChecks, 1)
    }

    func testZeroRetryDelayIsClampedToAvoidBusyLoop() async throws {
        let poller = ProxyStartupHealthPoller(timeoutNanoseconds: 2, retryDelayNanoseconds: 0)
        var currentTime: UInt64 = 0
        var sleeps: [UInt64] = []

        let outcome = try await poller.waitUntilReady(
            isProcessRunning: { true },
            checkHealth: { false },
            sleep: {
                sleeps.append($0)
                currentTime += $0
            },
            now: { currentTime }
        )

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(sleeps, [1, 1])
    }
}
