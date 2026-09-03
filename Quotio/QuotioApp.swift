//
//  QuotioApp.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import QuotioApplication
import QuotioDomain
import QuotioInfrastructure
import QuotioPresentation
import SwiftUI

@main
struct QuotioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var showOnboarding = false

    private var runtime: AppRuntime { appDelegate.runtime }
    private var proxyManagement: ProxyManagementScreenModel { runtime.proxyManagement }
    private var quotaScreenModel: QuotaScreenModel { runtime.quotaScreenModel }
    private var menuBarSettings: MenuBarSettingsManager { runtime.menuBarSettings }
    private var statusBarManager: StatusBarManager { runtime.statusBarManager }
    private var modeManager: OperatingModeManager { runtime.modeManager }
    private var appearanceManager: AppearanceManager { runtime.appearanceManager }
    private var languageManager: LanguageManager { runtime.languageManager }

    var body: some Scene {
        Window("Quotio", id: "main") {
            if AppEnvironment.isRunningUnitTests {
                EmptyView()
            } else {
                RootNavigationView(logsScreenModel: runtime.logsScreenModel)
                    .id(languageManager.currentLanguage)
                    .environment(proxyManagement)
                    .environment(runtime.quotaController)
                    .environment(quotaScreenModel)
                    .environment(runtime.accountsScreenModel)
                    .environment(runtime.dashboardScreenModel)
                    .environment(runtime.providersScreenModel)
                    .environment(runtime.navigationScreenModel)
                    .environment(runtime.warmupScreenModel)
                    .environment(runtime.ideImportScreenModel)
                    .environment(runtime.antigravityAccountScreenModel)
                    .environment(modeManager)
                    .environment(menuBarSettings)
                    .environment(appearanceManager)
                    .environment(languageManager)
                    .environment(runtime.settingsScreenModel)
                    .environment(runtime.refreshSettings)
                    .environment(runtime.warmupSettings)
                    .environment(runtime.ideScanSettings)
                    .environment(runtime.launchAtLoginManager)
                    .environment(runtime.updaterService)
                    .environment(runtime.notificationManager)
                    .environment(runtime.telemetrySettings)
                    .environment(runtime.updatePollingService)
                    .environment(runtime.pasteboard)
                    .environment(\.locale, languageManager.locale)
                    .task {
                        await runtime.initializeIfNeeded()
                        showOnboarding = runtime.needsOnboarding
                    }
                    .onChange(of: proxyManagement.directAuthFiles.count) {
                        runtime.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .sheet(isPresented: $showOnboarding) {
                        OnboardingFlow {
                            Task {
                                await runtime.completeOnboarding()
                            }
                        }
                    }
            }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    runtime.checkForUpdates()
                }
                .disabled(!runtime.canCheckForUpdates)
            }
        }
    }
}
