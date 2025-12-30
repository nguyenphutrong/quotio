//
//  SettingsScreen.swift
//  CKota
//
//  Settings screen with tabbed interface (General, Proxy, Notifications, Advanced).
//

import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Settings Tab Enum

enum SettingsTab: String, CaseIterable, CustomStringConvertible {
    case general
    case proxy
    case notifications
    case advanced

    var description: String {
        switch self {
        case .general: "settings.tab.general".localized()
        case .proxy: "settings.tab.proxy".localized()
        case .notifications: "settings.tab.notifications".localized()
        case .advanced: "settings.tab.advanced".localized()
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .proxy: "server.rack"
        case .notifications: "bell"
        case .advanced: "slider.horizontal.3"
        }
    }
}

// MARK: - Settings Screen

struct SettingsScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @SceneStorage("settingsSelectedTab") private var selectedTabRaw: String = SettingsTab.general.rawValue
    private let modeManager = AppModeManager.shared

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("showInDock") private var showInDock = true
    @AppStorage("autoStartProxy") private var autoStartProxy = false
    @AppStorage("routingStrategy") private var routingStrategy = "round-robin"
    @AppStorage("requestRetry") private var requestRetry = 3
    @AppStorage("switchProjectOnQuotaExceeded") private var switchProject = true
    @AppStorage("switchPreviewModelOnQuotaExceeded") private var switchPreviewModel = true
    @AppStorage("loggingToFile") private var loggingToFile = true

    @State private var portText: String = ""

    private var selectedTab: SettingsTab {
        get { SettingsTab(rawValue: selectedTabRaw) ?? .general }
        nonmutating set { selectedTabRaw = newValue.rawValue }
    }

    private var availableTabs: [SettingsTab] {
        if modeManager.isFullMode {
            SettingsTab.allCases
        } else {
            // Hide Proxy tab in Quota-Only mode
            [.general, .notifications, .advanced]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack {
                CKSegmentedTabs(
                    tabs: availableTabs,
                    selection: Binding(
                        get: { selectedTab },
                        set: { selectedTabRaw = $0.rawValue }
                    )
                )
                Spacer()
            }
            .padding(.horizontal, CKLayout.contentPadding)
            .padding(.vertical, .ckMD)

            Divider().background(Color.ckBorder)

            // Tab content
            ScrollView {
                VStack(alignment: .leading, spacing: .ckXXL) {
                    switch selectedTab {
                    case .general:
                        generalTabContent
                    case .proxy:
                        proxyTabContent
                    case .notifications:
                        notificationsTabContent
                    case .advanced:
                        advancedTabContent
                    }
                }
                .padding(CKLayout.contentPadding)
            }
        }
        .background(Color.ckBackground)
        .navigationTitle("nav.settings".localized())
        .onAppear {
            portText = String(viewModel.proxyManager.port)
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToNextTab)) { _ in
            guard viewModel.currentPage == .settings else { return }
            switchToNextTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToPreviousTab)) { _ in
            guard viewModel.currentPage == .settings else { return }
            switchToNextTab(reverse: true)
        }
    }

    // MARK: - Tab Navigation

    private func switchToNextTab(reverse: Bool = false) {
        guard let currentIndex = availableTabs.firstIndex(of: selectedTab) else { return }
        let nextIndex: Int = if reverse {
            (currentIndex - 1 + availableTabs.count) % availableTabs.count
        } else {
            (currentIndex + 1) % availableTabs.count
        }
        withAnimation(.ckStandard) {
            selectedTabRaw = availableTabs[nextIndex].rawValue
        }
    }

    // MARK: - General Tab

    @ViewBuilder
    private var generalTabContent: some View {
        VStack(alignment: .leading, spacing: .ckXL) {
            // App Mode
            SettingsSectionCard(title: "settings.appMode".localized(), icon: "switch.2") {
                AppModeSectionContent()
            }

            // Startup & Dock
            SettingsSectionCard(title: "settings.general".localized(), icon: "gearshape") {
                CKSettingsToggleRow(
                    title: "settings.launchAtLogin".localized(),
                    isOn: $launchAtLogin
                )
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

                Divider()
                    .padding(.horizontal, .ckMD)

                CKSettingsToggleRow(
                    title: "settings.showInDock".localized(),
                    isOn: $showInDock
                )
            }

            // Language
            SettingsSectionCard(
                title: "settings.language".localized(),
                icon: "globe",
                hint: "settings.restartForEffect".localized()
            ) {
                LanguagePickerRow()
            }

            // Appearance
            SettingsSectionCard(
                title: "settings.appearance.title".localized(),
                icon: "paintbrush",
                hint: "settings.appearance.help".localized()
            ) {
                AppearancePickerRow()
            }
        }
    }

    // MARK: - Proxy Tab (Full Mode only)

    @ViewBuilder
    private var proxyTabContent: some View {
        VStack(alignment: .leading, spacing: .ckXL) {
            // Proxy Server
            SettingsSectionCard(title: "settings.proxyServer".localized(), icon: "server.rack") {
                CKSettingsRow(title: "settings.port".localized()) {
                    TextField("settings.port".localized(), text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onChange(of: portText) { _, newValue in
                            if let port = UInt16(newValue), port > 0 {
                                viewModel.proxyManager.port = port
                            }
                        }
                }

                Divider()
                    .padding(.horizontal, .ckMD)

                CKSettingsRow(title: "settings.status".localized()) {
                    HStack(spacing: 6) {
                        CKStatusDot(
                            status: viewModel.proxyManager.proxyStatus.running ? .ready : .unknown,
                            showLabel: false
                        )
                        Text(viewModel.proxyManager.proxyStatus.running
                            ? "status.running".localized()
                            : "status.stopped".localized())
                            .font(.ckBody)
                            .foregroundStyle(Color.ckMutedForeground)
                    }
                }

                Divider()
                    .padding(.horizontal, .ckMD)

                CKSettingsRow(title: "settings.endpoint".localized()) {
                    HStack {
                        Text(viewModel.proxyManager.proxyStatus.endpoint)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Color.ckMutedForeground)
                            .textSelection(.enabled)

                        Button {
                            viewModel.proxyManager.copyEndpointToClipboard()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundStyle(Color.ckAccent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Copy endpoint to clipboard")
                        .ckTouchTarget()
                        .ckCursorPointer()
                    }
                }

                Divider()
                    .padding(.horizontal, .ckMD)

                CKSettingsToggleRow(
                    title: "settings.autoStartProxy".localized(),
                    subtitle: "settings.restartProxy".localized(),
                    isOn: $autoStartProxy
                )
            }

            // Routing Strategy
            SettingsSectionCard(
                title: "settings.routingStrategy".localized(),
                icon: "arrow.triangle.branch",
                hint: routingStrategy == "round-robin"
                    ? "settings.roundRobinDesc".localized()
                    : "settings.fillFirstDesc".localized()
            ) {
                Picker("", selection: $routingStrategy) {
                    Text("settings.roundRobin".localized()).tag("round-robin")
                    Text("settings.fillFirst".localized()).tag("fill-first")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, .ckMD)
                .padding(.vertical, .ckSM)
            }

            // Quota Exceeded Behavior
            SettingsSectionCard(
                title: "settings.quotaExceededBehavior".localized(),
                icon: "exclamationmark.triangle",
                hint: "settings.quotaExceededHelp".localized()
            ) {
                CKSettingsToggleRow(
                    title: "settings.autoSwitchAccount".localized(),
                    isOn: $switchProject
                )

                Divider()
                    .padding(.horizontal, .ckMD)

                CKSettingsToggleRow(
                    title: "settings.autoSwitchPreview".localized(),
                    isOn: $switchPreviewModel
                )
            }

            // Retry Configuration
            SettingsSectionCard(
                title: "settings.retryConfiguration".localized(),
                icon: "arrow.clockwise",
                hint: "settings.retryHelp".localized()
            ) {
                CKSettingsRow(title: "settings.maxRetries".localized()) {
                    Stepper("\(requestRetry)", value: $requestRetry, in: 0 ... 10)
                        .fixedSize()
                }
            }

            // Logging
            SettingsSectionCard(
                title: "settings.logging".localized(),
                icon: "doc.text",
                hint: "settings.loggingHelp".localized()
            ) {
                CKSettingsToggleRow(
                    title: "settings.loggingToFile".localized(),
                    isOn: $loggingToFile
                )
                .onChange(of: loggingToFile) { _, newValue in
                    viewModel.proxyManager.updateConfigLogging(enabled: newValue)
                }
            }

            // API Keys
            SettingsSectionCard(
                title: "nav.apiKeys".localized(),
                icon: "key.horizontal",
                hint: "apiKeys.description".localized()
            ) {
                APIKeysContent()
            }
        }
    }

    // MARK: - Notifications Tab

    @ViewBuilder
    private var notificationsTabContent: some View {
        VStack(alignment: .leading, spacing: .ckXL) {
            // Notifications
            SettingsSectionCard(
                title: "settings.notifications".localized(),
                icon: "bell",
                hint: "settings.notifications.help".localized()
            ) {
                NotificationSettingsContent()
            }

            // Quota Display
            SettingsSectionCard(
                title: "settings.quota.display".localized(),
                icon: "percent",
                hint: "settings.quota.display.help".localized()
            ) {
                QuotaDisplayContent()
            }

            // Menu Bar
            SettingsSectionCard(
                title: "settings.menubar".localized(),
                icon: "menubar.rectangle",
                hint: "settings.menubar.help".localized()
            ) {
                MenuBarSettingsContent()
            }
        }
    }

    // MARK: - Advanced Tab

    @ViewBuilder
    private var advancedTabContent: some View {
        VStack(alignment: .leading, spacing: .ckXL) {
            // Updates
            SettingsSectionCard(title: "settings.updates".localized(), icon: "arrow.down.circle") {
                UpdateSettingsContent()
            }

            if modeManager.isFullMode {
                // Paths
                SettingsSectionCard(title: "settings.paths".localized(), icon: "folder") {
                    PathsContent()
                }

                // Logs (only if logging enabled)
                if loggingToFile {
                    SettingsSectionCard(
                        title: "nav.logs".localized(),
                        icon: "doc.text",
                        hint: "logs.showingRecent".localized()
                    ) {
                        LogsContent()
                    }
                }
            }
        }
    }
}

// MARK: - Settings Section Card

struct SettingsSectionCard<Content: View>: View {
    let title: String
    let icon: String
    var hint: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: .ckMD) {
            // Section header
            HStack(spacing: .ckSM) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ckAccent)
                Text(title)
                    .font(.ckHeadline)
            }

            // Content with table border
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(Color.ckBackground)
            .clipShape(RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM))
            .overlay(
                RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM)
                    .stroke(Color.ckBorder, lineWidth: 1)
            )

            // Hint text outside table
            if let hint {
                Text(hint)
                    .font(.ckFootnote)
                    .foregroundStyle(Color.ckMutedForeground)
                    .padding(.horizontal, .ckMD)
            }
        }
        .ckCard()
    }
}

