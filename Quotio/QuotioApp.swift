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

// MARK: - App Bootstrap (Singleton for headless initialization)

/// Manages app-wide initialization that must happen regardless of window visibility.
/// This ensures the app works correctly when launched at login without opening a window.
@MainActor
final class AppBootstrap {
    static let shared = AppBootstrap()

    let viewModel = QuotaViewModel()
    let logsViewModel = LogsViewModel()

    private(set) var hasInitialized = false
    private(set) var needsOnboarding = false

    private let modeManager = OperatingModeManager.shared
    private let appearanceManager = AppearanceManager.shared
    private let statusBarManager = StatusBarManager.shared
    private let menuBarSettings = MenuBarSettingsManager.shared

    private init() {}

    /// Initialize core app services. Safe to call multiple times - only runs once.
    /// Called from AppDelegate.applicationDidFinishLaunching for headless launch support.
    func initializeIfNeeded() async {
        guard !hasInitialized else { return }
        hasInitialized = true

        appearanceManager.applyAppearance()

        // Check if onboarding is needed - if so, defer full initialization until after onboarding
        if !modeManager.hasCompletedOnboarding {
            needsOnboarding = true
            return
        }

        await performFullInitialization()
    }

    /// Called after onboarding completes to finish initialization
    func completeOnboarding() async {
        needsOnboarding = false
        await performFullInitialization()
    }

    private func performFullInitialization() async {
        // Scan auth files immediately (fast filesystem scan)
        // This allows menu bar to show providers before quota API calls complete
        await viewModel.loadDirectAuthFiles()

        // Setup menu bar immediately so user can open it while data loads
        statusBarManager.setViewModel(viewModel)
        updateStatusBar()

        // Listen for quota data changes to update menu bar even when window is closed
        NotificationCenter.default.addObserver(
            forName: QuotaViewModel.quotaDataDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusBar()
                StatusBarManager.shared.rebuildMenuInPlace()
            }
        }

        // Load data in background (includes proxy auto-start if enabled)
        await viewModel.initialize()

        #if canImport(Sparkle)
        UpdaterService.shared.checkForUpdatesInBackground()
        #endif
    }

    func updateStatusBar() {
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

    private var quotaItems: [MenuBarQuotaDisplayItem] {
        guard menuBarSettings.showQuotaInMenuBar else { return [] }

        var items: [MenuBarQuotaDisplayItem] = []

        for selectedItem in menuBarSettings.selectedItems {
            guard let provider = selectedItem.aiProvider else { continue }

            var displayPercent: Double = -1
            var isForbidden = false

            if let accountQuotas = viewModel.providerQuotas[provider],
               let quotaData = resolveQuotaData(
                   for: selectedItem,
                   provider: provider,
                   accountQuotas: accountQuotas
               ) {
                isForbidden = quotaData.isForbidden
                if !quotaData.models.isEmpty {
                    let models = quotaData.models.map { (name: $0.name, percentage: $0.percentage) }
                    displayPercent = menuBarSettings.totalUsagePercent(models: models)
                }
            }

            items.append(MenuBarQuotaDisplayItem(
                id: selectedItem.id,
                providerSymbol: provider.menuBarSymbol,
                accountShort: selectedItem.accountKey,
                percentage: displayPercent,
                provider: provider,
                isForbidden: isForbidden
            ))
        }

        return items
    }

    private func resolveQuotaData(
        for selectedItem: MenuBarQuotaItem,
        provider: AIProvider,
        accountQuotas: [String: ProviderQuotaData]
    ) -> ProviderQuotaData? {
        if let quotaData = accountQuotas[selectedItem.accountKey] {
            return quotaData
        }

        let cleanKey = selectedItem.accountKey.replacingOccurrences(of: ".json", with: "")
        if let quotaData = accountQuotas[cleanKey] {
            return quotaData
        }

        guard provider == .codex else { return nil }
        let normalizedSelected = normalizedCodexKey(cleanKey)
        return accountQuotas.first { normalizedCodexKey($0.key) == normalizedSelected }?.value
    }

    private func normalizedCodexKey(_ key: String) -> String {
        let cleanKey = key.replacingOccurrences(of: ".json", with: "")
        if let email = extractEmail(from: cleanKey) {
            return email.lowercased()
        }
        return cleanKey.lowercased()
    }

    private func extractEmail(from text: String) -> String? {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        guard let range = text.range(of: pattern, options: options) else { return nil }
        return String(text[range])
    }
}

