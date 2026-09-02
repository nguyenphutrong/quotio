import Foundation
import XCTest
@testable import QuotioApplication
@testable import QuotioDomain

final class ProxyLifecycleControllerTests: XCTestCase {
    func testConcurrentInitializationRunsOnceAndPublishesPersistedState() async {
        let harness = makeHarness(keyLoadDelay: .milliseconds(20))

        let first = Task { await harness.controller.initialize() }
        let second = Task { await harness.controller.initialize() }
        await first.value
        await second.value

        let snapshot = await harness.controller.snapshot()
        let ensureCount = await harness.configuration.ensureCount
        let keyLoadCount = await harness.keyVault.loadCount
        XCTAssertEqual(ensureCount, 1)
        XCTAssertEqual(keyLoadCount, 1)
        XCTAssertEqual(snapshot.status.port, 8317)
        XCTAssertEqual(snapshot.managementKey, "management-key")
        XCTAssertEqual(snapshot.activeVersion, "1.0.0")
    }

    func testStartAndStopDriveProcessAndLifecycleState() async throws {
        let harness = makeHarness()

        try await harness.controller.start()
        var snapshot = await harness.controller.snapshot()
        let requestCount = await harness.process.requestCount
        XCTAssertTrue(snapshot.status.running)
        XCTAssertEqual(snapshot.lifecycle, .active)
        XCTAssertEqual(requestCount, 1)

        await harness.controller.stopAndWait()
        snapshot = await harness.controller.snapshot()
        let stopCount = await harness.process.stopCount
        XCTAssertFalse(snapshot.status.running)
        XCTAssertEqual(snapshot.lifecycle, .idle)
        XCTAssertEqual(stopCount, 1)
    }

    func testProcessLaunchFailureReturnsToIdleAndAllowsRetry() async throws {
        let process = TestProcessController(startFailuresRemaining: 1)
        let harness = makeHarness(process: process)

        do {
            try await harness.controller.start()
            XCTFail("Expected the first process launch to fail")
        } catch {
            XCTAssertEqual(error as? ProxyFailure, .startupFailed)
        }

        var snapshot = await harness.controller.snapshot()
        XCTAssertFalse(snapshot.status.running)
        XCTAssertEqual(snapshot.lifecycle, .idle)

        try await harness.controller.start()
        snapshot = await harness.controller.snapshot()
        XCTAssertTrue(snapshot.status.running)
        XCTAssertEqual(snapshot.lifecycle, .active)
        await harness.controller.shutdown()
    }

    func testStaleExitFromPriorRunCannotStopReplacementProcess() async throws {
        let harness = makeHarness()
        try await harness.controller.start()
        try await harness.controller.restart()

        await harness.process.emitExit(requestIndex: 0, exitCode: 9)
        await Task.yield()

        let snapshot = await harness.controller.snapshot()
        let requestCount = await harness.process.requestCount
        let notifications = await harness.notifications.values
        XCTAssertTrue(snapshot.status.running)
        XCTAssertEqual(snapshot.lifecycle, .active)
        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(notifications.isEmpty)
        await harness.controller.shutdown()
    }

    func testUnexpectedExitNotifiesAndRestartsCurrentRun() async throws {
        let harness = makeHarness()
        try await harness.controller.start()

        await harness.process.emitExit(requestIndex: 0, exitCode: 9)
        let restarted = await waitUntil {
            await harness.process.requestCount == 2
        }

        let snapshot = await harness.controller.snapshot()
        let notifications = await harness.notifications.values
        XCTAssertTrue(restarted)
        XCTAssertTrue(snapshot.status.running)
        XCTAssertEqual(snapshot.lifecycle, .active)
        XCTAssertEqual(notifications, [.crashed(exitCode: 9)])
        await harness.controller.shutdown()
    }

