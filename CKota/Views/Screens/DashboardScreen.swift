//
//  DashboardScreen.swift
//  CKota
//

import SwiftUI

struct DashboardScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @AppStorage("hideGettingStarted") private var hideGettingStarted: Bool = false
    private let modeManager = AppModeManager.shared

    @State private var selectedProvider: AIProvider?
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
            viewModel.agentSetupViewModel.agentStatuses.contains(where: \.configured)
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
            VStack(alignment: .leading, spacing: .ckXXL) {
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
            .padding(CKLayout.contentPadding)
        }
        .background(Color.ckBackground)
        .navigationTitle("nav.home".localized())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if modeManager.isQuotaOnlyMode {
                    Button {
                        Task { await viewModel.refreshQuotasDirectly() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoadingQuotas)
                    .accessibilityLabel("Refresh quota data")
                    .accessibilityHint("Double tap to fetch latest quota information")
                } else {
                    Button {
                        Task { await viewModel.refreshData() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!viewModel.proxyManager.proxyStatus.running)
                    .accessibilityLabel("Refresh data")
                    .accessibilityHint("Double tap to fetch latest data from proxy")
                }
            }
        }
        .sheet(item: $selectedProvider) { provider in
            OAuthSheet(provider: provider) {
                selectedProvider = nil
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
        .task {
            if modeManager.isFullMode {
                await viewModel.agentSetupViewModel.refreshAgentStatuses()
            }
        }
    }

    // MARK: - Full Mode Content

    private var fullModeContent: some View {
        VStack(alignment: .leading, spacing: .ckXXL) {
            if showGettingStarted {
                gettingStartedSection
            }

            accountMonitorSection
            endpointSection
        }
    }

    // MARK: - Account Monitor Section

    private var accountMonitorSection: some View {
        VStack(alignment: .leading, spacing: .ckMD) {
            // Section header with LIVE badge
            accountMonitorHeader

            // KPI cards row
            kpiSection

            // Provider stats cards
            providerStatsSection
        }
        .ckCard()
    }

    private var accountMonitorHeader: some View {
        VStack(alignment: .leading, spacing: .ckSM) {
            HStack(spacing: .ckMD) {
                Text("Account Monitor")
                    .font(.ckTitle)
                    .foregroundStyle(Color.ckForeground)

                CKLiveBadge()

                Spacer()
            }

            // Info line: Updated Xs ago | X accounts | X req
            HStack(spacing: .ckSM) {
                if let lastRefresh = viewModel.lastQuotaRefreshTime {
                    Text(formatTimeAgo(lastRefresh))
                        .font(.ckCaption)
                        .foregroundStyle(Color.ckMutedForeground)
                } else {
                    Text("Updated just now")
                        .font(.ckCaption)
                        .foregroundStyle(Color.ckMutedForeground)
                }

                Text("|")
                    .font(.ckCaption)
                    .foregroundStyle(Color.ckMutedForeground)

                Text("\(viewModel.totalAccounts) accounts")
                    .font(.ckCaption)
                    .foregroundStyle(Color.ckMutedForeground)

                Text("|")
                    .font(.ckCaption)
                    .foregroundStyle(Color.ckMutedForeground)

                Text("\(viewModel.usageStats?.usage?.totalRequests ?? 0) req")
                    .font(.ckCaption)
                    .foregroundStyle(Color.ckMutedForeground)
            }
        }
    }

    private func formatTimeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 {
            return "Updated just now"
        } else if seconds < 60 {
            return "Updated \(seconds)s ago"
        } else if seconds < 3600 {
            return "Updated \(seconds / 60)m ago"
        } else {
            return "Updated \(seconds / 3600)h ago"
        }
    }

    // MARK: - Quota-Only Mode Content

    private var quotaOnlyModeContent: some View {
        VStack(alignment: .leading, spacing: .ckXXL) {
            // Quota Overview KPIs
            quotaOnlyKPISection

            // Quick Quota Status
            quotaStatusSection

            // Tracked Accounts
            trackedAccountsSection
        }
    }

    private var quotaOnlyKPISection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: .ckMD)], spacing: .ckMD) {
            CKKPICard(
                icon: "person.2.fill",
                label: "dashboard.trackedAccounts".localized(),
                value: "\(viewModel.directAuthFiles.count)",
                subtitle: "dashboard.accounts".localized(),
                iconBackgroundColor: Color.ckGemini.opacity(0.15),
                iconColor: .ckGemini
            )

            let providersCount = Set(viewModel.directAuthFiles.map(\.provider)).count
            CKKPICard(
                icon: "cpu",
                label: "dashboard.providers".localized(),
                value: "\(providersCount)",
                subtitle: "dashboard.connected".localized(),
                iconBackgroundColor: Color.ckSuccess.opacity(0.15),
                iconColor: .ckSuccess
            )

            // Show lowest quota percentage
            let lowestQuota = viewModel.providerQuotas.values.flatMap(\.values).flatMap(\.models).map(\.percentage)
                .min() ?? 100
            CKKPICard(
                icon: "chart.bar.fill",
                label: "dashboard.lowestQuota".localized(),
                value: String(format: "%.0f%%", lowestQuota),
                subtitle: "dashboard.remaining".localized(),
                status: lowestQuota > 50 ? .ready : (lowestQuota > 20 ? .cooling : .exhausted)
            )

            if let lastRefresh = viewModel.lastQuotaRefreshTime {
                CKKPICard(
                    icon: "clock.fill",
                    label: "dashboard.lastRefresh".localized(),
                    value: lastRefresh.formatted(date: .omitted, time: .shortened),
                    subtitle: "dashboard.updated".localized(),
                    iconBackgroundColor: Color.purple.opacity(0.15),
                    iconColor: .purple
                )
            }
        }
    }

    private var quotaStatusSection: some View {
        VStack(alignment: .leading, spacing: .ckMD) {
            HStack {
                Label("dashboard.quotaOverview".localized(), systemImage: "chart.bar.fill")
                    .font(.ckHeadline)

                Spacer()

                if viewModel.isLoadingQuotas {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if viewModel.providerQuotas.isEmpty {
                VStack(spacing: .ckMD) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.largeTitle)
                        .foregroundStyle(Color.ckMutedForeground)

                    Text("dashboard.noQuotaData".localized())
                        .font(.ckBody)
                        .foregroundStyle(Color.ckMutedForeground)

                    Button {
                        Task { await viewModel.refreshQuotasDirectly() }
                    } label: {
                        Label("action.refresh".localized(), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isLoadingQuotas)
                    .ckCursorPointer()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, .ckXL)
            } else {
                let providers = AIProvider.allCases.filter { viewModel.providerQuotas[$0] != nil }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                        if let accounts = viewModel.providerQuotas[provider], !accounts.isEmpty {
                            CKQuotaProviderRow(provider: provider, accounts: accounts)
                                .padding(.horizontal, .ckMD)
                                .padding(.vertical, .ckSM)

                            if index < providers.count - 1 {
                                Divider()
                                    .padding(.horizontal, .ckMD)
                            }
                        }
                    }
                }
                .background(Color.ckBackground)
                .clipShape(RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM))
                .overlay(
                    RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM)
                        .stroke(Color.ckBorder, lineWidth: 1)
                )
            }
        }
        .ckCard()
    }

    private var trackedAccountsSection: some View {
        VStack(alignment: .leading, spacing: .ckMD) {
            Label("dashboard.trackedAccounts".localized(), systemImage: "person.2.badge.key")
                .font(.ckHeadline)

            if viewModel.directAuthFiles.isEmpty {
                VStack(spacing: .ckMD) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(Color.ckMutedForeground)

                    Text("dashboard.noAccountsTracked".localized())
                        .font(.ckBody)
                        .foregroundStyle(Color.ckMutedForeground)

                    Text("dashboard.addAccountsHint".localized())
                        .font(.ckCaption)
                        .foregroundStyle(Color.ckMutedForeground)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, .ckXL)
            } else {
                let groupedAccounts = Dictionary(grouping: viewModel.directAuthFiles) { $0.provider }
                let providers = AIProvider.allCases.filter { groupedAccounts[$0] != nil }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                        if let accounts = groupedAccounts[provider] {
                            HStack(spacing: .ckMD) {
                                ProviderIcon(provider: provider, size: 20)

                                Text(provider.displayName)
                                    .font(.ckBodyMedium)

                                Spacer()

                                Text("\(accounts.count)")
                                    .font(.ckCaption)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(provider.color.opacity(0.15))
                                    )
                                    .foregroundStyle(provider.color)
                            }
                            .padding(.horizontal, .ckMD)
                            .padding(.vertical, .ckSM)

                            if index < providers.count - 1 {
                                Divider()
                                    .padding(.horizontal, .ckMD)
                            }
                        }
                    }
                }
                .background(Color.ckBackground)
                .clipShape(RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM))
                .overlay(
                    RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM)
                        .stroke(Color.ckBorder, lineWidth: 1)
                )
            }
        }
        .ckCard()
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
        VStack(alignment: .leading, spacing: .ckLG) {
            HStack {
                Label("dashboard.gettingStarted".localized(), systemImage: "sparkles")
                    .font(.ckHeadline)

                Spacer()

                Button {
                    withAnimation { hideGettingStarted = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(Color.ckMutedForeground)
                }
                .buttonStyle(.plain)
                .help("action.dismiss".localized())
                .accessibilityLabel("Dismiss getting started guide")
                .ckTouchTarget()
                .ckCursorPointer()
            }

            VStack(alignment: .leading, spacing: .ckLG) {
                ForEach(gettingStartedSteps) { step in
                    GettingStartedStepRow(
                        step: step,
                        onAction: { handleStepAction(step) }
                    )

                    if step.id != gettingStartedSteps.last?.id {
                        Divider()
                            .background(Color.ckBorder)
                    }
                }
            }
        }
        .ckCard()
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
                isCompleted: viewModel.agentSetupViewModel.agentStatuses.contains(where: \.configured),
                actionLabel: viewModel.agentSetupViewModel.agentStatuses.contains(where: \.configured) ? nil : "agents.configure"
                    .localized()
            ),
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

        if index >= 0, index < AIProvider.allCases.count {
            let provider = AIProvider.allCases[index]
            viewModel.oauthState = nil
            selectedProvider = provider
        }
    }

    private func showAgentPicker() {
        let installedAgents = viewModel.agentSetupViewModel.agentStatuses.filter(\.installed)
        guard let firstAgent = installedAgents.first else { return }

        let apiKey = viewModel.apiKeys.first ?? viewModel.proxyManager.managementKey
        viewModel.agentSetupViewModel.startConfiguration(for: firstAgent.agent, apiKey: apiKey)
        sheetPresentationID = UUID()
        selectedAgentForConfig = firstAgent.agent
    }

    // MARK: - KPI Section

    private var kpiSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: .ckMD)], spacing: .ckMD) {
            // ACCOUNTS
            CKKPICard(
                icon: "person.2.fill",
                label: "ACCOUNTS",
                value: "\(viewModel.totalAccounts)",
                iconBackgroundColor: Color.ckGemini.opacity(0.15),
                iconColor: .ckGemini
            )

            // SUCCESS (green value)
            CKKPICard(
                icon: "checkmark.circle.fill",
                label: "SUCCESS",
                value: "\(viewModel.usageStats?.usage?.successCount ?? 0)",
                valueColor: .ckSuccess,
                iconBackgroundColor: Color.ckSuccess.opacity(0.15),
                iconColor: .ckSuccess
            )

            // FAILED (red value)
            CKKPICard(
                icon: "xmark.circle.fill",
                label: "FAILED",
                value: "\(viewModel.usageStats?.usage?.failureCount ?? 0)",
                valueColor: .ckDestructive,
                iconBackgroundColor: Color.ckDestructive.opacity(0.15),
                iconColor: .ckDestructive
            )

            // RATE (success rate percentage)
            CKKPICard(
                icon: "chart.pie.fill",
                label: "RATE",
                value: String(format: "%.0f%%", viewModel.usageStats?.usage?.successRate ?? 0.0),
                iconBackgroundColor: Color.ckAccent.opacity(0.15),
                iconColor: .ckAccent
            )
        }
    }

    // MARK: - Provider Stats Section

    private var providerStatsSection: some View {
        VStack(alignment: .leading, spacing: .ckMD) {
            if viewModel.connectedProviders.isEmpty {
                // Empty state
                VStack(spacing: .ckMD) {
                    Image(systemName: "person.2.slash")
                        .font(.largeTitle)
                        .foregroundStyle(Color.ckMutedForeground)

                    Text("No providers connected")
                        .font(.ckBody)
                        .foregroundStyle(Color.ckMutedForeground)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, .ckLG)
            } else {
                // Provider stats cards in a 2-column grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: .ckMD) {
                    ForEach(viewModel.connectedProviders) { provider in
                        let accountCount = viewModel.authFilesByProvider[provider]?.count ?? 0
                        let (successCount, failureCount) = providerStats(for: provider)

                        CKProviderStatsCard(
                            provider: provider,
                            accountCount: accountCount,
                            successCount: successCount,
                            failureCount: failureCount
                        )
                    }
                }
            }
        }
    }

    /// Calculate success/failure counts for a provider.
    /// Currently uses total stats divided by provider count as placeholder.
    /// In production, this should come from per-provider usage API.
    private func providerStats(for provider: AIProvider) -> (success: Int, failure: Int) {
        let totalSuccess = viewModel.usageStats?.usage?.successCount ?? 0
        let totalFailure = viewModel.usageStats?.usage?.failureCount ?? 0
        let providerCount = max(viewModel.connectedProviders.count, 1)

        // Distribute stats proportionally by account count
        let accountCount = viewModel.authFilesByProvider[provider]?.count ?? 0
        let totalAccounts = max(viewModel.totalAccounts, 1)
        let ratio = Double(accountCount) / Double(totalAccounts)

        return (
            success: Int(Double(totalSuccess) * ratio),
            failure: Int(Double(totalFailure) * ratio)
        )
    }

    // MARK: - Endpoint Section

    private var endpointSection: some View {
        VStack(alignment: .leading, spacing: .ckMD) {
            Label("dashboard.apiEndpoint".localized(), systemImage: "link")
                .font(.ckHeadline)

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
                .accessibilityLabel("Copy endpoint to clipboard")
                .ckTouchTarget()
                .ckCursorPointer()
            }
        }
        .ckCard()
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
        HStack(spacing: .ckLG) {
            ZStack {
                Circle()
                    .fill(step.isCompleted ? Color.ckSuccess : Color.ckAccentLight)
                    .frame(width: 40, height: 40)

                if step.isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: step.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.ckAccent)
                }
            }

            VStack(alignment: .leading, spacing: .ckXS) {
                HStack {
                    Text(step.title)
                        .font(.ckHeadline)

                    if step.isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.ckSuccess)
                            .font(.caption)
                    }
                }

                Text(step.description)
                    .font(.ckBody)
                    .foregroundStyle(Color.ckMutedForeground)
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
        .padding(.vertical, .ckSM)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y),
                proposal: .unspecified
            )
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

            if currentX + size.width > maxWidth, currentX > 0 {
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

struct CKQuotaProviderRow: View {
    let provider: AIProvider
    let accounts: [String: ProviderQuotaData]

    private var lowestQuota: Double {
        accounts.values.flatMap(\.models).map(\.percentage).min() ?? 100
    }

    private var quotaStatus: CKStatusDot.Status {
        if lowestQuota > 50 { return .ready }
        if lowestQuota > 20 { return .cooling }
        return .exhausted
    }

    var body: some View {
        HStack(spacing: .ckMD) {
            ProviderIcon(provider: provider, size: 24)

            VStack(alignment: .leading, spacing: .ckXXS) {
                Text(provider.displayName)
                    .font(.ckBodyMedium)

                Text("\(accounts.count) " + "quota.accounts".localized())
                    .font(.ckCaption)
                    .foregroundStyle(Color.ckMutedForeground)
            }

            Spacer()

            // Lowest quota indicator
            HStack(spacing: .ckSM) {
                CKStatusDot(status: quotaStatus, showLabel: false)

                Text(String(format: "%.0f%%", lowestQuota))
                    .font(.ckBodyMedium)
                    .foregroundStyle(quotaStatus.color)
            }
            .padding(.horizontal, .ckMD)
            .padding(.vertical, .ckXS)
            .background(
                Capsule()
                    .fill(quotaStatus.color.opacity(0.1))
            )
        }
        .padding(.vertical, .ckSM)
    }
}
