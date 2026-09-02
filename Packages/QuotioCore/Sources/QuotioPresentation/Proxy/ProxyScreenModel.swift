import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class ProxyScreenModel {
    public private(set) var state: ProxySnapshot

    @ObservationIgnored private let controller: any ProxyControlling
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    public init(controller: any ProxyControlling, initialState: ProxySnapshot) {
        self.controller = controller
        self.state = initialState
    }

    deinit {
        observationTask?.cancel()
    }

    public var proxyStatus: ProxyStatus { state.status }
    public var port: UInt16 { state.status.port }
    public var baseURL: String { "http://127.0.0.1:\(port)" }
    public var managementURL: String { "\(baseURL)/v0/management" }
    public var managementKey: String { state.managementKey }
    public var binaryPath: String { state.paths.legacyBinaryPath }
    public var configPath: String { state.paths.configPath }
    public var authDir: String { state.paths.authDirectoryPath }
    public var effectiveBinaryPath: String {
        state.installedVersions.first(where: \.isCurrent)?.path
            ?? state.paths.expectedBinaryPath
    }
    public var isBinaryInstalled: Bool { state.isBinaryInstalled }
    public var isStarting: Bool { state.lifecycle == .starting }
    public var isDownloading: Bool { state.isDownloading }
    public var isRegeneratingKey: Bool { state.isRegeneratingKey }
    public var downloadProgress: Double { state.downloadProgress }
    public var lastError: String? { state.lastError.map(Self.message(for:)) }
    public var testingVersion: String? { state.testingVersion }
    public var testPort: UInt16? { state.testPort }
    public var activeVersion: String? { state.activeVersion }
    public var upgradeError: String? { state.upgradeError.map(Self.message(for:)) }
    public var upgradeAvailable: Bool { state.availableUpgrade != nil }
    public var availableUpgrade: ProxyVersionInfo? { state.availableUpgrade }
    public var lastProxyUpdateCheckDate: Date? { state.lastUpdateCheckDate }
    public var installedProxyVersion: String? { state.legacyInstalledVersion }
    public var currentVersion: String? { state.activeVersion }
    public var installedVersions: [InstalledProxyVersion] { state.installedVersions }
    public var isUsingVersionedStorage: Bool { state.isBinaryInstalled }

    public func errorMessage(for error: Error) -> String {
        guard let failure = error as? ProxyFailure else {
            return error.localizedDescription
        }
        return Self.message(for: failure)
    }

    public func initialize() async {
        observeIfNeeded()
        await controller.initialize()
        await refreshState()
    }

    public func start() async throws {
        try await controller.start()
        await refreshState()
    }

    public func stop() {
        state.status.running = false
        state.lifecycle = .idle
        Task {
            await controller.stop()
            await refreshState()
        }
    }

    public func stopAndWait() async {
        await controller.stopAndWait()
        await refreshState()
    }

    public func restart() async throws {
        try await controller.restart()
        await refreshState()
    }

    public func shutdown() async {
        await controller.shutdown()
        await refreshState()
    }

    public func toggle() async throws {
        if state.status.running {
            stop()
        } else {
            try await start()
        }
    }

    public func downloadAndInstallBinary() async throws {
        try await controller.installLatest()
        await refreshState()
    }

    public func checkForUpgrade() async {
        await controller.checkForUpgrade()
        await refreshState()
    }

    public func fetchAvailableVersions(limit: Int = 10) async throws -> [ProxyVersionInfo] {
        try await controller.availableVersions(limit: limit)
    }

    public func performManagedUpgrade(to version: ProxyVersionInfo) async throws {
        try await controller.install(version)
        await refreshState()
    }

    public func activateVersion(_ version: String) async throws {
        try await controller.activate(version: version)
        await refreshState()
    }

    public func deleteVersion(_ version: String) async throws {
        try await controller.delete(version: version)
        await refreshState()
    }

    public func rollback() async throws {
        try await controller.rollback()
        await refreshState()
    }

    public func versionsToBeDeleted(keeping count: Int) async -> [String] {
        await controller.versionsToDeleteAfterInstalling(keeping: count)
    }

    public func setPort(_ port: UInt16) {
        Task {
            await controller.setPort(port)
            await refreshState()
        }
    }

    public func setNetworkAccess(_ enabled: Bool) {
        Task {
            await controller.setNetworkAccess(enabled)
            await refreshState()
        }
    }

    public func updateConfigAllowRemote(_ enabled: Bool) async {
        await controller.setRemoteAccess(enabled)
        await refreshState()
    }

    public func updateConfigLogging(enabled: Bool) {
        Task {
            await controller.setLogging(enabled)
            await refreshState()
        }
    }

    public func updateConfigRoutingStrategy(_ strategy: String) {
        Task {
            await controller.setRoutingStrategy(strategy)
            await refreshState()
        }
    }

    public func updateConfigProxyURL(_ url: String?) {
        Task {
            await controller.setProxyURL(url)
            await refreshState()
        }
    }

    public func regenerateManagementKey() async throws {
        try await controller.regenerateManagementKey()
        await refreshState()
    }

    private func observeIfNeeded() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self, controller] in
            let snapshots = await controller.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                self?.state = snapshot
            }
        }
    }

    private func refreshState() async {
        state = await controller.snapshot()
    }

    private static func message(for failure: ProxyFailure) -> String {
        switch failure {
        case .binaryNotFound:
            "CLIProxyAPI upstream binary is not installed. Open Settings and install a release."
        case .startupFailed:
            "Failed to start proxy server."
        case .operationInProgress:
            "Another operation is already in progress. Please wait."
        case .network(let message):
            "Network error: \(message)"
        case .noCompatibleBinary:
            "No compatible binary found for your system."
        case .downloadFailed(let message):
            "Failed to download proxy: \(message)"
        case .checksumMissing:
            "No valid SHA256 checksum provided for downloaded binary"
        case .checksumMismatch(let expected, let actual):
            "Checksum verification failed: expected \(expected.prefix(16))..., got \(actual.prefix(16))..."
        case .extractionFailed(let message):
            "Failed to extract proxy: \(message)"
        case .installationFailed(let message):
            "Failed to install proxy: \(message)"
        case .compatibilityCheckFailed:
            "Compatibility check failed"
        case .dryRunFailed(let message):
            "Dry-run failed: \(message)"
        case .rollbackFailed(let message):
            "Rollback failed: \(message)"
        case .noVersionAvailable:
            "No compatible proxy version available"
        case .versionAlreadyInstalled(let version):
            "Version \(version) is already installed"
        case .cannotDeleteCurrentVersion:
            "Cannot delete the currently active version"
        case .cancelled:
            "Operation cancelled"
        }
    }
}
