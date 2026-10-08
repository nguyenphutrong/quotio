import QuotioApplication
import QuotioDomain
import SwiftUI

/// Pause and remove items for one login source, when the helper allows them. Place it
/// inside a `Menu` or a context menu.
struct LoginSourceMenu: View {
    let provider: QuotaProvider
    let source: AccountLoginSource
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaFeatureController.self) private var controller
    @Environment(AccountsSettingsScreenModel.self) private var model

    static func hasActions(_ source: AccountLoginSource) -> Bool { source.actions?.isEmpty == false }

    var body: some View {
        if source.actions?.contains("set_source_enabled") == true {
            Toggle("settings.sources.pause".localized(), isOn: Binding(
                get: { source.enabled == false },
                set: { paused in
                    Task {
                        do {
                            try await accounts.setSourceEnabled(!paused, sourceID: source.accountID)
                            await controller.refresh(provider: provider)
                        } catch { model.actionFailed = true }
                    }
                }
            ))
        }
        if source.actions?.contains("remove_source") == true {
            Button("action.remove".localized() + "…", role: .destructive) {
                model.removingSource = .init(provider: provider, source: source)
            }
        }
    }
}