// MARK: - Language Picker Row

private struct LanguagePickerRow: View {
    @State private var lang = LanguageManager.shared

    var body: some View {
        HStack {
            Text("settings.language".localized())
                .font(.ckBody)
                .foregroundStyle(Color.ckForeground)
            Spacer()
            Picker("", selection: Binding(
                get: { lang.currentLanguage },
                set: { lang.currentLanguage = $0 }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 120)
            .foregroundStyle(Color.ckForeground)
        }
        .padding(.horizontal, .ckMD)
        .padding(.vertical, .ckSM)
        .frame(minHeight: 44)
    }
}

// MARK: - Appearance Picker Row

private struct AppearancePickerRow: View {
    @State private var appearanceManager = AppearanceManager.shared

    var body: some View {
        HStack {
            Text("settings.appearance".localized())
                .font(.ckBody)
                .foregroundStyle(Color.ckForeground)
            Spacer()
            Picker("", selection: Binding(
                get: { appearanceManager.appearanceMode },
                set: { appearanceManager.appearanceMode = $0 }
            )) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.localizationKey.localized()).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 120)
            .foregroundStyle(Color.ckForeground)
        }
        .padding(.horizontal, .ckMD)
        .padding(.vertical, .ckSM)
        .frame(minHeight: 44)
    }
}

