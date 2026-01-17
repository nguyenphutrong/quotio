//
//  QuotaScreen.swift
//  Quotio
//

import SwiftUI

struct QuotaScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    private let modeManager = OperatingModeManager.shared
    
    @State private var selectedProvider: AIProvider?
    @State private var settings = MenuBarSettingsManager.shared
    
    // MARK: - Data Sources
    
    /// All providers with quota data (unified from both proxy and direct sources)
    private var availableProviders: [AIProvider] {
        var providers = Set<AIProvider>()
        
        // From proxy auth files
        for file in viewModel.authFiles {
            if let provider = file.providerType {
                providers.insert(provider)
            }
        }
        
        // From direct quota data
        for provider in viewModel.providerQuotas.keys {
            providers.insert(provider)
        }
        
        return providers.sorted { $0.displayName < $1.displayName }
    }
    
    /// Get account count for a provider
    private func accountCount(for provider: AIProvider) -> Int {
        var accounts = Set<String>()
        
        // From auth files
        for file in viewModel.authFiles where file.providerType == provider {
            accounts.insert(file.quotaLookupKey)
        }
        
        // From quota data
        if let quotaAccounts = viewModel.providerQuotas[provider] {
            for key in quotaAccounts.keys {
                accounts.insert(key)
            }
        }
        
        return accounts.count
    }
    
    private func lowestQuotaPercent(for provider: AIProvider) -> Double? {
        guard let accounts = viewModel.providerQuotas[provider] else { return nil }
        
        var allTotals: [Double] = []
        for (_, quotaData) in accounts {
            let models = quotaData.models.map { (name: $0.name, percentage: $0.percentage) }
            let total = settings.totalUsagePercent(models: models)
            if total >= 0 {
                allTotals.append(total)
            }
        }
        
        return allTotals.min()
    }
    
    /// Check if we have any data to show
    private var hasAnyData: Bool {
        if modeManager.isMonitorMode {
            return !viewModel.providerQuotas.isEmpty || !viewModel.directAuthFiles.isEmpty
        }
        return !viewModel.authFiles.isEmpty || !viewModel.providerQuotas.isEmpty
    }
    
    var body: some View {
        Group {
            if !hasAnyData {
                ContentUnavailableView(
                    "empty.noAccounts".localized(),
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("empty.addProviderAccounts".localized())
                )
            } else {
                mainContent
            }
        }
        .navigationTitle("nav.quota".localized())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                    Menu {
                        // Display Style
                        Picker(selection: Binding(
                            get: { settings.quotaDisplayStyle },
                            set: { settings.quotaDisplayStyle = $0 }
                        )) {
                            ForEach(QuotaDisplayStyle.allCases) { style in
                                Label(style.localizationKey.localized(), systemImage: style.iconName)
                                    .tag(style)
                            }
                        } label: {
                            Text("settings.quota.displayStyle".localized())
                        }
                        .pickerStyle(.inline)
                        
                        Divider()
                        
                        // Display Mode (Used vs Remaining)
                        Picker(selection: Binding(
                            get: { settings.quotaDisplayMode },
                            set: { settings.quotaDisplayMode = $0 }
                        )) {
                            ForEach(QuotaDisplayMode.allCases) { mode in
                                Text(mode.localizationKey.localized())
                                    .tag(mode)
                            }
                        } label: {
                            Text("display_mode".localized())
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await viewModel.refreshQuotasUnified()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingQuotas)
            }
        }
        .onAppear {
            if selectedProvider == nil, let first = availableProviders.first {
                selectedProvider = first
            }
        }
        .onChange(of: availableProviders) { _, newProviders in
            if selectedProvider == nil || !newProviders.contains(selectedProvider!) {
                selectedProvider = newProviders.first
            }
        }
    }
    
    // MARK: - Main Content
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            // Provider Segmented Control
            if availableProviders.count > 1 {
                providerSegmentedControl
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
            }
            
            // Selected Provider Content
            ScrollView {
                if let provider = selectedProvider ?? availableProviders.first {
                    ProviderQuotaView(
                        provider: provider,
                        authFiles: viewModel.authFiles.filter { $0.providerType == provider },
                        quotaData: viewModel.providerQuotas[provider] ?? [:],
                        subscriptionInfos: viewModel.subscriptionInfos[provider] ?? [:],
                        isLoading: viewModel.isLoadingQuotas
                    )
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                } else {
                    ContentUnavailableView(
                        "empty.noQuotaData".localized(),
                        systemImage: "chart.bar.xaxis",
                        description: Text("empty.refreshToLoad".localized())
                    )
                    .padding(24)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
    
    // MARK: - Segmented Control
    
    private var providerSegmentedControl: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(availableProviders) { provider in
                    ProviderSegmentButton(
                        provider: provider,
                        quotaPercent: lowestQuotaPercent(for: provider),
                        accountCount: accountCount(for: provider),
                        isSelected: selectedProvider == provider
                    ) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            selectedProvider = provider
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }
}

fileprivate struct QuotaDisplayHelper {
    let displayMode: QuotaDisplayMode
    
    func statusColor(remainingPercent: Double) -> Color {
        let clamped = max(0, min(100, remainingPercent))
        let usedPercent = 100 - clamped
        let checkValue = displayMode == .used ? usedPercent : clamped
        
        if displayMode == .used {
            if checkValue < 70 { return .green }
            if checkValue < 90 { return .yellow }
            return .red
        }
        
        if checkValue > 50 { return .green }
        if checkValue > 20 { return .orange }
        return .red
    }
    
    func displayPercent(remainingPercent: Double) -> Double {
        let clamped = max(0, min(100, remainingPercent))
        return displayMode == .used ? (100 - clamped) : clamped
    }
}

// MARK: - Provider Segment Button

private struct ProviderSegmentButton: View {
    let provider: AIProvider
    let quotaPercent: Double?
    let accountCount: Int
    let isSelected: Bool
    let action: () -> Void

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }
    
    private var statusColor: Color {
        guard let percent = quotaPercent else { return .secondary }
        return displayHelper.statusColor(remainingPercent: percent)
    }
    
    private var remainingPercent: Double {
        max(0, min(100, quotaPercent ?? 0))
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ProviderIcon(provider: provider, size: 20)
                
                Text(provider.displayName)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .medium)
                
                if accountCount > 1 {
                    Text(String(accountCount))
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(isSelected ? .white : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(isSelected ? statusColor : Color.primary.opacity(0.08))
                        .clipShape(Capsule())
                }
                
                if quotaPercent != nil {
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: remainingPercent / 100)
                            .stroke(statusColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 12, height: 12)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(statusColor.opacity(0.3), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Quota Status Dot

private struct QuotaStatusDot: View {
    let usedPercent: Double
    let size: CGFloat
    
    private var color: Color {
        if usedPercent < 70 { return .green }   // <70% used = healthy
        if usedPercent < 90 { return .yellow }  // 70-90% used = warning
        return .red                              // >90% used = critical
    }
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

// MARK: - Provider Quota View

private struct ProviderQuotaView: View {
    let provider: AIProvider
    let authFiles: [AuthFile]
    let quotaData: [String: ProviderQuotaData]
    let subscriptionInfos: [String: SubscriptionInfo]
    let isLoading: Bool
    
    /// Get all accounts (from auth files or quota data keys)
    private var allAccounts: [AccountInfo] {
        var accounts: [AccountInfo] = []
        
        // From auth files
        for file in authFiles {
            let key = file.quotaLookupKey
            accounts.append(AccountInfo(
                key: key,
                email: file.email ?? file.name,
                status: file.status,
                statusColor: file.statusColor,
                authFile: file,
                quotaData: quotaData[key],
                subscriptionInfo: subscriptionInfos[key]
            ))
        }
        
        // From quota data (if not already added)
        let existingKeys = Set(accounts.map { $0.key })
        for (key, data) in quotaData {
            if !existingKeys.contains(key) {
                accounts.append(AccountInfo(
                    key: key,
                    email: key,
                    status: "active",
                    statusColor: .green,
                    authFile: nil,
                    quotaData: data,
                    subscriptionInfo: subscriptionInfos[key]
                ))
            }
        }
        
        return accounts.sorted { $0.email < $1.email }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            if allAccounts.isEmpty && isLoading {
                QuotaLoadingView()
            } else if allAccounts.isEmpty {
                emptyState
            } else {
                ForEach(allAccounts, id: \.key) { account in
                    AccountQuotaCardV2(
                        provider: provider,
                        account: account,
                        isLoading: isLoading && account.quotaData == nil
                    )
                }
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("quota.noDataYet".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

// MARK: - Account Info

private struct AccountInfo {
    let key: String
    let email: String
    let status: String
    let statusColor: Color
    let authFile: AuthFile?
    let quotaData: ProviderQuotaData?
    let subscriptionInfo: SubscriptionInfo?
}

// MARK: - Account Quota Card V2

private struct AccountQuotaCardV2: View {
    @Environment(QuotaViewModel.self) private var viewModel
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    let provider: AIProvider
    let account: AccountInfo
    let isLoading: Bool
    
    @State private var isRefreshing = false
    @State private var showSwitchSheet = false
    @State private var showModelsDetailSheet = false

    /// Check if OAuth is in progress for this provider
    private var isReauthenticating: Bool {
        guard let oauthState = viewModel.oauthState else { return false }
        return oauthState.provider == provider &&
               (oauthState.status == .waiting || oauthState.status == .polling)
    }
    @State private var showWarmupSheet = false
    
    private var hasQuotaData: Bool {
        guard let data = account.quotaData else { return false }
        return !data.models.isEmpty
    }
    
    private var displayEmail: String {
        account.email.masked(if: settings.hideSensitiveInfo)
    }
    
    private var isWarmupEnabled: Bool {
        viewModel.isWarmupEnabled(for: provider, accountKey: account.key)
    }
    
    /// Check if this Antigravity account is active in IDE
    private var isActiveInIDE: Bool {
        provider == .antigravity && viewModel.isAntigravityAccountActive(email: account.email)
    }
    
    /// Build 4-group display for Antigravity: Gemini 3 Pro, Gemini 3 Flash, Gemini 3 Image, Claude 4.5
    private var antigravityDisplayGroups: [AntigravityDisplayGroup] {
        guard let data = account.quotaData, provider == .antigravity else { return [] }
        
        var groups: [AntigravityDisplayGroup] = []
        
        let gemini3ProModels = data.models.filter { 
            $0.name.contains("gemini-3-pro") && !$0.name.contains("image") 
        }
        if !gemini3ProModels.isEmpty {
            let aggregatedQuota = settings.aggregateModelPercentages(gemini3ProModels.map(\.percentage))
            if aggregatedQuota >= 0 {
                groups.append(AntigravityDisplayGroup(name: "Gemini 3 Pro", percentage: aggregatedQuota, models: gemini3ProModels))
            }
        }
        
        let gemini3FlashModels = data.models.filter { $0.name.contains("gemini-3-flash") }
        if !gemini3FlashModels.isEmpty {
            let aggregatedQuota = settings.aggregateModelPercentages(gemini3FlashModels.map(\.percentage))
            if aggregatedQuota >= 0 {
                groups.append(AntigravityDisplayGroup(name: "Gemini 3 Flash", percentage: aggregatedQuota, models: gemini3FlashModels))
            }
        }
        
        let geminiImageModels = data.models.filter { $0.name.contains("image") }
        if !geminiImageModels.isEmpty {
            let aggregatedQuota = settings.aggregateModelPercentages(geminiImageModels.map(\.percentage))
            if aggregatedQuota >= 0 {
                groups.append(AntigravityDisplayGroup(name: "Gemini 3 Image", percentage: aggregatedQuota, models: geminiImageModels))
            }
        }
        
        let claudeModels = data.models.filter { $0.name.contains("claude") }
        if !claudeModels.isEmpty {
            let aggregatedQuota = settings.aggregateModelPercentages(claudeModels.map(\.percentage))
            if aggregatedQuota >= 0 {
                groups.append(AntigravityDisplayGroup(name: "Claude", percentage: aggregatedQuota, models: claudeModels))
            }
        }
        
        return groups.sorted { $0.percentage < $1.percentage }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            accountHeader
            
            if isLoading {
                QuotaLoadingView()
            } else if hasQuotaData {
                usageSection
            } else if let message = account.authFile?.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.background)
                .shadow(color: .primary.opacity(0.06), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
    
    // MARK: - Account Header

    private var accountHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if let info = account.subscriptionInfo {
                        SubscriptionBadgeV2(info: info)
                    } else if let planName = account.quotaData?.planDisplayName {
                        PlanBadgeV2Compact(planName: planName)
                    }

                    Text(displayEmail)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }

                // Show token expiry for Kiro accounts
                if let quotaData = account.quotaData, let tokenExpiry = quotaData.formattedTokenExpiry {
                    HStack(spacing: 4) {
                        Image(systemName: "key")
                            .font(.caption2)
                        Text(tokenExpiry)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                if account.status != "ready" && account.status != "active" {
                    Text(account.status.capitalized)
                        .font(.caption)
                        .foregroundStyle(account.statusColor)
                }
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                if provider == .antigravity {
                    Button {
                        showWarmupSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isWarmupEnabled ? "bolt.fill" : "bolt")
                                .font(.caption)
                            Text("Warm Up")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                            .foregroundStyle(isWarmupEnabled ? provider.color : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(isWarmupEnabled ? provider.color.opacity(0.12) : Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("action.warmup".localized())
                }
                
                if isActiveInIDE {
                    Text("antigravity.active".localized())
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.1))
                        .clipShape(Capsule())
                }
                
                if provider == .antigravity && !isActiveInIDE {
                    Button {
                        showSwitchSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.square")
                                .font(.caption)
                            Text("Use in IDE")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("antigravity.useInIDE".localized())
                }
                
                Button {
                    Task {
                        isRefreshing = true
                        await viewModel.refreshQuotaForProvider(provider)
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing || isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                            Text("Refresh")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing || isLoading)
                
                if let data = account.quotaData, data.isForbidden {
                    if provider == .claude {
                        Button {
                            Task {
                                await viewModel.startOAuth(for: .claude)
                            }
                        } label: {
                            if isReauthenticating {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .frame(width: 28, height: 28)
                                    .background(Color.orange.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isReauthenticating)
                        .help("quota.reauthenticate".localized())
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(width: 28, height: 28)
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .help("Limit Reached")
                    }
                }
            }
        }
        .sheet(isPresented: $showSwitchSheet) {
            SwitchAccountSheet(
                accountEmail: account.email,
                onDismiss: {
                    showSwitchSheet = false
                }
            )
            .environment(viewModel)
        }
        .sheet(isPresented: $showWarmupSheet) {
            WarmupSheet(
                provider: provider,
                accountKey: account.key,
                accountEmail: account.email,
                onDismiss: {
                    showWarmupSheet = false
                }
            )
            .environment(viewModel)
        }
    }
    
    // MARK: - Usage Section

    private var isQuotaUnavailable: Bool {
        guard let data = account.quotaData else { return false }
        return data.models.allSatisfy { $0.percentage < 0 }
    }
    
    private var displayStyle: QuotaDisplayStyle { settings.quotaDisplayStyle }

    @ViewBuilder
    private var usageSection: some View {
        if let data = account.quotaData {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Usage")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    Spacer()

                    if provider == .antigravity && data.models.count > 4 {
                        Button {
                            showModelsDetailSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Text("quota.details".localized())
                                    .font(.caption)
                                Image(systemName: "list.bullet.rectangle")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
                    .opacity(0.5)

                // Display based on quotaDisplayStyle setting
                if isQuotaUnavailable {
                    quotaUnavailableView
                } else {
                    quotaContentByStyle
                }
            }
            .padding(.top, 4)
            .sheet(isPresented: $showModelsDetailSheet) {
                AntigravityModelsDetailSheet(
                    email: account.email,
                    models: data.models
                )
            }
        }
    }
    
    private var quotaUnavailableView: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Text("quota.notAvailable".localized())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
    
    @ViewBuilder
    private var quotaContentByStyle: some View {
        if provider == .antigravity && !antigravityDisplayGroups.isEmpty {
            // Antigravity uses grouped display
            antigravityContentByStyle
        } else if let data = account.quotaData {
            // Standard providers
            standardContentByStyle(data: data)
        }
    }
    
    @ViewBuilder
    private var antigravityContentByStyle: some View {
        switch displayStyle {
        case .lowestBar:
            AntigravityLowestBarLayout(groups: antigravityDisplayGroups)
        case .ring:
            AntigravityRingLayout(groups: antigravityDisplayGroups)
        case .card:
            VStack(spacing: 12) {
                ForEach(antigravityDisplayGroups) { group in
                    AntigravityGroupRow(group: group)
                }
            }
        }
    }
    
    @ViewBuilder
    private func standardContentByStyle(data: ProviderQuotaData) -> some View {
        switch displayStyle {
        case .lowestBar:
            StandardLowestBarLayout(models: data.models)
        case .ring:
            StandardRingLayout(models: data.models)
        case .card:
            VStack(spacing: 12) {
                ForEach(data.models) { model in
                    UsageRowV2(
                        name: model.displayName,
                        icon: nil,
                        usedPercent: model.usedPercentage,
                        used: model.used,
                        limit: model.limit,
                        resetTime: model.formattedResetTime,
                        tooltip: model.tooltip
                    )
                }
            }
        }
    }
}

// MARK: - Plan Badge V2 Compact (for header inline display)

private struct PlanBadgeV2Compact: View {
    let planName: String
    
    private var tierConfig: (name: String, color: Color) {
        let lowercased = planName.lowercased()
        
        // Check for Pro variants
        if lowercased.contains("pro") {
            return ("Pro", .purple)
        }
        
        // Check for Plus
        if lowercased.contains("plus") {
            return ("Plus", .blue)
        }
        
        // Check for Team
        if lowercased.contains("team") {
            return ("Team", .orange)
        }
        
        // Check for Enterprise
        if lowercased.contains("enterprise") {
            return ("Enterprise", .red)
        }
        
        // Free/Standard
        if lowercased.contains("free") || lowercased.contains("standard") {
            return ("Free", .secondary)
        }
        
        // Default: use display name
        let displayName = planName
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        return (displayName, .secondary)
    }
    
    var body: some View {
        Text(tierConfig.name)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(tierConfig.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tierConfig.color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Plan Badge V2

private struct PlanBadgeV2: View {
    let planName: String
    
    private var planConfig: (color: Color, icon: String) {
        let lowercased = planName.lowercased()
        
        // Handle compound names like "Pro Student"
        if lowercased.contains("pro") && lowercased.contains("student") {
            return (.purple, "graduationcap.fill")
        }
        
        switch lowercased {
        case "pro":
            return (.purple, "crown.fill")
        case "plus":
            return (.blue, "plus.circle.fill")
        case "team":
            return (.orange, "person.3.fill")
        case "enterprise":
            return (.red, "building.2.fill")
        case "free":
            return (.secondary, "person.fill")
        case "student":
            return (.green, "graduationcap.fill")
        default:
            return (.secondary, "person.fill")
        }
    }
    
    private var displayName: String {
        planName
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: planConfig.icon)
                .font(.caption)
            Text(displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(planConfig.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(planConfig.color.opacity(0.1))
        .clipShape(Capsule())
    }
}

// MARK: - Subscription Badge V2

private struct SubscriptionBadgeV2: View {
    let info: SubscriptionInfo
    
    private var tierConfig: (name: String, color: Color) {
        let tierId = info.tierId.lowercased()
        let tierName = info.tierDisplayName.lowercased()
        
        // Check for Ultra tier (highest priority)
        if tierId.contains("ultra") || tierName.contains("ultra") {
            return ("Ultra", .orange)
        }
        
        // Check for Pro tier
        if tierId.contains("pro") || tierName.contains("pro") {
            return ("Pro", .purple)
        }
        
        // Check for Free/Standard tier
        if tierId.contains("standard") || tierId.contains("free") || 
           tierName.contains("standard") || tierName.contains("free") {
            return ("Free", .secondary)
        }
        
        // Fallback: use the display name from API
        return (info.tierDisplayName, .secondary)
    }
    
    var body: some View {
        Text(tierConfig.name)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(tierConfig.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tierConfig.color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - Antigravity Display Group

private struct AntigravityDisplayGroup: Identifiable {
    let name: String
    let percentage: Double
    let models: [ModelQuota]
    
    var id: String { name }
}

// MARK: - Antigravity Group Row

private struct AntigravityGroupRow: View {
    let group: AntigravityDisplayGroup
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }

    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }
    
    private var remainingPercent: Double {
        max(0, min(100, group.percentage))
    }
    
    private var groupIcon: String {
        if group.name.contains("Claude") { return "brain.head.profile" }
        if group.name.contains("Image") { return "photo" }
        if group.name.contains("Flash") { return "bolt.fill" }
        return "sparkles"
    }
    
    var body: some View {
        let displayPercent = displayHelper.displayPercent(remainingPercent: remainingPercent)
        let statusColor = displayHelper.statusColor(remainingPercent: remainingPercent)
        
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: groupIcon)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                
                Text(group.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if group.models.count > 1 {
                    Text(String(group.models.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Capsule())
                }
                
                Spacer()
                
                Text(String(format: "%.0f%%", displayPercent))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(statusColor)
                    .monospacedDigit()
                
                if let firstModel = group.models.first,
                   firstModel.formattedResetTime != "—" && !firstModel.formattedResetTime.isEmpty {
                    Text(firstModel.formattedResetTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(statusColor.gradient)
                        .frame(width: proxy.size.width * (displayPercent / 100))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Antigravity Lowest Bar Layout

private struct AntigravityLowestBarLayout: View {
    let groups: [AntigravityDisplayGroup]
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }
    
    private var sorted: [AntigravityDisplayGroup] {
        groups.sorted { $0.percentage < $1.percentage }
    }
    
    private var lowest: AntigravityDisplayGroup? {
        sorted.first
    }
    
    private var others: [AntigravityDisplayGroup] {
        Array(sorted.dropFirst())
    }
    
    private func displayPercent(for remainingPercent: Double) -> Double {
        displayHelper.displayPercent(remainingPercent: remainingPercent)
    }
    
    var body: some View {
        VStack(spacing: 10) {
            if let lowest = lowest {
                // Hero row for bottleneck
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lowest.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(String(format: "%.0f%%", displayPercent(for: lowest.percentage)))
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(displayHelper.statusColor(remainingPercent: lowest.percentage))
                            .monospacedDigit()
                    }
                    
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(displayHelper.statusColor(remainingPercent: lowest.percentage).gradient)
                                .frame(width: proxy.size.width * (displayPercent(for: lowest.percentage) / 100))
                        }
                    }
                    .frame(height: 8)
                }
                .padding(10)
                .background(displayHelper.statusColor(remainingPercent: lowest.percentage).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            
            // Others as compact text rows
            if !others.isEmpty {
                VStack(spacing: 4) {
                    ForEach(others) { group in
                        HStack {
                            Text(group.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", displayPercent(for: group.percentage)))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(displayHelper.statusColor(remainingPercent: group.percentage))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Antigravity Ring Layout

private struct AntigravityRingLayout: View {
    let groups: [AntigravityDisplayGroup]
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }
    
    private var columns: [GridItem] {
        let count = min(max(groups.count, 1), 4)
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }
    
    private func displayPercent(for remainingPercent: Double) -> Double {
        displayHelper.displayPercent(remainingPercent: remainingPercent)
    }
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(groups) { group in
                VStack(spacing: 6) {
                    RingProgressView(
                        percent: displayPercent(for: group.percentage),
                        size: 44,
                        lineWidth: 5,
                        tint: displayHelper.statusColor(remainingPercent: group.percentage),
                        showLabel: true
                    )
                    
                    Text(group.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Standard Lowest Bar Layout

private struct StandardLowestBarLayout: View {
    let models: [ModelQuota]
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }
    
    private var sorted: [ModelQuota] {
        models.sorted { $0.percentage < $1.percentage }
    }
    
    private var lowest: ModelQuota? {
        sorted.first
    }
    
    private var others: [ModelQuota] {
        Array(sorted.dropFirst())
    }
    
    private func displayPercent(for remainingPercent: Double) -> Double {
        displayHelper.displayPercent(remainingPercent: remainingPercent)
    }
    
    var body: some View {
        VStack(spacing: 10) {
            if let lowest = lowest {
                // Hero row for bottleneck
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lowest.displayName)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(String(format: "%.0f%%", displayPercent(for: lowest.percentage)))
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(displayHelper.statusColor(remainingPercent: lowest.percentage))
                            .monospacedDigit()
                    }
                    
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(displayHelper.statusColor(remainingPercent: lowest.percentage).gradient)
                                .frame(width: proxy.size.width * (displayPercent(for: lowest.percentage) / 100))
                        }
                    }
                    .frame(height: 8)
                    
                    if lowest.formattedResetTime != "—" && !lowest.formattedResetTime.isEmpty {
                        Text(lowest.formattedResetTime)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .background(displayHelper.statusColor(remainingPercent: lowest.percentage).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            
            // Others as compact text rows
            if !others.isEmpty {
                VStack(spacing: 4) {
                    ForEach(others) { model in
                        HStack {
                            Text(model.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                                Text(model.formattedResetTime)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(String(format: "%.0f%%", displayPercent(for: model.percentage)))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(displayHelper.statusColor(remainingPercent: model.percentage))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Standard Ring Layout

private struct StandardRingLayout: View {
    let models: [ModelQuota]
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }
    
    private var columns: [GridItem] {
        let count = min(max(models.count, 1), 4)
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }
    
    private func displayPercent(for remainingPercent: Double) -> Double {
        displayHelper.displayPercent(remainingPercent: remainingPercent)
    }
    
    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(models) { model in
                VStack(spacing: 6) {
                    RingProgressView(
                        percent: displayPercent(for: model.percentage),
                        size: 44,
                        lineWidth: 5,
                        tint: displayHelper.statusColor(remainingPercent: model.percentage),
                        showLabel: true
                    )
                    
                    Text(model.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    
                    if model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                        Text(model.formattedResetTime)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Antigravity Models Detail Sheet

private struct AntigravityModelsDetailSheet: View {
    let email: String
    let models: [ModelQuota]
    
    @Environment(\.dismiss) private var dismiss
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    
    private var sortedModels: [ModelQuota] {
        models.sorted { $0.name < $1.name }
    }
    
    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("quota.allModels".localized())
                        .font(.headline)
                    Text(email.masked(if: settings.hideSensitiveInfo))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("action.close".localized())
            }
            .padding()
            
            Divider()
                .opacity(0.5)
            
            // Models Grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(sortedModels) { model in
                        ModelDetailCard(model: model)
                    }
                }
                .padding()
            }
            .scrollContentBackground(.hidden)
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(.background)
    }
}

// MARK: - Model Detail Card (for sheet)

private struct ModelDetailCard: View {
    let model: ModelQuota
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }
    
    private var remainingPercent: Double {
        max(0, min(100, model.percentage))
    }
    
    var body: some View {
        let displayPercent = displayHelper.displayPercent(remainingPercent: remainingPercent)
        let statusColor = displayHelper.statusColor(remainingPercent: remainingPercent)
        
        VStack(alignment: .leading, spacing: 8) {
            // Model name (raw name)
            Text(model.name)
                .font(.caption)
                .fontDesign(.monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
            // Progress bar
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(statusColor.gradient)
                        .frame(width: proxy.size.width * (displayPercent / 100))
                }
            }
            .frame(height: 6)
            
            // Footer: Percentage + Reset time
            HStack {
                Text(String(format: "%.0f%%", displayPercent))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(statusColor)
                    .monospacedDigit()
                
                Spacer()
                
                if model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                    Text(model.formattedResetTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Usage Row V2

private struct UsageRowV2: View {
    let name: String
    let icon: String?
    let usedPercent: Double
    let used: Int?
    let limit: Int?
    let resetTime: String
    let tooltip: String?
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }
    
    private var isUnknown: Bool {
        usedPercent < 0 || usedPercent > 100
    }
    
    private var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
    
    var body: some View {
        let displayPercent = displayHelper.displayPercent(remainingPercent: remainingPercent)
        let statusColor = displayHelper.statusColor(remainingPercent: remainingPercent)
        
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                }
                
                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .help(tooltip ?? "")
                
                Spacer()
                
                if let used = used {
                    if let limit = limit, limit > 0 {
                        Text(String(used) + "/" + String(limit))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                
                if !isUnknown {
                    Text(String(format: "%.0f%%", displayPercent))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(statusColor)
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                
                if resetTime != "—" && !resetTime.isEmpty {
                    Text(resetTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            if !isUnknown {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(statusColor.gradient)
                            .frame(width: proxy.size.width * (displayPercent / 100))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

// MARK: - Loading View

private struct QuotaLoadingView: View {
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 16) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 100, height: 12)
                        Spacer()
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 48, height: 12)
                    }
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 6)
                }
            }
        }
        .opacity(isAnimating ? 0.4 : 1)
        .animation(.easeOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
        .onAppear { isAnimating = true }
    }
}

// MARK: - Preview

#Preview {
    QuotaScreen()
        .environment(QuotaViewModel())
        .frame(width: 600, height: 500)
}
