//
//  QuotioApp.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import AppKit
import SwiftUI
import ServiceManagement
#if canImport(Sparkle)
import Sparkle
#endif

@main
struct QuotioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel = QuotaViewModel()
    @State private var menuBarSettings = MenuBarSettingsManager.shared
    @State private var statusBarManager = StatusBarManager.shared
    @State private var modeManager = OperatingModeManager.shared
    @State private var appearanceManager = AppearanceManager.shared
    @State private var languageManager = LanguageManager.shared
    @State private var showOnboarding = false
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    @Environment(\.openWindow) private var openWindow
    
    #if canImport(Sparkle)
    private let updaterService = UpdaterService.shared
    #endif
    
    private var quotaItems: [MenuBarQuotaDisplayItem] {
        guard menuBarSettings.showQuotaInMenuBar else { return [] }
        
        // Show quota in menu bar regardless of proxy status
        // Quota fetching works independently via CLI/cookies/auth files
        
        var items: [MenuBarQuotaDisplayItem] = []
        
        for selectedItem in menuBarSettings.selectedItems {
            guard let provider = selectedItem.aiProvider else { continue }
            
            if let accountQuotas = viewModel.providerQuotas[provider],
               let quotaData = accountQuotas[selectedItem.accountKey],
               !quotaData.models.isEmpty {
                // Get display percentage based on provider-specific strategy
                let displayPercent: Double
                switch provider {
                case .claude:
                    // Claude Code: prefer Session (5-hour) quota - resets frequently, most relevant
                    let sessionModel = quotaData.models.first { 
                        $0.name == "five-hour-session" || $0.name == "Session" 
                    }
                    displayPercent = sessionModel?.percentage ?? quotaData.models.first?.percentage ?? -1
                    
                case .codex:
                    // Codex: prefer Session quota - same logic as Claude
                    let sessionModel = quotaData.models.first { 
                        $0.name == "codex-session" 
                    }
                    displayPercent = sessionModel?.percentage ?? quotaData.models.first?.percentage ?? -1
                    
                case .cursor:
                    // Cursor: prefer Plan Usage - main usage indicator
                    let planModel = quotaData.models.first { 
                        $0.name == "plan-usage" 
                    }
                    displayPercent = planModel?.percentage ?? quotaData.models.first?.percentage ?? -1
                    
                case .trae:
                    // Trae: prefer Fast Requests quota
                    let fastModel = quotaData.models.first { 
                        $0.name == "premium-fast" 
                    }
                    displayPercent = fastModel?.percentage ?? quotaData.models.first?.percentage ?? -1
                    
                default:
                    // Other providers (Copilot, Gemini, Antigravity): show lowest percentage
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
        // Menu bar should show quota data regardless of proxy status
        // The quota is fetched directly and doesn't need proxy
        let hasQuotaData = !viewModel.providerQuotas.isEmpty
        
        statusBarManager.updateStatusBar(
            items: quotaItems,
            colorMode: menuBarSettings.colorMode,
            isRunning: hasQuotaData,
            showMenuBarIcon: menuBarSettings.showMenuBarIcon,
            showQuota: menuBarSettings.showQuotaInMenuBar
        )
    }
    
    private func initializeApp() async {
        appearanceManager.applyAppearance()
        
        if !modeManager.hasCompletedOnboarding {
            showOnboarding = true
            return
        }
        
        // Scan auth files immediately (fast filesystem scan)
        // This allows menu bar to show providers before quota API calls complete
        await viewModel.loadDirectAuthFiles()
        
        // Setup menu bar immediately so user can open it while data loads
        statusBarManager.setViewModel(viewModel)
        updateStatusBar()
        
        // Load data in background
        await viewModel.initialize()
        
        #if canImport(Sparkle)
        updaterService.checkForUpdatesInBackground()
        #endif
    }
    
    var body: some Scene {
        Window("Quotio", id: "main") {
            ContentView()
                .id(languageManager.currentLanguage) // Force re-render on language change
                .environment(viewModel)
                .environment(\.locale, languageManager.locale)
                .task {
                    await initializeApp()
                }
                .onChange(of: viewModel.proxyManager.proxyStatus.running) {
                    updateStatusBar()
                }
                .onChange(of: viewModel.isLoadingQuotas) {
                    updateStatusBar()
                    // Rebuild menu when loading state changes so loader updates
                    statusBarManager.rebuildMenuInPlace()
                }
                .onChange(of: languageManager.currentLanguage) { _, _ in
                    // Rebuild menu bar when language changes
                    statusBarManager.rebuildMenuInPlace()
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
                .onChange(of: viewModel.providerQuotas.count) {
                    updateStatusBar()
                    statusBarManager.rebuildMenuInPlace()
                }
                .onChange(of: viewModel.directAuthFiles.count) {
                    updateStatusBar()
                    statusBarManager.rebuildMenuInPlace()
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingFlow {
                        Task { await initializeApp() }
                    }
                }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) { }
            
            #if canImport(Sparkle)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterService.checkForUpdates()
                }
                .disabled(!updaterService.canCheckForUpdates)
            }
            #endif
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private nonisolated(unsafe) var windowWillCloseObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowDidBecomeKeyObserver: NSObjectProtocol?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register default values for UserDefaults
        UserDefaults.standard.register(defaults: [
            "useBridgeMode": true  // Enable two-layer proxy by default for connection stability
        ])
        
        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWindowWillClose()
            }
        }
        
        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWindowDidBecomeKey()
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        CLIProxyManager.terminateProxyOnShutdown()
    }
    
    private func handleWindowDidBecomeKey() {
        for window in NSApp.windows where window.title == "Quotio" {
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            break
        }
    }
    
    private func handleWindowWillClose() {
        // Check after a short delay to allow window to fully close
        DispatchQueue.main.async {
            let visibleQuotioWindows = NSApp.windows.filter { window in
                window.title == "Quotio" &&
                    window.isVisible &&
                    !window.isMiniaturized
            }
            if visibleQuotioWindows.isEmpty {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
    
    deinit {
        if let observer = windowWillCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = windowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct ContentView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @AppStorage("loggingToFile") private var loggingToFile = true
    @State private var modeManager = OperatingModeManager.shared
    
    var body: some View {
        @Bindable var vm = viewModel
        
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $vm.currentPage) {
                    Section {
                        // Always visible
                        Label("nav.dashboard".localized(), systemImage: "gauge.with.dots.needle.33percent")
                            .tag(NavigationPage.dashboard)
                        
                        Label("nav.quota".localized(), systemImage: "chart.bar.fill")
                            .tag(NavigationPage.quota)
                        
                        Label(modeManager.isMonitorMode ? "nav.accounts".localized() : "nav.providers".localized(), 
                              systemImage: "person.2.badge.key")
                            .tag(NavigationPage.providers)
                        
                        // Proxy mode only (local or remote)
                        if modeManager.isProxyMode {
                            if modeManager.currentMode.supportsAgentConfig {
                                Label("nav.agents".localized(), systemImage: "terminal")
                                    .tag(NavigationPage.agents)
                            }
                            
                            Label("nav.apiKeys".localized(), systemImage: "key.horizontal")
                                .tag(NavigationPage.apiKeys)
                            
                            if modeManager.isLocalProxyMode && loggingToFile {
                                Label("nav.logs".localized(), systemImage: "doc.text")
                                    .tag(NavigationPage.logs)
                            }
                        }
                        
                        Label("nav.settings".localized(), systemImage: "gearshape")
                            .tag(NavigationPage.settings)
                        
                        Label("nav.about".localized(), systemImage: "info.circle")
                            .tag(NavigationPage.about)
                    }
                }
                
                // Control section at bottom - current mode badge + status
                VStack(spacing: 0) {
                    Divider()
                    
                    // Current Mode Badge (replaces ModeSwitcherRow)
                    CurrentModeBadge()
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                    
                    // Status row - different per mode
                    Group {
                        if modeManager.isLocalProxyMode {
                            ProxyStatusRow(viewModel: viewModel)
                        } else if modeManager.isRemoteProxyMode {
                            RemoteStatusRow()
                        } else {
                            QuotaRefreshStatusRow(viewModel: viewModel)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
                .background(.regularMaterial)
            }
            .navigationTitle("Quotio")
            .toolbar {
                ToolbarItem {
                    if modeManager.isLocalProxyMode {
                        // Local proxy mode: proxy controls
                        if viewModel.proxyManager.isStarting {
                            SmallProgressView()
                        } else {
                            Button {
                                Task { await viewModel.toggleProxy() }
                            } label: {
                                Image(systemName: viewModel.proxyManager.proxyStatus.running ? "stop.fill" : "play.fill")
                            }
                            .help(viewModel.proxyManager.proxyStatus.running ? "action.stopProxy".localized() : "action.startProxy".localized())
                        }
                    } else {
                        // Monitor or remote mode: refresh button
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
            case .dashboard:
                DashboardScreen()
            case .quota:
                QuotaScreen()
            case .providers:
                ProvidersScreen()
            case .agents:
                AgentSetupScreen()
            case .apiKeys:
                APIKeysScreen()
            case .logs:
                LogsScreen()
            case .settings:
                SettingsScreen()
            case .about:
                AboutScreen()
            }
        }
    }
}

// MARK: - Sidebar Status Rows

/// Remote connection status row for Remote Proxy Mode
struct RemoteStatusRow: View {
    @State private var modeManager = OperatingModeManager.shared
    
    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(statusText)
                .font(.caption)
            
            Spacer()
            
            if let config = modeManager.remoteConfig {
                Text(config.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
    
    private var statusColor: Color {
        switch modeManager.connectionStatus {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }
    
    private var statusText: String {
        switch modeManager.connectionStatus {
        case .connected: return "status.connected".localized()
        case .connecting: return "status.connecting".localized()
        case .disconnected: return "status.disconnected".localized()
        case .error: return "status.error".localized()
        }
    }
}

/// Proxy status row for Local Proxy Mode
struct ProxyStatusRow: View {
    let viewModel: QuotaViewModel
    
    var body: some View {
        HStack {
            if viewModel.proxyManager.isStarting {
                SmallProgressView(size: 8)
            } else {
                Circle()
                    .fill(viewModel.proxyManager.proxyStatus.running ? .green : .gray)
                    .frame(width: 8, height: 8)
            }
            
            if viewModel.proxyManager.isStarting {
                Text("status.starting".localized())
                    .font(.caption)
            } else {
                Text(viewModel.proxyManager.proxyStatus.running ? "status.running".localized() : "status.stopped".localized())
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
                SmallProgressView(size: 8)
                Text("status.refreshing".localized())
                    .font(.caption)
            } else {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                
                if let lastRefresh = viewModel.lastQuotaRefreshTime {
                    Text("status.updatedAgo \(lastRefresh, style: .relative)")
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
