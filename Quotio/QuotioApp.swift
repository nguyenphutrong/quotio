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
        
        // Show quota in menu bar regardless of proxy status
        // Quota fetching works independently via CLI/cookies/auth files
        
        var items: [MenuBarQuotaDisplayItem] = []
        
        for selectedItem in menuBarSettings.selectedItems {
            guard let provider = selectedItem.aiProvider else { continue }
            
            if let accountQuotas = viewModel.providerQuotas[provider],
               let quotaData = accountQuotas[selectedItem.accountKey],
               !quotaData.models.isEmpty {
                // Filter out -1 (unknown) percentages when calculating lowest
                let validPercentages = quotaData.models.map(\.percentage).filter { $0 >= 0 }
                let lowestPercent = validPercentages.min() ?? (quotaData.models.first?.percentage ?? -1)
                items.append(MenuBarQuotaDisplayItem(
                    id: selectedItem.id,
                    providerSymbol: provider.menuBarSymbol,
                    accountShort: selectedItem.accountKey,
                    percentage: lowestPercent,
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
        Window("Quotio", id: "main") {
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
                .onChange(of: viewModel.providerQuotas.count) {
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
    private var windowWillCloseObserver: NSObjectProtocol?
    private var windowDidBecomeKeyObserver: NSObjectProtocol?
    
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
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        CLIProxyManager.terminateProxyOnShutdown()
    }
    
    private func handleWindowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard window.title == "Quotio" else { return }
        
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }
    
    private func handleWindowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        guard closingWindow.title == "Quotio" else { return }
        
        let remainingWindows = NSApp.windows.filter { window in
            window != closingWindow &&
                window.title == "Quotio" &&
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
    }
}

struct ContentView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @AppStorage("loggingToFile") private var loggingToFile = true
    @State private var modeManager = AppModeManager.shared
    
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
                        
                        Label(modeManager.isQuotaOnlyMode ? "nav.accounts".localized() : "nav.providers".localized(), 
                              systemImage: "person.2.badge.key")
                            .tag(NavigationPage.providers)
                        
                        // Full mode only
                        if modeManager.isFullMode {
                            Label("nav.agents".localized(), systemImage: "terminal")
                                .tag(NavigationPage.agents)
                            
                            Label("nav.apiKeys".localized(), systemImage: "key.horizontal")
                                .tag(NavigationPage.apiKeys)
                            
                            if loggingToFile {
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
                
                // Control section at bottom - mode switcher + status
                VStack(spacing: 0) {
                    Divider()
                    
                    // Mode Switcher
                    ModeSwitcherRow()
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 6)
                    
                    // Status row - different per mode
                    Group {
                        if modeManager.isFullMode {
                            ProxyStatusRow(viewModel: viewModel)
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
                    if modeManager.isFullMode {
                        // Full mode: proxy controls
                        if viewModel.proxyManager.isStarting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button {
                                Task { await viewModel.toggleProxy() }
                            } label: {
                                Image(systemName: viewModel.proxyManager.proxyStatus.running ? "stop.fill" : "play.fill")
                            }
                            .help(viewModel.proxyManager.proxyStatus.running ? "action.stopProxy".localized() : "action.startProxy".localized())
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

// MARK: - Sidebar Mode Switcher

/// Compact mode switcher for sidebar with custom toggle buttons
struct ModeSwitcherRow: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var modeManager = AppModeManager.shared
    @State private var showConfirmation = false
    @State private var pendingMode: AppMode?
    
    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Horizontal layout (preferred when space allows)
            HStack(spacing: 6) {
                modeButtons
            }
            
            // Vertical layout (fallback when sidebar is narrow)
            VStack(spacing: 6) {
                modeButtons
            }
        }
        .alert("settings.appMode.switchConfirmTitle".localized(), isPresented: $showConfirmation) {
            Button("action.cancel".localized(), role: .cancel) {
                pendingMode = nil
            }
            Button("action.switch".localized()) {
                if let mode = pendingMode {
                    switchToMode(mode)
                }
                pendingMode = nil
            }
        } message: {
            Text("settings.appMode.switchConfirmMessage".localized())
        }
    }
    
    @ViewBuilder
    private var modeButtons: some View {
        ModeButton(
            label: "Proxy + Quota",
            icon: "server.rack",
            color: .blue,
            isSelected: modeManager.currentMode == .full
        ) {
            handleModeSelection(.full)
        }
        
        ModeButton(
            label: "Quota Only",
            icon: "chart.bar.fill",
            color: .green,
            isSelected: modeManager.currentMode == .quotaOnly
        ) {
            handleModeSelection(.quotaOnly)
        }
    }
    
    private func handleModeSelection(_ mode: AppMode) {
        guard mode != modeManager.currentMode else { return }
        
        if modeManager.isFullMode && mode == .quotaOnly {
            // Confirm before switching from full to quota-only
            pendingMode = mode
            showConfirmation = true
        } else {
            switchToMode(mode)
        }
    }
    
    private func switchToMode(_ mode: AppMode) {
        modeManager.switchMode(to: mode) {
            viewModel.stopProxy()
        }
        
        Task {
            await viewModel.initialize()
        }
    }
}

// MARK: - Mode Button

/// Custom toggle button for mode selection
private struct ModeButton: View {
    let label: String
    let icon: String
    let color: Color
    let isSelected: Bool
    let onTap: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption)
                    .fontWeight(isSelected ? .medium : .regular)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(background)
            .foregroundStyle(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
    
    private var background: Color {
        if isSelected {
            return color.opacity(0.15)
        } else if isHovered {
            return Color.secondary.opacity(0.08)
        }
        return Color.clear
    }
    
    private var foregroundColor: Color {
        isSelected ? color : .secondary
    }
    
    private var borderColor: Color {
        if isSelected {
            return color.opacity(0.5)
        } else if isHovered {
            return Color.secondary.opacity(0.3)
        }
        return Color.secondary.opacity(0.15)
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
