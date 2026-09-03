import QuotioDomain

public protocol YubiKeyVaultManaging: Sendable {
    var identityName: String { get }
    func snapshot() async -> YubiKeyVaultSnapshot
    func select(_ identity: YubiKeyPIVIdentity) async -> Bool
    func preflight(_ device: YubiKeyPIVDevice) async -> Result<YubiKeyPIVPreflight, YubiKeyProvisioningError>
    func provision(
        device: YubiKeyPIVDevice,
        preflight: YubiKeyPIVPreflight,
        pin: String,
        managementKey: String?
    ) async -> Result<Void, YubiKeyProvisioningError>
}
