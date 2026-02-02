//
//  SettingsScreen.swift
//  Quotio
//

import SwiftUI
import AppKit

struct SettingsScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    private let modeManager = OperatingModeManager.shared
    private let launchManager = LaunchAtLoginManager.shared
    
    var body: some View {
        @Bindable var lang = LanguageManager.shared

        Form {
            // Operating Mode
            OperatingModeSection()
            
            // Remote Server Configuration - Only in Remote Proxy Mode
            if modeManager.isRemoteProxyMode {
                RemoteServerSection()
                UnifiedProxySettingsSection()
            }

            // General Settings
            Section {
                LaunchAtLoginToggle()
            } header: {
                Label("settings.general".localized(), systemImage: "gearshape")
            }

            // Language
            Section {
                Picker(selection: Binding(
                    get: { lang.currentLanguage },
                    set: { lang.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        HStack {
                            Text(language.flag)
                            Text(language.displayName)
                        }
                        .tag(language)
                    }
                } label: {
                    Text("settings.language".localized())
                }
            } header: {
                Label("settings.language".localized(), systemImage: "globe")
            }

            // Troubleshooting
            Section {
                Button("Apply Workaround (Backup & Force URL)") {
                    CLIProxyManager.shared.applyBaseURLWorkaround()
                }

                Button("Restore Original Settings") {
                    CLIProxyManager.shared.removeBaseURLWorkaround()
                }
            } header: {
                Label("Troubleshooting", systemImage: "hammer.fill")
            } footer: {
                Text("Forces the proxy to use the primary Google API URL to fix slowness. Original settings are backed up and can be restored.")
            }

            // Appearance
            AppearanceSettingsSection()
            
            // Privacy
            PrivacySettingsSection()
            
            // Local Proxy Server - Only in Local Proxy Mode
            if modeManager.isLocalProxyMode {
                LocalProxyServerSection()
                UnifiedProxySettingsSection()
            }
            
            // Notifications
            NotificationSettingsSection()
            
            // Quota Display
            QuotaDisplaySettingsSection()
            
            // Usage Display
            UsageDisplaySettingsSection()
            
            // Refresh Cadence
            RefreshCadenceSettingsSection()
            
            // Menu Bar
            MenuBarSettingsSection()
            
            // Paths - Only in Local Proxy Mode
            if modeManager.isLocalProxyMode {
                LocalPathsSection()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("nav.settings".localized())
    }
}

// MARK: - Operating Mode Section

struct OperatingModeSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    private let modeManager = OperatingModeManager.shared
    @State private var showModeChangeConfirmation = false
    @State private var pendingMode: OperatingMode?
    @State private var showRemoteConfigSheet = false
    
    var body: some View {
        Section {
            // Mode selection cards
            VStack(spacing: 10) {
                ForEach(OperatingMode.allCases) { mode in
                    OperatingModeCard(
                        mode: mode,
                        isSelected: modeManager.currentMode == mode
                    ) {
                        handleModeSelection(mode)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label("settings.appMode".localized(), systemImage: "switch.2")
        } footer: {
            footerText
        }
        .alert("settings.appMode.switchConfirmTitle".localized(), isPresented: $showModeChangeConfirmation) {
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
        .sheet(isPresented: $showRemoteConfigSheet) {
            RemoteConnectionSheet(
                existingConfig: modeManager.remoteConfig
            ) { config, managementKey in
                modeManager.switchToRemote(config: config, managementKey: managementKey)
                Task {
                    await viewModel.initialize()
                }
            }
            .environment(viewModel)
        }
    }
    
    @ViewBuilder
    private var footerText: some View {
        switch modeManager.currentMode {
        case .monitor:
            Label("settings.appMode.quotaOnlyNote".localized(), systemImage: "info.circle")
                .font(.caption)
        case .remoteProxy:
            Label("settings.appMode.remoteNote".localized(), systemImage: "info.circle")
                .font(.caption)
        case .localProxy:
            EmptyView()
        }
    }
    
    private func handleModeSelection(_ mode: OperatingMode) {
        guard mode != modeManager.currentMode else { return }
        
        // If switching to remote and no config exists, show config sheet
        if mode == .remoteProxy && modeManager.remoteConfig == nil {
            showRemoteConfigSheet = true
            return
        }
        
        // Confirm when switching FROM local proxy mode (stops the local proxy)
        if modeManager.currentMode == .localProxy && (mode == .monitor || mode == .remoteProxy) {
            pendingMode = mode
            showModeChangeConfirmation = true
        } else {
            // Switch immediately for other transitions
            switchToMode(mode)
        }
    }
    
    private func switchToMode(_ mode: OperatingMode) {
        modeManager.switchMode(to: mode) {
            viewModel.stopProxy()
        }
        
        // Re-initialize based on new mode
        Task {
            await viewModel.initialize()
        }
    }
}

// MARK: - Remote Server Section

struct RemoteServerSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var showRemoteConfigSheet = false
    @State private var isReconnecting = false
    
    private var modeManager: OperatingModeManager { OperatingModeManager.shared }
    
    var body: some View {
        Section {
            // Remote configuration row
            remoteConfigRow
            
            // Connection status
            connectionStatusRow
        } header: {
            HStack(spacing: 8) {
                Label("settings.remoteServer.title".localized(), systemImage: "network")
                ExperimentalBadge()
            }
        } footer: {
            Text("settings.remoteServer.help".localized())
                .font(.caption)
        }
        .sheet(isPresented: $showRemoteConfigSheet) {
            RemoteConnectionSheet(
                existingConfig: modeManager.remoteConfig
            ) { config, managementKey in
                saveRemoteConfig(config, managementKey: managementKey)
            }
            .environment(viewModel)
        }
    }
    
    // MARK: - Remote Config Row
    
    private var remoteConfigRow: some View {
        HStack {
            if let config = modeManager.remoteConfig {
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(config.endpointURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("settings.remoteServer.notConfigured".localized())
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button("settings.remoteServer.configure".localized()) {
                showRemoteConfigSheet = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
    
    // MARK: - Connection Status Row
    
    private var connectionStatusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(statusText)
                .font(.subheadline)
            
            Spacer()
            
            if shouldShowReconnectButton {
                Button {
                    reconnect()
                } label: {
                    if isReconnecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("action.reconnect".localized(), systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isReconnecting)
            }
        }
    }
    
    private var shouldShowReconnectButton: Bool {
        switch modeManager.connectionStatus {
        case .disconnected, .error:
            return true
        default:
            return false
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
        case .error(let message): return message
        }
    }
    
    // MARK: - Actions
    
    private func saveRemoteConfig(_ config: RemoteConnectionConfig, managementKey: String) {
        modeManager.switchToRemote(config: config, managementKey: managementKey)
        
        Task {
            await viewModel.initialize()
        }
    }
    
    private func reconnect() {
        isReconnecting = true
        
        Task {
            await viewModel.reconnectRemote()
            isReconnecting = false
        }
    }
}

// MARK: - Unified Proxy Settings Section
// Works for both Local Proxy and Remote Proxy modes
// Uses ManagementAPIClient for hot-reload settings

struct UnifiedProxySettingsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var modeManager = OperatingModeManager.shared
    
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isLoadingConfig = false  // Prevents onChange from firing during load
    
    @State private var proxyURL = ""
    @State private var routingStrategy = "round-robin"
    @State private var switchProject = true
    @State private var switchPreviewModel = true
    @State private var requestRetry = 3
    @State private var maxRetryInterval = 30
    @State private var loggingToFile = true
    @State private var requestLog = false
    @State private var debugMode = false
    
    @State private var proxyURLValidation: ProxyURLValidationResult = .empty
    
    /// Check if API is available (proxy running for local, or connected for remote)
    private var isAPIAvailable: Bool {
        if modeManager.isLocalProxyMode {
            return viewModel.proxyManager.proxyStatus.running && viewModel.apiClient != nil
        } else {
            // For remote mode, check both connection status AND apiClient
            // connectionStatus is observable, apiClient is not (@ObservationIgnored)
            if case .connected = modeManager.connectionStatus {
                return viewModel.apiClient != nil
            }
            return false
        }
    }
    
    /// Header title based on mode
    private var sectionTitle: String {
        modeManager.isLocalProxyMode 
            ? "settings.proxySettings".localized()
            : "settings.remoteProxySettings".localized()
    }
    
    var body: some View {
        if !isAPIAvailable {
            // Show placeholder when API is not available
            Section {
                HStack {
                    Image(systemName: "network.slash")
                        .foregroundStyle(.secondary)
                    Text(modeManager.isLocalProxyMode 
                         ? "settings.proxy.startToConfigureAdvanced".localized()
                         : "settings.remote.noConnection".localized())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label(sectionTitle, systemImage: "slider.horizontal.3")
            }
        } else if isLoading {
            Section {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("settings.remote.loading".localized())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label(sectionTitle, systemImage: "slider.horizontal.3")
            }
            .onAppear {
                Task {
                    await loadConfig()
                }
            }
        } else if let error = loadError {
            Section {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("action.retry".localized()) {
                        Task {
                            await loadConfig()
                        }
                    }
                }
            } header: {
                Label(sectionTitle, systemImage: "slider.horizontal.3")
            }
        } else {
            upstreamProxySection
            routingStrategySection
            quotaExceededSection
            retryConfigurationSection
            loggingSection
        }
    }
    
    private var upstreamProxySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("settings.upstreamProxy".localized()) {
                    TextField("", text: $proxyURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onChange(of: proxyURL) { _, newValue in
                            proxyURLValidation = ProxyURLValidator.validate(newValue)
                        }
                        .onSubmit {
                            Task { await saveProxyURL() }
                        }
                }
                
                if proxyURLValidation != .valid && proxyURLValidation != .empty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text((proxyURLValidation.localizationKey ?? "").localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("settings.upstreamProxy.placeholder".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("settings.upstreamProxy.title".localized(), systemImage: "network")
        }
    }
    
    private var routingStrategySection: some View {
        Section {
            Picker("settings.routingStrategy".localized(), selection: $routingStrategy) {
                Text("settings.roundRobin".localized()).tag("round-robin")
                Text("settings.fillFirst".localized()).tag("fill-first")
            }
            .pickerStyle(.segmented)
            .onChange(of: routingStrategy) { _, newValue in
                guard !isLoadingConfig else { return }
                Task { await saveRoutingStrategy(newValue) }
            }
        } header: {
            Label("settings.routingStrategy".localized(), systemImage: "arrow.triangle.branch")
        } footer: {
            Text(routingStrategy == "round-robin"
                 ? "settings.roundRobinDesc".localized()
                 : "settings.fillFirstDesc".localized())
            .font(.caption)
        }
    }
    
    private var quotaExceededSection: some View {
        Section {
            Toggle("settings.autoSwitchAccount".localized(), isOn: $switchProject)
                .onChange(of: switchProject) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveSwitchProject(newValue) }
                }
            Toggle("settings.autoSwitchPreview".localized(), isOn: $switchPreviewModel)
                .onChange(of: switchPreviewModel) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveSwitchPreviewModel(newValue) }
                }
        } header: {
            Label("settings.quotaExceededBehavior".localized(), systemImage: "exclamationmark.triangle")
        } footer: {
            Text("settings.quotaExceededHelp".localized())
                .font(.caption)
        }
    }
    
    private var retryConfigurationSection: some View {
        Section {
            Stepper("settings.maxRetries".localized() + ": \(requestRetry)", value: $requestRetry, in: 0...10)
                .onChange(of: requestRetry) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveRequestRetry(newValue) }
                }
            
            Stepper("settings.maxRetryInterval".localized() + ": \(maxRetryInterval)s", value: $maxRetryInterval, in: 5...300, step: 5)
                .onChange(of: maxRetryInterval) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveMaxRetryInterval(newValue) }
                }
        } header: {
            Label("settings.retryConfiguration".localized(), systemImage: "arrow.clockwise")
        } footer: {
            Text("settings.retryHelp".localized())
                .font(.caption)
        }
    }
    
    private var loggingSection: some View {
        Section {
            Toggle("settings.loggingToFile".localized(), isOn: $loggingToFile)
                .onChange(of: loggingToFile) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveLoggingToFile(newValue) }
                }
            
            Toggle("settings.requestLog".localized(), isOn: $requestLog)
                .onChange(of: requestLog) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveRequestLog(newValue) }
                }
            
            Toggle("settings.debugMode".localized(), isOn: $debugMode)
                .onChange(of: debugMode) { _, newValue in
                    guard !isLoadingConfig else { return }
                    Task { await saveDebugMode(newValue) }
                }
        } header: {
            Label("settings.logging".localized(), systemImage: "doc.text")
        } footer: {
            Text("settings.loggingHelp".localized())
                .font(.caption)
        }
    }
    
    private func loadConfig() async {
        isLoading = true
        isLoadingConfig = true
        loadError = nil
        
        guard let apiClient = viewModel.apiClient else {
            loadError = modeManager.isLocalProxyMode
                ? "settings.proxy.startToConfigureAdvanced".localized()
                : "settings.remote.noConnection".localized()
            isLoading = false
            isLoadingConfig = false
            return
        }
        
        do {
            async let configTask = apiClient.fetchConfig()
            async let routingTask = apiClient.getRoutingStrategy()
            
            let (config, fetchedStrategy) = try await (configTask, routingTask)
            
            proxyURL = config.proxyURL ?? ""
            routingStrategy = fetchedStrategy
            requestRetry = config.requestRetry ?? 3
            maxRetryInterval = config.maxRetryInterval ?? 30
            loggingToFile = config.loggingToFile ?? true
            requestLog = config.requestLog ?? false
            debugMode = config.debug ?? false
            switchProject = config.quotaExceeded?.switchProject ?? true
            switchPreviewModel = config.quotaExceeded?.switchPreviewModel ?? true
            proxyURLValidation = ProxyURLValidator.validate(proxyURL)
            isLoading = false
            
            try? await Task.sleep(for: .milliseconds(100))
            isLoadingConfig = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
            isLoadingConfig = false
        }
    }
    
    private func saveProxyURL() async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            if proxyURL.isEmpty {
                try await apiClient.deleteProxyURL()
            } else if proxyURLValidation == .valid {
                try await apiClient.setProxyURL(ProxyURLValidator.sanitize(proxyURL))
            }
        } catch {
            NSLog("[RemoteSettings] Failed to save proxy URL: \(error)")
        }
    }
    
    private func saveRoutingStrategy(_ strategy: String) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setRoutingStrategy(strategy)
        } catch {
            NSLog("[RemoteSettings] Failed to save routing strategy: \(error)")
        }
    }
    
    private func saveSwitchProject(_ enabled: Bool) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setQuotaExceededSwitchProject(enabled)
        } catch {
            NSLog("[RemoteSettings] Failed to save switch project: \(error)")
        }
    }
    
    private func saveSwitchPreviewModel(_ enabled: Bool) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setQuotaExceededSwitchPreviewModel(enabled)
        } catch {
            NSLog("[RemoteSettings] Failed to save switch preview model: \(error)")
        }
    }
    
    private func saveRequestRetry(_ count: Int) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setRequestRetry(count)
        } catch {
            NSLog("[RemoteSettings] Failed to save request retry: \(error)")
        }
    }
    
    private func saveMaxRetryInterval(_ seconds: Int) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setMaxRetryInterval(seconds)
        } catch {
            NSLog("[RemoteSettings] Failed to save max retry interval: \(error)")
        }
    }
    
    private func saveLoggingToFile(_ enabled: Bool) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setLoggingToFile(enabled)
        } catch {
            NSLog("[RemoteSettings] Failed to save logging to file: \(error)")
        }
    }
    
    private func saveRequestLog(_ enabled: Bool) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setRequestLog(enabled)
        } catch {
            NSLog("[RemoteSettings] Failed to save request log: \(error)")
        }
    }
    
    private func saveDebugMode(_ enabled: Bool) async {
        guard let apiClient = viewModel.apiClient else { return }
        do {
            try await apiClient.setDebug(enabled)
        } catch {
            NSLog("[RemoteSettings] Failed to save debug mode: \(error)")
        }
    }
}

