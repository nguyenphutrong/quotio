//
//  DashboardScreen.swift
//  Quotio
//

import SwiftUI
import UniformTypeIdentifiers

struct DashboardScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @AppStorage("hideGettingStarted") private var hideGettingStarted: Bool = false
    private let modeManager = AppModeManager.shared
    
    @State private var selectedProvider: AIProvider?
    @State private var projectId: String = ""
    @State private var isImporterPresented = false
    @State private var selectedAgentForConfig: CLIAgent?
    @State private var sheetPresentationID = UUID()
    
    private var showGettingStarted: Bool {
        guard !hideGettingStarted else { return false }
        guard modeManager.isFullMode else { return false }
        return !isSetupComplete
    }
    
    private var isSetupComplete: Bool {
        viewModel.proxyManager.isBinaryInstalled &&
        viewModel.proxyManager.proxyStatus.running &&
        !viewModel.authFiles.isEmpty &&
        viewModel.agentSetupViewModel.agentStatuses.contains(where: { $0.configured })
    }
    
    /// Check if we should show main content
    private var shouldShowContent: Bool {
        if modeManager.isQuotaOnlyMode {
            return true // Always show content in quota-only mode
        }
        return viewModel.proxyManager.proxyStatus.running
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if modeManager.isFullMode {
                    // Full Mode: Check binary and proxy status
                    if !viewModel.proxyManager.isBinaryInstalled {
                        installBinarySection
                    } else if !viewModel.proxyManager.proxyStatus.running {
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
                if modeManager.isQuotaOnlyMode {
                    Button {
                        Task { await viewModel.refreshQuotasDirectly() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoadingQuotas)
                } else {
                    Button {
                        Task { await viewModel.refreshData() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!viewModel.proxyManager.proxyStatus.running)
                }
            }
        }
        .sheet(item: $selectedProvider) { provider in
            OAuthSheet(provider: provider, projectId: $projectId) {
                selectedProvider = nil
                projectId = ""
                viewModel.oauthState = nil
                Task { await viewModel.refreshData() }
            }
            .environment(viewModel)
        }
        .sheet(item: $selectedAgentForConfig) { (agent: CLIAgent) in
            AgentConfigSheet(viewModel: viewModel.agentSetupViewModel, agent: agent)
                .id(sheetPresentationID)
                .onDisappear {
                    viewModel.agentSetupViewModel.dismissConfiguration()
                    Task { await viewModel.agentSetupViewModel.refreshAgentStatuses() }
                }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task {
                    await viewModel.importVertexServiceAccount(url: url)
                    await viewModel.refreshData()
                }
            }
        }
        .task {
            if modeManager.isFullMode {
                await viewModel.agentSetupViewModel.refreshAgentStatuses()
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
                value: "\(viewModel.directAuthFiles.count)",
                subtitle: "dashboard.accounts".localized(),
                icon: "person.2.fill",
                color: .blue
            )
            
            let providersCount = Set(viewModel.directAuthFiles.map { $0.provider }).count
            KPICard(
                title: "dashboard.providers".localized(),
                value: "\(providersCount)",
                subtitle: "dashboard.connected".localized(),
                icon: "cpu",
                color: .green
            )
            
            // Show lowest quota percentage
            let lowestQuota = viewModel.providerQuotas.values.flatMap { $0.values }.flatMap { $0.models }.map { $0.percentage }.min() ?? 100
            KPICard(
                title: "dashboard.lowestQuota".localized(),
                value: String(format: "%.0f%%", lowestQuota),
                subtitle: "dashboard.remaining".localized(),
                icon: "chart.bar.fill",
                color: lowestQuota > 50 ? .green : (lowestQuota > 20 ? .orange : .red)
            )
            
            if let lastRefresh = viewModel.lastQuotaRefreshTime {
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
            if viewModel.providerQuotas.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    
                    Text("dashboard.noQuotaData".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Button {
                        Task { await viewModel.refreshQuotasDirectly() }
                    } label: {
                        Label("action.refresh".localized(), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isLoadingQuotas)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(viewModel.providerQuotas.keys), id: \.self) { provider in
                        if let accounts = viewModel.providerQuotas[provider], !accounts.isEmpty {
                            QuotaProviderRow(provider: provider, accounts: accounts)
                        }
                    }
                }
            }
        } label: {
            HStack {
                Label("dashboard.quotaOverview".localized(), systemImage: "chart.bar.fill")
                
                Spacer()
                
                if viewModel.isLoadingQuotas {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }
    
    private var trackedAccountsSection: some View {
        GroupBox {
            if viewModel.directAuthFiles.isEmpty {
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
                    let groupedAccounts = Dictionary(grouping: viewModel.directAuthFiles) { $0.provider }
                    
                    ForEach(AIProvider.allCases.filter { groupedAccounts[$0] != nil }, id: \.self) { provider in
                        if let accounts = groupedAccounts[provider] {
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
            if viewModel.proxyManager.isDownloading {
                ProgressView(value: viewModel.proxyManager.downloadProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
            } else {
                Button("dashboard.installCLI".localized()) {
                    Task {
                        do {
                            try await viewModel.proxyManager.downloadAndInstallBinary()
                        } catch {
                            viewModel.errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            
            if let error = viewModel.proxyManager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
    
    // MARK: - Start Proxy
    
    private var startProxySection: some View {
        ContentUnavailableView {
            Label("empty.proxyNotRunning".localized(), systemImage: "power")
        } description: {
            Text("dashboard.startToBegin".localized())
        } actions: {
            Button("action.startProxy".localized()) {
                Task { await viewModel.startProxy() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
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
                    withAnimation { hideGettingStarted = true }
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
                isCompleted: !viewModel.authFiles.isEmpty,
                actionLabel: viewModel.authFiles.isEmpty ? "providers.addProvider".localized() : nil
            ),
            GettingStartedStep(
                id: "agent",
                icon: "terminal",
                title: "onboarding.configureAgent".localized(),
                description: "onboarding.configureAgentDesc".localized(),
                isCompleted: viewModel.agentSetupViewModel.agentStatuses.contains(where: { $0.configured }),
                actionLabel: viewModel.agentSetupViewModel.agentStatuses.contains(where: { $0.configured }) ? nil : "agents.configure".localized()
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
        
        for provider in AIProvider.allCases {
            alert.addButton(withTitle: provider.displayName)
        }
        alert.addButton(withTitle: "action.cancel".localized())
        
        let response = alert.runModal()
        let index = response.rawValue - 1000
        
        if index >= 0 && index < AIProvider.allCases.count {
            let provider = AIProvider.allCases[index]
            if provider == .vertex {
                isImporterPresented = true
            } else {
                viewModel.oauthState = nil
                selectedProvider = provider
            }
        }
    }
    
    private func showAgentPicker() {
        let installedAgents = viewModel.agentSetupViewModel.agentStatuses.filter { $0.installed }
        guard let firstAgent = installedAgents.first else { return }
        
        let apiKey = viewModel.apiKeys.first ?? viewModel.proxyManager.managementKey
        viewModel.agentSetupViewModel.startConfiguration(for: firstAgent.agent, apiKey: apiKey)
        sheetPresentationID = UUID()
        selectedAgentForConfig = firstAgent.agent
    }
    
    // MARK: - KPI Section
    
    private var kpiSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
            KPICard(
                title: "dashboard.accounts".localized(),
                value: "\(viewModel.totalAccounts)",
                subtitle: "\(viewModel.readyAccounts) " + "dashboard.ready".localized(),
                icon: "person.2.fill",
                color: .blue
            )
            
            KPICard(
                title: "dashboard.requests".localized(),
                value: "\(viewModel.usageStats?.usage?.totalRequests ?? 0)",
                subtitle: "dashboard.total".localized(),
                icon: "arrow.up.arrow.down",
                color: .green
            )
            
            KPICard(
                title: "dashboard.tokens".localized(),
                value: (viewModel.usageStats?.usage?.totalTokens ?? 0).formattedCompact,
                subtitle: "dashboard.processed".localized(),
                icon: "text.word.spacing",
                color: .purple
            )
            
            KPICard(
                title: "dashboard.successRate".localized(),
                value: String(format: "%.0f%%", viewModel.usageStats?.usage?.successRate ?? 0.0),
                subtitle: "\(viewModel.usageStats?.usage?.failureCount ?? 0) " + "dashboard.failed".localized(),
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
                    ForEach(viewModel.connectedProviders) { provider in
                        ProviderChip(provider: provider, count: viewModel.authFilesByProvider[provider]?.count ?? 0)
                    }
                    
                    ForEach(viewModel.disconnectedProviders.filter { $0.supportsManualAuth }) { provider in
                        Button {
                            if provider == .vertex {
                                isImporterPresented = true
                            } else {
                                viewModel.oauthState = nil
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
    
    private var endpointSection: some View {
        GroupBox {
            HStack {
                Text(viewModel.proxyManager.proxyStatus.endpoint)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                
                Spacer()
                
                Button {
                    viewModel.proxyManager.copyEndpointToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
        } label: {
            Label("dashboard.apiEndpoint".localized(), systemImage: "link")
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
