import Foundation

public enum ProxyEndpointError: Error, Equatable, Sendable {
    case invalidPort
}

public struct ProxyEndpoint: Codable, Equatable, Sendable {
    public let port: UInt16

    public init(port: UInt16) throws {
        guard port > 0 else {
            throw ProxyEndpointError.invalidPort
        }
        self.port = port
    }

    public var baseURL: String {
        "http://127.0.0.1:\(port)"
    }

    public var managementURL: String {
        "\(baseURL)/v0/management"
    }

    public var clientEndpoint: String {
        "http://localhost:\(port)/v1"
    }
}

public enum ProxyLifecycleState: String, Codable, Equatable, Sendable {
    case idle
    case starting
    case active
    case stopping
    case downloading
    case testing
    case promoting
    case rollingBack
}

public enum ProxyLifecycleTransitionError: Error, Equatable, Sendable {
    case illegal(from: ProxyLifecycleState, to: ProxyLifecycleState)
}

public struct ProxyLifecycleStateMachine: Equatable, Sendable {
    public private(set) var state: ProxyLifecycleState

    public init(state: ProxyLifecycleState = .idle) {
        self.state = state
    }

    public mutating func transition(to next: ProxyLifecycleState) throws {
        guard Self.canTransition(from: state, to: next) else {
            throw ProxyLifecycleTransitionError.illegal(from: state, to: next)
        }
        state = next
    }

    public static func canTransition(
        from current: ProxyLifecycleState,
        to next: ProxyLifecycleState
    ) -> Bool {
        if current == next { return true }

        switch (current, next) {
        case (.idle, .starting),
             (.idle, .downloading),
             (.idle, .rollingBack),
             (.starting, .active),
             (.starting, .idle),
             (.starting, .stopping),
             (.active, .stopping),
             (.active, .idle),
             (.active, .downloading),
             (.active, .rollingBack),
             (.stopping, .idle),
             (.stopping, .starting),
             (.downloading, .testing),
             (.downloading, .idle),
             (.downloading, .active),
             (.downloading, .stopping),
             (.testing, .promoting),
             (.testing, .idle),
             (.testing, .active),
             (.testing, .stopping),
             (.promoting, .starting),
             (.promoting, .idle),
             (.promoting, .active),
             (.promoting, .stopping),
             (.rollingBack, .starting),
             (.rollingBack, .idle),
             (.rollingBack, .active),
             (.rollingBack, .stopping):
            return true
        default:
            return false
        }
    }
}

public struct ProxyStatus: Codable, Equatable, Sendable {
    public var running: Bool
    public var port: UInt16

    public init(running: Bool = false, port: UInt16 = 8317) {
        self.running = running
        self.port = port
    }

    public var endpoint: String {
        "http://localhost:\(port)/v1"
    }
}

public struct ProxyVersionInfo: Sendable, Identifiable, Equatable {
    public let version: String
    public let sha256: String
    public let downloadURL: String?
    public let releaseNotes: String?
    public let size: Int?
    public let localFilePath: String?

    public var id: String { version }

    public init(
        version: String,
        sha256: String,
        downloadURL: String? = nil,
        localFilePath: String? = nil,
        releaseNotes: String? = nil,
        size: Int? = nil
    ) {
        self.version = version
        self.sha256 = sha256
        self.downloadURL = downloadURL
        self.localFilePath = localFilePath
        self.releaseNotes = releaseNotes
        self.size = size
    }
}

public struct InstalledProxyVersion: Sendable, Identifiable, Equatable {
    public let version: String
    public let path: String
    public let installedAt: Date
    public let isCurrent: Bool

    public var id: String { version }

    public init(version: String, path: String, installedAt: Date, isCurrent: Bool) {
        self.version = version
        self.path = path
        self.installedAt = installedAt
        self.isCurrent = isCurrent
    }
}

public enum ProxyCompatibilityResult: Equatable, Sendable {
    case compatible
    case proxyNotResponding
    case proxyNotRunning
    case connectionError(String)

    public var isCompatible: Bool {
        self == .compatible
    }
}

public enum ProxyFailure: Error, Equatable, Sendable {
    case binaryNotFound
    case startupFailed
    case operationInProgress
    case network(String)
    case noCompatibleBinary
    case downloadFailed(String)
    case checksumMissing
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case installationFailed(String)
    case compatibilityCheckFailed(ProxyCompatibilityResult)
    case dryRunFailed(String)
    case rollbackFailed(String)
    case noVersionAvailable
    case versionAlreadyInstalled(String)
    case cannotDeleteCurrentVersion
    case cancelled
}

