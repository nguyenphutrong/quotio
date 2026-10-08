import Foundation
import Observation
import QuotioApplication
import QuotioDomain

/// View-owned presentation state for the Accounts screen. Rows record intent here and
/// the screen hosts each sheet and confirmation once instead of once per provider.
@MainActor
@Observable
final class AccountsSettingsScreenModel {
    enum Sheet: Identifiable {
        case oauth(QuotaProvider)
        case apiKey(QuotaProvider, Account?)

        var id: String {
            switch self {
            case .oauth(let provider): "oauth:" + provider.rawValue
            case .apiKey(let provider, let account): "apiKey:" + provider.rawValue + ":" + (account?.id ?? "")
            }
        }
    }

    struct SourceRemoval: Identifiable {
        let provider: QuotaProvider
        let source: AccountLoginSource
        var id: String { source.id }
    }

    var sheet: Sheet?
    var renamingAccount: Account?
    var newName = ""
    var removingAccount: Account?
    var removingSource: SourceRemoval?
    var pendingPin: MenuBarQuotaItem?
    var actionFailed = false
    var failedAuthorizationID: String?

    func beginRename(_ account: Account) {
        newName = account.displayName
        renamingAccount = account
    }

    /// Requests Keychain access directly; macOS presents its own consent dialog.
    func authorize(_ source: NativeSourcePermission, accounts: AccountsScreenModel, controller: QuotaFeatureController) async {
        failedAuthorizationID = nil
        do {
            try await accounts.authorizeNativeSource(source)
            await controller.refresh(provider: source.provider)
        } catch {
            failedAuthorizationID = source.id
        }
    }
}
