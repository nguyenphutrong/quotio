import Foundation

public enum CloudflareTunnelStatus: String, Equatable, Sendable {
    case idle
    case starting
    case active
    case stopping
    case error
}

public struct CloudflaredInstallation: Equatable, Sendable {
    public let isInstalled: Bool
    public let path: String?
    public let version: String?

    public init(isInstalled: Bool, path: String?, version: String?) {
        self.isInstalled = isInstalled
        self.path = path
        self.version = version
    }

    public static let notInstalled = CloudflaredInstallation(
        isInstalled: false,
        path: nil,
        version: nil
    )
}

public enum TunnelFailure: Error, Equatable, Sendable {
    case notInstalled
    case alreadyRunning
    case startFailed(String)
    case unexpectedExit
    case startTimeout
}

public struct CloudflareTunnelSnapshot: Equatable, Sendable {
    public var status: CloudflareTunnelStatus
    public var publicURL: String?
    public var failure: TunnelFailure?
    public var startTime: Date?
    public var installation: CloudflaredInstallation

    public init(
        status: CloudflareTunnelStatus = .idle,
        publicURL: String? = nil,
        failure: TunnelFailure? = nil,
        startTime: Date? = nil,
        installation: CloudflaredInstallation = .notInstalled
    ) {
        self.status = status
        self.publicURL = publicURL
        self.failure = failure
        self.startTime = startTime
        self.installation = installation
    }

    public var isActive: Bool { status == .active }
    public var isTransitioning: Bool { status == .starting || status == .stopping }
}