// MARK: - App Mode Section Content

private struct AppModeSectionContent: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var modeManager = AppModeManager.shared
    @State private var showModeChangeConfirmation = false
    @State private var pendingMode: AppMode?

    var body: some View {
        VStack(spacing: .ckSM) {
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
        .padding(.horizontal, .ckMD)
        .padding(.vertical, .ckSM)
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

        if modeManager.isFullMode, mode == .quotaOnly {
            pendingMode = mode
            showModeChangeConfirmation = true
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

// MARK: - App Mode Card

private struct AppModeCard: View {
    let mode: AppMode
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Radio button indicator
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.ckAccent : Color.ckBorder)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.ckBodyMedium)
                        .foregroundStyle(Color.ckForeground)

                    Text(mode.description)
                        .font(.ckCaption)
                        .foregroundStyle(Color.ckMutedForeground)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.ckMD)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.ckAccent : Color.ckBorder, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .ckCursorPointer()
        .animation(.ckStandard, value: isHovered)
        .animation(.ckStandard, value: isSelected)
    }
}

// MARK: - Notification Settings Content

private struct NotificationSettingsContent: View {
    @State private var notificationManager = NotificationManager.shared

    var body: some View {
        CKSettingsToggleRow(
            title: "settings.notifications.enabled".localized(),
            isOn: Binding(
                get: { notificationManager.notificationsEnabled },
                set: { notificationManager.notificationsEnabled = $0 }
            )
        )

        if notificationManager.notificationsEnabled {
            Divider()
                .padding(.horizontal, .ckMD)

            CKSettingsToggleRow(
                title: "settings.notifications.quotaLow".localized(),
                isOn: Binding(
                    get: { notificationManager.notifyOnQuotaLow },
                    set: { notificationManager.notifyOnQuotaLow = $0 }
                )
            )

            Divider()
                .padding(.horizontal, .ckMD)

            CKSettingsToggleRow(
                title: "settings.notifications.cooling".localized(),
                isOn: Binding(
                    get: { notificationManager.notifyOnCooling },
                    set: { notificationManager.notifyOnCooling = $0 }
                )
            )

            Divider()
                .padding(.horizontal, .ckMD)

            CKSettingsToggleRow(
                title: "settings.notifications.proxyCrash".localized(),
                isOn: Binding(
                    get: { notificationManager.notifyOnProxyCrash },
                    set: { notificationManager.notifyOnProxyCrash = $0 }
                )
            )

            Divider()
                .padding(.horizontal, .ckMD)

            CKSettingsRow(title: "settings.notifications.threshold".localized()) {
                Picker("", selection: Binding(
                    get: { Int(notificationManager.quotaAlertThreshold) },
                    set: { notificationManager.quotaAlertThreshold = Double($0) }
                )) {
                    Text("10%").tag(10)
                    Text("20%").tag(20)
                    Text("30%").tag(30)
                    Text("50%").tag(50)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .foregroundStyle(Color.ckForeground)
            }
        }

        if !notificationManager.isAuthorized {
            Divider()
                .padding(.horizontal, .ckMD)

            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("settings.notifications.notAuthorized".localized())
                    .font(.ckFootnote)
                    .foregroundStyle(Color.ckMutedForeground)
            }
            .padding(.horizontal, .ckMD)
            .padding(.vertical, .ckSM)
        }
    }
}