// MARK: - Local Proxy Server Section

struct LocalProxyServerSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    @AppStorage("autoStartTunnel") private var autoStartTunnel = false
    @AppStorage("allowNetworkAccess") private var allowNetworkAccess = false
    @State private var portText: String = ""
    
    var body: some View {
        Section {
            HStack {
                Text("settings.port".localized())
                Spacer()
                TextField("settings.port".localized(), text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .onChange(of: portText) { _, newValue in
                        if let port = UInt16(newValue), port > 0 {
                            viewModel.proxyManager.port = port
                        }
                    }
            }
            
            LabeledContent("settings.status".localized()) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.proxyManager.proxyStatus.running ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(viewModel.proxyManager.proxyStatus.running ? "status.running".localized() : "status.stopped".localized())
                }
            }
            
            LabeledContent("settings.endpoint".localized()) {
                Text(viewModel.proxyManager.proxyStatus.endpoint)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            
            ManagementKeyRow()
            
            Toggle("settings.autoStartProxy".localized(), isOn: $autoStartProxy)
            
            Toggle("settings.autoStartTunnel".localized(), isOn: $autoStartTunnel)
                .disabled(!viewModel.tunnelManager.installation.isInstalled)
                
            NetworkAccessSection(allowNetworkAccess: $allowNetworkAccess)
                .onChange(of: allowNetworkAccess) { _, newValue in
                    viewModel.proxyManager.allowNetworkAccess = newValue
                }
                

        } header: {
            Label("settings.proxyServer".localized(), systemImage: "server.rack")
        } footer: {
            Text("settings.restartProxy".localized())
                .font(.caption)
        }
        .onAppear {
            portText = String(viewModel.proxyManager.port)
        }
    }
}

