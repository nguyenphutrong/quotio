import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain

final class TunnelLifecycleControllerTests: XCTestCase {
    private let installed = CloudflaredInstallation(
        isInstalled: true,
        path: "/test/cloudflared",
        version: "1.2.3"
    )

    func testStartFailureRollsBackRemoteAccess() async {
        let process = TunnelProcessDouble(installation: installed, startFailures: [.startFailed("boom")])
        let remoteAccess = TunnelRemoteAccessDouble()
        let controller = makeController(process: process, remoteAccess: remoteAccess)

        await controller.start(port: 8317)

        let snapshot = await controller.snapshot
        let remoteUpdates = await remoteAccess.updates
        let stopCount = await process.stopCount
        XCTAssertEqual(snapshot.status, .error)
        XCTAssertEqual(snapshot.failure, .startFailed("boom"))
        XCTAssertEqual(remoteUpdates, [true, false])
        XCTAssertEqual(stopCount, 1)
    }

    func testCancellationWhileEnablingRemoteAccessRollsBack() async {
        let process = TunnelProcessDouble(installation: installed)
        let remoteAccess = TunnelRemoteAccessDouble(suspendFirstEnable: true)
        let controller = makeController(process: process, remoteAccess: remoteAccess)
        let task = Task { await controller.start(port: 8317) }
        let didSuspend = await eventually { await remoteAccess.hasSuspendedEnable }
        XCTAssertTrue(didSuspend)

        task.cancel()
        await remoteAccess.resumeEnable()
        await task.value

        let snapshot = await controller.snapshot
        let remoteUpdates = await remoteAccess.updates
        let startCount = await process.startCount
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertEqual(remoteUpdates, [true, false])
        XCTAssertEqual(startCount, 0)
    }

    func testCancellationWhileStartingProcessStopsItAndRollsBackRemoteAccess() async {
        let process = TunnelProcessDouble(
            installation: installed,
            suspendFirstStart: true
        )
        let remoteAccess = TunnelRemoteAccessDouble()
        let controller = makeController(process: process, remoteAccess: remoteAccess)
        let task = Task { await controller.start(port: 8317) }
        let didSuspend = await eventually { await process.hasSuspendedStart }
        XCTAssertTrue(didSuspend)

        task.cancel()
        await process.resumeStart()
        await task.value

        let snapshot = await controller.snapshot
        let remoteUpdates = await remoteAccess.updates
        let stopCount = await process.stopCount
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertEqual(remoteUpdates, [true, false])
        XCTAssertEqual(stopCount, 1)
    }

    func testStartTimeoutStopsProcessAndRollsBackRemoteAccess() async {
        let process = TunnelProcessDouble(installation: installed)
        let remoteAccess = TunnelRemoteAccessDouble()
        let sleeper = TunnelSleeperDouble()
        let controller = makeController(
            process: process,
            remoteAccess: remoteAccess,
            sleeper: sleeper
        )

        await controller.start(port: 8317)
        let didScheduleTimeout = await eventually {
            await sleeper.waitingCount(for: .seconds(30)) == 1
        }
        XCTAssertTrue(didScheduleTimeout)
        await sleeper.resumeFirst(for: .seconds(30))

        let didTimeOut = await eventually { await controller.snapshot.status == .error }
        XCTAssertTrue(didTimeOut)
        let snapshot = await controller.snapshot
        let remoteUpdates = await remoteAccess.updates
        let stopCount = await process.stopCount
        XCTAssertEqual(snapshot.failure, .startTimeout)
        XCTAssertEqual(remoteUpdates, [true, false])
        XCTAssertEqual(stopCount, 1)
    }

    func testStaleURLCallbackCannotReplaceCurrentRequestOrRollBackItsRemoteAccess() async {
        let process = TunnelProcessDouble(installation: installed)
        let remoteAccess = TunnelRemoteAccessDouble()
        let controller = makeController(process: process, remoteAccess: remoteAccess)

        await controller.start(port: 8317)
        await controller.stop()
        await controller.start(port: 9000)
        await process.emitURL("https://stale.trycloudflare.com", callbackIndex: 0)

        let stayedStarting = await eventually { await controller.snapshot.status == .starting }
        XCTAssertTrue(stayedStarting)
        let staleSnapshot = await controller.snapshot
        let remoteUpdates = await remoteAccess.updates
        XCTAssertNil(staleSnapshot.publicURL)
        XCTAssertEqual(remoteUpdates, [true, false, true])

        await process.emitURL("https://current.trycloudflare.com", callbackIndex: 1)
        let becameActive = await eventually { await controller.snapshot.status == .active }
        XCTAssertTrue(becameActive)
        let activeSnapshot = await controller.snapshot
        XCTAssertEqual(activeSnapshot.publicURL, "https://current.trycloudflare.com")
        XCTAssertEqual(activeSnapshot.startTime, Date(timeIntervalSince1970: 1_234))
        await controller.shutdown()
    }