    func testThreeFailedHealthChecksRestartWithoutCancellingRecovery() async throws {
        let sleeper = TestSleeper(healthSleepsToRelease: 3)
        let management = TestManagementChecker(healthResponses: [false, false, false])
        let harness = makeHarness(sleeper: sleeper, management: management)

        try await harness.controller.start()
        let restarted = await waitUntil {
            await harness.process.requestCount == 2
        }

        let snapshot = await harness.controller.snapshot()
        let stopCount = await harness.process.stopCount
        let notifications = await harness.notifications.values
        XCTAssertTrue(restarted)
        XCTAssertTrue(snapshot.status.running)
        XCTAssertEqual(snapshot.lifecycle, .active)
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(notifications.isEmpty)
        await harness.controller.shutdown()
    }

    func testCompatibilityFailureCleansCandidateAndKeepsCurrentProxyRunning() async throws {
        let management = TestManagementChecker(compatibilityResult: .proxyNotResponding)
        let harness = makeHarness(management: management)
        try await harness.controller.start()

        do {
            try await harness.controller.install(testVersion("2.0.0"))
            XCTFail("Expected compatibility failure")
        } catch {
            XCTAssertEqual(
                error as? ProxyFailure,
                .compatibilityCheckFailed(.proxyNotResponding)
            )
        }

        let snapshot = await harness.controller.snapshot()
        let currentVersion = await harness.versions.currentVersion
        let containsCandidate = await harness.versions.contains("2.0.0")
        let removedTestConfigurationCount = await harness.configuration.removedTestConfigurationCount
        let notifications = await harness.notifications.values
        XCTAssertEqual(currentVersion, "1.0.0")
        XCTAssertFalse(containsCandidate)
        XCTAssertTrue(snapshot.status.running)
        XCTAssertEqual(snapshot.lifecycle, .active)
        XCTAssertEqual(removedTestConfigurationCount, 1)
        XCTAssertEqual(notifications.count, 1)
        await harness.controller.shutdown()
    }

    func testSuccessfulUpgradePromotesCandidateAndRestartsProxy() async throws {
        let harness = makeHarness()
        try await harness.controller.start()

        try await harness.controller.install(testVersion("2.0.0"))

        let snapshot = await harness.controller.snapshot()
        let requestCount = await harness.process.requestCount
        let cleanupCount = await harness.versions.cleanupCount
        let notifications = await harness.notifications.values
        XCTAssertEqual(snapshot.activeVersion, "2.0.0")
        XCTAssertTrue(snapshot.status.running)
        XCTAssertEqual(snapshot.lifecycle, .active)
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(harness.metadata.savedLegacyVersion, "2.0.0")
        XCTAssertEqual(
            notifications,
            [.suppressUpgrade(version: "2.0.0"), .upgradeSucceeded(version: "2.0.0")]
        )
        await harness.controller.shutdown()
    }

    func testFirstInstallPromotesWithoutAPreviousVersion() async throws {
        let versions = TestVersionRepository(installedVersions: [], currentVersion: nil)
        let harness = makeHarness(versions: versions)

        try await harness.controller.install(testVersion("2.0.0"))

        let snapshot = await harness.controller.snapshot()
        let containsInstalledVersion = await versions.contains("2.0.0")
        let notifications = await harness.notifications.values
        XCTAssertEqual(snapshot.activeVersion, "2.0.0")
        XCTAssertTrue(containsInstalledVersion)
        XCTAssertFalse(snapshot.status.running)
        XCTAssertEqual(snapshot.lifecycle, .idle)
        XCTAssertEqual(
            notifications,
            [.suppressUpgrade(version: "2.0.0"), .upgradeSucceeded(version: "2.0.0")]
        )
    }