// MARK: - Quota Display Content

private struct QuotaDisplayContent: View {
    @State private var settings = MenuBarSettingsManager.shared

    var body: some View {
        Picker("", selection: Binding(
            get: { settings.quotaDisplayMode },
            set: { settings.quotaDisplayMode = $0 }
        )) {
            Text("settings.quota.displayMode.used".localized()).tag(QuotaDisplayMode.used)
            Text("settings.quota.displayMode.remaining".localized()).tag(QuotaDisplayMode.remaining)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, .ckMD)
        .padding(.vertical, .ckSM)
    }
}

// MARK: - Menu Bar Settings Content

private struct MenuBarSettingsContent: View {
    @State private var settings = MenuBarSettingsManager.shared

    var body: some View {
        CKSettingsToggleRow(
            title: "settings.menubar.showIcon".localized(),
            isOn: Binding(
                get: { settings.showMenuBarIcon },
                set: { settings.showMenuBarIcon = $0 }
            )
        )

        if settings.showMenuBarIcon {
            Divider()
                .padding(.horizontal, .ckMD)

            CKSettingsToggleRow(
                title: "settings.menubar.showQuota".localized(),
                isOn: Binding(
                    get: { settings.showQuotaInMenuBar },
                    set: { settings.showQuotaInMenuBar = $0 }
                )
            )

            if settings.showQuotaInMenuBar {
                Divider()
                    .padding(.horizontal, .ckMD)

                CKSettingsRow(title: "settings.menubar.colorMode".localized()) {
                    Picker("", selection: Binding(
                        get: { settings.colorMode },
                        set: { settings.colorMode = $0 }
                    )) {
                        Text("settings.menubar.colored".localized()).tag(MenuBarColorMode.colored)
                        Text("settings.menubar.monochrome".localized()).tag(MenuBarColorMode.monochrome)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
        }
    }
}

// MARK: - Update Settings Content

private struct UpdateSettingsContent: View {
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true

    #if canImport(Sparkle)
        private let updaterService = UpdaterService.shared
    #endif

    var body: some View {
        #if canImport(Sparkle)
            CKSettingsToggleRow(
                title: "settings.autoCheckUpdates".localized(),
                isOn: $autoCheckUpdates
            )
            .onChange(of: autoCheckUpdates) { _, newValue in
                updaterService.automaticallyChecksForUpdates = newValue
            }

            Divider()
                .padding(.horizontal, .ckMD)

            CKSettingsRow(title: "settings.lastChecked".localized()) {
                if let date = updaterService.lastUpdateCheckDate {
                    Text(date, style: .relative)
                        .font(.ckBody)
                        .foregroundStyle(Color.ckMutedForeground)
                } else {
                    Text("settings.never".localized())
                        .font(.ckBody)
                        .foregroundStyle(Color.ckMutedForeground)
                }
            }

            Button("settings.checkNow".localized()) {
                updaterService.checkForUpdates()
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.ckAccent)
            .disabled(!updaterService.canCheckForUpdates)
            .padding(.horizontal, .ckMD)
            .padding(.vertical, .ckSM)
        #else
            CKSettingsRow(
                title: "settings.version".localized(),
                value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            )
        #endif
    }
}

// MARK: - Paths Content

private struct PathsContent: View {
    @Environment(QuotaViewModel.self) private var viewModel

    var body: some View {
        PathRow(title: "settings.binary".localized(), path: viewModel.proxyManager.binaryPath)

        Divider()
            .padding(.horizontal, .ckMD)

        PathRow(title: "settings.config".localized(), path: viewModel.proxyManager.configPath)

        Divider()
            .padding(.horizontal, .ckMD)

        PathRow(title: "settings.authDir".localized(), path: viewModel.proxyManager.authDir)
    }
}

// MARK: - Path Row

private struct PathRow: View {
    let title: String
    let path: String

    var body: some View {
        CKSettingsRow(title: title) {
            HStack {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Color.ckMutedForeground)
                    .textSelection(.enabled)

                Button {
                    NSWorkspace.shared.selectFile(
                        nil,
                        inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent
                    )
                } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.ckAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reveal in Finder")
                .ckTouchTarget()
                .ckCursorPointer()
            }
        }
    }
}

// MARK: - API Keys Content

private struct APIKeysContent: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var newAPIKey: String = ""
    @State private var editingKeyIndex: Int? = nil
    @State private var editedKeyValue: String = ""
    @State private var showingAddKey: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(viewModel.apiKeys.enumerated()), id: \.offset) { index, key in
                if index > 0 {
                    Divider()
                        .padding(.horizontal, .ckMD)
                }
                apiKeyRow(key: key, index: index)
            }

