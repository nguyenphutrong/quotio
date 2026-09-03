import Foundation
import QuotioInfrastructure

/// Infrastructure bridge from the existing PIV vault to the credential storage port.
nonisolated struct YubiKeyCredentialDataStore: ProtectedCredentialDataStoring {
    var isEnabled: Bool {
        get async { YubiKeySecretVault.isEnabled }
    }

    func read(service: String, account: String) async -> ProtectedCredentialReadResult {
        switch YubiKeySecretVault.readResult(service: service, account: account) {
        case .absent: .absent
        case .unreadable: .unreadable
        case .success(let data): .success(data)
        }
    }

    func save(_ data: Data, service: String, account: String) async -> Bool {
        YubiKeySecretVault.save(data, service: service, account: account)
    }

    func delete(service: String, account: String) async {
        YubiKeySecretVault.delete(service: service, account: account)
    }
}
