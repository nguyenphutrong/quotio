//
//  CKotaApp.swift
//  CKota - CLIProxyAPI GUI Wrapper
//

import AppKit
import ServiceManagement
import SwiftUI
#if canImport(Sparkle)
    import Sparkle
#endif

@main
struct CKotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = QuotaViewModel()
    @State private var menuBarSettings = MenuBarSettingsManager.shared
    @State private var statusBarManager = StatusBarManager.shared
    @State private var modeManager = AppModeManager.shared
    @State private var appearanceManager = AppearanceManager.shared
    @State private var showOnboarding = false
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    @Environment(\.openWindow) private var openWindow

    #if canImport(Sparkle)
        private let updaterService = UpdaterService.shared
    #endif

    private var quotaItems: [MenuBarQuotaDisplayItem] {
        guard menuBarSettings.showQuotaInMenuBar else { return [] }

        // In quota-only mode, show quota even without proxy running
        if modeManager.isFullMode, !viewModel.proxyManager.proxyStatus.running {
            return []
        }

        var items: [MenuBarQuotaDisplayItem] = []

        for selectedItem in menuBarSettings.selectedItems {
            guard let provider = selectedItem.aiProvider else { continue }

            if let accountQuotas = viewModel.providerQuotas[provider],
               let quotaData = accountQuotas[selectedItem.accountKey],
               !quotaData.models.isEmpty
            {
                let displayPercent: Double

                // For Claude Code: prioritize 5h Burst (five-hour) over Weekly
                if provider == .claude {
                    if let fiveHour = quotaData.models.first(where: { $0.name == "five-hour" }) {
                        displayPercent = fiveHour.percentage
                    } else {
                        // Fallback to first available model
                        displayPercent = quotaData.models.first?.percentage ?? -1
                    }
                } else {
                    // For other providers: show lowest percentage (most critical)
                    let validPercentages = quotaData.models.map(\.percentage).filter { $0 >= 0 }
                    displayPercent = validPercentages.min() ?? (quotaData.models.first?.percentage ?? -1)
                }

                items.append(MenuBarQuotaDisplayItem(
                    id: selectedItem.id,
                    providerSymbol: provider.menuBarSymbol,
                    accountShort: selectedItem.accountKey,
                    percentage: displayPercent,
                    provider: provider
                ))
            } else {
                items.append(MenuBarQuotaDisplayItem(
                    id: selectedItem.id,
                    providerSymbol: provider.menuBarSymbol,
                    accountShort: selectedItem.accountKey,
                    percentage: -1,
                    provider: provider
                ))
            }
        }

        return items
    }

    private func updateStatusBar() {
        let isRunning = modeManager.isFullMode ? viewModel.proxyManager.proxyStatus.running : true

        statusBarManager.updateStatusBar(
            items: quotaItems,
            colorMode: menuBarSettings.colorMode,
            isRunning: isRunning,
            showMenuBarIcon: menuBarSettings.showMenuBarIcon,
            showQuota: menuBarSettings.showQuotaInMenuBar,
            menuContentProvider: {
                AnyView(
                    MenuBarView()
                        .environment(viewModel)
                )
            }
        )
    }

    private func initializeApp() async {
        // Apply saved appearance mode
        appearanceManager.applyAppearance()

        // Check if onboarding needed
        if !modeManager.hasCompletedOnboarding {
            showOnboarding = true
            return
        }

        // Initialize based on mode
        await viewModel.initialize()

        #if canImport(Sparkle)
            updaterService.checkForUpdatesInBackground()
        #endif

        updateStatusBar()
    }

    var body: some Scene {
        Window("CKota", id: "main") {
            ContentView()
                .environment(viewModel)
                .task {
                    await initializeApp()
                }
                .onChange(of: viewModel.proxyManager.proxyStatus.running) {
                    updateStatusBar()
                }
                .onChange(of: viewModel.isLoadingQuotas) {
                    updateStatusBar()
                }
                .onChange(of: menuBarSettings.showQuotaInMenuBar) {
                    updateStatusBar()
                }
                .onChange(of: menuBarSettings.showMenuBarIcon) {
                    updateStatusBar()
                }
                .onChange(of: menuBarSettings.selectedItems) {
                    updateStatusBar()
                }
                .onChange(of: menuBarSettings.colorMode) {
                    updateStatusBar()
                }
                .onChange(of: modeManager.currentMode) {
                    updateStatusBar()
                }
                .sheet(isPresented: $showOnboarding) {
                    ModePickerView {
                        Task { await initializeApp() }
                    }
                }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}

            #if canImport(Sparkle)
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates...") {
                        updaterService.checkForUpdates()
                    }
                    .disabled(!updaterService.canCheckForUpdates)
                }
            #endif

            // View menu commands
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)),
                        with: nil
                    )
                }
                .keyboardShortcut("b", modifiers: .command)

                Divider()

                Button("Refresh All") {
                    Task {
                        if modeManager.isQuotaOnlyMode {
                            await viewModel.refreshQuotasDirectly()
                        } else {
                            await viewModel.refreshData()
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.isLoadingQuotas)
            }
        }
    }
}

// MARK: - Keyboard Shortcut Notifications

