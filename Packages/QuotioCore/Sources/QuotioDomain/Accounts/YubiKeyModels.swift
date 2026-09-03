public struct YubiKeyPIVIdentity: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let fingerprint: String

    public init(id: String, name: String, fingerprint: String) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
    }
}

public struct YubiKeyPIVDevice: Identifiable, Hashable, Sendable {
    public let serial: String
    public let name: String
    public var id: String { serial }

    public init(serial: String, name: String) {
        self.serial = serial
        self.name = name
    }
}

public enum YubiKeyPIVSlotState: Sendable, Equatable {
    case empty
    case occupied
    case unknown
}

public struct YubiKeyPIVPreflight: Sendable, Equatable {
    public let slot9d: YubiKeyPIVSlotState
    public let managementKeyProtected: Bool
    public let usesDefaultManagementKey: Bool
    public let pinTriesRemaining: String?
    public let report: String

    public var destroysExistingKey: Bool { slot9d != .empty }

    public init(
        slot9d: YubiKeyPIVSlotState,
        managementKeyProtected: Bool,
        usesDefaultManagementKey: Bool,
        pinTriesRemaining: String?,
        report: String
    ) {
        self.slot9d = slot9d
        self.managementKeyProtected = managementKeyProtected
        self.usesDefaultManagementKey = usesDefaultManagementKey
        self.pinTriesRemaining = pinTriesRemaining
        self.report = report
    }
}

public enum YubiKeyProvisioningError: Error, Sendable, Equatable {
    case toolMissing
    case timedOut
    case deviceUnavailable(String)
    case managementKeyRejected
    case pinRejected(triesRemaining: Int?)
    case pinBlocked
    case stepFailed(String)
}

public struct YubiKeyVaultSnapshot: Equatable, Sendable {
    public let isConnected: Bool
    public let devices: [YubiKeyPIVDevice]
    public let identities: [YubiKeyPIVIdentity]
    public let selectedIdentity: YubiKeyPIVIdentity?
    public let selectedFingerprint: String?
    public let protectedSecretCount: Int

    public init(
        isConnected: Bool,
        devices: [YubiKeyPIVDevice],
        identities: [YubiKeyPIVIdentity],
        selectedIdentity: YubiKeyPIVIdentity?,
        selectedFingerprint: String?,
        protectedSecretCount: Int
    ) {
        self.isConnected = isConnected
        self.devices = devices
        self.identities = identities
        self.selectedIdentity = selectedIdentity
        self.selectedFingerprint = selectedFingerprint
        self.protectedSecretCount = protectedSecretCount
    }
}
