import Foundation
import QuotioDomain

public actor ProxyLifecycleController: ProxyControlling {
    private let processController: any ProxyProcessControlling
    private let versionRepository: any ProxyVersionRepository
    private let releaseRepository: any ProxyReleaseRepository
    private let updateFeed: any ProxyUpdateFeedChecking
    private let configurationRepository: any ProxyConfigurationRepository
    private let binaryDownloader: any ProxyBinaryDownloading
    private let checksumVerifier: any ProxyChecksumVerifying
    private let managementChecker: any ProxyManagementChecking
    private let metadataRepository: any ProxyRuntimeMetadataRepository
    private let preferencesRepository: any ProxyPreferencesRepository
    private let keyVault: any ProxyManagementKeyVault
    private let configurationSupplement: any ProxyConfigurationSupplementing
    private let notificationDelivery: any ProxyNotificationDelivering
    private let sleeper: any Sleeping
    private let dateProvider: any DateProviding
    private let startupPoller: ProxyStartupHealthPoller
    private let installedVersionLimit: Int

    private var stateMachine = ProxyLifecycleStateMachine()
    private var currentSnapshot: ProxySnapshot
    private var continuations: [UUID: AsyncStream<ProxySnapshot>.Continuation] = [:]
    private var activeRunID: ProxyRunID?
    private var activeOperationID: UUID?
    private var testRunID: ProxyRunID?
    private var testConfigurationPath: String?
    private var healthMonitorTask: Task<Void, Never>?
    private var healthRecoveryTask: Task<Void, Never>?
    private var healthRecoveryID: UUID?
    private var crashRestartTask: Task<Void, Never>?
    private var crashRestartAttempts = 0
    private var healthCheckFailures = 0
    private var isInitialized = false
    private var isInitializing = false
    private var initializationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        paths: ProxyPaths,
        processController: any ProxyProcessControlling,
        versionRepository: any ProxyVersionRepository,
        releaseRepository: any ProxyReleaseRepository,
        updateFeed: any ProxyUpdateFeedChecking,
        configurationRepository: any ProxyConfigurationRepository,
        binaryDownloader: any ProxyBinaryDownloading,
        checksumVerifier: any ProxyChecksumVerifying,
        managementChecker: any ProxyManagementChecking,
        metadataRepository: any ProxyRuntimeMetadataRepository,
        preferencesRepository: any ProxyPreferencesRepository,
        keyVault: any ProxyManagementKeyVault,
        configurationSupplement: any ProxyConfigurationSupplementing,
        notificationDelivery: any ProxyNotificationDelivering,
        sleeper: any Sleeping,
        dateProvider: any DateProviding,
        startupPoller: ProxyStartupHealthPoller = ProxyStartupHealthPoller(),
        installedVersionLimit: Int = 3
    ) {
        self.processController = processController
        self.versionRepository = versionRepository
        self.releaseRepository = releaseRepository
        self.updateFeed = updateFeed
        self.configurationRepository = configurationRepository
        self.binaryDownloader = binaryDownloader
        self.checksumVerifier = checksumVerifier
        self.managementChecker = managementChecker
        self.metadataRepository = metadataRepository
        self.preferencesRepository = preferencesRepository
        self.keyVault = keyVault
        self.configurationSupplement = configurationSupplement
        self.notificationDelivery = notificationDelivery
        self.sleeper = sleeper
        self.dateProvider = dateProvider
        self.startupPoller = startupPoller
        self.installedVersionLimit = installedVersionLimit
        self.currentSnapshot = ProxySnapshot(paths: paths)
    }

    deinit {
        healthMonitorTask?.cancel()
        healthRecoveryTask?.cancel()
        crashRestartTask?.cancel()
        for continuation in initializationWaiters {
            continuation.resume()
        }
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    public func snapshots() -> AsyncStream<ProxySnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ProxySnapshot.self)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuations[id] = continuation
        continuation.yield(currentSnapshot)
        return stream
    }

    public func snapshot() -> ProxySnapshot {
        currentSnapshot
    }

    public func initialize() async {
        if isInitialized { return }
        if isInitializing {
            await withCheckedContinuation { continuation in
                initializationWaiters.append(continuation)
            }
            return
        }
        isInitializing = true

        let port = metadataRepository.loadPort()
        let preferences = preferencesRepository.load()
        let loadedKey = await keyVault.loadManagementKey()
        let managementKey: String
        if let loadedKey, !loadedKey.hasPrefix("$2a$") {
            managementKey = loadedKey
        } else {
            managementKey = UUID().uuidString
            _ = await keyVault.saveManagementKey(managementKey)
        }

        currentSnapshot.status.port = port
        currentSnapshot.managementKey = managementKey
        currentSnapshot.lastUpdateCheckDate = metadataRepository.loadLastUpdateCheckDate()
        currentSnapshot.legacyInstalledVersion = metadataRepository.loadLegacyInstalledVersion()
        await configurationRepository.ensureExists(
            port: port,
            managementKey: managementKey,
            allowNetworkAccess: preferences.allowNetworkAccess
        )
        await refreshVersionState()
        isInitialized = true
        isInitializing = false
        let waiters = initializationWaiters
        initializationWaiters.removeAll()
        publish()
        for continuation in waiters {
            continuation.resume()
        }
    }

    public func start() async throws {
        await initialize()
        let operationID = try beginOperation()
        defer { finishOperation(operationID) }

        do {
            try await startProcess(operationID: operationID, resetCrashRecovery: true)
        } catch {
            let failure = mapFailure(error)
            currentSnapshot.lastError = failure
            publish()
            throw failure
        }
    }

    public func stop() async {
        supersedeOperation()
        await stopActiveProcess()
    }

    public func stopAndWait() async {
        await stop()
    }

    public func restart() async throws {
        await initialize()
        let operationID = try beginOperation()
        defer { finishOperation(operationID) }

        do {
            await stopActiveProcess(preservingOperation: operationID)
            try await sleeper.sleep(for: .milliseconds(500))
            try ensureCurrentOperation(operationID)
            try await startProcess(operationID: operationID, resetCrashRecovery: true)
        } catch {
            let failure = mapFailure(error)
            currentSnapshot.lastError = failure
            publish()
            throw failure
        }
    }

    public func shutdown() async {
        supersedeOperation()
        await stopActiveProcess()
    }

    public func installLatest() async throws {
        do {
            let release = try await releaseRepository.latestRelease()
            try await install(release)
        } catch {
            let failure = mapFailure(error)
            currentSnapshot.lastError = failure
            publish()
            throw failure
        }
    }

    public func checkForUpgrade() async {
        await initialize()
        let checkedAt = dateProvider.now()
        currentSnapshot.lastUpdateCheckDate = checkedAt
        metadataRepository.saveLastUpdateCheckDate(checkedAt)

        let currentVersion = currentSnapshot.activeVersion ?? currentSnapshot.legacyInstalledVersion
        guard let latestTag = await updateFeed.latestVersion(comparedTo: currentVersion) else {
            currentSnapshot.availableUpgrade = nil
            publish()
            return
        }

        do {
            currentSnapshot.availableUpgrade = try await releaseRepository.release(tag: latestTag)
        } catch {
            currentSnapshot.availableUpgrade = nil
        }
        publish()
    }

    public func availableVersions(limit: Int) async throws -> [ProxyVersionInfo] {
        do {
            return try await releaseRepository.releases(limit: limit)
        } catch {
            throw mapFailure(error)
        }
    }

    public func install(_ version: ProxyVersionInfo) async throws {
        await initialize()
        let operationID = try beginOperation()
        let wasRunning = currentSnapshot.status.running
        let previousVersion = currentSnapshot.activeVersion
        var installedVersion: String?
        defer { finishOperation(operationID) }

        do {
            try transition(to: .downloading)
            currentSnapshot.isDownloading = true
            currentSnapshot.downloadProgress = 0
            currentSnapshot.upgradeError = nil
            publish()

            let data: Data
            let assetName: String
            if let localFilePath = version.localFilePath {
                data = try await binaryDownloader.readLocalFile(at: localFilePath)
                assetName = URL(fileURLWithPath: localFilePath).lastPathComponent
            } else {
                guard let downloadURL = version.downloadURL else {
                    throw ProxyFailure.downloadFailed("No compatible binary found")
                }
                currentSnapshot.downloadProgress = 0.1
                publish()
                data = try await binaryDownloader.download(from: downloadURL)
                assetName = URL(string: downloadURL)?.lastPathComponent ?? "CLIProxyAPI"
            }
            try ensureCurrentOperation(operationID)

            currentSnapshot.downloadProgress = 0.6
            publish()
            guard !version.sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProxyFailure.checksumMissing
            }
            try checksumVerifier.verify(data, expectedSHA256: version.sha256)
            currentSnapshot.downloadProgress = 0.7
            publish()

            let installed = try await versionRepository.install(
                version: version.version,
                data: data,
                assetName: assetName
            )
            installedVersion = installed.version
            try ensureCurrentOperation(operationID)
            currentSnapshot.downloadProgress = 1
            currentSnapshot.isDownloading = false
            try transition(to: .testing)
            currentSnapshot.testingVersion = installed.version
            publish()

            try await testInstalledVersion(installed.version, operationID: operationID)
            try await promote(
                version: installed.version,
                wasRunning: wasRunning,
                operationID: operationID
            )
            await versionRepository.cleanup(keeping: installedVersionLimit)
            metadataRepository.saveLegacyInstalledVersion(installed.version)
            currentSnapshot.availableUpgrade = nil
            await refreshVersionState()
            await notificationDelivery.deliver(.suppressUpgrade(version: installed.version))
            await notificationDelivery.deliver(.upgradeSucceeded(version: installed.version))
            publish()
        } catch {
            await stopTestProcess()
            if let installedVersion,
               await versionRepository.snapshot().currentVersion == installedVersion,
               let previousVersion {
                try? await versionRepository.activate(version: previousVersion)
            }
            await refreshVersionState()
            if activeOperationID == operationID,
               wasRunning,
               !currentSnapshot.status.running,
               currentSnapshot.activeVersion == previousVersion {
                try? await startProcess(
                    operationID: operationID,
                    resetCrashRecovery: true
                )
            }
            if let installedVersion,
               await versionRepository.snapshot().currentVersion != installedVersion {
                try? await versionRepository.delete(version: installedVersion)
            }
            currentSnapshot.isDownloading = false
            currentSnapshot.downloadProgress = 0
            currentSnapshot.testingVersion = nil
            currentSnapshot.testPort = nil
            await refreshVersionState()

            guard activeOperationID == operationID else {
                publish()
                throw ProxyFailure.cancelled
            }

            let failure = mapFailure(error)
            currentSnapshot.upgradeError = failure
            currentSnapshot.lastError = failure
            returnToRuntimeState(wasRunning: currentSnapshot.status.running)
            if installedVersion != nil {
                await notificationDelivery.deliver(
                    .upgradeFailed(version: version.version, failure: failure)
                )
            }
            publish()
            throw failure
        }
    }

    public func activate(version: String) async throws {
        await initialize()
        let operationID = try beginOperation()
        let wasRunning = currentSnapshot.status.running
        let previousVersion = currentSnapshot.activeVersion
        defer { finishOperation(operationID) }

        do {
            if wasRunning {
                await stopActiveProcess(preservingOperation: operationID)
            }
            try ensureCurrentOperation(operationID)
            try await versionRepository.activate(version: version)
            await refreshVersionState()
            if wasRunning {
                try await startProcess(operationID: operationID, resetCrashRecovery: true)
            }
        } catch {
            if let previousVersion {
                if await versionRepository.snapshot().currentVersion == version {
                    try? await versionRepository.activate(version: previousVersion)
                }
                await refreshVersionState()
                if activeOperationID == operationID,
                   wasRunning,
                   !currentSnapshot.status.running,
                   currentSnapshot.activeVersion == previousVersion {
                    try? await startProcess(
                        operationID: operationID,
                        resetCrashRecovery: true
                    )
                }
            }
            let failure = mapFailure(error)
            currentSnapshot.lastError = failure
            returnToRuntimeState(wasRunning: currentSnapshot.status.running)
            publish()
            throw failure
        }
    }

    public func delete(version: String) async throws {
        do {
            try await versionRepository.delete(version: version)
            await refreshVersionState()
            publish()
        } catch {
            throw mapFailure(error)
        }
    }

    public func rollback() async throws {
        await initialize()
        let operationID = try beginOperation()
        let wasRunning = currentSnapshot.status.running
        defer { finishOperation(operationID) }

        guard let previousVersion = currentSnapshot.installedVersions
            .filter({ $0.version != currentSnapshot.activeVersion })
            .sorted(by: { $0.installedAt > $1.installedAt })
            .first?.version else {
            throw ProxyFailure.rollbackFailed("No previous version to rollback to")
        }

        do {
            try transition(to: .rollingBack)
            publish()
            let replacedVersion = currentSnapshot.activeVersion
            if wasRunning {
                await stopActiveProcess(preservingOperation: operationID)
            }
            try ensureCurrentOperation(operationID)
            try await versionRepository.activate(version: previousVersion)
            await refreshVersionState()
            if wasRunning {
                try transition(to: .starting)
                try await startProcess(
                    operationID: operationID,
                    resetCrashRecovery: true,
                    transitionToStarting: false
                )
            } else {
                try transition(to: .idle)
            }
            if let replacedVersion, replacedVersion != previousVersion {
                try? await versionRepository.delete(version: replacedVersion)
                await refreshVersionState()
            }
            await notificationDelivery.deliver(.rolledBack(version: previousVersion))
            publish()
        } catch {
            let failure = mapFailure(error)
            currentSnapshot.lastError = failure
            returnToRuntimeState(wasRunning: currentSnapshot.status.running)
            publish()
            throw failure
        }
    }

    public func versionsToDeleteAfterInstalling(keeping count: Int) async -> [String] {
        await versionRepository.versionsToDeleteAfterInstalling(keeping: count)
    }

    public func setPort(_ port: UInt16) async {
        guard port > 0, port != currentSnapshot.status.port else { return }
        currentSnapshot.status.port = port
        metadataRepository.savePort(port)
        await configurationRepository.setPort(port)
        publish()
        await restartIfRunning()
    }

    public func setNetworkAccess(_ enabled: Bool) async {
        await configurationRepository.setHost(enabled ? "0.0.0.0" : "127.0.0.1")
        if enabled {
            await configurationRepository.ensureAPIKey()
        }
        await restartIfRunning()
    }

    public func setRemoteAccess(_ enabled: Bool) async {
        await configurationRepository.setAllowRemote(enabled)
    }

    public func setLogging(_ enabled: Bool) async {
        await configurationRepository.setLogging(enabled)
        await restartIfRunning()
    }

    public func setRoutingStrategy(_ strategy: String) async {
        await configurationRepository.setRoutingStrategy(strategy)
        await restartIfRunning()
    }

    public func setProxyURL(_ url: String?) async {
        await configurationRepository.setProxyURL(url)
        await restartIfRunning()
    }

    public func regenerateManagementKey() async throws {
        await initialize()
        guard !currentSnapshot.isRegeneratingKey else {
            throw ProxyFailure.operationInProgress
        }
        currentSnapshot.isRegeneratingKey = true
        publish()
        defer {
            currentSnapshot.isRegeneratingKey = false
            publish()
        }

        let previousKey = currentSnapshot.managementKey
        let newKey = UUID().uuidString
        currentSnapshot.managementKey = newKey
        await configurationRepository.setManagementKey(newKey)

        guard currentSnapshot.status.running else {
            _ = await keyVault.saveManagementKey(newKey)
            return
        }

        do {
            try await restart()
            _ = await keyVault.saveManagementKey(newKey)
        } catch {
            currentSnapshot.managementKey = previousKey
            await configurationRepository.setManagementKey(previousKey)
            try? await sleeper.sleep(for: .milliseconds(300))
            try? await start()
            throw mapFailure(error)
        }
    }

    private func startProcess(
        operationID: UUID,
        resetCrashRecovery: Bool,
        transitionToStarting: Bool = true
    ) async throws {
        await refreshVersionState()
        guard currentSnapshot.isBinaryInstalled else {
            throw ProxyFailure.binaryNotFound
        }
        guard !currentSnapshot.status.running else { return }
        try ensureCurrentOperation(operationID)

        if resetCrashRecovery {
            crashRestartTask?.cancel()
            crashRestartTask = nil
            crashRestartAttempts = 0
        }
        if transitionToStarting {
            try transition(to: .starting)
        }
        currentSnapshot.lastError = nil
        publish()

        let port = currentSnapshot.status.port
        await processController.cleanupProcesses(on: port)
        try ensureCurrentOperation(operationID)
        await prepareConfigurationForStart()
        try ensureCurrentOperation(operationID)

        let versions = await versionRepository.snapshot()
        let executablePath = versions.currentBinaryPath ?? versions.expectedBinaryPath
        let runID = ProxyRunID()
        activeRunID = runID
        let request = ProxyProcessRequest(
            runID: runID,
            executablePath: executablePath,
            configurationPath: currentSnapshot.paths.configPath
        )
        do {
            try await processController.start(request) { [weak self] exit in
                Task { await self?.handleProcessExit(exit) }
            }
            try await sleeper.sleep(for: .milliseconds(1_500))
            try ensureCurrentOperation(operationID)
            guard activeRunID == runID, await processController.isRunning(runID) else {
                throw ProxyFailure.startupFailed
            }
        } catch {
            if activeRunID == runID {
                activeRunID = nil
                await processController.stop(runID, on: port)
                currentSnapshot.status.running = false
                try? transition(to: .idle)
                publish()
            }
            throw error
        }

        currentSnapshot.status.running = true
        try transition(to: .active)
        startHealthMonitor(for: runID)
        publish()
    }

    private func prepareConfigurationForStart() async {
        let preferences = preferencesRepository.load()
        await configurationRepository.setManagementKey(currentSnapshot.managementKey)
        if let savedURL = preferences.proxyURL {
            let sanitized = sanitizeProxyURL(savedURL)
            await configurationRepository.setProxyURL(isValidProxyURL(sanitized) ? sanitized : nil)
        }
        await configurationSupplement.synchronize(
            configurationPath: currentSnapshot.paths.configPath
        )
        await configurationRepository.setPort(currentSnapshot.status.port)
    }

    private func stopActiveProcess(
        preservingOperation operationID: UUID? = nil,
        preservingHealthRecovery: Bool = false
    ) async {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        if !preservingHealthRecovery {
            healthRecoveryTask?.cancel()
            healthRecoveryTask = nil
            healthRecoveryID = nil
        }
        crashRestartTask?.cancel()
        crashRestartTask = nil

        if stateMachine.state != .idle {
            try? transition(to: .stopping)
        }
        let runID = activeRunID
        activeRunID = nil
        currentSnapshot.status.running = false
        publish()
        await processController.stop(runID, on: currentSnapshot.status.port)

        if let operationID, activeOperationID != operationID {
            return
        }
        try? transition(to: .idle)
        publish()
    }

    private func testInstalledVersion(_ version: String, operationID: UUID) async throws {
        guard let binaryPath = await versionRepository.binaryPath(for: version) else {
            throw ProxyFailure.dryRunFailed("Version \(version) not installed")
        }
        let port: UInt16
        do {
            port = try await processController.firstAvailablePort(
                in: 18_000...18_100,
                excluding: currentSnapshot.status.port
            )
        } catch {
            throw ProxyFailure.dryRunFailed("No available port for testing")
        }
        let endpoint = try ProxyEndpoint(port: port)
        let managementKey = UUID().uuidString
        let configurationPath = try await configurationRepository.makeTestConfiguration(
            port: port,
            managementKey: managementKey
        )
        testConfigurationPath = configurationPath
        currentSnapshot.testPort = port
        publish()

        let runID = ProxyRunID()
        testRunID = runID
        let request = ProxyProcessRequest(
            runID: runID,
            executablePath: binaryPath,
            configurationPath: configurationPath
        )
        try await processController.start(request) { _ in }

        let outcome = try await startupPoller.waitUntilReady(
            isProcessRunning: { [processController] in
                await processController.isRunning(runID)
            },
            checkHealth: { [managementChecker] in
                await managementChecker.isHealthy(
                    endpoint: endpoint,
                    managementKey: managementKey,
                    timeout: .seconds(1)
                )
            }
        )
        try ensureCurrentOperation(operationID)

        switch outcome {
        case .ready:
            break
        case .processExited:
            throw ProxyFailure.dryRunFailed("Test proxy process exited before becoming ready")
        case .timedOut:
            throw ProxyFailure.dryRunFailed("Test proxy startup timed out")
        }

        let result = await managementChecker.compatibility(
            endpoint: endpoint,
            managementKey: managementKey
        )
        try ensureCurrentOperation(operationID)
        guard result.isCompatible else {
            throw ProxyFailure.compatibilityCheckFailed(result)
        }
    }

    private func promote(version: String, wasRunning: Bool, operationID: UUID) async throws {
        try transition(to: .promoting)
        publish()
        await stopTestProcess()
        try ensureCurrentOperation(operationID)
        if wasRunning {
            await stopActiveProcess(preservingOperation: operationID)
        }
        try ensureCurrentOperation(operationID)
        try await versionRepository.activate(version: version)
        await refreshVersionState()
        if wasRunning {
            try transition(to: .starting)
            try await startProcess(
                operationID: operationID,
                resetCrashRecovery: true,
                transitionToStarting: false
            )
        } else {
            try transition(to: .idle)
        }
        currentSnapshot.testingVersion = nil
        currentSnapshot.testPort = nil
        publish()
    }

    private func stopTestProcess() async {
        if let runID = testRunID {
            await processController.stop(runID, on: currentSnapshot.testPort ?? 18_000)
        }
        testRunID = nil
        if let path = testConfigurationPath {
            await configurationRepository.removeTestConfiguration(at: path)
        }
        testConfigurationPath = nil
    }

    private func handleProcessExit(_ exit: ProxyProcessExit) async {
        guard activeRunID == exit.runID else { return }
        activeRunID = nil
        currentSnapshot.status.running = false
        healthMonitorTask?.cancel()
        healthMonitorTask = nil

        if stateMachine.state == .starting {
            try? transition(to: .idle)
            publish()
            return
        }

        try? transition(to: .idle)
        currentSnapshot.lastError = .startupFailed
        publish()
        if exit.exitCode != 0 {
            await notificationDelivery.deliver(.crashed(exitCode: exit.exitCode))
        }
        scheduleCrashRestart(after: exit.exitCode)
    }

    private func scheduleCrashRestart(after exitCode: Int32) {
        guard crashRestartTask == nil, crashRestartAttempts < 3 else { return }
        crashRestartAttempts += 1
        let attempt = crashRestartAttempts
        let delay = min(2 * (1 << max(0, attempt - 1)), 30)
        crashRestartTask = Task { [weak self, sleeper] in
            try? await sleeper.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.performCrashRestart(after: exitCode)
        }
    }

    private func performCrashRestart(after exitCode: Int32) async {
        crashRestartTask = nil
        guard !currentSnapshot.status.running, activeOperationID == nil else { return }
        do {
            let operationID = try beginOperation()
            defer { finishOperation(operationID) }
            try await startProcess(operationID: operationID, resetCrashRecovery: false)
        } catch {
            currentSnapshot.lastError = mapFailure(error)
            publish()
            scheduleCrashRestart(after: exitCode)
        }
    }

    private func startHealthMonitor(for runID: ProxyRunID) {
        healthMonitorTask?.cancel()
        healthCheckFailures = 0
        healthMonitorTask = Task { [weak self, sleeper] in
            while !Task.isCancelled {
                try? await sleeper.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                await self?.performHealthCheck(for: runID)
            }
        }
    }

    private func performHealthCheck(for runID: ProxyRunID) async {
        guard activeRunID == runID, currentSnapshot.status.running else { return }
        let endpoint = try? ProxyEndpoint(port: currentSnapshot.status.port)
        guard let endpoint else { return }
        let healthy = await managementChecker.isHealthy(
            endpoint: endpoint,
            managementKey: currentSnapshot.managementKey,
            timeout: .seconds(3)
        )
        guard activeRunID == runID, currentSnapshot.status.running else { return }
        if healthy {
            healthCheckFailures = 0
            crashRestartAttempts = 0
            return
        }

        healthCheckFailures += 1
        guard healthCheckFailures >= 3 else { return }
        healthCheckFailures = 0
        scheduleHealthRecovery(for: runID)
    }

    private func scheduleHealthRecovery(for runID: ProxyRunID) {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        healthRecoveryTask?.cancel()
        let recoveryID = UUID()
        healthRecoveryID = recoveryID
        healthRecoveryTask = Task { [weak self, sleeper] in
            try? await sleeper.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.performHealthRecovery(for: runID, recoveryID: recoveryID)
        }
    }

    private func performHealthRecovery(for runID: ProxyRunID, recoveryID: UUID) async {
        guard healthRecoveryID == recoveryID,
              activeRunID == runID,
              currentSnapshot.status.running,
              activeOperationID == nil else {
            finishHealthRecovery(recoveryID)
            return
        }

        do {
            let operationID = try beginOperation()
            defer { finishOperation(operationID) }
            await stopActiveProcess(
                preservingOperation: operationID,
                preservingHealthRecovery: true
            )
            try ensureCurrentOperation(operationID)
            try await startProcess(operationID: operationID, resetCrashRecovery: true)
        } catch {
            if healthRecoveryID == recoveryID {
                await notificationDelivery.deliver(.crashed(exitCode: -1))
            }
        }
        finishHealthRecovery(recoveryID)
    }

    private func finishHealthRecovery(_ recoveryID: UUID) {
        guard healthRecoveryID == recoveryID else { return }
        healthRecoveryTask = nil
        healthRecoveryID = nil
    }

    private func restartIfRunning() async {
        guard currentSnapshot.status.running else { return }
        do {
            try await restart()
        } catch {
            currentSnapshot.lastError = mapFailure(error)
            publish()
        }
    }

    private func refreshVersionState() async {
        let versions = await versionRepository.snapshot()
        currentSnapshot.isBinaryInstalled = versions.currentBinaryPath != nil
        currentSnapshot.activeVersion = versions.currentVersion
        currentSnapshot.installedVersions = versions.installedVersions
    }

    private func transition(to state: ProxyLifecycleState) throws {
        try stateMachine.transition(to: state)
        currentSnapshot.lifecycle = state
    }

    private func returnToRuntimeState(wasRunning: Bool) {
        let target: ProxyLifecycleState = wasRunning ? .active : .idle
        try? transition(to: target)
    }

    private func beginOperation() throws -> UUID {
        guard activeOperationID == nil else {
            throw ProxyFailure.operationInProgress
        }
        let id = UUID()
        activeOperationID = id
        return id
    }

    private func finishOperation(_ id: UUID) {
        if activeOperationID == id {
            activeOperationID = nil
        }
    }

    private func supersedeOperation() {
        activeOperationID = nil
    }

    private func ensureCurrentOperation(_ id: UUID) throws {
        guard activeOperationID == id else {
            throw ProxyFailure.cancelled
        }
        try Task.checkCancellation()
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(currentSnapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func mapFailure(_ error: Error) -> ProxyFailure {
        if let failure = error as? ProxyFailure {
            return failure
        }
        if error is CancellationError {
            return .cancelled
        }
        return .installationFailed(String(describing: error))
    }

    private func sanitizeProxyURL(_ value: String) -> String {
        var sanitized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.hasSuffix("/") {
            sanitized.removeLast()
        }
        return sanitized
    }

    private func isValidProxyURL(_ value: String) -> Bool {
        guard !value.isEmpty,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "socks5"].contains(scheme),
              url.host?.isEmpty == false else {
            return false
        }
        if scheme == "socks5", url.port == nil {
            return false
        }
        if let port = url.port, !(1...65_535).contains(port) {
            return false
        }
        return true
    }
}