struct NetworkAccessSection: View {
    @Binding var allowNetworkAccess: Bool
    
    var body: some View {
        Section {
            Toggle("settings.allowNetworkAccess".localized(), isOn: $allowNetworkAccess)
            
            LabeledContent("settings.bindAddress".localized()) {
                Text(allowNetworkAccess ? "0.0.0.0 (All Interfaces)" : "127.0.0.1 (Localhost)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(allowNetworkAccess ? .orange : .secondary)
            }
            
            if allowNetworkAccess {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("settings.networkAccessWarning".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Label("settings.networkAccess".localized(), systemImage: "network")
        } footer: {
            Text("settings.networkAccessFooter".localized())
                .font(.caption)
        }
    }
}

// MARK: - Local Paths Section

struct LocalPathsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    
    var body: some View {
        Section {
            LabeledContent("settings.binary".localized()) {
                PathLabel(path: viewModel.proxyManager.effectiveBinaryPath)
            }
            
            LabeledContent("settings.config".localized()) {
                PathLabel(path: viewModel.proxyManager.configPath)
            }
            
            LabeledContent("settings.authDir".localized()) {
                PathLabel(path: viewModel.proxyManager.authDir)
            }
        } header: {
            Label("settings.paths".localized(), systemImage: "folder")
        }
    }
}

// MARK: - Path Label

struct PathLabel: View {
    let path: String
    
    var body: some View {
        HStack {
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(path, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }
}

struct NotificationSettingsSection: View {
    private let notificationManager = NotificationManager.shared
    
    var body: some View {
        @Bindable var manager = notificationManager
        
        Section {
            Toggle("settings.notifications.enabled".localized(), isOn: Binding(
                get: { manager.notificationsEnabled },
                set: { manager.notificationsEnabled = $0 }
            ))
            
            if manager.notificationsEnabled {
                Toggle("settings.notifications.quotaLow".localized(), isOn: Binding(
                    get: { manager.notifyOnQuotaLow },
                    set: { manager.notifyOnQuotaLow = $0 }
                ))
                
                Toggle("settings.notifications.cooling".localized(), isOn: Binding(
                    get: { manager.notifyOnCooling },
                    set: { manager.notifyOnCooling = $0 }
                ))
                
                Toggle("settings.notifications.proxyCrash".localized(), isOn: Binding(
                    get: { manager.notifyOnProxyCrash },
                    set: { manager.notifyOnProxyCrash = $0 }
                ))
                
                Toggle("settings.notifications.upgradeAvailable".localized(), isOn: Binding(
                    get: { manager.notifyOnUpgradeAvailable },
                    set: { manager.notifyOnUpgradeAvailable = $0 }
                ))
                
                HStack {
                    Text("settings.notifications.threshold".localized())
                    Spacer()
                    Picker("", selection: Binding(
                        get: { Int(manager.quotaAlertThreshold) },
                        set: { manager.quotaAlertThreshold = Double($0) }
                    )) {
                        Text("10%").tag(10)
                        Text("20%").tag(20)
                        Text("30%").tag(30)
                        Text("50%").tag(50)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }
            }
            
            if !manager.isAuthorized {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("settings.notifications.notAuthorized".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("settings.notifications".localized(), systemImage: "bell")
        } footer: {
            Text("settings.notifications.help".localized())
                .font(.caption)
        }
    }
}

// MARK: - Quota Display Settings Section

struct QuotaDisplaySettingsSection: View {
    @State private var settings = MenuBarSettingsManager.shared
    
    private var displayModeBinding: Binding<QuotaDisplayMode> {
        Binding(
            get: { settings.quotaDisplayMode },
            set: { settings.quotaDisplayMode = $0 }
        )
    }
    
    private var displayStyleBinding: Binding<QuotaDisplayStyle> {
        Binding(
            get: { settings.quotaDisplayStyle },
            set: { settings.quotaDisplayStyle = $0 }
        )
    }
    
    var body: some View {
        Section {
            Picker("settings.quota.displayMode".localized(), selection: displayModeBinding) {
                Text("settings.quota.displayMode.used".localized()).tag(QuotaDisplayMode.used)
                Text("settings.quota.displayMode.remaining".localized()).tag(QuotaDisplayMode.remaining)
            }
            .pickerStyle(.segmented)
            
            Picker("settings.quota.displayStyle".localized(), selection: displayStyleBinding) {
                ForEach(QuotaDisplayStyle.allCases) { style in
                    Text(style.localizationKey.localized()).tag(style)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Label("settings.quota.display".localized(), systemImage: "percent")
        } footer: {
            Text("settings.quota.display.help".localized())
                .font(.caption)
        }
    }
}

// MARK: - Refresh Cadence Settings Section

struct RefreshCadenceSettingsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var refreshSettings = RefreshSettingsManager.shared
    
    private var cadenceBinding: Binding<RefreshCadence> {
        Binding(
            get: { refreshSettings.refreshCadence },
            set: { refreshSettings.refreshCadence = $0 }
        )
    }
    
    var body: some View {
        Section {
            Picker("settings.refresh.cadence".localized(), selection: cadenceBinding) {
                ForEach(RefreshCadence.allCases) { cadence in
                    Text(cadence.localizationKey.localized()).tag(cadence)
                }
            }
            
            if refreshSettings.refreshCadence == .manual {
                Button {
                    Task {
                        await viewModel.manualRefresh()
                    }
                } label: {
                    Label("settings.refresh.now".localized(), systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Label("settings.refresh".localized(), systemImage: "clock.arrow.2.circlepath")
        } footer: {
            Text("settings.refresh.help".localized())
                .font(.caption)
        }
    }
}

// MARK: - Update Settings Section

struct UpdateSettingsSection: View {
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    
    #if canImport(Sparkle)
    private let updaterService = UpdaterService.shared
    #endif
    
    var body: some View {
        Section {
            #if canImport(Sparkle)
            Toggle("settings.autoCheckUpdates".localized(), isOn: $autoCheckUpdates)
                .onChange(of: autoCheckUpdates) { _, newValue in
                    updaterService.automaticallyChecksForUpdates = newValue
                }
            
            HStack {
                Text("settings.lastChecked".localized())
                Spacer()
                if let date = updaterService.lastUpdateCheckDate {
                    Text(date, style: .relative)
                        .foregroundStyle(.secondary)
                } else {
                    Text("settings.never".localized())
                        .foregroundStyle(.secondary)
                }
            }
            
            Button("settings.checkNow".localized()) {
                updaterService.checkForUpdates()
            }
            .disabled(!updaterService.canCheckForUpdates)
            #else
            Text("settings.version".localized() + ": " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"))
            #endif
        } header: {
            Label("settings.updates".localized(), systemImage: "arrow.down.circle")
        }
    }
}

// MARK: - Proxy Update Settings Section

struct ProxyUpdateSettingsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var isCheckingForUpdate = false
    @State private var isUpgrading = false
    @State private var upgradeError: String?
    @State private var showAdvancedSheet = false

    private var proxyManager: CLIProxyManager {
        viewModel.proxyManager
    }

    private var atomFeedService: AtomFeedUpdateService {
        AtomFeedUpdateService.shared
    }
    
    var body: some View {
        Section {
            // Current version
            LabeledContent("settings.proxyUpdate.currentVersion".localized()) {
                if let version = proxyManager.currentVersion ?? proxyManager.installedProxyVersion {
                    Text("v\(version)")
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text("settings.proxyUpdate.unknown".localized())
                        .foregroundStyle(.secondary)
                }
            }
            
            // Upgrade status
            if proxyManager.upgradeAvailable, let upgrade = proxyManager.availableUpgrade {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text("settings.proxyUpdate.available".localized())
                        } icon: {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(.green)
                        }
                        
                        Text("v\(upgrade.version)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button {
                        performUpgrade(to: upgrade)
                    } label: {
                        ZStack {
                            Text("action.update".localized())
                                .opacity(isUpgrading ? 0 : 1)
                            
                            if isUpgrading {
                                SmallProgressView()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isUpgrading || !proxyManager.proxyStatus.running)
                }
            } else {
                HStack {
                    Label {
                        Text("settings.proxyUpdate.upToDate".localized())
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    
                    Spacer()
                    
                    Button {
                        checkForUpdate()
                    } label: {
                        ZStack {
                            Text("settings.proxyUpdate.checkNow".localized())
                                .opacity(isCheckingForUpdate ? 0 : 1)
                            
                            if isCheckingForUpdate {
                                SmallProgressView()
                            }
                        }
                    }
                    .disabled(isCheckingForUpdate)
                }

                // Last checked time
                if let lastCheck = atomFeedService.lastCLIProxyCheck {
                    HStack {
                        Text("Last checked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(lastCheck, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Error message
            if let error = upgradeError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Proxy must be running hint (only shown when upgrade available but proxy not running)
            if proxyManager.upgradeAvailable && !proxyManager.proxyStatus.running {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("settings.proxyUpdate.proxyMustRun".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Advanced button
            Button {
                showAdvancedSheet = true
            } label: {
                HStack {
                    Label("settings.proxyUpdate.advanced".localized(), systemImage: "gearshape.2")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Label("settings.proxyUpdate".localized(), systemImage: "shippingbox.and.arrow.backward")
        } footer: {
            Text("settings.proxyUpdate.help".localized())
                .font(.caption)
        }
        .sheet(isPresented: $showAdvancedSheet) {
            ProxyVersionManagerSheet()
                .environment(viewModel)
        }
    }
    
    private func checkForUpdate() {
        isCheckingForUpdate = true
        upgradeError = nil

        Task { @MainActor in
            defer {
                // Always reset loading state
                isCheckingForUpdate = false
            }

            await proxyManager.checkForUpgrade()
        }
    }
    
    private func performUpgrade(to version: ProxyVersionInfo) {
        isUpgrading = true
        upgradeError = nil
        
        Task { @MainActor in
            do {
                try await proxyManager.performManagedUpgrade(to: version)
                isUpgrading = false
            } catch {
                upgradeError = error.localizedDescription
                isUpgrading = false
            }
        }
    }
}

// MARK: - Proxy Version Manager Sheet

struct ProxyVersionManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuotaViewModel.self) private var viewModel
    
    @State private var availableReleases: [GitHubRelease] = []
    @State private var installedVersions: [InstalledProxyVersion] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var installingVersion: String?
    @State private var installError: String?
    
    // State for deletion warning
    @State private var showDeleteWarning = false
    @State private var pendingInstallRelease: GitHubRelease?
    @State private var versionsToDelete: [String] = []
    
    private var proxyManager: CLIProxyManager {
        viewModel.proxyManager
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.proxyUpdate.advanced.title".localized())
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("settings.proxyUpdate.advanced.description".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // Content
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("settings.proxyUpdate.advanced.loading".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("settings.proxyUpdate.advanced.fetchError".localized())
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("action.refresh".localized()) {
                        Task { await loadReleases() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Installed Versions Section
                        if !installedVersions.isEmpty {
                            sectionHeader("settings.proxyUpdate.advanced.installedVersions".localized())
                            
                            ForEach(installedVersions) { installed in
                                InstalledVersionRow(
                                    version: installed,
                                    onActivate: { activateVersion(installed.version) },
                                    onDelete: { deleteVersion(installed.version) }
                                )
                                Divider().padding(.leading, 16)
                            }
                        }
                        
                        // Available Versions Section
                        sectionHeader("settings.proxyUpdate.advanced.availableVersions".localized())
                        
                        if availableReleases.isEmpty {
                            HStack {
                                Text("settings.proxyUpdate.advanced.noReleases".localized())
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        } else {
                            ForEach(availableReleases, id: \.tagName) { release in
                                AvailableVersionRow(
                                    release: release,
                                    isInstalled: isVersionInstalled(release.versionString),
                                    isInstalling: installingVersion == release.versionString,
                                    onInstall: { installVersion(release) }
                                )
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                    .padding(.bottom)
                }
            }
            
            // Error footer
            if let error = installError {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        installError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color.orange.opacity(0.1))
            }
        }
        .frame(width: 500, height: 500)
        .task {
            await loadReleases()
        }
        .alert("settings.proxyUpdate.deleteWarning.title".localized(), isPresented: $showDeleteWarning) {
            Button("action.cancel".localized(), role: .cancel) {
                pendingInstallRelease = nil
                versionsToDelete = []
            }
            Button("settings.proxyUpdate.deleteWarning.confirm".localized(), role: .destructive) {
                if let release = pendingInstallRelease {
                    performInstall(release)
                }
                pendingInstallRelease = nil
                versionsToDelete = []
            }
        } message: {
            Text(String(format: "settings.proxyUpdate.deleteWarning.message".localized(), AppConstants.maxInstalledVersions, versionsToDelete.joined(separator: ", ")))
        }
    }
    
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }
    
    private func isVersionInstalled(_ version: String) -> Bool {
        installedVersions.contains { $0.version == version }
    }
    
    private func refreshInstalledVersions() {
        installedVersions = proxyManager.installedVersions
    }
    
    private func loadReleases() async {
        isLoading = true
        loadError = nil
        
        do {
            availableReleases = try await proxyManager.fetchAvailableReleases(limit: 15)
            refreshInstalledVersions()
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }
    
    private func installVersion(_ release: GitHubRelease) {
        guard proxyManager.versionInfo(from: release) != nil else {
            installError = "No compatible binary found for this release"
            return
        }
        
        // Check if installing will delete old versions
        let toDelete = proxyManager.storageManager.versionsToBeDeleted(keepLast: AppConstants.maxInstalledVersions)
        if !toDelete.isEmpty {
            versionsToDelete = toDelete
            pendingInstallRelease = release
            showDeleteWarning = true
            return
        }
        
        performInstall(release)
    }
    
    private func performInstall(_ release: GitHubRelease) {
        guard let versionInfo = proxyManager.versionInfo(from: release) else {
            installError = "No compatible binary found for this release"
            return
        }
        
        installingVersion = release.versionString
        installError = nil
        
        Task { @MainActor in
            do {
                try await proxyManager.performManagedUpgrade(to: versionInfo)
                installingVersion = nil
                refreshInstalledVersions()
            } catch {
                installError = error.localizedDescription
                installingVersion = nil
            }
        }
    }
    
    private func activateVersion(_ version: String) {
        Task { @MainActor in
            do {
                let wasRunning = proxyManager.proxyStatus.running
                if wasRunning {
                    proxyManager.stop()
                }
                try proxyManager.storageManager.setCurrentVersion(version)
                if wasRunning {
                    try await proxyManager.start()
                }
                refreshInstalledVersions()
            } catch {
                installError = error.localizedDescription
            }
        }
    }
    
    private func deleteVersion(_ version: String) {
        do {
            try proxyManager.storageManager.deleteVersion(version)
            refreshInstalledVersions()
        } catch {
            installError = error.localizedDescription
        }
    }
}

// MARK: - Installed Version Row

private struct InstalledVersionRow: View {
    let version: InstalledProxyVersion
    let onActivate: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Version info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("v\(version.version)")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    
                    if version.isCurrent {
                        Text("settings.proxyUpdate.advanced.current".localized())
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green)
                            .clipShape(Capsule())
                    }
                }
                
                Text(version.installedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Actions
            if !version.isCurrent {
                Button("settings.proxyUpdate.advanced.activate".localized()) {
                    onActivate()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Available Version Row

private struct AvailableVersionRow: View {
    let release: GitHubRelease
    let isInstalled: Bool
    let isInstalling: Bool
    let onInstall: () -> Void
    
    // Cached DateFormatters to avoid repeated allocations (performance fix)
    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    
    private static let isoFormatterStandard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    
    var body: some View {
        HStack(spacing: 12) {
            // Version info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("v\(release.versionString)")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    
                    if release.prerelease {
                        Text("settings.proxyUpdate.advanced.prerelease".localized())
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    
                    if isInstalled {
                        Text("settings.proxyUpdate.advanced.installed".localized())
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                
                if let publishedAt = release.publishedAt {
                    Text(formatDate(publishedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Install button
            if !isInstalled {
                Button {
                    onInstall()
                } label: {
                    if isInstalling {
                        SmallProgressView()
                    } else {
                        Text("settings.proxyUpdate.advanced.install".localized())
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isInstalling)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    private func formatDate(_ isoString: String) -> String {
        // Try with fractional seconds first
        if let date = Self.isoFormatterWithFractional.date(from: isoString) {
            return Self.displayFormatter.string(from: date)
        }
        
        // Try without fractional seconds
        if let date = Self.isoFormatterStandard.date(from: isoString) {
            return Self.displayFormatter.string(from: date)
        }
        
        return isoString
    }
}

// MARK: - Menu Bar Settings Section

struct MenuBarSettingsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    private let settings = MenuBarSettingsManager.shared
    @AppStorage("showInDock") private var showInDock = true
    @State private var showTruncationAlert = false
    @State private var pendingMaxItems: Int?
    
    private var showMenuBarIconBinding: Binding<Bool> {
        Binding(
            get: { settings.showMenuBarIcon },
            set: { newValue in
                // Prevent disabling both dock and menu bar icon (user would have no way to access app)
                if !newValue && !showInDock {
                    // Re-enable dock if user tries to disable menu bar icon while dock is already disabled
                    showInDock = true
                    // activation policy will be set by showInDockBinding automatically
                }
                settings.showMenuBarIcon = newValue
            }
        )
    }

    private var showInDockBinding: Binding<Bool> {
        Binding(
            get: { showInDock },
            set: { newValue in
                // Prevent disabling both dock and menu bar icon (user would have no way to access app)
                if !newValue && !settings.showMenuBarIcon {
                    // Re-enable menu bar icon if user tries to disable dock while menu bar is already disabled
                    settings.showMenuBarIcon = true
                }

                // Update the value
                showInDock = newValue

                // This is the ONLY place where activation policy is changed based on user settings
                // - true: dock icon always visible, even when window is closed
                // - false: dock icon never visible
                NSApp.setActivationPolicy(newValue ? .regular : .accessory)
            }
        )
    }
    
    private var showQuotaBinding: Binding<Bool> {
        Binding(
            get: { settings.showQuotaInMenuBar },
            set: { settings.showQuotaInMenuBar = $0 }
        )
    }
    
    private var colorModeBinding: Binding<MenuBarColorMode> {
        Binding(
            get: { settings.colorMode },
            set: { settings.colorMode = $0 }
        )
    }
    
    private var maxItemsBinding: Binding<Int> {
        Binding(
            get: { settings.menuBarMaxItems },
            set: { newValue in
                let clamped = min(max(newValue, MenuBarSettingsManager.minMenuBarItems), MenuBarSettingsManager.maxMenuBarItems)

                // Check if reducing max items would truncate current selection
                if clamped < settings.menuBarMaxItems && settings.selectedItems.count > clamped {
                    pendingMaxItems = clamped
                    showTruncationAlert = true
                } else {
                    settings.menuBarMaxItems = clamped
                    viewModel.syncMenuBarSelection()
                }
            }
        )
    }
    
    var body: some View {
        Section {
            Toggle("settings.showInDock".localized(), isOn: showInDockBinding)
            
            Toggle("settings.menubar.showIcon".localized(), isOn: showMenuBarIconBinding)
            
            if settings.showMenuBarIcon {
                Toggle("settings.menubar.showQuota".localized(), isOn: showQuotaBinding)
                
                if settings.showQuotaInMenuBar {
                    HStack {
                        Text("settings.menubar.maxItems".localized())
                        Spacer()
                        Text("\(settings.menuBarMaxItems)")
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Stepper(
                            "",
                            value: maxItemsBinding,
                            in: MenuBarSettingsManager.minMenuBarItems...MenuBarSettingsManager.maxMenuBarItems,
                            step: 1
                        )
                        .labelsHidden()
                    }
                    
                    Picker("settings.menubar.colorMode".localized(), selection: colorModeBinding) {
                        Text("settings.menubar.colored".localized()).tag(MenuBarColorMode.colored)
                        Text("settings.menubar.monochrome".localized()).tag(MenuBarColorMode.monochrome)
                    }
                    .pickerStyle(.segmented)
                }
            }
        } header: {
            Label("settings.menubar".localized(), systemImage: "menubar.rectangle")
        } footer: {
            Text(String(
                format: "settings.menubar.help".localized(),
                settings.menuBarMaxItems
            ))
            .font(.caption)
        }
        .alert("menubar.truncation.title".localized(), isPresented: $showTruncationAlert) {
            Button("action.cancel".localized(), role: .cancel) {
                pendingMaxItems = nil
            }
            Button("action.ok".localized(), role: .destructive) {
                if let newMax = pendingMaxItems {
                    settings.menuBarMaxItems = newMax
                    viewModel.syncMenuBarSelection()
                    pendingMaxItems = nil
                }
            }
        } message: {
            if let newMax = pendingMaxItems {
                Text(String(
                    format: "menubar.truncation.message".localized(),
                    settings.selectedItems.count,
                    newMax
                ))
            }
        }
    }
}

// MARK: - Appearance Settings Section

struct AppearanceSettingsSection: View {
    @State private var appearanceManager = AppearanceManager.shared
    
    private var appearanceModeBinding: Binding<AppearanceMode> {
        Binding(
            get: { appearanceManager.appearanceMode },
            set: { appearanceManager.appearanceMode = $0 }
        )
    }
    
    var body: some View {
        Section {
            Picker("settings.appearance.mode".localized(), selection: appearanceModeBinding) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.localizationKey.localized(), systemImage: mode.icon)
                        .tag(mode)
                }
            }
        } header: {
            Label("settings.appearance.title".localized(), systemImage: "paintbrush")
        } footer: {
            Text("settings.appearance.help".localized())
                .font(.caption)
        }
    }
}

// MARK: - Privacy Settings Section

struct PrivacySettingsSection: View {
    @State private var settings = MenuBarSettingsManager.shared
    
    private var hideSensitiveBinding: Binding<Bool> {
        Binding(
            get: { settings.hideSensitiveInfo },
            set: { settings.hideSensitiveInfo = $0 }
        )
    }
    
    var body: some View {
        Section {
            Toggle("settings.privacy.hideSensitive".localized(), isOn: hideSensitiveBinding)
        } header: {
            Label("settings.privacy".localized(), systemImage: "eye.slash")
        } footer: {
            Text("settings.privacy.hideSensitiveHelp".localized())
                .font(.caption)
        }
    }
}

struct GeneralSettingsTab: View {
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    
    var body: some View {
        @Bindable var lang = LanguageManager.shared
        
        Form {
            Section {
                LaunchAtLoginToggle()
                
                Toggle("settings.autoStartProxy".localized(), isOn: $autoStartProxy)
            } header: {
                Label("settings.startup".localized(), systemImage: "power")
            }
            
            Section {
                Picker(selection: Binding(
                    get: { lang.currentLanguage },
                    set: { lang.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        HStack {
                            Text(language.flag)
                            Text(language.displayName)
                        }
                        .tag(language)
                    }
                } label: {
                    Label("settings.language".localized(), systemImage: "globe")
                }
            } header: {
                Label("settings.language".localized(), systemImage: "globe")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            
            Text("Quotio")
                .font(.title)
                .fontWeight(.bold)
            
            Text("CLIProxyAPI GUI Wrapper")
                .foregroundStyle(.secondary)
            
            Text("Version 1.0")
                .font(.caption)
                .foregroundStyle(.tertiary)
            
            Link("GitHub: CLIProxyAPI", destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - About Screen (New Full-Page Version)

struct AboutScreen: View {
    @State private var showCopiedToast = false
    @State private var isHoveringVersion = false
    @State private var updaterService = UpdaterService.shared
    
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Hero Section
                heroSection
                
                // Description
                descriptionSection
                
                // Updates Grid
                updatesSection
                
                Divider()
                    .frame(maxWidth: 500)
                
                // Links Grid
                linksSection
                
                Spacer(minLength: 40)
                
                // Footer
                footerSection
            }
            .frame(maxWidth: .infinity)
            .padding(40)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if showCopiedToast {
                versionCopyToast
                    .transition(.opacity)
            }
        }
        .onAppear {
            #if canImport(Sparkle)
            updaterService.initializeIfNeeded()
            #endif
        }
        .navigationTitle("nav.about".localized())
    }
    
    // MARK: - Hero Section
    
    private var heroSection: some View {
        VStack(spacing: 20) {
            // App Icon with gradient glow
            ZStack {
                // Glow effect
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.blue.opacity(0.2),
                                Color.purple.opacity(0.1),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 160, height: 160)
                    .blur(radius: 40)
                
                // App Icon - uses observable currentAppIcon from UpdaterService
                if let appIcon = UpdaterService.shared.currentAppIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 8)
                }
            }
            
            // App Name & Tagline
            VStack(spacing: 8) {
                Text("Quotio")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("about.tagline".localized())
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            
            // Version Badges
            HStack(spacing: 12) {
                VersionBadge(
                    label: "Version",
                    value: appVersion,
                    icon: "tag"
                )
                .onHover { hovering in
                    isHoveringVersion = hovering
                }
                
                VersionBadge(
                    label: "Build",
                    value: buildNumber,
                    icon: "hammer.fill"
                )
            }
        }
        .padding(.top, 20)
    }
    
    // MARK: - Description Section
    
    private var descriptionSection: some View {
        Text("about.description".localized())
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 500)
    }
    
    // MARK: - Updates Section
    
    private var updatesSection: some View {
        VStack(spacing: 12) {
            AboutUpdateCard()
            
            if OperatingModeManager.shared.isLocalProxyMode {
                AboutProxyUpdateCard()
            }
        }
        .frame(maxWidth: 500)
    }
    
    // MARK: - Links Section
    
    private var linksSection: some View {
        VStack(spacing: 16) {
            Text("Links")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                LinkCard(
                    title: "GitHub: Quotio",
                    icon: "link",
                    color: .blue,
                    url: URL(string: "https://github.com/nguyenphutrong/quotio")!
                )
                
                LinkCard(
                    title: "GitHub: CLIProxyAPI",
                    icon: "link",
                    color: .purple,
                    url: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!
                )
                
                LinkCard(
                    title: "about.support".localized(),
                    icon: "heart.fill",
                    color: .pink,
                    url: URL(string: "https://www.quotio.dev/sponsors")!
                )
            }
        }
        .frame(maxWidth: 500)
    }
    
    // MARK: - Footer Section
    
    private var footerSection: some View {
        VStack(spacing: 8) {
            Text("about.madeWith".localized())
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 16)
    }
    
    // MARK: - Version Copy Toast
    
    private var versionCopyToast: some View {
        VStack {
            Spacer()
            
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Version copied to clipboard")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 4)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - About Update Section

struct AboutUpdateSection: View {
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    
    #if canImport(Sparkle)
    private let updaterService = UpdaterService.shared
    #endif
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("settings.updates".localized(), systemImage: "arrow.down.circle")
                .font(.headline)
            
            #if canImport(Sparkle)
            HStack {
                Toggle("settings.autoCheckUpdates".localized(), isOn: $autoCheckUpdates)
                    .onChange(of: autoCheckUpdates) { _, newValue in
                        updaterService.automaticallyChecksForUpdates = newValue
                    }
            }
            
            HStack {
                Text("settings.lastChecked".localized())
                Spacer()
                if let date = updaterService.lastUpdateCheckDate {
                    Text(date, style: .relative)
                        .foregroundStyle(.secondary)
                } else {
                    Text("settings.never".localized())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            
            Button("settings.checkNow".localized()) {
                updaterService.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .disabled(!updaterService.canCheckForUpdates)
            #else
            Text("settings.version".localized() + ": " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"))
            #endif
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            #if canImport(Sparkle)
            updaterService.initializeIfNeeded()
            #endif
        }
    }
}

// MARK: - About Proxy Update Section

struct AboutProxyUpdateSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var isCheckingForUpdate = false
    @State private var isUpgrading = false
    @State private var upgradeError: String?
    @State private var showAdvancedSheet = false

    private var proxyManager: CLIProxyManager {
        viewModel.proxyManager
    }

    private var atomFeedService: AtomFeedUpdateService {
        AtomFeedUpdateService.shared
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("settings.proxyUpdate".localized(), systemImage: "shippingbox.and.arrow.backward")
                .font(.headline)
            
            // Current version
            HStack {
                Text("settings.proxyUpdate.currentVersion".localized())
                Spacer()
                if let version = proxyManager.currentVersion ?? proxyManager.installedProxyVersion {
                    Text("v\(version)")
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text("settings.proxyUpdate.unknown".localized())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            
            // Upgrade status
            if proxyManager.upgradeAvailable, let upgrade = proxyManager.availableUpgrade {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label {
                            Text("settings.proxyUpdate.available".localized())
                        } icon: {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(.green)
                        }
                        
                        Text("v\(upgrade.version)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button {
                        performUpgrade(to: upgrade)
                    } label: {
                        ZStack {
                            Text("action.update".localized())
                                .opacity(isUpgrading ? 0 : 1)
                            
                            if isUpgrading {
                                SmallProgressView()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isUpgrading || !proxyManager.proxyStatus.running)
                }
            } else {
                HStack {
                    Label {
                        Text("settings.proxyUpdate.upToDate".localized())
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    
                    Spacer()
                    
                    Button {
                        checkForUpdate()
                    } label: {
                        ZStack {
                            Text("settings.proxyUpdate.checkNow".localized())
                                .opacity(isCheckingForUpdate ? 0 : 1)
                            
                            if isCheckingForUpdate {
                                SmallProgressView()
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCheckingForUpdate)
                }

                // Last checked time
                if let lastCheck = atomFeedService.lastCLIProxyCheck {
                    HStack {
                        Text("Last checked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(lastCheck, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Error message
            if let error = upgradeError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Proxy must be running hint
            if !proxyManager.proxyStatus.running {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("settings.proxyUpdate.proxyMustRun".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Advanced button
            Button {
                showAdvancedSheet = true
            } label: {
                HStack {
                    Label("settings.proxyUpdate.advanced".localized(), systemImage: "gearshape.2")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showAdvancedSheet) {
            ProxyVersionManagerSheet()
                .environment(viewModel)
        }
    }
    
    private func checkForUpdate() {
        isCheckingForUpdate = true
        upgradeError = nil

        Task { @MainActor in
            defer {
                // Always reset loading state
                isCheckingForUpdate = false
            }

            await proxyManager.checkForUpgrade()
        }
    }
    
    private func performUpgrade(to version: ProxyVersionInfo) {
        isUpgrading = true
        upgradeError = nil
        
        Task { @MainActor in
            do {
                try await proxyManager.performManagedUpgrade(to: version)
                isUpgrading = false
            } catch {
                upgradeError = error.localizedDescription
                isUpgrading = false
            }
        }
    }
}

// MARK: - Version Badge

struct VersionBadge: View {
    let label: String
    let value: String
    let icon: String
    
    @State private var isHovered = false
    
    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        } label: {
            HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(isHovered ? .blue : .secondary)
                
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(isHovered ? .blue : .secondary)
                
                Text(value)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isHovered ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.05),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isHovered ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.2),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - About Update Card

struct AboutUpdateCard: View {
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true
    @State private var isHovered = false
    
    #if canImport(Sparkle)
    private let updaterService = UpdaterService.shared
    #endif
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("settings.updates".localized())
                    .font(.headline)
                Spacer()
            }
            
            #if canImport(Sparkle)
            HStack {
                Text("settings.autoCheckUpdates".localized())
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: $autoCheckUpdates)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: autoCheckUpdates) { _, newValue in
                        updaterService.automaticallyChecksForUpdates = newValue
                    }
            }
            
            HStack {
                Text("settings.updateChannel.receiveBeta".localized())
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { updaterService.updateChannel == .beta },
                    set: { newValue in
                        updaterService.updateChannel = newValue ? .beta : .stable
                    }
                ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            
            HStack {
                Text("settings.lastChecked".localized())
                Spacer()
                if let date = updaterService.lastUpdateCheckDate {
                    Text(date, style: .relative)
                        .foregroundStyle(.secondary)
                } else {
                    Text("settings.never".localized())
                        .foregroundStyle(.secondary)
                }
                
                Button("settings.checkNow".localized()) {
                    updaterService.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            #else
            Text("settings.version".localized() + ": " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"))
                .font(.caption)
            #endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(
            color: .black.opacity(isHovered ? 0.08 : 0.04),
            radius: isHovered ? 8 : 4,
            x: 0,
            y: isHovered ? 2 : 1
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - About Proxy Update Card

struct AboutProxyUpdateCard: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var isHovered = false
    @State private var showAdvancedSheet = false
    @State private var isCheckingForUpdate = false
    @State private var isUpgrading = false
    @State private var upgradeError: String?

    private var proxyManager: CLIProxyManager {
        viewModel.proxyManager
    }

    private var atomFeedService: AtomFeedUpdateService {
        AtomFeedUpdateService.shared
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.title3)
                    .foregroundStyle(.purple)
                Text("settings.proxyUpdate".localized())
                    .font(.headline)
                Spacer()
            }
            
            // Current version row
            HStack {
                Text("settings.proxyUpdate.currentVersion".localized())
                if let version = proxyManager.currentVersion ?? proxyManager.installedProxyVersion {
                    Text("v\(version)")
                        .font(.system(.subheadline).monospaced())
                        .fontWeight(.medium)
                } else {
                    Text("settings.proxyUpdate.unknown".localized())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            
            // Upgrade status with action buttons
            if proxyManager.upgradeAvailable, let upgrade = proxyManager.availableUpgrade {
                HStack {
                    Label {
                        Text("v\(upgrade.version) " + "settings.proxyUpdate.available".localized())
                    } icon: {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                    
                    Spacer()
                    
                    Button {
                        performUpgrade(to: upgrade)
                    } label: {
                        ZStack {
                            Text("action.update".localized())
                                .opacity(isUpgrading ? 0 : 1)
                            
                            if isUpgrading {
                                SmallProgressView()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isUpgrading || !proxyManager.proxyStatus.running)
                }
            } else {
                HStack {
                    Label {
                        Text("settings.proxyUpdate.upToDate".localized())
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                    
                    Spacer()
                    
                    Button {
                        checkForUpdate()
                    } label: {
                        ZStack {
                            Text("settings.proxyUpdate.checkNow".localized())
                                .opacity(isCheckingForUpdate ? 0 : 1)
                            
                            if isCheckingForUpdate {
                                SmallProgressView()
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCheckingForUpdate)
                }

                // Last checked time
                if let lastCheck = atomFeedService.lastCLIProxyCheck {
                    HStack {
                        Text("Last checked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(lastCheck, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Error message
            if let error = upgradeError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Proxy must be running hint (only for Update action, not Check)
            if proxyManager.upgradeAvailable && !proxyManager.proxyStatus.running {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("settings.proxyUpdate.proxyMustRun".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            HStack {
                Spacer()
                
                Button {
                    showAdvancedSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text("settings.proxyUpdate.advanced".localized())
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(
            color: .black.opacity(isHovered ? 0.08 : 0.04),
            radius: isHovered ? 8 : 4,
            x: 0,
            y: isHovered ? 2 : 1
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .sheet(isPresented: $showAdvancedSheet) {
            ProxyVersionManagerSheet()
                .environment(viewModel)
        }
    }
    
    private func checkForUpdate() {
        isCheckingForUpdate = true
        upgradeError = nil

        Task { @MainActor in
            defer {
                // Always reset loading state
                isCheckingForUpdate = false
            }

            await proxyManager.checkForUpgrade()
        }
    }
    
    private func performUpgrade(to version: ProxyVersionInfo) {
        isUpgrading = true
        upgradeError = nil
        
        Task { @MainActor in
            do {
                try await proxyManager.performManagedUpgrade(to: version)
                isUpgrading = false
            } catch {
                upgradeError = error.localizedDescription
                isUpgrading = false
            }
        }
    }
}

// MARK: - Link Card

struct LinkCard: View {
    let title: String
    let icon: String
    let color: Color
    let url: URL?
    let action: (() -> Void)?
    
    @State private var isHovered = false
    
    init(
        title: String,
        icon: String,
        color: Color,
        url: URL? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.icon = icon
        self.color = color
        self.url = url
        self.action = action
    }
    
    var body: some View {
        Button {
            if let url = url {
                NSWorkspace.shared.open(url)
            } else if let action = action {
                action()
            }
        } label: {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(color.opacity(isHovered ? 0.15 : 0.08))
                        .frame(width: 40, height: 40)
                    
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(isHovered ? color : .secondary)
                }
                
                // Title
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(isHovered ? color : .primary)
                
                Spacer()
                
                // Arrow icon (for links)
                if url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(isHovered ? color : .secondary.opacity(0.5))
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isHovered ? color.opacity(0.3) : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .shadow(
                color: .black.opacity(isHovered ? 0.1 : 0.03),
                radius: isHovered ? 10 : 4,
                x: 0,
                y: isHovered ? 3 : 1
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Management Key Row

struct ManagementKeyRow: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var settings = MenuBarSettingsManager.shared
    @State private var regenerateError: String?
    @State private var showRegenerateConfirmation = false
    @State private var showCopyConfirmation = false
    
    private var displayKey: String {
        if settings.hideSensitiveInfo {
            let key = viewModel.proxyManager.managementKey
            return String(repeating: "•", count: 8) + "..." + key.suffix(4)
        }
        return viewModel.proxyManager.managementKey
    }
    
    var body: some View {
        LabeledContent("settings.managementKey".localized()) {
            HStack(spacing: 8) {
                Text(displayKey)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(viewModel.proxyManager.managementKey, forType: .string)
                    showCopyConfirmation = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        showCopyConfirmation = false
                    }
                } label: {
                    Image(systemName: showCopyConfirmation ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(showCopyConfirmation ? .green : .primary)
                        .modifier(SymbolEffectTransitionModifier())
                }
                .buttonStyle(.borderless)
                .help("action.copy".localized())
                
                Button {
                    showRegenerateConfirmation = true
                } label: {
                    if viewModel.proxyManager.isRegeneratingKey {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.proxyManager.isRegeneratingKey)
                .help("settings.managementKey.regenerate".localized())
            }
        }
        .confirmationDialog(
            "settings.managementKey.regenerate.title".localized(),
            isPresented: $showRegenerateConfirmation,
            titleVisibility: .visible
        ) {
            Button("settings.managementKey.regenerate.confirm".localized(), role: .destructive) {
                Task {
                    regenerateError = nil
                    do {
                        try await viewModel.proxyManager.regenerateManagementKey()
                    } catch {
                        regenerateError = error.localizedDescription
                    }
                }
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("settings.managementKey.regenerate.warning".localized())
        }
        .alert("Error".localized(), isPresented: .init(
            get: { regenerateError != nil },
            set: { if !$0 { regenerateError = nil } }
        )) {
            Button("OK".localized()) { regenerateError = nil }
        } message: {
            Text(regenerateError ?? "")
        }
    }
}

// MARK: - Launch at Login Toggle

/// Reusable toggle component for Launch at Login functionality
/// Uses LaunchAtLoginManager for proper SMAppService handling
struct LaunchAtLoginToggle: View {
    private let launchManager = LaunchAtLoginManager.shared
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showLocationWarning = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("settings.launchAtLogin".localized(), isOn: Binding(
                get: { launchManager.isEnabled },
                set: { newValue in
                    do {
                        try launchManager.setEnabled(newValue)
                        
                        // Show warning if app is not in /Applications when enabling
                        if newValue && !launchManager.isInValidLocation {
                            showLocationWarning = true
                        } else {
                            showLocationWarning = false
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            ))
            
            // Show location warning inline
            if showLocationWarning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("launchAtLogin.warning.notInApplications".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 2)
            }
        }
        .onAppear {
            // Refresh status when view appears to sync with System Settings
            launchManager.refreshStatus()
        }
        .alert("launchAtLogin.error.title".localized(), isPresented: $showError) {
            Button("OK".localized()) { showError = false }
            Button("launchAtLogin.openSystemSettings".localized()) {
                launchManager.openSystemSettings()
                showError = false
            }
        } message: {
            Text(errorMessage)
        }
    }
}

// MARK: - Usage Display Settings Section

struct UsageDisplaySettingsSection: View {
    @State private var settings = MenuBarSettingsManager.shared
    
    private var totalUsageModeBinding: Binding<TotalUsageMode> {
        Binding(
            get: { settings.totalUsageMode },
            set: { settings.totalUsageMode = $0 }
        )
    }
    
    private var modelAggregationModeBinding: Binding<ModelAggregationMode> {
        Binding(
            get: { settings.modelAggregationMode },
            set: { settings.modelAggregationMode = $0 }
        )
    }
    
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.usageDisplay.totalMode.title".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Picker("", selection: totalUsageModeBinding) {
                    ForEach(TotalUsageMode.allCases) { mode in
                        Text(mode.localizationKey.localized()).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                
                Text("settings.usageDisplay.totalMode.description".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.usageDisplay.modelAggregation.title".localized())
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Picker("", selection: modelAggregationModeBinding) {
                    ForEach(ModelAggregationMode.allCases) { mode in
                        Text(mode.localizationKey.localized()).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                
                Text("settings.usageDisplay.modelAggregation.description".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Label("settings.usageDisplay.title".localized(), systemImage: "chart.bar.doc.horizontal")
        } footer: {
            Text("settings.usageDisplay.description".localized())
                .font(.caption)
        }
    }
}
