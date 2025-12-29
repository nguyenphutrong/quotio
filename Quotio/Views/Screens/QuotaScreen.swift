//
//  QuotaScreen.swift
//  Quotio
//
//  Redesigned Quota UI with segmented provider control and improved hierarchy
//

import SwiftUI

struct QuotaScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    private let modeManager = AppModeManager.shared
    
    @State private var selectedProvider: AIProvider?
    
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
    
    /// Get lowest quota percentage for a provider (for segment indicator)
    private func lowestQuotaPercent(for provider: AIProvider) -> Double? {
        guard let accounts = viewModel.providerQuotas[provider] else { return nil }
        
        var lowestPercent: Double? = nil
        for (_, quotaData) in accounts {
            for model in quotaData.models {
                if model.percentage >= 0 {
                    if lowestPercent == nil || model.percentage < lowestPercent! {
                        lowestPercent = model.percentage
                    }
                }
            }
        }
        return lowestPercent
    }
    
    /// Check if we have any data to show
    private var hasAnyData: Bool {
        if modeManager.isQuotaOnlyMode {
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
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }
            
            // Selected Provider Content
            ScrollView {
                if let provider = selectedProvider ?? availableProviders.first {
                    ProviderQuotaView(
                        provider: provider,
                        authFiles: viewModel.authFiles.filter { $0.providerType == provider },
                        quotaData: viewModel.providerQuotas[provider] ?? [:],
                        subscriptionInfos: viewModel.subscriptionInfos,
                        isLoading: viewModel.isLoadingQuotas
                    )
                    .padding(20)
                } else {
                    ContentUnavailableView(
                        "empty.noQuotaData".localized(),
                        systemImage: "chart.bar.xaxis",
                        description: Text("empty.refreshToLoad".localized())
                    )
                    .padding(20)
                }
            }
        }
    }
    
    // MARK: - Segmented Control
    
    private var providerSegmentedControl: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableProviders, id: \.self) { provider in
                    ProviderSegmentButton(
                        provider: provider,
                        quotaPercent: lowestQuotaPercent(for: provider),
                        accountCount: accountCount(for: provider),
                        isSelected: selectedProvider == provider
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedProvider = provider
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Provider Segment Button

private struct ProviderSegmentButton: View {
    let provider: AIProvider
    let quotaPercent: Double?
    let accountCount: Int
    let isSelected: Bool
    let action: () -> Void
    
    private var statusColor: Color {
        guard let percent = quotaPercent else { return .gray }
        if percent > 30 { return .green }    // >30% remaining = healthy
        if percent > 10 { return .yellow }   // 10-30% remaining = warning
        return .red                           // <10% remaining = critical
    }
    
    private var usedPercent: Double {
        guard let percent = quotaPercent else { return 0 }
        return 100 - percent
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ProviderIcon(provider: provider, size: 18)
                
                Text(provider.displayName)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .medium)
                
                // Account count badge
                if accountCount > 0 {
                    Text("\(accountCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.accentColor : Color.secondary)
                        .clipShape(Capsule())
                }
                
                // Status indicator
                if quotaPercent != nil {
                    QuotaStatusDot(usedPercent: usedPercent, size: 8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
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
                    subscriptionInfo: nil
                ))
            }
        }
        
        return accounts.sorted { $0.email < $1.email }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Loading indicator at top if loading
            if isLoading && !allAccounts.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            
            // Account Cards
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
        GroupBox {
            VStack(spacing: 12) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("quota.noDataYet".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
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
    let provider: AIProvider
    let account: AccountInfo
    let isLoading: Bool
    
    @State private var isRefreshing = false
    
    private var hasQuotaData: Bool {
        guard let data = account.quotaData else { return false }
        return !data.models.isEmpty
    }
    
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                // Account Header
                accountHeader
                
                // Plan Badge
                planSection
                
                // Usage Section
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
        }
    }
    
    // MARK: - Account Header
    
    private var accountHeader: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(account.statusColor)
                .frame(width: 10, height: 10)
            
            // Email
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                    .font(.headline)
                    .lineLimit(1)
                
                if account.status != "ready" && account.status != "active" {
                    Text(account.status.capitalized)
                        .font(.caption)
                        .foregroundStyle(account.statusColor)
                }
            }
            
            Spacer()
            
            // Refresh button
            Button {
                Task {
                    isRefreshing = true
                    await viewModel.refreshQuotaForProvider(provider)
                    isRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isRefreshing || isLoading)
            .opacity(isRefreshing ? 0.5 : 1)
            
            // Forbidden badge
            if let data = account.quotaData, data.isForbidden {
                Label("Limit Reached", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.red.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
    }
    
    // MARK: - Plan Section
    
    @ViewBuilder
    private var planSection: some View {
        if let info = account.subscriptionInfo {
            SubscriptionBadgeV2(info: info)
        } else if let planName = account.quotaData?.planDisplayName {
            PlanBadgeV2(planName: planName)
        }
    }
    
    // MARK: - Usage Section
    
    @ViewBuilder
    private var usageSection: some View {
        if let data = account.quotaData {
            VStack(alignment: .leading, spacing: 4) {
                Text("Usage")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                
                Divider()
                
                VStack(spacing: 14) {
                    if provider == .antigravity && data.hasGroupedModels {
                        ForEach(data.groupedModels) { groupedModel in
                            UsageRowV2(
                                name: groupedModel.displayName,
                                icon: groupedModel.group.icon,
                                usedPercent: 100 - groupedModel.percentage,
                                used: nil,
                                limit: nil,
                                resetTime: groupedModel.formattedResetTime
                            )
                        }
                    } else {
                        ForEach(data.models.sorted { $0.name < $1.name }) { model in
                            UsageRowV2(
                                name: model.displayName,
                                icon: nil,
                                usedPercent: model.usedPercentage,
                                used: model.used,
                                limit: model.limit,
                                resetTime: model.formattedResetTime
                            )
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Plan Badge V2

private struct PlanBadgeV2: View {
    let planName: String
    
    private var planConfig: (color: Color, icon: String, description: String) {
        let lowercased = planName.lowercased()
        
        // Handle compound names like "Pro Student"
        if lowercased.contains("pro") && lowercased.contains("student") {
            return (.purple, "graduationcap.fill", "Student Pro Plan")
        }
        
        switch lowercased {
        case "pro":
            return (.purple, "crown.fill", "Premium features unlocked")
        case "plus":
            return (.blue, "plus.circle.fill", "Enhanced features")
        case "team":
            return (.orange, "person.3.fill", "Team collaboration")
        case "enterprise":
            return (.red, "building.2.fill", "Enterprise features")
        case "free":
            return (.gray, "person.fill", "Free tier")
        case "student":
            return (.green, "graduationcap.fill", "Student plan")
        default:
            return (.secondary, "person.fill", "")
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
        HStack(spacing: 10) {
            // Icon and name
            HStack(spacing: 6) {
                Image(systemName: planConfig.icon)
                    .font(.subheadline)
                Text(displayName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(planConfig.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(planConfig.color.opacity(0.12))
            .clipShape(Capsule())
            
            // Description tooltip (for Pro/Plus differentiation)
            if !planConfig.description.isEmpty {
                Text(planConfig.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Subscription Badge V2

private struct SubscriptionBadgeV2: View {
    let info: SubscriptionInfo
    
    private var tierConfig: (color: Color, icon: String) {
        switch info.tierId {
        case "g1-pro-tier":
            return (.purple, "crown.fill")
        case "g1-ultra-tier":
            return (.orange, "star.fill")
        case "standard-tier":
            return (.blue, "star.fill")
        default:
            return (.gray, "person.fill")
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // Tier badge
                HStack(spacing: 6) {
                    Image(systemName: tierConfig.icon)
                        .font(.subheadline)
                    Text(info.tierDisplayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(tierConfig.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(tierConfig.color.opacity(0.12))
                .clipShape(Capsule())
                
                // Project info
                if let project = info.cloudaicompanionProject {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.caption)
                        Text(project)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            
            // Upgrade prompt
            if let paidTier = info.paidTier,
               let upgradeUri = paidTier.upgradeSubscriptionUri,
               let url = URL(string: upgradeUri) {
                UpgradePromptView(paidTier: paidTier, url: url)
            }
        }
    }
}

// MARK: - Upgrade Prompt

private struct UpgradePromptView: View {
    let paidTier: SubscriptionTier
    let url: URL
    
    private var tierColor: Color {
        switch paidTier.id {
        case "g1-pro-tier": return .purple
        case "g1-ultra-tier": return .orange
        default: return .purple
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                    Text(paidTier.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .foregroundStyle(tierColor)
                
                if let text = paidTier.upgradeSubscriptionText {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            Link(destination: url) {
                Text("Upgrade")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
            .tint(tierColor)
            .controlSize(.small)
        }
        .padding(12)
        .background(tierColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
    
    @State private var settings = MenuBarSettingsManager.shared
    
    private var isUnknown: Bool {
        usedPercent < 0 || usedPercent > 100
    }
    
    private var statusColor: Color {
        if isUnknown { return .gray }
        if usedPercent < 70 { return .green }   // <70% used = healthy
        if usedPercent < 90 { return .yellow }  // 70-90% used = warning
        return .red                              // >90% used = critical
    }
    
    private var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
    
    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayPercent = displayMode == .used ? usedPercent : remainingPercent
        
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Model name with icon
                HStack(spacing: 6) {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                
                Spacer()
                
                // Usage info
                HStack(spacing: 10) {
                    // Count (e.g., "150/2000")
                    if let used = used {
                        if let limit = limit, limit > 0 {
                            Text("\(used)/\(limit)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            Text("\(used) used")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Percentage with color
                    if !isUnknown {
                        Text(String(format: "%.0f%% %@", displayPercent, displayMode.suffixKey.localized()))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(statusColor)
                    } else {
                        Text("—")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Reset time
                    if resetTime != "—" && !resetTime.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.caption2)
                            Text(resetTime)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary)
                        .clipShape(Capsule())
                    }
                }
            }
            
            // Progress bar (showing remaining)
            if !isUnknown {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                        Capsule()
                            .fill(statusColor.gradient)
                            .frame(width: proxy.size.width * (remainingPercent / 100))
                    }
                }
                .frame(height: 8)
            }
        }
    }
}

// MARK: - Loading View

private struct QuotaLoadingView: View {
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .frame(width: 100, height: 14)
                        Spacer()
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .frame(width: 60, height: 14)
                    }
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .frame(height: 8)
                }
            }
        }
        .opacity(isAnimating ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isAnimating)
        .onAppear { isAnimating = true }
    }
}

// MARK: - Preview

#Preview {
    QuotaScreen()
        .environment(QuotaViewModel())
        .frame(width: 600, height: 500)
}
