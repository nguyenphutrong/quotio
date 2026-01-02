//
//  SettingsScreen.swift
//  Quotio
//

import SwiftUI
import AppKit
import ServiceManagement

struct SettingsScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    private let modeManager = AppModeManager.shared
    
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    @AppStorage("routingStrategy") private var routingStrategy = "round-robin"
    @AppStorage("requestRetry") private var requestRetry = 3
    @AppStorage("switchProjectOnQuotaExceeded") private var switchProject = true
    @AppStorage("switchPreviewModelOnQuotaExceeded") private var switchPreviewModel = true
    @AppStorage("loggingToFile") private var loggingToFile = true
    @AppStorage("proxyURL") private var proxyURL = ""
    
    @State private var portText: String = ""
    @State private var proxyURLValidation: ProxyURLValidationResult = .empty
    
    var body: some View {
        @Bindable var lang = LanguageManager.shared

        Form {
            // App Mode
            AppModeSection()

            // General Settings
            Section {
                Toggle("settings.launchAtLogin".localized(), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }

                Toggle("settings.showInDock".localized(), isOn: $showInDock)
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

            // Appearance
            AppearanceSettingsSection()
            
            // Privacy
            PrivacySettingsSection()
            
            // Proxy Server - Only in Full Mode
            if modeManager.isFullMode {
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
                    
                    Toggle("settings.autoStartProxy".localized(), isOn: $autoStartProxy)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("settings.upstreamProxy".localized()) {
                            TextField("", text: $proxyURL)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .onChange(of: proxyURL) { _, newValue in
                                    proxyURLValidation = ProxyURLValidator.validate(newValue)
                                    applyProxyURLSettings()
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
                    Label("settings.proxyServer".localized(), systemImage: "server.rack")
                } footer: {
                    Text("settings.restartProxy".localized())
                }
                
                // Routing Strategy
                Section {
                    Picker("settings.routingStrategy".localized(), selection: $routingStrategy) {
                        Text("settings.roundRobin".localized()).tag("round-robin")
                        Text("settings.fillFirst".localized()).tag("fill-first")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Label("settings.routingStrategy".localized(), systemImage: "arrow.triangle.branch")
                } footer: {
                    Text(routingStrategy == "round-robin"
                         ? "settings.roundRobinDesc".localized()
                         : "settings.fillFirstDesc".localized())
                }
                
                // Quota Exceeded Behavior
                Section {
                    Toggle("settings.autoSwitchAccount".localized(), isOn: $switchProject)
                    Toggle("settings.autoSwitchPreview".localized(), isOn: $switchPreviewModel)
                } header: {
                    Label("settings.quotaExceededBehavior".localized(), systemImage: "exclamationmark.triangle")
                } footer: {
                    Text("settings.quotaExceededHelp".localized())
                }
                
                // Retry Configuration
                Section {
                    Stepper("settings.maxRetries".localized() + ": \(requestRetry)", value: $requestRetry, in: 0...10)
                } header: {
                    Label("settings.retryConfiguration".localized(), systemImage: "arrow.clockwise")
                } footer: {
                    Text("settings.retryHelp".localized())
                }
                
                // Logging
                Section {
                    Toggle("settings.loggingToFile".localized(), isOn: $loggingToFile)
                        .onChange(of: loggingToFile) { _, newValue in
                            viewModel.proxyManager.updateConfigLogging(enabled: newValue)
                        }
                } header: {
                    Label("settings.logging".localized(), systemImage: "doc.text")
                } footer: {
                    Text("settings.loggingHelp".localized())
                }
            }
            
            // Notifications
            NotificationSettingsSection()
            
            // Quota Display
            QuotaDisplaySettingsSection()
            
            // Refresh Cadence
            RefreshCadenceSettingsSection()
            
            // Menu Bar
            MenuBarSettingsSection()
            
            // Paths - Only in Full Mode
            if modeManager.isFullMode {
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
        .formStyle(.grouped)
        .navigationTitle("nav.settings".localized())
        .onAppear {
            portText = String(viewModel.proxyManager.port)
            proxyURLValidation = ProxyURLValidator.validate(proxyURL)
        }
    }
    
    private func applyProxyURLSettings() {
        guard viewModel.proxyManager.proxyStatus.running else { return }
        
        if proxyURLValidation == .valid {
            viewModel.proxyManager.updateConfigProxyURL(ProxyURLValidator.sanitize(proxyURL))
        } else {
            viewModel.proxyManager.updateConfigProxyURL(nil)
        }
    }
}

// MARK: - App Mode Section

struct AppModeSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var modeManager = AppModeManager.shared
    @State private var showModeChangeConfirmation = false
    @State private var pendingMode: AppMode?
    
    var body: some View {
        Section {
            // Mode selection cards
            VStack(spacing: 10) {
                AppModeCard(
                    mode: .full,
                    isSelected: modeManager.currentMode == .full
                ) {
                    handleModeSelection(.full)
                }
                
                AppModeCard(
                    mode: .quotaOnly,
                    isSelected: modeManager.currentMode == .quotaOnly
                ) {
                    handleModeSelection(.quotaOnly)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label("settings.appMode".localized(), systemImage: "switch.2")
        } footer: {
            if modeManager.isQuotaOnlyMode {
                Label("settings.appMode.quotaOnlyNote".localized(), systemImage: "info.circle")
                    .font(.caption)
            }
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
    }
    
    private func handleModeSelection(_ mode: AppMode) {
        guard mode != modeManager.currentMode else { return }
        
        if modeManager.isFullMode && mode == .quotaOnly {
            // Confirm before switching from full to quota-only
            pendingMode = mode
            showModeChangeConfirmation = true
        } else {
            // Switch immediately for other transitions
            switchToMode(mode)
        }
    }
    
    private func switchToMode(_ mode: AppMode) {
        modeManager.switchMode(to: mode) {
            viewModel.stopProxy()
        }
        
        // Re-initialize based on new mode
        Task {
            await viewModel.initialize()
        }
    }
}

// MARK: - App Mode Card

private struct AppModeCard: View {
    let mode: AppMode
    let isSelected: Bool
    let onSelect: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Icon
                Image(systemName: mode.icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .white : modeColor)
                    .frame(width: 36, height: 36)
                    .background(isSelected ? modeColor : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(modeColor, lineWidth: isSelected ? 0 : 1.5)
                    )
                
                // Content
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    
                    Text(mode.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? modeColor : .secondary.opacity(0.4))
            }
            .padding(10)
            .background(backgroundView)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
    
    private var modeColor: Color {
        switch mode {
        case .full: return .blue
        case .quotaOnly: return .green
        }
    }
    
    private var borderColor: Color {
        if isSelected {
            return modeColor
        } else if isHovered {
            return Color.secondary.opacity(0.5)
        } else {
            return Color.secondary.opacity(0.2)
        }
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        if isSelected {
            modeColor.opacity(0.08)
        } else if isHovered {
            Color.secondary.opacity(0.05)
        } else {
            Color.clear
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
    
    var body: some View {
        Section {
            Picker("settings.quota.displayMode".localized(), selection: displayModeBinding) {
                Text("settings.quota.displayMode.used".localized()).tag(QuotaDisplayMode.used)
                Text("settings.quota.displayMode.remaining".localized()).tag(QuotaDisplayMode.remaining)
            }
            .pickerStyle(.segmented)
        } header: {
            Label("settings.quota.display".localized(), systemImage: "percent")
        } footer: {
            Text("settings.quota.display.help".localized())
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
            await proxyManager.checkForUpgrade()
            isCheckingForUpdate = false
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: isoString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .none
            return displayFormatter.string(from: date)
        }
        
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoString) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .none
            return displayFormatter.string(from: date)
        }
        
        return isoString
    }
}

// MARK: - Menu Bar Settings Section

struct MenuBarSettingsSection: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var settings = MenuBarSettingsManager.shared
    
    private var showMenuBarIconBinding: Binding<Bool> {
        Binding(
            get: { settings.showMenuBarIcon },
            set: { settings.showMenuBarIcon = $0 }
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
    
    var body: some View {
        Section {
            Toggle("settings.menubar.showIcon".localized(), isOn: showMenuBarIconBinding)
            
            if settings.showMenuBarIcon {
                Toggle("settings.menubar.showQuota".localized(), isOn: showQuotaBinding)
                
                if settings.showQuotaInMenuBar {
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
            Text("settings.menubar.help".localized())
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
        }
    }
}

struct GeneralSettingsTab: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    
    var body: some View {
        @Bindable var lang = LanguageManager.shared
        
        Form {
            Section {
                Toggle("settings.launchAtLogin".localized(), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }
                
                Toggle("settings.autoStartProxy".localized(), isOn: $autoStartProxy)
            } header: {
                Label("settings.startup".localized(), systemImage: "power")
            }
            
            Section {
                Toggle("settings.showInDock".localized(), isOn: $showInDock)
            } header: {
                Label("settings.appearance".localized(), systemImage: "macwindow")
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
            
            if AppModeManager.shared.isFullMode {
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
                    .disabled(isCheckingForUpdate || !proxyManager.proxyStatus.running)
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
            await proxyManager.checkForUpgrade()
            isCheckingForUpdate = false
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
            await proxyManager.checkForUpgrade()
            isCheckingForUpdate = false
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
