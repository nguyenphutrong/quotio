import Foundation

public enum ProxyCLIAuthCommand: Equatable, Sendable {
    case copilotLogin
    case kiroGoogleLogin
    case kiroAWSLogin
    case kiroAWSAuthCode
    case kiroImport

    public var arguments: [String] {
        switch self {
        case .copilotLogin: ["-github-copilot-login"]
        case .kiroGoogleLogin: ["-kiro-google-login"]
        case .kiroAWSLogin: ["-kiro-aws-login"]
        case .kiroAWSAuthCode: ["-kiro-aws-authcode"]
        case .kiroImport: ["-kiro-import"]
        }
    }
}

public struct ProxyCLIAuthRuntime: Equatable, Sendable {
    public let binaryPath: String
    public let configurationPath: String

    public init(binaryPath: String, configurationPath: String) {
        self.binaryPath = binaryPath
        self.configurationPath = configurationPath
    }
}

public struct LocalProxyOAuthRuntime: Equatable, Sendable {
    public let cli: ProxyCLIAuthRuntime?
    public let management: ProxyManagementConnection?

    public init(cli: ProxyCLIAuthRuntime?, management: ProxyManagementConnection?) {
        self.cli = cli
        self.management = management
    }
}

public enum ProxyCLIAuthStatus: Equatable, Sendable {
    case authenticationCompleted
    case authenticationCancelled
    case copilotBrowserOpened(deviceCode: String?)
    case browserOpened
    case failedToStart(details: String)
}

public struct ProxyCLIAuthResult: Equatable, Sendable {
    public let success: Bool
    public let status: ProxyCLIAuthStatus
    public let deviceCode: String?

    public init(success: Bool, status: ProxyCLIAuthStatus, deviceCode: String?) {
        self.success = success
        self.status = status
        self.deviceCode = deviceCode
    }
}

public protocol ProxyCLIAuthenticating: Sendable {
    func run(_ command: ProxyCLIAuthCommand, runtime: ProxyCLIAuthRuntime) async -> ProxyCLIAuthResult
    func terminate() async
}

public protocol AntigravityAuthFileWorkaroundApplying: Sendable {
    func apply(in authDirectory: String) async
    func remove(in authDirectory: String) async
}
