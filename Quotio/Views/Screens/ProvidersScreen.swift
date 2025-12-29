//
//  ProvidersScreen.swift
//  Quotio
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProvidersScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var isImporterPresented = false
    @State private var selectedProvider: AIProvider?
    @State private var projectId: String = ""
    @State private var showProxyRequiredAlert = false
    private let modeManager = AppModeManager.shared
    
    /// Check if we should show content
    private var shouldShowContent: Bool {
        if modeManager.isQuotaOnlyMode {
            return true // Always show in quota-only mode
        }
        return viewModel.proxyManager.proxyStatus.running
    }
    
    var body: some View {
        List {
            if modeManager.isQuotaOnlyMode {
                // Quota-only mode: Show direct auth files and add providers
                quotaOnlyContent
            } else {
                // Full mode: Show all content (works with or without proxy)
                fullModeContent
            }
        }
        .navigationTitle(modeManager.isQuotaOnlyMode ? "nav.accounts".localized() : "nav.providers".localized())
        .sheet(item: $selectedProvider) { provider in
            OAuthSheet(provider: provider, projectId: $projectId) {
                selectedProvider = nil
                projectId = ""
                viewModel.oauthState = nil
            }
            .environment(viewModel)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        await viewModel.importVertexServiceAccount(url: url)
                    }
                }
            case .failure(let error):
                print("Import failed: \(error.localizedDescription)")
            }
        }
        .task {
            if modeManager.isQuotaOnlyMode {
                await viewModel.loadDirectAuthFiles()
            } else {
                await viewModel.loadDirectAuthFiles()
            }
        }
        .alert("providers.proxyRequired.title".localized(), isPresented: $showProxyRequiredAlert) {
            Button("action.startProxy".localized()) {
                Task { await viewModel.startProxy() }
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("providers.proxyRequired.message".localized())
        }
    }
    
    // MARK: - Full Mode Content
    
    private var autoDetectedProviderAccounts: [(provider: AIProvider, accountKey: String)] {
        var accounts: [(provider: AIProvider, accountKey: String)] = []
        for (provider, quotas) in viewModel.providerQuotas {
            if !provider.supportsManualAuth {
                for (accountKey, _) in quotas {
                    accounts.append((provider: provider, accountKey: accountKey))
                }
            }
        }
        return accounts
    }
    
    @ViewBuilder
    private var fullModeContent: some View {
        // Connected Accounts section
        if viewModel.proxyManager.proxyStatus.running {
            // Proxy running: Show from API with full status info
            Section {
                if viewModel.authFiles.isEmpty {
                    Text("providers.noAccountsYet".localized())
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.authFiles, id: \.id) { file in
                        AuthFileRow(file: file) {
                            Task { await viewModel.deleteAuthFile(file) }
                        }
                    }
                }
            } header: {
                Label("providers.connectedAccounts".localized() + " (\(viewModel.authFiles.count))", systemImage: "checkmark.seal.fill")
            } footer: {
                if !viewModel.authFiles.isEmpty {
                    MenuBarHintView()
                }
            }
        } else {
            // Proxy not running: Show from direct auth files on disk
            Section {
                if viewModel.directAuthFiles.isEmpty {
                    Text("providers.noAccountsYet".localized())
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.directAuthFiles) { file in
                        DirectAuthFileRow(file: file)
                    }
                }
            } header: {
                HStack {
                    Label("providers.connectedAccounts".localized() + " (\(viewModel.directAuthFiles.count))", systemImage: "checkmark.seal.fill")
                    
                    Spacer()
                    
                    Button {
                        Task { await viewModel.loadDirectAuthFiles() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            } footer: {
                if !viewModel.directAuthFiles.isEmpty {
                    MenuBarHintView()
                }
            }
        }
        
        // Auto-detected Accounts (like Cursor, Trae, Claude) - always show
        if !autoDetectedProviderAccounts.isEmpty {
            Section {
                ForEach(autoDetectedProviderAccounts, id: \.accountKey) { account in
                    AutoDetectedAccountRow(provider: account.provider, accountKey: account.accountKey)
                }
            } header: {
                HStack {
                    Label("providers.autoDetected".localized() + " (\(autoDetectedProviderAccounts.count))", systemImage: "sparkle.magnifyingglass")
                    
                    Spacer()
                    
                    Button {
                        Task { 
                            await viewModel.refreshAutoDetectedProviders()
                        }
                    } label: {
                        if viewModel.isLoadingQuotas {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isLoadingQuotas)
                }
            } footer: {
                MenuBarHintView()
            }
        }
        
        // Add Provider
        addProviderSection
    }
    
    // MARK: - Quota-Only Mode Content
    
    @ViewBuilder
    private var quotaOnlyContent: some View {
        // Tracked Accounts (from direct auth files)
        Section {
            if viewModel.directAuthFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    
                    Text("providers.noAccountsFound".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("providers.quotaOnlyHint".localized())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(viewModel.directAuthFiles) { file in
                    DirectAuthFileRow(file: file)
                }
            }
        } header: {
            HStack {
                Label("providers.trackedAccounts".localized() + " (\(viewModel.directAuthFiles.count))", systemImage: "person.2.badge.key")
                
                Spacer()
                
                Button {
                    Task { await viewModel.loadDirectAuthFiles() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            if !viewModel.directAuthFiles.isEmpty {
                MenuBarHintView()
            }
        }
        
        // Add Provider (for OAuth)
        addProviderSection
    }
    
    // MARK: - Add Provider Section
    
    /// Providers that can be added manually (excludes quota-tracking-only providers like Cursor)
    private var addableProviders: [AIProvider] {
        if modeManager.isFullMode {
            // In Full Mode, only show providers that support manual auth
            return AIProvider.allCases.filter { $0.supportsManualAuth }
        } else {
            // In Quota-Only mode, show providers that support quota tracking AND can be added manually
            // Cursor is auto-detected from local database, so it shouldn't be in "Add Provider"
            return AIProvider.allCases.filter { $0.supportsQuotaOnlyMode && $0.supportsManualAuth }
        }
    }
    
    private var addProviderSection: some View {
        Section {
            ForEach(addableProviders) { provider in
                Button {
                    // In Full Mode, require proxy to be running for OAuth
                    if modeManager.isFullMode && !viewModel.proxyManager.proxyStatus.running {
                        showProxyRequiredAlert = true
                        return
                    }
                    
                    if provider == .vertex {
                        isImporterPresented = true
                    } else {
                        viewModel.oauthState = nil
                        selectedProvider = provider
                    }
                } label: {
                    HStack {
                        ProviderIcon(provider: provider, size: 24)
                        
                        Text(provider.displayName)
                        
                        Spacer()
                        
                        if modeManager.isFullMode,
                           let count = viewModel.authFilesByProvider[provider]?.count, count > 0 {
                            Text("\(count)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(provider.color.opacity(0.15))
                                .foregroundStyle(provider.color)
                                .clipShape(Capsule())
                        } else if modeManager.isQuotaOnlyMode {
                            let count = viewModel.directAuthFiles.filter { $0.provider == provider }.count
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(provider.color.opacity(0.15))
                                    .foregroundStyle(provider.color)
                                    .clipShape(Capsule())
                            }
                        }
                        
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Label("providers.addProvider".localized(), systemImage: "plus.circle.fill")
        }
    }
}

// MARK: - Direct Auth File Row (for Quota-Only Mode)

struct DirectAuthFileRow: View {
    let file: DirectAuthFile
    @State private var settings = MenuBarSettingsManager.shared
    @State private var showWarning = false
    
    private var menuBarItem: MenuBarQuotaItem {
        MenuBarQuotaItem(provider: file.provider.rawValue, accountKey: file.email ?? file.filename)
    }
    
    private var isSelected: Bool {
        settings.isSelected(menuBarItem)
    }
    
    private func handleToggle() {
        if isSelected {
            settings.toggleItem(menuBarItem)
        } else if settings.shouldWarnOnAdd {
            showWarning = true
        } else {
            settings.toggleItem(menuBarItem)
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ProviderIcon(provider: file.provider, size: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(file.email ?? file.filename)
                    .fontWeight(.medium)
                
                HStack(spacing: 6) {
                    Text(file.provider.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    Text(file.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            MenuBarBadge(
                isSelected: isSelected,
                onTap: handleToggle
            )
        }
        .contextMenu {
            Button {
                handleToggle()
            } label: {
                if isSelected {
                    Label("menubar.hideFromMenuBar".localized(), systemImage: "chart.bar")
                } else {
                    Label("menubar.showOnMenuBar".localized(), systemImage: "chart.bar.fill")
                }
            }
        }
        .alert("menubar.warning.title".localized(), isPresented: $showWarning) {
            Button("menubar.warning.confirm".localized()) {
                settings.toggleItem(menuBarItem)
            }
            Button("menubar.warning.cancel".localized(), role: .cancel) {}
        } message: {
            Text("menubar.warning.message".localized())
        }
    }
}

// MARK: - Auth File Row

struct AuthFileRow: View {
    let file: AuthFile
    let onDelete: () -> Void
    @State private var settings = MenuBarSettingsManager.shared
    @State private var showWarning = false
    
    private var menuBarItem: MenuBarQuotaItem? {
        guard let provider = file.providerType else { return nil }
        let accountKey = file.quotaLookupKey.isEmpty ? file.name : file.quotaLookupKey
        return MenuBarQuotaItem(provider: provider.rawValue, accountKey: accountKey)
    }
    
    private var isSelected: Bool {
        guard let item = menuBarItem else { return false }
        return settings.isSelected(item)
    }
    
    private func handleToggle() {
        guard let item = menuBarItem else { return }
        if isSelected {
            settings.toggleItem(item)
        } else if settings.shouldWarnOnAdd {
            showWarning = true
        } else {
            settings.toggleItem(item)
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            if let provider = file.providerType {
                ProviderIcon(provider: provider, size: 24)
            } else {
                Image(systemName: "questionmark.circle")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(file.email ?? file.name)
                    .fontWeight(.medium)
                
                HStack(spacing: 6) {
                    Text(file.providerType?.displayName ?? "[\(file.provider)]")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Circle()
                        .fill(file.statusColor)
                        .frame(width: 6, height: 6)
                    
                    Text(file.status)
                        .font(.caption)
                        .foregroundStyle(file.statusColor)
                }
            }
            
            Spacer()
            
            if file.disabled {
                Text("providers.disabled".localized())
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }
            
            if menuBarItem != nil {
                MenuBarBadge(
                    isSelected: isSelected,
                    onTap: handleToggle
                )
            }
            
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("action.delete".localized())
        }
        .contextMenu {
            if menuBarItem != nil {
                Button {
                    handleToggle()
                } label: {
                    if isSelected {
                        Label("menubar.hideFromMenuBar".localized(), systemImage: "chart.bar")
                    } else {
                        Label("menubar.showOnMenuBar".localized(), systemImage: "chart.bar.fill")
                    }
                }
                
                Divider()
            }
            
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("action.delete".localized(), systemImage: "trash")
            }
        }
        .alert("menubar.warning.title".localized(), isPresented: $showWarning) {
            Button("menubar.warning.confirm".localized()) {
                if let item = menuBarItem {
                    settings.toggleItem(item)
                }
            }
            Button("menubar.warning.cancel".localized(), role: .cancel) {}
        } message: {
            Text("menubar.warning.message".localized())
        }
    }
}

// MARK: - Auto-detected Account Row (for Cursor, etc.)

struct AutoDetectedAccountRow: View {
    let provider: AIProvider
    let accountKey: String
    @State private var settings = MenuBarSettingsManager.shared
    @State private var showWarning = false
    
    private var menuBarItem: MenuBarQuotaItem {
        MenuBarQuotaItem(provider: provider.rawValue, accountKey: accountKey)
    }
    
    private var isSelected: Bool {
        settings.isSelected(menuBarItem)
    }
    
    private func handleToggle() {
        if isSelected {
            settings.toggleItem(menuBarItem)
        } else if settings.shouldWarnOnAdd {
            showWarning = true
        } else {
            settings.toggleItem(menuBarItem)
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ProviderIcon(provider: provider, size: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(accountKey)
                    .fontWeight(.medium)
                
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    Text("providers.autoDetected".localized())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            
            Spacer()
            
            MenuBarBadge(
                isSelected: isSelected,
                onTap: handleToggle
            )
        }
        .contextMenu {
            Button {
                handleToggle()
            } label: {
                if isSelected {
                    Label("menubar.hideFromMenuBar".localized(), systemImage: "chart.bar")
                } else {
                    Label("menubar.showOnMenuBar".localized(), systemImage: "chart.bar.fill")
                }
            }
        }
        .alert("menubar.warning.title".localized(), isPresented: $showWarning) {
            Button("menubar.warning.confirm".localized()) {
                settings.toggleItem(menuBarItem)
            }
            Button("menubar.warning.cancel".localized(), role: .cancel) {}
        } message: {
            Text("menubar.warning.message".localized())
        }
    }
}

// MARK: - Menu Bar Badge Component

struct MenuBarBadge: View {
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
                    .frame(width: 28, height: 28)
                
                Image(systemName: isSelected ? "chart.bar.fill" : "chart.bar")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                showTooltip = true
            } else {
                showTooltip = false
            }
        }
        .popover(isPresented: $showTooltip, arrowEdge: .bottom) {
            Text(isSelected ? "menubar.hideFromMenuBar".localized() : "menubar.showOnMenuBar".localized())
                .font(.caption)
                .padding(8)
        }
    }
    
    @State private var showTooltip = false
}

// MARK: - Menu Bar Hint View

struct MenuBarHintView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(.blue)
                .font(.caption2)
            Text("menubar.hint".localized())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - OAuth Sheet

struct OAuthSheet: View {
    @Environment(QuotaViewModel.self) private var viewModel
    let provider: AIProvider
    @Binding var projectId: String
    let onDismiss: () -> Void
    
    @State private var hasStartedAuth = false
    @State private var selectedKiroMethod: AuthCommand = .kiroGoogleLogin
    
    private var isPolling: Bool {
        viewModel.oauthState?.status == .polling || viewModel.oauthState?.status == .waiting
    }
    
    private var isSuccess: Bool {
        viewModel.oauthState?.status == .success
    }
    
    private var isError: Bool {
        viewModel.oauthState?.status == .error
    }
    
    private var kiroAuthMethods: [AuthCommand] {
        [.kiroGoogleLogin, .kiroAWSAuthCode, .kiroAWSLogin, .kiroImport]
    }
    
    var body: some View {
        VStack(spacing: 28) {
            ProviderIcon(provider: provider, size: 64)
            
            VStack(spacing: 8) {
                Text("oauth.connect".localized() + " " + provider.displayName)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("oauth.authenticateWith".localized() + " " + provider.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            if provider == .gemini {
                VStack(alignment: .leading, spacing: 6) {
                    Text("oauth.projectId".localized())
                        .font(.subheadline)
                        .fontWeight(.medium)
                    TextField("oauth.projectIdPlaceholder".localized(), text: $projectId)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: 320)
            }
            
            if provider == .kiro {
                VStack(alignment: .leading, spacing: 6) {
                    Text("oauth.authMethod".localized())
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Picker("", selection: $selectedKiroMethod) {
                        ForEach(kiroAuthMethods, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                .frame(maxWidth: 320)
            }
            
            if let state = viewModel.oauthState, state.provider == provider {
                OAuthStatusView(status: state.status, error: state.error, state: state.state, provider: provider)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
            
            HStack(spacing: 16) {
                Button("action.cancel".localized(), role: .cancel) {
                    viewModel.cancelOAuth()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                
                if isError {
                    Button {
                        hasStartedAuth = false
                        Task {
                            await viewModel.startOAuth(for: provider, projectId: projectId.isEmpty ? nil : projectId, authMethod: provider == .kiro ? selectedKiroMethod : nil)
                        }
                    } label: {
                        Label("oauth.retry".localized(), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                } else if !isSuccess {
                    Button {
                        hasStartedAuth = true
                        Task {
                            await viewModel.startOAuth(for: provider, projectId: projectId.isEmpty ? nil : projectId, authMethod: provider == .kiro ? selectedKiroMethod : nil)
                        }
                    } label: {
                        if isPolling {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("oauth.authenticate".localized(), systemImage: "key.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(provider.color)
                    .disabled(isPolling)
                }
            }
        }
        .padding(40)
        .frame(width: 480, height: 400)
        .animation(.easeInOut(duration: 0.2), value: viewModel.oauthState?.status)
        .onChange(of: viewModel.oauthState?.status) { _, newStatus in
            if newStatus == .success {
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    onDismiss()
                }
            }
        }
    }
}

private struct OAuthStatusView: View {
    let status: OAuthState.OAuthStatus
    let error: String?
    let state: String?
    let provider: AIProvider
    
    var body: some View {
        Group {
            switch status {
            case .waiting:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("oauth.openingBrowser".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                
            case .polling:
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(provider.color.opacity(0.2), lineWidth: 4)
                            .frame(width: 60, height: 60)
                        
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(provider.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 60, height: 60)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: UUID())
                        
                        Image(systemName: "person.badge.key.fill")
                            .font(.title2)
                            .foregroundStyle(provider.color)
                    }
                    
                    // For Copilot Device Code flow, show device code with copy button
                    if provider == .copilot, let deviceCode = state, !deviceCode.isEmpty {
                        VStack(spacing: 8) {
                            Text("oauth.enterCodeInBrowser".localized())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            
                            HStack(spacing: 12) {
                                Text(deviceCode)
                                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                                    .foregroundStyle(provider.color)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(provider.color.opacity(0.1))
                                    .cornerRadius(8)
                                
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(deviceCode, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.title3)
                                }
                                .buttonStyle(.borderless)
                                .help("action.copyCode".localized())
                            }
                            
                            Text("oauth.waitingForAuth".localized())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if provider == .copilot, let message = error {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 350)
                    } else {
                        Text("oauth.waitingForAuth".localized())
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Text("oauth.completeBrowser".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 16)
                
            case .success:
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    
                    Text("oauth.success".localized())
                        .font(.headline)
                        .foregroundStyle(.green)
                    
                    Text("oauth.closingSheet".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
                
            case .error:
                VStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    
                    Text("oauth.failed".localized())
                        .font(.headline)
                        .foregroundStyle(.red)
                    
                    if let error = error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                }
                .padding(.vertical, 16)
            }
        }
        .frame(height: 120)
    }
}