@main
struct QuotioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Use shared bootstrap instance for viewModel
    private var bootstrap: AppBootstrap { AppBootstrap.shared }
    @State private var logsViewModel = LogsViewModel()
    @State private var menuBarSettings = MenuBarSettingsManager.shared
    @State private var statusBarManager = StatusBarManager.shared
    @State private var modeManager = OperatingModeManager.shared
    @State private var appearanceManager = AppearanceManager.shared
    @State private var languageManager = LanguageManager.shared
    @State private var showOnboarding = false
    @Environment(\.openWindow) private var openWindow

    private var viewModel: QuotaViewModel { bootstrap.viewModel }


    var body: some Scene {
        Window("Quotio", id: "main") {
            ContentView()
                .id(languageManager.currentLanguage) // Force re-render on language change
                .environment(viewModel)
                .environment(logsViewModel)
                .environment(\.locale, languageManager.locale)
                .task {
                    // Initialize via bootstrap (idempotent - safe to call multiple times)
                    // This handles the case where window opens before AppDelegate finishes
                    await bootstrap.initializeIfNeeded()

                    // Show onboarding if needed
                    if bootstrap.needsOnboarding {
                        showOnboarding = true
                    }
                }
                .onChange(of: viewModel.proxyManager.proxyStatus.running) {
                    bootstrap.updateStatusBar()
                }
                .onChange(of: viewModel.isLoadingQuotas) {
                    bootstrap.updateStatusBar()
                    // Rebuild menu when loading state changes so loader updates
                    statusBarManager.rebuildMenuInPlace()
                }
                .onChange(of: languageManager.currentLanguage) { _, _ in
                    // Rebuild menu bar when language changes
                    statusBarManager.rebuildMenuInPlace()
                }
                .onChange(of: menuBarSettings.showQuotaInMenuBar) {
                    bootstrap.updateStatusBar()
                }
                .onChange(of: menuBarSettings.showMenuBarIcon) {
                    bootstrap.updateStatusBar()
                }
                .onChange(of: menuBarSettings.selectedItems) {
                    bootstrap.updateStatusBar()
                }
                .onChange(of: menuBarSettings.colorMode) {
                    bootstrap.updateStatusBar()
                }
                .onChange(of: menuBarSettings.totalUsageMode) {
                    bootstrap.updateStatusBar()
                    statusBarManager.rebuildMenuInPlace()
                }
                .onChange(of: menuBarSettings.modelAggregationMode) {
                    bootstrap.updateStatusBar()
                    statusBarManager.rebuildMenuInPlace()
                }
                .onChange(of: modeManager.currentMode) {
                    bootstrap.updateStatusBar()
                }
                .onChange(of: viewModel.providerQuotas.count) {
                    bootstrap.updateStatusBar()
                    statusBarManager.rebuildMenuInPlace()
                }
                .onChange(of: viewModel.directAuthFiles.count) {
                    bootstrap.updateStatusBar()
                    statusBarManager.rebuildMenuInPlace()
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingFlow {
                        Task {
                            await bootstrap.completeOnboarding()
                        }
                    }
                }
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) { }

            #if canImport(Sparkle)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    UpdaterService.shared.checkForUpdates()
                }
                .disabled(!UpdaterService.shared.canCheckForUpdates)
            }
            #endif
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private nonisolated(unsafe) var windowWillCloseObserver: NSObjectProtocol?
    private nonisolated(unsafe) var windowDidBecomeKeyObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Move orphan cleanup off main thread to avoid blocking app launch
        DispatchQueue.global(qos: .utility).async {
            TunnelManager.cleanupOrphans()
        }

        UserDefaults.standard.register(defaults: [
            "useBridgeMode": true,
            "showInDock": true,
            "totalUsageMode": TotalUsageMode.sessionOnly.rawValue,
            "modelAggregationMode": ModelAggregationMode.lowest.rawValue
        ])

        // Apply initial dock visibility based on saved preference
        let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)

        // CRITICAL: Initialize app services immediately on launch.
        // This ensures proxy auto-start works even when launched at login
        // without opening a window (e.g., when showInDock=false).
        // The bootstrap.initializeIfNeeded() is idempotent and safe to call
        // multiple times - the window's .task will also call it but it's a no-op
        // if already initialized.
        Task { @MainActor in
            await AppBootstrap.shared.initializeIfNeeded()

            // Start background polling for CLIProxyAPI updates (every 5 minutes)
            // Uses Atom feed with ETag caching for efficiency
            AtomFeedUpdateService.shared.startPolling {
                CLIProxyManager.shared.currentVersion ?? CLIProxyManager.shared.installedProxyVersion
            }
        }

        windowWillCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWindowWillClose()
            }
        }

        windowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWindowDidBecomeKey()
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When user clicks dock icon or menubar "Open Quotio" and no visible windows
        if !flag {
            // Find and show the main window
            for window in sender.windows {
                if window.title == "Quotio" {
                    // Restore minimized window first
                    if window.isMiniaturized {
                        window.deminiaturize(nil)
                    }
                    window.makeKeyAndOrderFront(nil)
                    return true
                }
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop background polling
        AtomFeedUpdateService.shared.stopPolling()

        CLIProxyManager.terminateProxyOnShutdown()
        
        // Use semaphore to ensure tunnel cleanup completes before app terminates
        // with a timeout to prevent hanging termination
        let semaphore = DispatchSemaphore(value: 0)
        let cleanupTimeout: DispatchTime = .now() + .milliseconds(1500)
        
        Task { @MainActor in
            await TunnelManager.shared.stopTunnel()
            semaphore.signal()
        }
        
        let result = semaphore.wait(timeout: cleanupTimeout)
        if result == .timedOut {
            // Fallback: force kill orphan processes if stopTunnel timed out
            TunnelManager.cleanupOrphans()
            NSLog("[AppDelegate] Tunnel cleanup timed out, forced orphan cleanup")
        }
    }

    private func handleWindowDidBecomeKey() {
        // Do nothing - activation policy is managed by showInDock setting only
    }

    private func handleWindowWillClose() {
        // Do nothing - activation policy is managed by showInDock setting only
        // When showInDock = true, dock icon stays visible even when window is closed
        // When showInDock = false, dock icon is never visible
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
                            HStack(spacing: 6) {
                                Label("nav.fallback".localized(), systemImage: "arrow.triangle.branch")
                                ExperimentalBadge()
                            }
                            .tag(NavigationPage.fallback)

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
            case .fallback:
                FallbackScreen()
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
