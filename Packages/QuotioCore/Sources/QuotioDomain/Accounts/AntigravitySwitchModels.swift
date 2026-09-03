import Foundation

public struct AntigravityActiveAccount: Equatable, Sendable {
    public let email: String
    public let detectedAt: Date

    public init(email: String, detectedAt: Date) {
        self.email = email
        self.detectedAt = detectedAt
    }

    public func matches(email: String) -> Bool {
        self.email.caseInsensitiveCompare(email) == .orderedSame
    }
}

public enum AntigravityTokenFormat: Equatable, Sendable {
    case legacy
    case unified
    case unknown
}

public struct AntigravityInstalledVersion: Equatable, Sendable {
    public let shortVersion: String
    public let bundleVersion: String

    public init(shortVersion: String, bundleVersion: String) {
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
    }
}

public struct AntigravityDeviceProfile: Codable, Equatable, Sendable {
    public let machineID: String
    public let macMachineID: String
    public let deviceID: String
    public let sqmID: String

    public init(machineID: String, macMachineID: String, deviceID: String, sqmID: String) {
        self.machineID = machineID
        self.macMachineID = macMachineID
        self.deviceID = deviceID
        self.sqmID = sqmID
    }

    private enum CodingKeys: String, CodingKey {
        case machineID = "machineId"
        case macMachineID = "macMachineId"
        case deviceID = "devDeviceId"
        case sqmID = "sqmId"
    }
}

public enum AntigravitySwitchProgress: String, CaseIterable, Equatable, Sendable {
    case closingIDE
    case creatingBackup
    case injectingToken
    case restartingIDE
}

public enum AntigravitySwitchState: Equatable, Sendable {
    case idle
    case confirming(accountID: String, accountEmail: String)
    case switching(progress: AntigravitySwitchProgress)
    case success(accountID: String)
    case failed(message: String)
}

public struct AntigravitySwitchSnapshot: Equatable, Sendable {
    public var state: AntigravitySwitchState
    public var activeAccount: AntigravityActiveAccount?

    public init(
        state: AntigravitySwitchState = .idle,
        activeAccount: AntigravityActiveAccount? = nil
    ) {
        self.state = state
        self.activeAccount = activeAccount
    }
}