    func testFailedPromotedStartupRestoresPriorVersionAndRuntime() async throws {
        let process = TestProcessController(startRunningOutcomes: [true, true, false, true])
        let harness = makeHarness(process: process)
        try await harness.controller.start()

        do {
            try await harness.controller.install(testVersion("2.0.0"))
            XCTFail("Expected promoted startup failure")
        } catch {
            XCTAssertEqual(error as? ProxyFailure, .startupFailed)
        }

        let snapshot = await harness.controller.snapshot()
        let containsCandidate = await harness.versions.contains("2.0.0")
        let requestCount = await harness.process.requestCount
        let notifications = await harness.notifications.values
        XCTAssertEqual(snapshot.activeVersion, "1.0.0")
        XCTAssertTrue(snapshot.status.running)
        XCTAssertEqual(snapshot.lifecycle, .active)
        XCTAssertFalse(containsCandidate)
        XCTAssertEqual(requestCount, 4)
        XCTAssertEqual(notifications.count, 1)
        await harness.controller.shutdown()
    }

    func testRollbackActivatesPreviousVersionBeforeDeletingReplacedVersion() async throws {
        let versions = TestVersionRepository(
            installedVersions: ["1.0.0", "2.0.0"],
            currentVersion: "2.0.0"
        )
        let harness = makeHarness(versions: versions)

        try await harness.controller.rollback()

        let snapshot = await harness.controller.snapshot()
        let containsReplacedVersion = await versions.contains("2.0.0")
        let versionEvents = await versions.events
        let notifications = await harness.notifications.values
        XCTAssertEqual(snapshot.activeVersion, "1.0.0")
        XCTAssertFalse(containsReplacedVersion)
        XCTAssertEqual(versionEvents, ["activate:1.0.0", "delete:2.0.0"])
        XCTAssertEqual(notifications, [.rolledBack(version: "1.0.0")])
    }

    func testSupersededDownloadCannotPublishStaleFailureOrNotification() async throws {
        let downloader = GatedBinaryDownloader()
        let harness = makeHarness(downloader: downloader)
        let version = testVersion("2.0.0")
        let install = Task {
            try await harness.controller.install(version)
        }
        let didStart = await waitUntil { await downloader.hasStarted }
        XCTAssertTrue(didStart)

        await harness.controller.stop()
        await downloader.resume(with: Data("binary".utf8))

        do {
            try await install.value
            XCTFail("Expected superseded install to be cancelled")
        } catch {
            XCTAssertEqual(error as? ProxyFailure, .cancelled)
        }
        let snapshot = await harness.controller.snapshot()
        let notifications = await harness.notifications.values
        XCTAssertEqual(snapshot.lifecycle, .idle)
        XCTAssertFalse(snapshot.isDownloading)
        XCTAssertNil(snapshot.upgradeError)
        XCTAssertNil(snapshot.lastError)
        XCTAssertTrue(notifications.isEmpty)
    }

    func testMissingProxyPreferencePreservesManualConfiguration() async throws {
        let preferences = TestProxyPreferences(proxyURL: nil)
        let harness = makeHarness(preferences: preferences)

        try await harness.controller.start()

        let proxyURLValues = await harness.configuration.proxyURLValues
        XCTAssertTrue(proxyURLValues.isEmpty)
        await harness.controller.shutdown()
    }

    func testInvalidProxyPreferenceClearsConfiguration() async throws {
        let preferences = TestProxyPreferences(proxyURL: "not a proxy URL")
        let harness = makeHarness(preferences: preferences)

        try await harness.controller.start()

        let values = await harness.configuration.proxyURLValues
        XCTAssertEqual(values.count, 1)
        XCTAssertNil(values[0])
        await harness.controller.shutdown()
    }

