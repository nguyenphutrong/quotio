import QuotioApplication
import QuotioDomain
import XCTest
@testable import QuotioPresentation

@MainActor
final class YubiKeySettingsScreenModelTests: XCTestCase {
    func testRefreshMapsActiveAndMissingVaultStates() async {
        let identity = identity()
        let vault = YubiKeyVaultFake(snapshots: [
            snapshot(selectedIdentity: identity, selectedFingerprint: identity.fingerprint),
            snapshot(selectedIdentity: nil, selectedFingerprint: identity.fingerprint),
        ])
        let model = YubiKeySettingsScreenModel(vault: vault)

        await model.refresh()
        XCTAssertEqual(
            model.status,
            .active(name: identity.name, fingerprint: identity.fingerprint, protectedSecretCount: 2)
        )

        await model.refresh()
        XCTAssertEqual(
            model.status,
            .keyMissing(fingerprint: identity.fingerprint, protectedSecretCount: 2)
        )
    }

    func testCompleteProvisioningRetriesUntilIdentityAppearsAndAdoptsIt() async {
        let identity = identity()
        let unavailable = snapshot(selectedIdentity: nil, selectedFingerprint: nil, identities: [])
        let available = snapshot(selectedIdentity: nil, selectedFingerprint: nil, identities: [identity])
        let selected = snapshot(
            selectedIdentity: identity,
            selectedFingerprint: identity.fingerprint,
            identities: [identity]
        )
        let vault = YubiKeyVaultFake(snapshots: [unavailable, available, selected])
        let model = YubiKeySettingsScreenModel(vault: vault, retryDelay: {})

        let completion = await model.completeProvisioning()
        let selectedIdentities = await vault.selectedIdentities()
        XCTAssertEqual(completion, .adopted)
        XCTAssertEqual(selectedIdentities, [identity])
        XCTAssertEqual(
            model.status,
            .active(name: identity.name, fingerprint: identity.fingerprint, protectedSecretCount: 2)
        )
    }

    func testCompleteProvisioningDoesNotReplaceConfiguredKey() async {
        let identity = identity()
        let vault = YubiKeyVaultFake(snapshots: [
            snapshot(selectedIdentity: identity, selectedFingerprint: identity.fingerprint),
        ])
        let model = YubiKeySettingsScreenModel(vault: vault, retryDelay: {})

        let completion = await model.completeProvisioning()
        let selectedIdentities = await vault.selectedIdentities()
        XCTAssertEqual(completion, .unusedBecauseVaultConfigured)
        XCTAssertTrue(selectedIdentities.isEmpty)
    }

    private func identity() -> YubiKeyPIVIdentity {
        YubiKeyPIVIdentity(id: "fingerprint", name: "Quotio Secret Vault", fingerprint: "fingerprint")
    }

    private func snapshot(
        selectedIdentity: YubiKeyPIVIdentity?,
        selectedFingerprint: String?,
        identities: [YubiKeyPIVIdentity]? = nil
    ) -> YubiKeyVaultSnapshot {
        YubiKeyVaultSnapshot(
            isConnected: true,
            devices: [],
            identities: identities ?? [identity()],
            selectedIdentity: selectedIdentity,
            selectedFingerprint: selectedFingerprint,
            protectedSecretCount: 2
        )
    }
}

private actor YubiKeyVaultFake: YubiKeyVaultManaging {
    nonisolated let identityName = "Quotio Secret Vault"
    private var snapshots: [YubiKeyVaultSnapshot]
    private var selections: [YubiKeyPIVIdentity] = []

    init(snapshots: [YubiKeyVaultSnapshot]) {
        self.snapshots = snapshots
    }

    func snapshot() -> YubiKeyVaultSnapshot {
        if snapshots.count > 1 { return snapshots.removeFirst() }
        return snapshots[0]
    }

    func select(_ identity: YubiKeyPIVIdentity) -> Bool {
        selections.append(identity)
        return true
    }

    func preflight(
        _: YubiKeyPIVDevice
    ) -> Result<YubiKeyPIVPreflight, YubiKeyProvisioningError> {
        .failure(.toolMissing)
    }

    func provision(
        device _: YubiKeyPIVDevice,
        preflight _: YubiKeyPIVPreflight,
        pin _: String,
        managementKey _: String?
    ) -> Result<Void, YubiKeyProvisioningError> {
        .success(())
    }

    func selectedIdentities() -> [YubiKeyPIVIdentity] {
        selections
    }
}
