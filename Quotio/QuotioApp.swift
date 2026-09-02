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
    private var viewModel: QuotaViewModel { runtime.viewModel }
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
                RootNavigationView()
                    .id(languageManager.currentLanguage)
                    .environment(viewModel)
                    .environment(runtime.logsViewModel)
                    .environment(modeManager)
                    .environment(\.locale, languageManager.locale)
                    .task {
                        await runtime.initializeIfNeeded()
                        showOnboarding = runtime.needsOnboarding
                    }
                    .onChange(of: viewModel.proxyManager.proxyStatus.running) {
                        runtime.updateStatusBar()
                    }
                    .onChange(of: viewModel.isLoadingQuotas) {
                        runtime.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: languageManager.currentLanguage) { _, _ in
                        runtime.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: appearanceManager.appearanceMode) {
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: menuBarSettings.showQuotaInMenuBar) {
                        runtime.updateStatusBar()
                    }
                    .onChange(of: menuBarSettings.showMenuBarIcon) {
                        runtime.updateStatusBar()
                    }
                    .onChange(of: menuBarSettings.selectedItems) {
                        runtime.updateStatusBar()
                    }
                    .onChange(of: menuBarSettings.colorMode) {
                        runtime.updateStatusBar()
                    }
                    .onChange(of: menuBarSettings.quotaDisplayMode) {
                        runtime.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: menuBarSettings.stackPairedQuotaMetrics) {
                        runtime.updateStatusBar()
                    }
                    .onChange(of: menuBarSettings.totalUsageMode) {
                        runtime.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: menuBarSettings.modelAggregationMode) {
                        runtime.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: modeManager.currentMode) {
                        runtime.updateStatusBar()
                    }
                    .onChange(of: viewModel.providerQuotas.count) {
                        runtime.updateStatusBar()
                        statusBarManager.rebuildMenuInPlace()
                    }
                    .onChange(of: viewModel.directAuthFiles.count) {
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
