import QuotioApplication
import QuotioDomain
import SwiftUI

struct QuotaScreen: View {
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(ProxyManagementScreenModel.self) private var proxyManagement
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaFeatureController.self) private var quotaController
    @Environment(NavigationScreenModel.self) private var navigation
    @Environment(MenuBarSettingsManager.self) private var settings
    @State private var providerFilter: QuotaProvider?

    private var providers: [QuotaProvider] {
        quota.providerQuotas.filter { !$0.value.isEmpty }.keys.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        Group {
            if providers.isEmpty {
                ContentUnavailableView {
                    Label("empty.noQuotaData".localized(), systemImage: "chart.bar")
                } description: {
                    Text("connections.usageEmpty".localized())
                } actions: {
                    Button("connections.all".localized()) { navigation.showProviders() }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(providers.filter { providerFilter == nil || $0 == providerFilter }) { provider in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    ProviderIcon(provider: provider, size: 24)
                                    Text(provider.displayName).font(.title3.weight(.semibold))
                                    Spacer()
                                    Button("connections.manage".localized()) { navigation.selectProvider(provider) }
                                }
                                ProviderQuotaView(
                                    provider: provider,
                                    authFiles: proxyManagement.authFiles.filter { $0.providerID == provider },
                                    quotaData: quota.providerQuotas[provider] ?? [:],
                                    subscriptionInfos: quota.subscriptionInfos[provider] ?? [:],
                                    aliases: quota.state.accountAliases[provider] ?? [:],
                                    isLoading: quota.isRefreshing(provider: provider)
                                )
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("connections.usage".localized())
        .toolbar {
            ToolbarItem {
                Picker("nav.providers".localized(), selection: $providerFilter) {
                    Text("connections.all".localized()).tag(Optional<QuotaProvider>.none)
                    ForEach(providers) { Text($0.displayName).tag(Optional($0)) }
                }
                .labelsHidden()
                .help("nav.providers".localized())
            }
            ToolbarItem {
                Menu {
                    Picker("display_mode".localized(), selection: Binding(
                        get: { settings.quotaDisplayMode }, set: { settings.quotaDisplayMode = $0 }
                    )) {
                        ForEach(QuotaDisplayMode.allCases) { Text($0.localizationKey.localized()).tag($0) }
                    }
                    Picker("settings.quota.displayStyle".localized(), selection: Binding(
                        get: { settings.quotaDisplayStyle }, set: { settings.quotaDisplayStyle = $0 }
                    )) {
                        ForEach(QuotaDisplayStyle.allCases) { Label($0.localizationKey.localized(), systemImage: $0.iconName).tag($0) }
                    }
                } label: {
                    Label("connections.display".localized(), systemImage: "slider.horizontal.3")
                }
            }
            ToolbarItem {
                RefreshButton(title: "action.refresh".localized(), isRefreshing: quota.isLoadingQuotas) {
                    if let providerFilter { await quotaController.refresh(provider: providerFilter) }
                    else { await quotaController.refreshAll(force: true) }
                }
            }
        }
        .onChange(of: providers) {
            if let providerFilter, !providers.contains(providerFilter) { self.providerFilter = nil }
        }
    }
}