            if showingAddKey {
                if !viewModel.apiKeys.isEmpty {
                    Divider()
                        .padding(.horizontal, .ckMD)
                }
                addKeyRow
            }

            if viewModel.apiKeys.isEmpty, !showingAddKey {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "key.slash")
                            .font(.title2)
                            .foregroundStyle(Color.ckMutedForeground)
                        Text("apiKeys.empty".localized())
                            .font(.ckCaption)
                            .foregroundStyle(Color.ckMutedForeground)
                    }
                    Spacer()
                }
                .padding(.horizontal, .ckMD)
                .padding(.vertical, .ckMD)
            }

            Divider()
                .padding(.horizontal, .ckMD)

            HStack(spacing: .ckMD) {
                Button {
                    newAPIKey = generateRandomKey()
                    showingAddKey = true
                } label: {
                    Label("apiKeys.generate".localized(), systemImage: "wand.and.stars")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ckAccent)
                .ckCursorPointer()

                Button {
                    showingAddKey = true
                } label: {
                    Label("apiKeys.add".localized(), systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ckAccent)
                .ckCursorPointer()
            }
            .padding(.horizontal, .ckMD)
            .padding(.vertical, .ckSM)
        }
    }

    @ViewBuilder
    private func apiKeyRow(key: String, index: Int) -> some View {
        HStack {
            if editingKeyIndex == index {
                TextField("apiKeys.placeholder".localized(), text: $editedKeyValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { saveEdit(oldKey: key) }

                Button { saveEdit(oldKey: key) } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .ckCursorPointer()

                Button { cancelEdit() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.ckMutedForeground)
                }
                .buttonStyle(.plain)
                .ckCursorPointer()
            } else {
                Text(maskedKey(key))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Color.ckForeground)

                Spacer()

                Button { copyToClipboard(key) } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(Color.ckAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy API key to clipboard")
                .ckTouchTarget()
                .ckCursorPointer()

                Button {
                    editingKeyIndex = index
                    editedKeyValue = key
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(Color.ckAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit API key")
                .ckTouchTarget()
                .ckCursorPointer()

                Button {
                    Task { await viewModel.deleteAPIKey(key) }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.ckDestructive)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete API key")
                .ckTouchTarget()
                .ckCursorPointer()
            }
        }
        .padding(.horizontal, .ckMD)
        .padding(.vertical, .ckSM)
        .frame(minHeight: 44)
    }

    private var addKeyRow: some View {
        HStack {
            TextField("apiKeys.placeholder".localized(), text: $newAPIKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(addNewKey)

            Button { newAPIKey = generateRandomKey() } label: {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Color.ckAccent)
            }
            .buttonStyle(.plain)
            .ckCursorPointer()

            Button(action: addNewKey) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .disabled(newAPIKey.trimmingCharacters(in: .whitespaces).isEmpty)
            .ckCursorPointer()

            Button {
                showingAddKey = false
                newAPIKey = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.ckMutedForeground)
            }
            .buttonStyle(.plain)
            .ckCursorPointer()
        }
        .padding(.horizontal, .ckMD)
        .padding(.vertical, .ckSM)
        .frame(minHeight: 44)
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        let prefix = String(key.prefix(6))
        let suffix = String(key.suffix(4))
        return "\(prefix)••••••••\(suffix)"
    }

    private func addNewKey() {
        let trimmed = newAPIKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            await viewModel.addAPIKey(trimmed)
            newAPIKey = ""
            showingAddKey = false
        }
    }

    private func saveEdit(oldKey: String) {
        Task {
            await viewModel.updateAPIKey(old: oldKey, new: editedKeyValue)
            editingKeyIndex = nil
            editedKeyValue = ""
        }
    }

    private func cancelEdit() {
        editingKeyIndex = nil
        editedKeyValue = ""
    }

    private func generateRandomKey() -> String {
        let prefix = "sk-"
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let randomPart = String((0 ..< 32).map { _ in characters.randomElement()! })
        return prefix + randomPart
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Logs Content

private struct LogsContent: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var filterLevel: LogEntry.LogLevel? = nil

    private var filteredLogs: [LogEntry] {
        guard let level = filterLevel else { return viewModel.logs }
        return viewModel.logs.filter { $0.level == level }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !viewModel.proxyManager.proxyStatus.running {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.title2)
                            .foregroundStyle(Color.ckMutedForeground)
                        Text("logs.startProxy".localized())
                            .font(.ckCaption)
                            .foregroundStyle(Color.ckMutedForeground)
                    }
                    Spacer()
                }
                .padding(.horizontal, .ckMD)
                .padding(.vertical, .ckMD)
            } else if filteredLogs.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.title2)
                            .foregroundStyle(Color.ckMutedForeground)
                        Text("logs.logsWillAppear".localized())
                            .font(.ckCaption)
                            .foregroundStyle(Color.ckMutedForeground)
                    }
                    Spacer()
                }
                .padding(.horizontal, .ckMD)
                .padding(.vertical, .ckMD)
            } else {
                ForEach(filteredLogs.suffix(20)) { entry in
                    logRow(entry)
                        .padding(.horizontal, .ckMD)
                        .padding(.vertical, .ckXS)
                }
            }

            Divider()
                .padding(.horizontal, .ckMD)

            HStack {
                Picker("Filter", selection: $filterLevel) {
                    Text("logs.all".localized()).tag(nil as LogEntry.LogLevel?)
                    Divider()
                    Text("logs.info".localized()).tag(LogEntry.LogLevel.info as LogEntry.LogLevel?)
                    Text("logs.warn".localized()).tag(LogEntry.LogLevel.warn as LogEntry.LogLevel?)
                    Text("logs.error".localized()).tag(LogEntry.LogLevel.error as LogEntry.LogLevel?)
                }
                .pickerStyle(.menu)
                .frame(width: 100)
                .foregroundStyle(Color.ckForeground)

                Spacer()

                Button {
                    Task { await viewModel.refreshLogs() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Color.ckAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh logs")
                .ckTouchTarget()
                .ckCursorPointer()

                Button(role: .destructive) {
                    Task { await viewModel.clearLogs() }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.ckDestructive)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear all logs")
                .ckTouchTarget()
                .ckCursorPointer()
            }
            .padding(.horizontal, .ckMD)
            .padding(.vertical, .ckSM)
        }
        .task {
            while !Task.isCancelled {
                await viewModel.refreshLogs()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    @ViewBuilder
    private func logRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp, style: .time)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.ckMutedForeground)
                .frame(width: 60, alignment: .leading)

            Text(entry.level.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(entry.level.color)
                .clipShape(RoundedRectangle(cornerRadius: 3))

            Text(entry.message)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.ckForeground)
                .lineLimit(2)
        }
    }
}

