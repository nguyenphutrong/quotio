//
//  QuotioApp.swift
//  Quotio - Native quota monitoring frontend
//

import QuotioPresentation
import SwiftUI

@main
struct QuotioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var showOnboarding = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    private var runtime: AppRuntime { appDelegate.runtime }
    private var quotaScreenModel: QuotaScreenModel { runtime.quotaScreenModel }
    private var menuBarSettings: MenuBarSettingsManager { runtime.menuBarSettings }
    private var modeManager: OperatingModeManager { runtime.modeManager }
    private var appearanceManager: AppearanceManager { runtime.appearanceManager }
    private var languageManager: LanguageManager { runtime.languageManager }

    var body: some Scene {
        Window(AppIdentity.displayName, id: AppKitWindowPresenter.mainWindowID) {
            if AppEnvironment.isRunningUnitTests {
                EmptyView()
            } else {
                configured(
                    RootNavigationView()
                        .sheet(isPresented: $showOnboarding) {
                            OnboardingFlow { mode in
                                Task {
                                    await runtime.completeOnboarding(mode: mode)
                                }
                            }
                        }
                )
                .task {
                    await runtime.initializeIfNeeded()
                    showOnboarding = runtime.needsOnboarding
                }
            }
        }
        .defaultSize(width: 900, height: 640)
        .onChange(of: scenePhase, initial: true) { _, _ in
            guard !AppEnvironment.isRunningUnitTests else { return }
            // Keep the scene opener at app scope, even after the last window closes.
            let action = openWindow
            runtime.windowPresenter.registerSceneOpener { id in
                action(id: id)
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("nav.about".localized()) {
                    runtime.navigationScreenModel.currentPage = .updates
                    runtime.windowPresenter.showMainWindow()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("action.openApp".localized()) {
                    runtime.navigationScreenModel.currentPage = .general
                    runtime.windowPresenter.showMainWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .appInfo) {
                Button("action.checkUpdates".localized()) {
                    runtime.checkForUpdates()
                }
                .disabled(!runtime.canCheckForUpdates)
            }
        }
    }

    private func configured<Content: View>(_ content: Content) -> some View {
        content
            .id(runtime.languageManager.currentLanguage)
            .environment(runtime.quotaController)
            .environment(runtime.proxyScreenModel)
            .environment(runtime.quotaScreenModel)
            .environment(runtime.quotaHistory)
            .environment(runtime.accountsScreenModel)
            .environment(runtime.navigationScreenModel)
            .environment(runtime.modeManager)
            .environment(runtime.menuBarSettings)
            .environment(runtime.appearanceManager)
            .environment(runtime.languageManager)
            .environment(runtime.settingsScreenModel)
            .environment(runtime.launchAtLoginModel)
            .environment(runtime.applicationUpdateModel)
            .environment(runtime.notificationSettingsModel)
            .environment(runtime.credentialMigrationModel)
            .environment(runtime.providerImageModel)
            .environment(runtime.platformActions)
            .environment(runtime.pasteboard)
            .environment(\.locale, runtime.languageManager.locale)
    }

}