    private func makeHarness(
        process: TestProcessController = TestProcessController(),
        versions: TestVersionRepository = TestVersionRepository(),
        downloader: any ProxyBinaryDownloading = TestBinaryDownloader(),
        sleeper: any Sleeping = TestSleeper(),
        management: TestManagementChecker = TestManagementChecker(),
        preferences: TestProxyPreferences = TestProxyPreferences(),
        keyLoadDelay: Duration? = nil
    ) -> ProxyHarness {
        let paths = ProxyPaths(
            legacyBinaryPath: "/tmp/legacy/CLIProxyAPI",
            configPath: "/tmp/config.yaml",
            authDirectoryPath: "/tmp/auth",
            expectedBinaryPath: "/tmp/proxy/current/CLIProxyAPI"
        )
        let configuration = TestConfigurationRepository(paths: paths)
        let metadata = TestMetadataRepository()
        let keyVault = TestKeyVault(loadDelay: keyLoadDelay)
        let notifications = TestNotificationDelivery()
        let controller = ProxyLifecycleController(
            paths: paths,
            processController: process,
            versionRepository: versions,
            releaseRepository: TestReleaseRepository(),
            updateFeed: TestUpdateFeed(),
            configurationRepository: configuration,
            binaryDownloader: downloader,
            checksumVerifier: TestChecksumVerifier(),
            managementChecker: management,
            metadataRepository: metadata,
            preferencesRepository: preferences,
            keyVault: keyVault,
            configurationSupplement: TestConfigurationSupplement(),
            notificationDelivery: notifications,
            sleeper: sleeper,
            dateProvider: TestDateProvider()
        )
        return ProxyHarness(
            controller: controller,
            process: process,
            versions: versions,
            configuration: configuration,
            metadata: metadata,
            keyVault: keyVault,
            notifications: notifications
        )
    }

    private func testVersion(_ version: String) -> ProxyVersionInfo {
        ProxyVersionInfo(
            version: version,
            sha256: "expected-checksum",
            downloadURL: "https://example.com/CLIProxyAPI"
        )
    }