// MARK: - About Screen

struct AboutScreen: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // App Icon and Title
                VStack(spacing: 16) {
                    if let appIcon = NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 128, height: 128)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                    }

                    VStack(spacing: 8) {
                        Text("CKota")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("about.tagline".localized())
                            .font(.title3)
                            .foregroundStyle(Color.ckMutedForeground)

                        Text("Version \(appVersion) (\(buildNumber))")
                            .font(.ckCaption)
                            .foregroundStyle(Color.ckMutedForeground.opacity(0.7))
                    }
                }
                .padding(.top, 40)

                // Description
                Text("about.description".localized())
                    .font(.ckBody)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.ckMutedForeground)
                    .frame(maxWidth: 500)
                    .padding(.horizontal)

                // Feature Badges
                HStack(spacing: 16) {
                    FeatureBadge(
                        icon: "person.2.fill",
                        title: "about.multiAccount".localized(),
                        color: .blue
                    )

                    FeatureBadge(
                        icon: "chart.bar.fill",
                        title: "about.quotaTracking".localized(),
                        color: .green
                    )

                    FeatureBadge(
                        icon: "terminal.fill",
                        title: "about.agentConfig".localized(),
                        color: .purple
                    )
                }
                .padding(.vertical, 8)

                Divider()
                    .frame(maxWidth: 400)

                // Links
                VStack(spacing: 12) {
                    Link(destination: URL(string: "https://github.com/Csynnh/CKota")!) {
                        HStack {
                            Image(systemName: "link")
                            Text("GitHub: CKota")
                        }
                        .frame(width: 200)
                    }
                    .buttonStyle(.bordered)
                    .ckCursorPointer()

                    Link(destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!) {
                        HStack {
                            Image(systemName: "link")
                            Text("GitHub: CLIProxyAPI")
                        }
                        .frame(width: 200)
                    }
                    .buttonStyle(.bordered)
                    .ckCursorPointer()
                }

                Spacer(minLength: 40)

                // Credits
                Text("about.madeWith".localized())
                    .font(.ckFootnote)
                    .foregroundStyle(Color.ckMutedForeground)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.ckBackground)
        .navigationTitle("nav.about".localized())
    }
}

// MARK: - Feature Badge

struct FeatureBadge: View {
    let icon: String
    let title: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(title)
                .font(.ckCaption)
                .fontWeight(.medium)
                .foregroundStyle(Color.ckForeground)
        }
        .frame(width: 100)
    }
}
