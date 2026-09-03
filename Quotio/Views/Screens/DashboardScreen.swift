//
//  DashboardScreen.swift
//  Quotio
//

import QuotioDomain
import QuotioPresentation
import SwiftUI
import UniformTypeIdentifiers

struct DashboardScreen: View {
    @Environment(ProxyManagementScreenModel.self) private var proxyManagement
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(AccountsScreenModel.self) private var accounts
    @Environment(DashboardScreenModel.self) private var dashboard
    @Environment(QuotaFeatureController.self) private var quotaController
    @Environment(OperatingModeManager.self) private var modeManager
    @Environment(SettingsScreenModel.self) private var settingsModel
    @Environment(PasteboardAdapter.self) private var pasteboard

    @State private var selectedProvider: AIProvider?
    @State private var isImporterPresented = false
    @State private var selectedAgentForConfig: CLIAgent?
    @State private var sheetPresentationID = UUID()
    @State private var showTunnelSheet = false
    
    private var tunnel: TunnelScreenModel { proxyManagement.tunnel }
    
    private var showGettingStarted: Bool {
        guard !settingsModel.appShellPreferences.hideGettingStarted else { return false }
        guard modeManager.isLocalProxyMode else { return false }
        return !isSetupComplete
    }
    
    private var isSetupComplete: Bool {
        proxyManagement.proxy.isBinaryInstalled &&
        proxyManagement.proxy.proxyStatus.running &&
        !proxyManagement.authFiles.isEmpty &&
        proxyManagement.agentSetup.agentStatuses.contains(where: { $0.configured })
    }
    
    /// Check if we should show main content
    private var shouldShowContent: Bool {
        if modeManager.isMonitorMode {
            return true // Always show content in quota-only mode
        }
        return proxyManagement.proxy.proxyStatus.running
    }
    
    // MARK: - Precomputed Properties (performance optimization)
    
    /// Unique provider count from direct auth files
    private var directProvidersCount: Int {
        dashboard.connectedProviderCount
    }
    
    /// Lowest quota percentage across all providers using total usage logic
    private var lowestQuotaPercentage: Double {
        dashboard.lowestQuotaPercentage
    }
    