public enum ProxyNotification: Equatable, Sendable {
    case crashed(exitCode: Int32)
    case upgradeSucceeded(version: String)
    case upgradeFailed(version: String, reason: String)
    case rolledBack(version: String)
    case suppressUpgrade(version: String)
}

public struct ProxyRunID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ProxyProcessRequest: Equatable, Sendable {
    public let runID: ProxyRunID
    public let executablePath: String
    public let configurationPath: String

    public init(
        runID: ProxyRunID = ProxyRunID(),
        executablePath: String,
        configurationPath: String
    ) {
        self.runID = runID
        self.executablePath = executablePath
        self.configurationPath = configurationPath
    }
}

public struct ProxyProcessExit: Equatable, Sendable {
    public let runID: ProxyRunID
    public let processID: Int32
    public let exitCode: Int32

    public init(runID: ProxyRunID, processID: Int32, exitCode: Int32) {
        self.runID = runID
        self.processID = processID
        self.exitCode = exitCode
    }
}

public struct ProxyVersionSnapshot: Equatable, Sendable {
    public let currentBinaryPath: String?
    public let expectedBinaryPath: String
    public let currentVersion: String?
    public let installedVersions: [InstalledProxyVersion]

    public init(
        currentBinaryPath: String?,
        expectedBinaryPath: String,
        currentVersion: String?,
        installedVersions: [InstalledProxyVersion]
    ) {
        self.currentBinaryPath = currentBinaryPath
        self.expectedBinaryPath = expectedBinaryPath
        self.currentVersion = currentVersion
        self.installedVersions = installedVersions
    }
}

public struct ProxyPaths: Equatable, Sendable {
    public let legacyBinaryPath: String
    public let configPath: String
    public let authDirectoryPath: String
    public let expectedBinaryPath: String

    public init(
        legacyBinaryPath: String,
        configPath: String,
        authDirectoryPath: String,
        expectedBinaryPath: String
    ) {
        self.legacyBinaryPath = legacyBinaryPath
        self.configPath = configPath
        self.authDirectoryPath = authDirectoryPath
        self.expectedBinaryPath = expectedBinaryPath
    }
}

public struct ProxySnapshot: Equatable, Sendable {
    public var lifecycle: ProxyLifecycleState
    public var status: ProxyStatus
    public var paths: ProxyPaths
    public var managementKey: String
    public var isBinaryInstalled: Bool
    public var isDownloading: Bool
    public var isRegeneratingKey: Bool
    public var downloadProgress: Double
    public var lastError: ProxyFailure?
    public var testingVersion: String?
    public var testPort: UInt16?
    public var activeVersion: String?
    public var upgradeError: ProxyFailure?
    public var availableUpgrade: ProxyVersionInfo?
    public var lastUpdateCheckDate: Date?
    public var legacyInstalledVersion: String?
    public var installedVersions: [InstalledProxyVersion]

    public init(
        lifecycle: ProxyLifecycleState = .idle,
        status: ProxyStatus = ProxyStatus(),
        paths: ProxyPaths,
        managementKey: String = "",
        isBinaryInstalled: Bool = false,
        isDownloading: Bool = false,
        isRegeneratingKey: Bool = false,
        downloadProgress: Double = 0,
        lastError: ProxyFailure? = nil,
        testingVersion: String? = nil,
        testPort: UInt16? = nil,
        activeVersion: String? = nil,
        upgradeError: ProxyFailure? = nil,
        availableUpgrade: ProxyVersionInfo? = nil,
        lastUpdateCheckDate: Date? = nil,
        legacyInstalledVersion: String? = nil,
        installedVersions: [InstalledProxyVersion] = []
    ) {
        self.lifecycle = lifecycle
        self.status = status
        self.paths = paths
        self.managementKey = managementKey
        self.isBinaryInstalled = isBinaryInstalled
        self.isDownloading = isDownloading
        self.isRegeneratingKey = isRegeneratingKey
        self.downloadProgress = downloadProgress
        self.lastError = lastError
        self.testingVersion = testingVersion
        self.testPort = testPort
        self.activeVersion = activeVersion
        self.upgradeError = upgradeError
        self.availableUpgrade = availableUpgrade
        self.lastUpdateCheckDate = lastUpdateCheckDate
        self.legacyInstalledVersion = legacyInstalledVersion
        self.installedVersions = installedVersions
    }
}