extension Notification.Name {
    static let switchToNextTab = Notification.Name("switchToNextTab")
    static let switchToPreviousTab = Notification.Name("switchToPreviousTab")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowWillCloseObserver: NSObjectProtocol?
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
    private var keyEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowWillClose(notification)
        }

        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowDidBecomeKey(notification)
        }

        // Monitor Ctrl+Tab for tab switching
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Check for Ctrl+Tab
            if event.keyCode == 48, event.modifierFlags.contains(.control) {
                if event.modifierFlags.contains(.shift) {
                    NotificationCenter.default.post(name: .switchToPreviousTab, object: nil)
                } else {
                    NotificationCenter.default.post(name: .switchToNextTab, object: nil)
                }
                return nil // Consume the event
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_: Notification) {
        CLIProxyManager.terminateProxyOnShutdown()
    }

    private func handleWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard window.title == "CKota" else { return }

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func handleWindowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        guard closingWindow.title == "CKota" else { return }

        let remainingWindows = NSApp.windows.filter { window in
            window != closingWindow &&
                window.title == "CKota" &&
                window.isVisible &&
                !window.isMiniaturized
        }

        if remainingWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    deinit {
        if let observer = windowWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

struct ContentView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var modeManager = AppModeManager.shared

    var body: some View {
        @Bindable var vm = viewModel

        NavigationSplitView {
            VStack(spacing: 0) {
                SidebarHeaderView()

                List(selection: $vm.currentPage) {
                    Section(header: Text("GENERAL").font(.caption).foregroundStyle(.secondary)) {
                        Label("nav.home".localized(), systemImage: NavigationPage.home.icon)
                            .tag(NavigationPage.home)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .ckNavItemHover()

                        Label("nav.analytics".localized(), systemImage: NavigationPage.analytics.icon)
                            .tag(NavigationPage.analytics)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .ckNavItemHover()
                    }

                    Section(header: Text("IDENTITY & ACCESS").font(.caption).foregroundStyle(.secondary)) {
                        Label(modeManager.isQuotaOnlyMode ? "nav.accounts".localized() : "nav.providers".localized(),
                              systemImage: NavigationPage.providers.icon)
                            .tag(NavigationPage.providers)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .ckNavItemHover()
                    }

                    Section(header: Text("SYSTEM").font(.caption).foregroundStyle(.secondary)) {
                        Label("nav.settings".localized(), systemImage: NavigationPage.settings.icon)
                            .tag(NavigationPage.settings)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .ckNavItemHover()

                        Label("nav.about".localized(), systemImage: NavigationPage.about.icon)
                            .tag(NavigationPage.about)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .ckNavItemHover()
                    }
                }

                // Status section at bottom - different per mode
                VStack(spacing: 0) {
                    Divider()
                    Group {
                        if modeManager.isFullMode {
                            ProxyStatusRow(viewModel: viewModel)
                        } else {
                            QuotaRefreshStatusRow(viewModel: viewModel)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(.regularMaterial)
            }
            .navigationTitle("CKota")
            .toolbar {
                ToolbarItem {
                    if modeManager.isFullMode {
                        // Full mode: proxy controls
                        if viewModel.proxyManager.isStarting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button {
                                Task { await viewModel.toggleProxy() }
                            } label: {
                                Image(systemName: viewModel.proxyManager.proxyStatus
                                    .running ? "stop.fill" : "play.fill")
                            }
                            .help(viewModel.proxyManager.proxyStatus.running ? "action.stopProxy".localized() : "action.startProxy"
                                .localized())
                        }
                    } else {
                        // Quota-only mode: refresh button
                        Button {
                            Task { await viewModel.refreshQuotasDirectly() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("action.refreshQuota".localized())
                        .disabled(viewModel.isLoadingQuotas)
                    }
                }
            }
        } detail: {
            switch viewModel.currentPage {
            case .home:
                DashboardScreen()
            case .analytics:
                QuotaScreen()
            case .providers:
                ProvidersScreen()
            case .settings:
                SettingsScreen()
            case .about:
                AboutScreen()
            }
        }
        .tint(Color.ckAccent)
    }
}

// MARK: - Sidebar Status Rows

/// Proxy status row for Full Mode
struct ProxyStatusRow: View {
    let viewModel: QuotaViewModel

    var body: some View {
        HStack {
            if viewModel.proxyManager.isStarting {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(viewModel.proxyManager.proxyStatus.running ? .green : .gray)
                    .frame(width: 8, height: 8)
            }

            if viewModel.proxyManager.isStarting {
                Text("status.starting".localized())
                    .font(.caption)
            } else {
                Text(viewModel.proxyManager.proxyStatus.running ? "status.running".localized() : "status.stopped"
                    .localized())
                    .font(.caption)
            }

            Spacer()

            Text(":" + String(viewModel.proxyManager.port))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Quota refresh status row for Quota-Only Mode
struct QuotaRefreshStatusRow: View {
    let viewModel: QuotaViewModel

    var body: some View {
        HStack {
            if viewModel.isLoadingQuotas {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 8, height: 8)
                Text("status.refreshing".localized())
                    .font(.caption)
            } else {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let lastRefresh = viewModel.lastQuotaRefreshTime {
                    Text("Updated \(lastRefresh, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("status.notRefreshed".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
    }
}
