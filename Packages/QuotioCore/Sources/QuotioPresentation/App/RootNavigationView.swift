import SwiftUI

public struct RootNavigationView: View {
    public init() {}

    @Environment(NavigationScreenModel.self) private var navigation
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var controller

    private var attentionCount: Int {
        let providerItems = ProviderAccountsSummary.totalAttention(providers: controller.providers,
            accounts: accounts.accounts, permissions: accounts.nativeSourcePermissions,
            snapshot: quota.state, tracking: controller.trackingPreferences)
        return providerItems + (accounts.storageProblem == nil ? 0 : 1)
    }

    public var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(selection: $navigation.currentPage) {
                Label("nav.accounts".localized(), systemImage: "person.2")
                    .badge(attentionCount)
                    .tag(NavigationPage.providers)
                Label(NavigationPage.companion.settingsTitle, systemImage: NavigationPage.companion.icon)
                    .tag(NavigationPage.companion)
                Label(NavigationPage.proxy.settingsTitle, systemImage: NavigationPage.proxy.icon)
                    .tag(NavigationPage.proxy)
                Section("settings.application".localized()) {
                    ForEach(NavigationPage.applicationPages) { page in
                        Label(page.settingsTitle, systemImage: page.icon).tag(page)
                    }
                }
                Section {
                    Label(NavigationPage.updates.settingsTitle, systemImage: NavigationPage.updates.icon)
                        .tag(NavigationPage.updates)
                } header: {
                    VStack {
                        Divider()
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            if navigation.currentPage == .providers {
                AccountsSettingsScreen()
            } else {
                AppSettingsPage(page: navigation.currentPage)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
    }
}

extension NavigationPage {
    static let applicationPages: [Self] = [.general, .menuBar, .notifications, .privacy]

    @MainActor var settingsTitle: String {
        switch self {
        case .general, .settings: "settings.general".localized()
        case .companion: "companion.title".localized()
        case .menuBar: "connections.menuBar".localized()
        case .notifications: "settings.notifications.title".localized()
        case .privacy: "connections.privacy".localized()
        case .proxy: "CLIProxyAPI"
        case .updates, .about: "settings.aboutUpdates".localized()
        default: "settings.general".localized()
        }
    }
}
