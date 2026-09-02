import Foundation
import QuotioDomain

public protocol ProxyProcessControlling: Sendable {
    func start(
        _ request: ProxyProcessRequest,
        termination: @escaping @Sendable (ProxyProcessExit) -> Void
    ) async throws
    func isRunning(_ runID: ProxyRunID) async -> Bool
    func stop(_ runID: ProxyRunID?, on port: UInt16) async
    func cleanupProcesses(on port: UInt16) async
    func firstAvailablePort(in range: ClosedRange<UInt16>, excluding port: UInt16) async throws -> UInt16
}

public protocol ProxyVersionRepository: Sendable {
    func snapshot() async -> ProxyVersionSnapshot
    func binaryPath(for version: String) async -> String?
    func install(version: String, data: Data, assetName: String) async throws -> InstalledProxyVersion
    func activate(version: String) async throws
    func delete(version: String) async throws
    func cleanup(keeping count: Int) async
    func versionsToDeleteAfterInstalling(keeping count: Int) async -> [String]
}

public protocol ProxyReleaseRepository: Sendable {
    func latestRelease() async throws -> ProxyVersionInfo
    func release(tag: String) async throws -> ProxyVersionInfo
    func releases(limit: Int) async throws -> [ProxyVersionInfo]
}

public protocol ProxyUpdateFeedChecking: Sendable {
    func latestVersion(comparedTo currentVersion: String?) async -> String?
}

public protocol ProxyConfigurationRepository: Sendable {
    func paths() async -> ProxyPaths
    func ensureExists(port: UInt16, managementKey: String, allowNetworkAccess: Bool) async
    func setPort(_ port: UInt16) async
    func setHost(_ host: String) async
    func ensureAPIKey() async
    func setAllowRemote(_ enabled: Bool) async
    func setLogging(_ enabled: Bool) async
    func setRoutingStrategy(_ strategy: String) async
    func setProxyURL(_ url: String?) async
    func setManagementKey(_ key: String) async
    func makeTestConfiguration(port: UInt16, managementKey: String) async throws -> String
    func removeTestConfiguration(at path: String) async
}

public protocol ProxyBinaryDownloading: Sendable {
    func download(from url: String) async throws -> Data
    func readLocalFile(at path: String) async throws -> Data
}

public protocol ProxyChecksumVerifying: Sendable {
    func verify(_ data: Data, expectedSHA256: String) throws
}

public protocol ProxyManagementChecking: Sendable {
    func isHealthy(endpoint: ProxyEndpoint, managementKey: String, timeout: Duration) async -> Bool
    func compatibility(endpoint: ProxyEndpoint, managementKey: String) async -> ProxyCompatibilityResult
}

public protocol ProxyRuntimeMetadataRepository: Sendable {
    func loadPort() -> UInt16
    func savePort(_ port: UInt16)
    func loadLegacyInstalledVersion() -> String?
    func saveLegacyInstalledVersion(_ version: String)
    func loadLastUpdateCheckDate() -> Date?
    func saveLastUpdateCheckDate(_ date: Date)
}

public protocol ProxyManagementKeyVault: Sendable {
    func loadManagementKey() async -> String?
    @discardableResult
    func saveManagementKey(_ key: String) async -> Bool
}

public protocol ProxyConfigurationSupplementing: Sendable {
    func synchronize(configurationPath: String) async
}

public protocol ProxyNotificationDelivering: Sendable {
    func deliver(_ notification: ProxyNotification) async
}

public protocol ProxyControlling: Sendable {
    func snapshots() async -> AsyncStream<ProxySnapshot>
    func snapshot() async -> ProxySnapshot
    func initialize() async
    func start() async throws
    func stop() async
    func stopAndWait() async
    func restart() async throws
    func shutdown() async
    func installLatest() async throws
    func checkForUpgrade() async
    func availableVersions(limit: Int) async throws -> [ProxyVersionInfo]
    func install(_ version: ProxyVersionInfo) async throws
    func activate(version: String) async throws
    func delete(version: String) async throws
    func rollback() async throws
    func versionsToDeleteAfterInstalling(keeping count: Int) async -> [String]
    func setPort(_ port: UInt16) async
    func setNetworkAccess(_ enabled: Bool) async
    func setRemoteAccess(_ enabled: Bool) async
    func setLogging(_ enabled: Bool) async
    func setRoutingStrategy(_ strategy: String) async
    func setProxyURL(_ url: String?) async
    func regenerateManagementKey() async throws
}