    func testSuccessfulAutomaticRestartResetsRetryBudget() async {
        let process = TunnelProcessDouble(installation: installed)
        let remoteAccess = TunnelRemoteAccessDouble()
        let sleeper = TunnelSleeperDouble()
        let controller = makeController(
            process: process,
            remoteAccess: remoteAccess,
            sleeper: sleeper,
            autoRestart: true,
            maximumAutoRestartAttempts: 1
        )

        await controller.start(port: 8317)
        await process.emitURL("https://initial.trycloudflare.com", callbackIndex: 0)
        let initiallyActive = await eventually { await controller.snapshot.status == .active }
        XCTAssertTrue(initiallyActive)

        for recovery in 1...2 {
            await process.setRunning(false)
            let monitoring = await eventually {
                await sleeper.waitingCount(for: .seconds(2)) == 1
            }
            XCTAssertTrue(monitoring)
            await sleeper.resumeFirst(for: .seconds(2))
            let detectedExit = await eventually { await controller.snapshot.status == .error }
            XCTAssertTrue(detectedExit)
            let scheduledRestart = await eventually {
                await sleeper.waitingCount(for: .seconds(5)) == 1
            }
            XCTAssertTrue(scheduledRestart)
            await sleeper.resumeFirst(for: .seconds(5))
            let restarted = await eventually { await process.startCount == recovery + 1 }
            XCTAssertTrue(restarted)
            await process.emitURL(
                "https://recovery-\(recovery).trycloudflare.com",
                callbackIndex: recovery
            )
            let recoveryBecameActive = await eventually {
                await controller.snapshot.status == .active
            }
            XCTAssertTrue(recoveryBecameActive)
        }

        let startCount = await process.startCount
        XCTAssertEqual(startCount, 3)
        await controller.shutdown()
    }

    func testConsecutiveFailedAutomaticRestartsStopAtConfiguredRetryCap() async {
        let process = TunnelProcessDouble(installation: installed)
        let sleeper = TunnelSleeperDouble()
        let controller = makeController(
            process: process,
            remoteAccess: TunnelRemoteAccessDouble(),
            sleeper: sleeper,
            autoRestart: true,
            maximumAutoRestartAttempts: 3
        )

        await controller.start(port: 8317)
        await process.emitURL("https://initial.trycloudflare.com", callbackIndex: 0)
        let initiallyActive = await eventually { await controller.snapshot.status == .active }
        XCTAssertTrue(initiallyActive)
        await process.setStartFailures([
            .startFailed("first"),
            .startFailed("second"),
            .startFailed("third"),
        ])
        await process.setRunning(false)
        let monitoring = await eventually {
            await sleeper.waitingCount(for: .seconds(2)) == 1
        }
        XCTAssertTrue(monitoring)
        await sleeper.resumeFirst(for: .seconds(2))
        let detectedExit = await eventually { await controller.snapshot.status == .error }
        XCTAssertTrue(detectedExit)

        for attempt in 1...3 {
            let scheduledRestart = await eventually {
                await sleeper.waitingCount(for: .seconds(5)) == 1
            }
            XCTAssertTrue(scheduledRestart)
            await sleeper.resumeFirst(for: .seconds(5))
            let failed = await eventually {
                let startCount = await process.startCount
                let status = await controller.snapshot.status
                return startCount == attempt + 1 && status == .error
            }
            XCTAssertTrue(failed)
        }
        await Task.yield()

        let startCount = await process.startCount
        let pendingRestarts = await sleeper.waitingCount(for: .seconds(5))
        XCTAssertEqual(startCount, 4)
        XCTAssertEqual(pendingRestarts, 0)
        await controller.shutdown()
    }

    func testShutdownStopsTunnelDisablesRemoteAccessAndCancelsRestart() async {
        let process = TunnelProcessDouble(installation: installed)
        let remoteAccess = TunnelRemoteAccessDouble()
        let sleeper = TunnelSleeperDouble()
        let controller = makeController(
            process: process,
            remoteAccess: remoteAccess,
            sleeper: sleeper,
            autoRestart: true
        )

        await controller.start(port: 8317)
        await process.emitURL("https://active.trycloudflare.com", callbackIndex: 0)
        let becameActive = await eventually { await controller.snapshot.status == .active }
        XCTAssertTrue(becameActive)

        await controller.shutdown()

        let snapshot = await controller.snapshot
        let remoteUpdates = await remoteAccess.updates
        let stopCount = await process.stopCount
        let pendingRestarts = await sleeper.waitingCount(for: .seconds(5))
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertNil(snapshot.publicURL)
        XCTAssertEqual(remoteUpdates, [true, false])
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(pendingRestarts, 0)
    }