    /// Grouped accounts by provider (cached computation)
    private var groupedMonitorAccounts: [AIProvider: [MonitorAccount]] {
        Dictionary(grouping: accounts.accounts) { $0.provider }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if modeManager.isLocalProxyMode {
                    if !proxyManagement.proxy.isBinaryInstalled {
                        installBinarySection
                    } else if !proxyManagement.proxy.proxyStatus.running {
                        startProxySection
                    } else {
                        fullModeContent
                    }
                } else {
                    // Quota-Only Mode: Show quota dashboard
                    quotaOnlyModeContent
                }
            }
            .padding(24)
        }
        .navigationTitle("nav.dashboard".localized())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        if modeManager.isMonitorMode {
                            await quotaController.refreshAll(force: true)
                        } else if modeManager.isLocalProxyMode && proxyManagement.proxy.proxyStatus.running {
                            await proxyManagement.refreshData()
                        } else {
                            await quotaController.refreshAll(force: true)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(quota.isLoadingQuotas)
            }
        }
        .sheet(item: $selectedProvider) { provider in
            OAuthSheet(provider: provider) {
                selectedProvider = nil
                quotaController.cancelOAuth()
                Task {
                    if modeManager.isMonitorMode {
                        await quotaController.refreshAll(force: true)
                    } else {
                        await proxyManagement.refreshData()
                    }
                }
            }
        }
        .sheet(item: $selectedAgentForConfig) { (agent: CLIAgent) in
            AgentConfigSheet(viewModel: proxyManagement.agentSetup, agent: agent)
                .id(sheetPresentationID)
                .onDisappear {
                    proxyManagement.agentSetup.dismissConfiguration()
                    Task { await proxyManagement.agentSetup.refreshAgentStatuses() }
                }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    await proxyManagement.importVertexServiceAccount(url: url)
                    await proxyManagement.refreshData()
                }
            }
        }
        .task {
            if modeManager.isLocalProxyMode {
                await proxyManagement.agentSetup.refreshAgentStatuses()
            }
        }
    }
    
    // MARK: - Full Mode Content
    
    private var fullModeContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            if showGettingStarted {
                gettingStartedSection
            }
            
            kpiSection
            providerSection
            endpointSection
            AvailableModelsSection()
            tunnelSection
        }
    }
    
    // MARK: - Quota-Only Mode Content
    
    private var quotaOnlyModeContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Quota Overview KPIs
            quotaOnlyKPISection
            
            // Quick Quota Status
            quotaStatusSection
            
            // Tracked Accounts
            trackedAccountsSection
        }
    }
    
    private var quotaOnlyKPISection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
            KPICard(
                title: "dashboard.trackedAccounts".localized(),
                value: "\(dashboard.trackedAccountCount)",
                subtitle: "dashboard.accounts".localized(),
                icon: "person.2.fill",
                color: .blue
            )
            
            KPICard(
                title: "dashboard.providers".localized(),
                value: "\(directProvidersCount)",
                subtitle: "dashboard.connected".localized(),
                icon: "cpu",
                color: .green
            )
            
            // Show lowest quota percentage (precomputed)
            KPICard(
                title: "dashboard.lowestQuota".localized(),
                value: String(format: "%.0f%%", lowestQuotaPercentage),
                subtitle: "dashboard.remaining".localized(),
                icon: "chart.bar.fill",
                color: lowestQuotaPercentage > 50 ? .green : (lowestQuotaPercentage > 20 ? .orange : .red)
            )
            
            if let lastRefresh = dashboard.lastRefreshTime {
                KPICard(
                    title: "dashboard.lastRefresh".localized(),
                    value: lastRefresh.formatted(date: .omitted, time: .shortened),
                    subtitle: "dashboard.updated".localized(),
                    icon: "clock.fill",
                    color: .purple
                )
            }
        }
    }
    
    private var quotaStatusSection: some View {
        GroupBox {
            if quota.providerQuotas.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    
                    Text("dashboard.noQuotaData".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Button {
                        Task { await quotaController.refreshAll(force: true) }
                    } label: {
                        Label("action.refresh".localized(), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(quota.isLoadingQuotas)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Sort providers for stable iteration order (ForEach performance fix)
                    ForEach(quota.providerQuotas.keys.sorted { $0.displayName < $1.displayName }) { provider in
                        if let accounts = quota.providerQuotas[provider], !accounts.isEmpty {
                            QuotaProviderRow(provider: provider, accounts: accounts)
                        }
                    }
                }
            }
        } label: {
            HStack {
                Label("dashboard.quotaOverview".localized(), systemImage: "chart.bar.fill")
                
                Spacer()
                
                if quota.isLoadingQuotas {
                    SmallProgressView()
                }
            }
        }
    }
    
    private var trackedAccountsSection: some View {
        GroupBox {
            if accounts.accounts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    
                    Text("dashboard.noAccountsTracked".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Text("dashboard.addAccountsHint".localized())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AIProvider.allCases.filter { groupedMonitorAccounts[$0] != nil }) { provider in
                        if let accounts = groupedMonitorAccounts[provider] {
                            HStack(spacing: 12) {
                                ProviderIcon(provider: provider, size: 20)
                                
                                Text(provider.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                
                                Spacer()
                                
                                Text("\(accounts.count)")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(provider.color.opacity(0.15))
                                    .foregroundStyle(provider.color)
                                    .clipShape(Capsule())
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        } label: {
            Label("dashboard.trackedAccounts".localized(), systemImage: "person.2.badge.key")
        }
    }
    
    // MARK: - Install Binary
    
    private var installBinarySection: some View {
        ContentUnavailableView {
            Label("dashboard.cliNotInstalled".localized(), systemImage: "arrow.down.circle")
        } description: {
            Text("dashboard.clickToInstall".localized())
        } actions: {
            if proxyManagement.proxy.isDownloading {
                ProgressView(value: proxyManagement.proxy.downloadProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
            } else {
                Button("dashboard.installCLI".localized()) {
                    Task {
                        do {
                            try await proxyManagement.proxy.downloadAndInstallBinary()
                        } catch {
                            proxyManagement.errorMessage = proxyManagement.proxy.errorMessage(for: error)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            
            if let error = proxyManagement.proxy.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
    
    // MARK: - Start Proxy
    
    private var startProxySection: some View {
        ProxyRequiredView(
            description: "dashboard.startToBegin".localized()
        ) {
            await proxyManagement.startProxy()
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
    
    // MARK: - Getting Started Section
    
    private var gettingStartedSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(gettingStartedSteps) { step in
                    GettingStartedStepRow(
                        step: step,
                        onAction: { handleStepAction(step) }
                    )
                    
                    if step.id != gettingStartedSteps.last?.id {
                        Divider()
                    }
                }
            }
        } label: {
            HStack {
                Label("dashboard.gettingStarted".localized(), systemImage: "sparkles")
                
                Spacer()
                
                Button {
                    withAnimation { settingsModel.setHideGettingStarted(true) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("action.dismiss".localized())
            }
        }
    }
    
    private var gettingStartedSteps: [GettingStartedStep] {
        [
            GettingStartedStep(
                id: "provider",
                icon: "person.2.badge.key",
                title: "onboarding.addProvider".localized(),
                description: "onboarding.addProviderDesc".localized(),
                isCompleted: !proxyManagement.authFiles.isEmpty,
                actionLabel: proxyManagement.authFiles.isEmpty ? "providers.addProvider".localized() : nil
            ),
            GettingStartedStep(
                id: "agent",
                icon: "terminal",
                title: "onboarding.configureAgent".localized(),
                description: "onboarding.configureAgentDesc".localized(),
                isCompleted: proxyManagement.agentSetup.agentStatuses.contains(where: { $0.configured }),
                actionLabel: proxyManagement.agentSetup.agentStatuses.contains(where: { $0.configured }) ? nil : "agents.configure".localized()
            )
        ]
    }
    
    private func handleStepAction(_ step: GettingStartedStep) {
        switch step.id {
        case "provider":
            showProviderPicker()
        case "agent":
            showAgentPicker()
        default:
            break
        }
    }
    
    private func showProviderPicker() {
        let alert = NSAlert()
        alert.messageText = "providers.addProvider".localized()
        alert.informativeText = "onboarding.addProviderDesc".localized()

        let providers = AIProvider.allCases.filter(\.supportsLocalProxySetup)
        for provider in providers {
            alert.addButton(withTitle: provider.displayName)
        }
        alert.addButton(withTitle: "action.cancel".localized())
        
        let response = alert.runModal()
        let index = response.rawValue - 1000
        
        if index >= 0 && index < providers.count {
            let provider = providers[index]
            if provider == .vertex {
                isImporterPresented = true
            } else {
                quotaController.cancelOAuth()
                selectedProvider = provider
            }
        }
    }
    
    private func showAgentPicker() {
        let installedAgents = proxyManagement.agentSetup.agentStatuses.filter { $0.installed }
        guard let firstAgent = installedAgents.first else { return }
        
        proxyManagement.agentSetup.startConfiguration(for: firstAgent.agent)
        sheetPresentationID = UUID()
        selectedAgentForConfig = firstAgent.agent
    }
    
    // MARK: - KPI Section
    
    private var kpiSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
            KPICard(
                title: "dashboard.accounts".localized(),
                value: "\(proxyManagement.totalAccounts)",
                subtitle: "\(proxyManagement.readyAccounts) " + "dashboard.ready".localized(),
                icon: "person.2.fill",
                color: .blue
            )
            
            KPICard(
                title: "dashboard.requests".localized(),
                value: "\(proxyManagement.usageStats?.usage?.totalRequests ?? 0)",
                subtitle: "dashboard.total".localized(),
                icon: "arrow.up.arrow.down",
                color: .green
            )
            
            KPICard(
                title: "dashboard.tokens".localized(),
                value: (proxyManagement.usageStats?.usage?.totalTokens ?? 0).formattedCompact,
                subtitle: "dashboard.processed".localized(),
                icon: "text.word.spacing",
                color: .purple
            )
            
            KPICard(
                title: "dashboard.successRate".localized(),
                value: String(format: "%.0f%%", proxyManagement.usageStats?.usage?.successRate ?? 0.0),
                subtitle: "\(proxyManagement.usageStats?.usage?.failureCount ?? 0) " + "dashboard.failed".localized(),
                icon: "checkmark.circle.fill",
                color: .orange
            )
        }
    }
    
    // MARK: - Provider Section
    
    private var providerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                FlowLayout(spacing: 8) {
                    ForEach(proxyManagement.connectedProviders) { provider in
                        ProviderChip(provider: provider, count: proxyManagement.authFilesByProvider[provider]?.count ?? 0)
                    }
                    
                    ForEach(proxyManagement.disconnectedProviders.filter(\.supportsLocalProxySetup)) { provider in
                        Button {
                            if provider == .vertex {
                                isImporterPresented = true
                            } else {
                                quotaController.cancelOAuth()
                                selectedProvider = provider
                            }
                        } label: {
                            Label(provider.displayName, systemImage: "plus.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                    }
                }
            }
        } label: {
            Label("dashboard.providers".localized(), systemImage: "cpu")
        }
    }
    
    // MARK: - Endpoint Section

    /// The display endpoint for clients to connect to
    private var displayEndpoint: String {
        proxyManagement.proxy.baseURL + "/v1"
    }

    private var endpointSection: some View {
        GroupBox {
            HStack {
                Text(displayEndpoint)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)

                Spacer()

                Button {
                    pasteboard.copy(displayEndpoint)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
        } label: {
            Label("dashboard.apiEndpoint".localized(), systemImage: "link")
        }
    }
    
    // MARK: - Tunnel Section
    
    private var tunnelSection: some View {
        GroupBox {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.15), .purple.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    
                    Image(systemName: "globe")
                        .font(.system(size: 24))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .blue.opacity(0.3), radius: 4, x: 0, y: 2)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("tunnel.section.title".localized())
                            .font(.headline)
                        
                        TunnelStatusBadge(status: tunnel.tunnelState.status, compact: true)
                    }
                    
                    if tunnel.tunnelState.isActive, let url = tunnel.tunnelState.publicURL {
                        Text(url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .monospaced()
                    } else {
                        Text("tunnel.section.description".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                if tunnel.tunnelState.isActive {
                    Button {
                        if let url = tunnel.tunnelState.publicURL {
                            pasteboard.copy(url)
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("action.copy".localized())
                }
                
                Button {
                    showTunnelSheet = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } label: {
            Label("tunnel.section.label".localized(), systemImage: "network")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showTunnelSheet) {
            TunnelSheet()
        }
    }
}

// MARK: - Getting Started Step

struct GettingStartedStep: Identifiable {
    let id: String
    let icon: String
    let title: String
    let description: String
    let isCompleted: Bool
    let actionLabel: String?
}

struct GettingStartedStepRow: View {
    let step: GettingStartedStep
    let onAction: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(step.isCompleted ? Color.green : Color.accentColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                if step.isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: step.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.title)
                        .font(.headline)
                    
                    if step.isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                
                Text(step.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if let actionLabel = step.actionLabel {
                Button(actionLabel) {
                    onAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - KPI Card

struct KPICard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color
    
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: icon)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Provider Chip

struct ProviderChip: View {
    let provider: AIProvider
    let count: Int
    
    var body: some View {
        HStack(spacing: 6) {
            ProviderIcon(provider: provider, size: 16)
            Text(provider.displayName)
            if count > 1 {
                Text("×\(count)")
                    .fontWeight(.semibold)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(provider.color.opacity(0.15))
        .foregroundStyle(provider.color)
        .clipShape(Capsule())
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }
    
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            
            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        
        return (CGSize(width: maxWidth, height: currentY + lineHeight), positions)
    }
}

// MARK: - Quota Provider Row (for Quota-Only Mode Dashboard)

struct QuotaProviderRow: View {
    let provider: AIProvider
    let accounts: [String: ProviderQuotaData]
    
    private var lowestQuota: Double {
        accounts.values.flatMap { $0.models }.map { $0.percentage }.min() ?? 100
    }
    
    private var quotaColor: Color {
        if lowestQuota > 50 { return .green }
        if lowestQuota > 20 { return .orange }
        return .red
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ProviderIcon(provider: provider, size: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("\(accounts.count) " + "quota.accounts".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            // Lowest quota indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(quotaColor)
                    .frame(width: 8, height: 8)
                
                Text(String(format: "%.0f%%", lowestQuota))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(quotaColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(quotaColor.opacity(0.1))
            .clipShape(Capsule())
        }
        .padding(.vertical, 6)
    }
}
