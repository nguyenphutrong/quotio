import Observation
import QuotioApplication
import QuotioDomain

public enum YubiKeyVaultStatus: Equatable, Sendable {
    case notConfigured
    case active(name: String, fingerprint: String, protectedSecretCount: Int)
    case keyMissing(fingerprint: String, protectedSecretCount: Int)
}

public enum YubiKeyProvisioningCompletion: Equatable, Sendable {
    case adopted
    case identityUnavailable
    case unusedBecauseVaultConfigured
    case requiresSelection
}

@MainActor
@Observable
public final class YubiKeySettingsScreenModel {
    public private(set) var snapshot: YubiKeyVaultSnapshot
    public private(set) var status: YubiKeyVaultStatus = .notConfigured

    public var identityName: String { vault.identityName }

    private let vault: any YubiKeyVaultManaging
    private let retryDelay: @Sendable () async -> Void

    public init(
        vault: any YubiKeyVaultManaging,
        retryDelay: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(1))
        }
    ) {
        self.vault = vault
        self.retryDelay = retryDelay
        self.snapshot = YubiKeyVaultSnapshot(
            isConnected: false,
            devices: [],
            identities: [],
            selectedIdentity: nil,
            selectedFingerprint: nil,
            protectedSecretCount: 0
        )
    }

    public func refresh() async {
        snapshot = await vault.snapshot()
        status = Self.status(from: snapshot)
    }

    public func select(_ identity: YubiKeyPIVIdentity) async -> Bool {
        let didSelect = await vault.select(identity)
        await refresh()
        return didSelect
    }

    public func preflight(
        _ device: YubiKeyPIVDevice
    ) async -> Result<YubiKeyPIVPreflight, YubiKeyProvisioningError> {
        await vault.preflight(device)
    }

    public func provision(
        device: YubiKeyPIVDevice,
        preflight: YubiKeyPIVPreflight,
        pin: String,
        managementKey: String?
    ) async -> Result<Void, YubiKeyProvisioningError> {
        await vault.provision(
            device: device,
            preflight: preflight,
            pin: pin,
            managementKey: managementKey
        )
    }

    public func completeProvisioning() async -> YubiKeyProvisioningCompletion {
        for attempt in 0..<3 {
            if attempt > 0 { await retryDelay() }
            await refresh()
            if !snapshot.identities.isEmpty { break }
        }

        guard !snapshot.identities.isEmpty else { return .identityUnavailable }
        guard case .notConfigured = status else { return .unusedBecauseVaultConfigured }

        let identity = snapshot.identities.first { $0.name == identityName }
            ?? (snapshot.identities.count == 1 ? snapshot.identities.first : nil)
        guard let identity else { return .requiresSelection }
        guard await select(identity) else { return .requiresSelection }
        return .adopted
    }

    private static func status(from snapshot: YubiKeyVaultSnapshot) -> YubiKeyVaultStatus {
        if let identity = snapshot.selectedIdentity {
            return .active(
                name: identity.name,
                fingerprint: identity.fingerprint,
                protectedSecretCount: snapshot.protectedSecretCount
            )
        }
        if let fingerprint = snapshot.selectedFingerprint {
            return .keyMissing(
                fingerprint: fingerprint,
                protectedSecretCount: snapshot.protectedSecretCount
            )
        }
        return .notConfigured
    }
}