    private func waitUntil(
        attempts: Int = 500,
        condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private struct ProxyHarness {
    let controller: ProxyLifecycleController
    let process: TestProcessController
    let versions: TestVersionRepository
    let configuration: TestConfigurationRepository
    let metadata: TestMetadataRepository
    let keyVault: TestKeyVault
    let notifications: TestNotificationDelivery
}

private actor TestProcessController: ProxyProcessControlling {
    private var requests: [ProxyProcessRequest] = []
    private var terminations: [ProxyRunID: @Sendable (ProxyProcessExit) -> Void] = [:]
    private var runningIDs: Set<ProxyRunID> = []
    private var startRunningOutcomes: [Bool]
    private var startFailuresRemaining: Int
    private(set) var stopCount = 0

    init(startRunningOutcomes: [Bool] = [], startFailuresRemaining: Int = 0) {
        self.startRunningOutcomes = startRunningOutcomes
        self.startFailuresRemaining = startFailuresRemaining
    }

    var requestCount: Int { requests.count }

    func start(
        _ request: ProxyProcessRequest,
        termination: @escaping @Sendable (ProxyProcessExit) -> Void
    ) throws {
        requests.append(request)
        terminations[request.runID] = termination
        if startFailuresRemaining > 0 {
            startFailuresRemaining -= 1
            throw ProxyFailure.startupFailed
        }
        let shouldRun = startRunningOutcomes.isEmpty ? true : startRunningOutcomes.removeFirst()
        if shouldRun {
            runningIDs.insert(request.runID)
        }
    }

    func isRunning(_ runID: ProxyRunID) -> Bool {
        runningIDs.contains(runID)
    }

    func stop(_ runID: ProxyRunID?, on port: UInt16) {
        stopCount += 1
        if let runID {
            runningIDs.remove(runID)
        }
    }

    func cleanupProcesses(on port: UInt16) {}

    func firstAvailablePort(
        in range: ClosedRange<UInt16>,
        excluding port: UInt16
    ) throws -> UInt16 {
        range.first(where: { $0 != port })!
    }

    func emitExit(requestIndex: Int, exitCode: Int32) {
        let request = requests[requestIndex]
        runningIDs.remove(request.runID)
        terminations[request.runID]?(
            ProxyProcessExit(runID: request.runID, processID: 100, exitCode: exitCode)
        )
    }
}

private actor TestVersionRepository: ProxyVersionRepository {
    private var versions: [String: InstalledProxyVersion]
    private(set) var currentVersion: String?
    private(set) var cleanupCount = 0
    private(set) var events: [String] = []

    init(
        installedVersions: [String] = ["1.0.0"],
        currentVersion: String? = "1.0.0"
    ) {
        self.currentVersion = currentVersion
        self.versions = Dictionary(uniqueKeysWithValues: installedVersions.enumerated().map { index, version in
            (
                version,
                InstalledProxyVersion(
                    version: version,
                    path: "/tmp/proxy/v\(version)/CLIProxyAPI",
                    installedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                    isCurrent: version == currentVersion
                )
            )
        })
    }

    func snapshot() -> ProxyVersionSnapshot {
        let installed = versions.values.map { value in
            InstalledProxyVersion(
                version: value.version,
                path: value.path,
                installedAt: value.installedAt,
                isCurrent: value.version == currentVersion
            )
        }
        return ProxyVersionSnapshot(
            currentBinaryPath: currentVersion.flatMap { versions[$0]?.path },
            expectedBinaryPath: "/tmp/proxy/current/CLIProxyAPI",
            currentVersion: currentVersion,
            installedVersions: installed
        )
    }

    func binaryPath(for version: String) -> String? {
        versions[version]?.path
    }

    func install(
        version: String,
        data: Data,
        assetName: String
    ) throws -> InstalledProxyVersion {
        let installed = InstalledProxyVersion(
            version: version,
            path: "/tmp/proxy/v\(version)/CLIProxyAPI",
            installedAt: Date(timeIntervalSince1970: 100),
            isCurrent: false
        )
        versions[version] = installed
        events.append("install:\(version)")
        return installed
    }

    func activate(version: String) throws {
        guard versions[version] != nil else {
            throw ProxyFailure.installationFailed("Version is not installed")
        }
        currentVersion = version
        events.append("activate:\(version)")
    }

    func delete(version: String) throws {
        guard version != currentVersion else {
            throw ProxyFailure.cannotDeleteCurrentVersion
        }
        versions.removeValue(forKey: version)
        events.append("delete:\(version)")
    }

    func cleanup(keeping count: Int) {
        cleanupCount += 1
    }

    func versionsToDeleteAfterInstalling(keeping count: Int) -> [String] {
        []
    }

    func contains(_ version: String) -> Bool {
        versions[version] != nil
    }
}

private actor TestConfigurationRepository: ProxyConfigurationRepository {
    private let storedPaths: ProxyPaths
    private(set) var ensureCount = 0
    private(set) var proxyURLValues: [String?] = []
    private(set) var removedTestConfigurationCount = 0

    init(paths: ProxyPaths) {
        self.storedPaths = paths
    }

    func paths() -> ProxyPaths { storedPaths }

    func ensureExists(port: UInt16, managementKey: String, allowNetworkAccess: Bool) {
        ensureCount += 1
    }

    func setPort(_ port: UInt16) {}
    func setHost(_ host: String) {}
    func ensureAPIKey() {}
    func setAllowRemote(_ enabled: Bool) {}
    func setLogging(_ enabled: Bool) {}
    func setRoutingStrategy(_ strategy: String) {}

    func setProxyURL(_ url: String?) {
        proxyURLValues.append(url)
    }

    func setManagementKey(_ key: String) {}

    func makeTestConfiguration(port: UInt16, managementKey: String) -> String {
        "/tmp/test-\(port).yaml"
    }

    func removeTestConfiguration(at path: String) {
        removedTestConfigurationCount += 1
    }
}

private struct TestReleaseRepository: ProxyReleaseRepository {
    func latestRelease() async throws -> ProxyVersionInfo {
        ProxyVersionInfo(version: "2.0.0", sha256: "expected-checksum")
    }

    func release(tag: String) async throws -> ProxyVersionInfo {
        ProxyVersionInfo(version: tag, sha256: "expected-checksum")
    }

    func releases(limit: Int) async throws -> [ProxyVersionInfo] { [] }
}

private struct TestUpdateFeed: ProxyUpdateFeedChecking {
    func latestVersion(comparedTo currentVersion: String?) async -> String? { nil }
}

private struct TestBinaryDownloader: ProxyBinaryDownloading {
    func download(from url: String) async throws -> Data { Data("binary".utf8) }
    func readLocalFile(at path: String) async throws -> Data { Data("binary".utf8) }
}

private actor GatedBinaryDownloader: ProxyBinaryDownloading {
    private var continuation: CheckedContinuation<Data, Error>?
    private(set) var hasStarted = false

    func download(from url: String) async throws -> Data {
        hasStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func readLocalFile(at path: String) async throws -> Data {
        try await download(from: path)
    }

    func resume(with data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

private struct TestChecksumVerifier: ProxyChecksumVerifying {
    func verify(_ data: Data, expectedSHA256: String) throws {}
}

private actor TestManagementChecker: ProxyManagementChecking {
    private var healthResponses: [Bool]
    private let compatibilityResult: ProxyCompatibilityResult

    init(
        healthResponses: [Bool] = [],
        compatibilityResult: ProxyCompatibilityResult = .compatible
    ) {
        self.healthResponses = healthResponses
        self.compatibilityResult = compatibilityResult
    }

    func isHealthy(
        endpoint: ProxyEndpoint,
        managementKey: String,
        timeout: Duration
    ) -> Bool {
        healthResponses.isEmpty ? true : healthResponses.removeFirst()
    }

    func compatibility(
        endpoint: ProxyEndpoint,
        managementKey: String
    ) -> ProxyCompatibilityResult {
        compatibilityResult
    }
}

private final class TestMetadataRepository: ProxyRuntimeMetadataRepository, @unchecked Sendable {
    private(set) var savedLegacyVersion: String?

    func loadPort() -> UInt16 { 8317 }
    func savePort(_ port: UInt16) {}
    func loadLegacyInstalledVersion() -> String? { "1.0.0" }
    func saveLegacyInstalledVersion(_ version: String) { savedLegacyVersion = version }
    func loadLastUpdateCheckDate() -> Date? { nil }
    func saveLastUpdateCheckDate(_ date: Date) {}
}

private final class TestProxyPreferences: ProxyPreferencesRepository, @unchecked Sendable {
    private let proxyURL: String?

    init(proxyURL: String? = nil) {
        self.proxyURL = proxyURL
    }

    func load() -> ProxyPreferences { ProxyPreferences(proxyURL: proxyURL) }
    func setAutoStartProxy(_ enabled: Bool) {}
    func setAllowNetworkAccess(_ enabled: Bool) {}
    func setLoggingToFile(_ enabled: Bool) {}
    func setProxyURL(_ proxyURL: String?) {}
}

private actor TestKeyVault: ProxyManagementKeyVault {
    private let loadDelay: Duration?
    private(set) var loadCount = 0

    init(loadDelay: Duration?) {
        self.loadDelay = loadDelay
    }

    func loadManagementKey() async -> String? {
        loadCount += 1
        if let loadDelay {
            try? await Task.sleep(for: loadDelay)
        }
        return "management-key"
    }

    func saveManagementKey(_ key: String) -> Bool { true }
}

private struct TestConfigurationSupplement: ProxyConfigurationSupplementing {
    func synchronize(configurationPath: String) async {}
}

private actor TestNotificationDelivery: ProxyNotificationDelivering {
    private(set) var values: [ProxyNotification] = []

    func deliver(_ notification: ProxyNotification) {
        values.append(notification)
    }
}

private actor TestSleeper: Sleeping {
    private var healthSleepsToRelease: Int

    init(healthSleepsToRelease: Int = 0) {
        self.healthSleepsToRelease = healthSleepsToRelease
    }

    func sleep(for duration: Duration) async throws {
        guard duration == .seconds(30) else { return }
        if healthSleepsToRelease > 0 {
            healthSleepsToRelease -= 1
            return
        }
        try await Task.sleep(for: .seconds(60))
    }
}

private struct TestDateProvider: DateProviding {
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}
