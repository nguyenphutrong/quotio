import Foundation
import QuotioDomain

public actor TunnelLifecycleController: TunnelLifecycleControlling {
    public struct Configuration: Equatable, Sendable {
        public var startTimeout: Duration
        public var monitorInterval: Duration
        public var autoRestartDelay: Duration
        public var maximumAutoRestartAttempts: Int

        public init(
            startTimeout: Duration = .seconds(30),
            monitorInterval: Duration = .seconds(2),
            autoRestartDelay: Duration = .seconds(5),
            maximumAutoRestartAttempts: Int = 3
        ) {
            self.startTimeout = startTimeout
            self.monitorInterval = monitorInterval
            self.autoRestartDelay = autoRestartDelay
            self.maximumAutoRestartAttempts = maximumAutoRestartAttempts
        }
    }

    private let tunnel: any TunnelControlling
    private let remoteAccess: any TunnelRemoteAccessControlling
    private let preferences: any TunnelPreferencesRepository
    private let sleeper: any Sleeping
    private let clock: any DateProviding
    private let configuration: Configuration

    private var currentSnapshot: CloudflareTunnelSnapshot
    private var continuations: [UUID: AsyncStream<CloudflareTunnelSnapshot>.Continuation] = [:]
    private var monitorTask: Task<Void, Never>?
    private var startTimeoutTask: Task<Void, Never>?
    private var autoRestartTask: Task<Void, Never>?
    private var requestID: UInt64 = 0
    private var remoteAccessOwner: UInt64?
    private var lastPort: UInt16?
    private var autoRestartAttempts = 0

    public init(
        tunnel: any TunnelControlling,
        remoteAccess: any TunnelRemoteAccessControlling,
        preferences: any TunnelPreferencesRepository,
        sleeper: any Sleeping,
        clock: any DateProviding,
        configuration: Configuration = Configuration(),
        initialSnapshot: CloudflareTunnelSnapshot = CloudflareTunnelSnapshot()
    ) {
        self.tunnel = tunnel
        self.remoteAccess = remoteAccess
        self.preferences = preferences
        self.sleeper = sleeper
        self.clock = clock
        self.configuration = configuration
        self.currentSnapshot = initialSnapshot
    }

    deinit {
        monitorTask?.cancel()
        startTimeoutTask?.cancel()
        autoRestartTask?.cancel()
        continuations.values.forEach { $0.finish() }
    }

    public var snapshot: CloudflareTunnelSnapshot { currentSnapshot }

    public func states() -> AsyncStream<CloudflareTunnelSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: CloudflareTunnelSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = continuation
        continuation.yield(currentSnapshot)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    public func refreshInstallation() async {
        currentSnapshot.installation = await tunnel.detectInstallation()
        publish()
    }

    public func start(port: UInt16) async {
        await start(port: port, isAutomaticRestart: false)
    }

    public func stop() async {
        let previousStatus = currentSnapshot.status
        requestID &+= 1
        cancelScheduledTasks()

        if previousStatus == .active || previousStatus == .starting {
            currentSnapshot.status = .stopping
            currentSnapshot.failure = nil
            publish()
        }

        let shouldDisableRemoteAccess = remoteAccessOwner != nil
        remoteAccessOwner = nil
        await tunnel.stop()
        if shouldDisableRemoteAccess {
            await remoteAccess.setRemoteAccessEnabled(false)
        }

        currentSnapshot.status = .idle
        currentSnapshot.publicURL = nil
        currentSnapshot.failure = nil
        currentSnapshot.startTime = nil
        publish()
    }

    public func toggle(port: UInt16) async {
        if currentSnapshot.isActive || currentSnapshot.status == .starting {
            await stop()
        } else {
            await start(port: port)
        }
    }

    public func shutdown() async {
        await stop()
    }

    public func cleanupOrphans() async {
        await tunnel.cleanupOrphans()
    }

    private func start(port: UInt16, isAutomaticRestart: Bool) async {
        guard currentSnapshot.status == .idle || currentSnapshot.status == .error else {
            return
        }
        guard currentSnapshot.installation.isInstalled else {
            currentSnapshot.status = .error
            currentSnapshot.failure = .notInstalled
            publish()
            return
        }

        if !isAutomaticRestart {
            autoRestartAttempts = 0
            cancelAutoRestart()
        }
        cancelStartTimeout()
        stopMonitoring()

        requestID &+= 1
        let activeRequestID = requestID
        remoteAccessOwner = activeRequestID
        currentSnapshot.status = .starting
        currentSnapshot.publicURL = nil
        currentSnapshot.failure = nil
        currentSnapshot.startTime = nil
        publish()

        await remoteAccess.setRemoteAccessEnabled(true)
        guard await continueStarting(requestID: activeRequestID) else { return }

        do {
            try await tunnel.start(port: port) { [weak self] url in
                Task { await self?.receive(url: url, requestID: activeRequestID, port: port) }
            }
            guard await continueStarting(requestID: activeRequestID) else { return }
            scheduleStartTimeout(requestID: activeRequestID)
            startMonitoring(requestID: activeRequestID)
        } catch is CancellationError {
            await failStart(
                requestID: activeRequestID,
                failure: nil,
                shouldRetry: false
            )
        } catch let failure as TunnelFailure {
            await failStart(
                requestID: activeRequestID,
                failure: failure,
                shouldRetry: isAutomaticRestart
            )
        } catch {
            await failStart(
                requestID: activeRequestID,
                failure: .startFailed(error.localizedDescription),
                shouldRetry: isAutomaticRestart
            )
        }
    }

    private func continueStarting(requestID expectedRequestID: UInt64) async -> Bool {
        guard !Task.isCancelled else {
            await failStart(requestID: expectedRequestID, failure: nil, shouldRetry: false)
            return false
        }
        return requestID == expectedRequestID
            && remoteAccessOwner == expectedRequestID
            && currentSnapshot.status == .starting
    }

    private func receive(url: String, requestID expectedRequestID: UInt64, port: UInt16) {
        guard requestID == expectedRequestID,
              remoteAccessOwner == expectedRequestID,
              currentSnapshot.status == .starting else {
            return
        }

        cancelStartTimeout()
        autoRestartAttempts = 0
        currentSnapshot.status = .active
        currentSnapshot.publicURL = url
        currentSnapshot.failure = nil
        currentSnapshot.startTime = clock.now()
        lastPort = port
        publish()
    }

    private func failStart(
        requestID expectedRequestID: UInt64,
        failure: TunnelFailure?,
        shouldRetry: Bool
    ) async {
        guard requestID == expectedRequestID else { return }

        requestID &+= 1
        cancelStartTimeout()
        stopMonitoring()
        let shouldDisableRemoteAccess = remoteAccessOwner == expectedRequestID
        remoteAccessOwner = nil

        if let failure {
            currentSnapshot.status = .error
            currentSnapshot.failure = failure
        } else {
            currentSnapshot.status = .idle
            currentSnapshot.failure = nil
        }
        currentSnapshot.publicURL = nil
        currentSnapshot.startTime = nil
        publish()

        await tunnel.stop()
        if shouldDisableRemoteAccess {
            await remoteAccess.setRemoteAccessEnabled(false)
        }
        if shouldRetry {
            scheduleAutoRestart()
        }
    }

    private func scheduleStartTimeout(requestID expectedRequestID: UInt64) {
        cancelStartTimeout()
        let sleeper = sleeper
        let duration = configuration.startTimeout
        startTimeoutTask = Task { [weak self] in
            do {
                try await sleeper.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.handleStartTimeout(requestID: expectedRequestID)
        }
    }

    private func handleStartTimeout(requestID expectedRequestID: UInt64) async {
        guard requestID == expectedRequestID, currentSnapshot.status == .starting else {
            return
        }
        await failStart(
            requestID: expectedRequestID,
            failure: .startTimeout,
            shouldRetry: false
        )
    }

    private func startMonitoring(requestID expectedRequestID: UInt64) {
        stopMonitoring()
        let sleeper = sleeper
        let duration = configuration.monitorInterval
        let tunnel = tunnel
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleeper.sleep(for: duration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard !(await tunnel.isRunning()) else { continue }
                await self?.handleUnexpectedExit(requestID: expectedRequestID)
                return
            }
        }
    }

    private func handleUnexpectedExit(requestID expectedRequestID: UInt64) async {
        guard requestID == expectedRequestID,
              (currentSnapshot.status == .active || currentSnapshot.status == .starting) else {
            return
        }

        requestID &+= 1
        cancelStartTimeout()
        stopMonitoring()
        let shouldDisableRemoteAccess = remoteAccessOwner == expectedRequestID
        remoteAccessOwner = nil
        currentSnapshot.status = .error
        currentSnapshot.publicURL = nil
        currentSnapshot.failure = .unexpectedExit
        currentSnapshot.startTime = nil
        publish()

        await tunnel.stop()
        if shouldDisableRemoteAccess {
            await remoteAccess.setRemoteAccessEnabled(false)
        }
        scheduleAutoRestart()
    }

    private func scheduleAutoRestart() {
        cancelAutoRestart()
        guard preferences.load().autoRestartTunnel,
              let lastPort,
              autoRestartAttempts < configuration.maximumAutoRestartAttempts else {
            return
        }

        let sleeper = sleeper
        let duration = configuration.autoRestartDelay
        autoRestartTask = Task { [weak self] in
            do {
                try await sleeper.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.performAutoRestart(port: lastPort)
        }
    }

    private func performAutoRestart(port: UInt16) async {
        guard currentSnapshot.status == .error || currentSnapshot.status == .idle,
              preferences.load().autoRestartTunnel,
              autoRestartAttempts < configuration.maximumAutoRestartAttempts else {
            return
        }
        autoRestartAttempts += 1
        await start(port: port, isAutomaticRestart: true)
    }

    private func cancelScheduledTasks() {
        cancelStartTimeout()
        stopMonitoring()
        cancelAutoRestart()
    }

    private func cancelStartTimeout() {
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func cancelAutoRestart() {
        autoRestartTask?.cancel()
        autoRestartTask = nil
    }

    private func publish() {
        continuations.values.forEach { $0.yield(currentSnapshot) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
