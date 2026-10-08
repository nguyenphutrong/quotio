import SwiftUI

/// Asks for access to Quotio's own Keychain item in place; macOS shows its own consent
/// dialog, so no explanatory sheet sits in front of it.
struct AccountStorageAccessSection: View {
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaFeatureController.self) private var quota
    @State private var failed = false
    @State private var isSubmitting = false

    var body: some View {
        switch accounts.storageProblem {
        case nil:
            EmptyView()
        case .unreadable:
            problem("settings.vaultProblem.unreadable".localized())
        case .newerVersion:
            problem("settings.vaultProblem.newerVersion".localized())
        case .requiresAuthorization:
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.vaultAccess.title".localized())
                        Text("settings.vaultAccess.reason".localized() + " " + "settings.authorize.alwaysAllow".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if failed {
                            Text((accounts.nativeAuthorizationFailure ?? .unknown).message)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isSubmitting || accounts.authorizingStorage {
                        ProgressView().controlSize(.small)
                    }
                    Button("settings.authorize".localized()) { authorize() }
                        .controlSize(.small)
                        .disabled(!quota.canAuthorizeNative || isSubmitting || accounts.authorizingStorage)
                }
                .help("settings.vaultAccess.explanation".localized())
            }
        }
    }

    private func problem(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func authorize() {
        isSubmitting = true
        failed = false
        Task {
            defer { isSubmitting = false }
            do {
                try await accounts.authorizeAccountStorage()
                await quota.refreshAll(force: true)
            } catch { failed = true }
        }
    }
}
