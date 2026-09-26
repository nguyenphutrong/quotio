import QuotioApplication
import QuotioDomain
import SwiftUI

struct AppSettingsPage: View {
    let page: NavigationPage
    @Environment(LanguageManager.self) private var language
    @Environment(SettingsScreenModel.self) private var settings
    @Environment(MenuBarSettingsManager.self) private var menuBar
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(QuotaFeatureController.self) private var quota
    @Environment(OperatingModeManager.self) private var onboarding
    @State private var showOnboarding = false

    var body: some View {
        Group {
            switch page {
            case .updates, .about: AboutSettingsPage()
            default:
                Form {
                    AccountStorageAccessSection()
                    switch page {
                    case .menuBar:
                        MenuBarSettingsSection()
                        QuotaDisplaySettingsSection()
                        UsageDisplaySettingsSection()
                    case .notifications:
                        NotificationSettingsSection()
                    case .privacy:
                        PrivacySettingsSection()
                        Section("settings.authorizedSources".localized()) {
                            ForEach(accounts.authorizedNativeSources) { source in
                                LabeledContent(source.provider.displayName, value: source.keychainItemName)
                            }
                            if accounts.authorizedNativeSources.isEmpty {
                                Text("settings.noAuthorizedSources".localized()).foregroundStyle(.secondary)
                            }
                            Text("settings.revokeAccessHint".localized()).font(.caption).foregroundStyle(.secondary)
                        }
                        CredentialMigrationSection()
                    default:
                        Section("settings.general".localized()) {
                            LaunchAtLoginToggle()
                            Toggle("settings.showInDock".localized(), isOn: Binding(
                                get: { settings.appShellPreferences.showInDock },
                                set: { value in
                                    if !value && !menuBar.showMenuBarIcon { menuBar.showMenuBarIcon = true }
                                    settings.setShowInDock(value)
                                }
                            ))
                            Picker("settings.language".localized(), selection: Binding(
                                get: { language.currentLanguage }, set: { language.setLanguage($0) }
                            )) {
                                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                            }
                            Button("settings.reopenOnboarding".localized()) { showOnboarding = true }
                        }
                        AppearanceSettingsSection()
                        RefreshCadenceSettingsSection()
                        Section("settings.localLogins".localized()) {
                            Toggle("settings.automaticDiscovery".localized(), isOn: Binding(
                                get: { quota.trackingPreferences.automaticallyDiscoverLogins },
                                set: { enabled in Task { await quota.setAutomaticDiscovery(enabled) } }
                            ))
                            .disabled(!quota.canManageSettings || quota.monitoringSettings == nil || quota.isUpdatingSettings)
                            Button("settings.scanAll".localized()) {
                                Task {
                                    await accounts.scanAllNativeAccounts()
                                    await quota.refreshAll(force: true)
                                }
                            }
                            .disabled(!quota.canDiscoverNative || accounts.isScanningAll || accounts.discoveringProvider != nil)
                            if accounts.isScanningAll { ProgressView().controlSize(.small) }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(page.settingsTitle)
        .sheet(isPresented: $showOnboarding) {
            OnboardingFlow { _ in onboarding.completeOnboarding(mode: .monitor) }
        }
    }
}