    func testCleanupOrphansDelegatesToProcessAdapter() async {
        let process = TunnelProcessDouble(installation: installed)
        let controller = makeController(
            process: process,
            remoteAccess: TunnelRemoteAccessDouble()
        )

        await controller.cleanupOrphans()

        let orphanCleanupCount = await process.orphanCleanupCount
        XCTAssertEqual(orphanCleanupCount, 1)
    }

    private func makeController(
        process: TunnelProcessDouble,
        remoteAccess: TunnelRemoteAccessDouble,
        sleeper: TunnelSleeperDouble = TunnelSleeperDouble(),
        autoRestart: Bool = false,
        maximumAutoRestartAttempts: Int = 3
    ) -> TunnelLifecycleController {
        TunnelLifecycleController(
            tunnel: process,
            remoteAccess: remoteAccess,
            preferences: TunnelPreferencesDouble(autoRestart: autoRestart),
            sleeper: sleeper,
            clock: TunnelClockDouble(),
            configuration: TunnelLifecycleController.Configuration(
                startTimeout: .seconds(30),
                monitorInterval: .seconds(2),
                autoRestartDelay: .seconds(5),
                maximumAutoRestartAttempts: maximumAutoRestartAttempts
            ),
            initialSnapshot: CloudflareTunnelSnapshot(installation: installed)
        )
    }

    private func eventually(
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }
}

private actor TunnelProcessDouble: TunnelControlling {
    private let installation: CloudflaredInstallation
    private var startFailures: [TunnelFailure]
    private let suspendFirstStart: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var callbacks: [@Sendable (String) -> Void] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var orphanCleanupCount = 0
    private var running = false

    init(
        installation: CloudflaredInstallation,
        startFailures: [TunnelFailure] = [],
        suspendFirstStart: Bool = false
    ) {
        self.installation = installation
        self.startFailures = startFailures
        self.suspendFirstStart = suspendFirstStart
    }

    var hasSuspendedStart: Bool { startContinuation != nil }

    func detectInstallation() -> CloudflaredInstallation { installation }

    func start(
        port: UInt16,
        onURLDetected: @escaping @Sendable (String) -> Void
    ) async throws {
        startCount += 1
        if !startFailures.isEmpty {
            throw startFailures.removeFirst()
        }
        callbacks.append(onURLDetected)
        running = true
        if suspendFirstStart, startCount == 1 {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
    }

    func stop() {
        stopCount += 1
        running = false
    }

    func isRunning() -> Bool { running }

    func cleanupOrphans() {
        orphanCleanupCount += 1
    }

    func setRunning(_ running: Bool) {
        self.running = running
    }

    func setStartFailures(_ failures: [TunnelFailure]) {
        startFailures = failures
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func emitURL(_ url: String, callbackIndex: Int) {
        callbacks[callbackIndex](url)
    }
}

private actor TunnelRemoteAccessDouble: TunnelRemoteAccessControlling {
    private let suspendFirstEnable: Bool
    private var enableContinuation: CheckedContinuation<Void, Never>?
    private(set) var updates: [Bool] = []

    init(suspendFirstEnable: Bool = false) {
        self.suspendFirstEnable = suspendFirstEnable
    }

    var hasSuspendedEnable: Bool { enableContinuation != nil }

    func setRemoteAccessEnabled(_ enabled: Bool) async {
        updates.append(enabled)
        guard enabled, suspendFirstEnable, updates.count == 1 else { return }
        await withCheckedContinuation { continuation in
            enableContinuation = continuation
        }
    }

    func resumeEnable() {
        enableContinuation?.resume()
        enableContinuation = nil
    }
}

private actor TunnelSleeperDouble: Sleeping {
    private struct Waiter {
        let id: UUID
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(
                        id: id,
                        duration: duration,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func waitingCount(for duration: Duration) -> Int {
        waiters.count { $0.duration == duration }
    }

    func resumeFirst(for duration: Duration) {
        guard let index = waiters.firstIndex(where: { $0.duration == duration }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume()
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private struct TunnelPreferencesDouble: TunnelPreferencesRepository {
    let autoRestart: Bool

    func load() -> TunnelPreferences {
        TunnelPreferences(autoRestartTunnel: autoRestart)
    }

    func setAutoStartTunnel(_ enabled: Bool) {}
    func setAutoRestartTunnel(_ enabled: Bool) {}
}

private struct TunnelClockDouble: DateProviding {
    func now() -> Date { Date(timeIntervalSince1970: 1_234) }
}
