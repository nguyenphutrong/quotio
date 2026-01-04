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
                // availableProviders is already sorted; AIProvider is Identifiable
                ForEach(availableProviders) { provider in
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
                    subscriptionInfo: subscriptionInfos[key]
                ))
            }
        }
        
        return accounts.sorted { $0.email < $1.email }
    }
    
    var body: some View {
        VStack(spacing: 16) {
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
        
        // Gemini 3 Pro (excluding image models)
        let gemini3ProModels = data.models.filter { 
            $0.name.contains("gemini-3-pro") && !$0.name.contains("image") 
        }
        if !gemini3ProModels.isEmpty {
            let minQuota = gemini3ProModels.map(\.percentage).min() ?? 0
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Pro", percentage: minQuota, models: gemini3ProModels))
        }
        
        // Gemini 3 Flash
        let gemini3FlashModels = data.models.filter { $0.name.contains("gemini-3-flash") }
        if !gemini3FlashModels.isEmpty {
            let minQuota = gemini3FlashModels.map(\.percentage).min() ?? 0
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Flash", percentage: minQuota, models: gemini3FlashModels))
        }
        
        // Gemini 3 Image (any model containing "image")
        let geminiImageModels = data.models.filter { $0.name.contains("image") }
        if !geminiImageModels.isEmpty {
            let minQuota = geminiImageModels.map(\.percentage).min() ?? 0
            groups.append(AntigravityDisplayGroup(name: "Gemini 3 Image", percentage: minQuota, models: geminiImageModels))
        }
        
        // Claude (any model containing "claude")
        let claudeModels = data.models.filter { $0.name.contains("claude") }
        if !claudeModels.isEmpty {
            let minQuota = claudeModels.map(\.percentage).min() ?? 0
            groups.append(AntigravityDisplayGroup(name: "Claude", percentage: minQuota, models: claudeModels))
        }
        
        // Sort by lowest quota first (most urgent)
        return groups.sorted { $0.percentage < $1.percentage }
    }
    
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                // Account Header
                accountHeader
                
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
            // Tier badge (before email) - Antigravity uses SubscriptionBadgeV2, others use PlanBadgeV2
            if let info = account.subscriptionInfo {
                SubscriptionBadgeV2(info: info)
            } else if let planName = account.quotaData?.planDisplayName {
                PlanBadgeV2Compact(planName: planName)
            }
            
            // Email
            VStack(alignment: .leading, spacing: 2) {
                Text(displayEmail)
                    .font(.headline)
                    .lineLimit(1)
                
                if account.status != "ready" && account.status != "active" {
                    Text(account.status.capitalized)
                        .font(.caption)
                        .foregroundStyle(account.statusColor)
                }
            }
            
            Spacer()
            
            if provider == .antigravity {
                Button {
                    showWarmupSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isWarmupEnabled ? "bolt.fill" : "bolt")
                            .font(.caption)
                        Text("action.warmup".localized())
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isWarmupEnabled ? provider.color.opacity(0.15) : Color.secondary.opacity(0.1))
                    .foregroundStyle(isWarmupEnabled ? provider.color : .secondary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            
            // Active badge (Antigravity only)
            if isActiveInIDE {
                Text("antigravity.active".localized())
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(Color(red: 0.13, green: 0.55, blue: 0.13))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(red: 0.85, green: 0.95, blue: 0.85))
                    .clipShape(Capsule())
            }
            
            // Switch account button (Antigravity, non-active)
            if provider == .antigravity && !isActiveInIDE {
                Button {
                    showSwitchSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.caption)
                        Text("antigravity.useInIDE".localized())
                            .font(.caption)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            
            // Refresh button - shows loader when loading
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
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .frame(width: 24, height: 24)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isRefreshing || isLoading)
            
            // Forbidden badge or Re-authenticate button
            if let data = account.quotaData, data.isForbidden {
                if provider == .claude {
                    // Claude Code: Token expired, show re-authenticate button
                    Button {
                        Task {
                            await viewModel.startOAuth(for: .claude)
                        }
                    } label: {
                        if isReauthenticating {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("quota.reauthenticating".localized())
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.orange.opacity(0.1))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                        } else {
                            Label("quota.reauthenticate".localized(), systemImage: "arrow.clockwise.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.orange.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isReauthenticating)
                } else {
                    // Other providers: Limit reached badge
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
    
    // MARK: - Plan Section (removed - now in header)
    
    // MARK: - Usage Section

    /// Check if all models have unavailable quota (percentage == -1)
    private var isQuotaUnavailable: Bool {
        guard let data = account.quotaData else { return false }
        return data.models.allSatisfy { $0.percentage < 0 }
    }

    @ViewBuilder
    private var usageSection: some View {
        if let data = account.quotaData {
            VStack(alignment: .leading, spacing: 4) {
                // Header with Details button for Antigravity
                HStack {
                    Text("Usage")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    Spacer()

                    // Details button for Antigravity (shows all models)
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

                VStack(spacing: 14) {
                    // Check if quota is unavailable (e.g., Gemini CLI has no public quota API)
                    if isQuotaUnavailable {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text("quota.notAvailable".localized())
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    // Antigravity uses 4-group display (non-expandable)
                    else if provider == .antigravity && !antigravityDisplayGroups.isEmpty {
                        ForEach(antigravityDisplayGroups) { group in
                            AntigravityGroupRow(group: group)
                        }
                    } else {
                        // Other providers show individual models
                        ForEach(data.models) { model in
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
            .sheet(isPresented: $showModelsDetailSheet) {
                AntigravityModelsDetailSheet(
                    email: account.email,
                    models: data.models
                )
            }
        }
    }
}

// MARK: - Plan Badge V2 Compact (for header inline display)

private struct PlanBadgeV2Compact: View {
    let planName: String
    
    private var tierConfig: (name: String, bgColor: Color, textColor: Color) {
        let lowercased = planName.lowercased()
        
        // Check for Pro variants
        if lowercased.contains("pro") {
            return ("Pro", Color(red: 0.8, green: 0.9, blue: 1.0), Color(red: 0.0, green: 0.25, blue: 0.52))
        }
        
        // Check for Plus
        if lowercased.contains("plus") {
            return ("Plus", Color(red: 0.85, green: 0.9, blue: 1.0), Color(red: 0.0, green: 0.3, blue: 0.6))
        }
        
        // Check for Team
        if lowercased.contains("team") {
            return ("Team", Color(red: 1.0, green: 0.9, blue: 0.8), Color(red: 0.6, green: 0.3, blue: 0.0))
        }
        
        // Check for Enterprise
        if lowercased.contains("enterprise") {
            return ("Enterprise", Color(red: 1.0, green: 0.85, blue: 0.85), Color(red: 0.5, green: 0.0, blue: 0.0))
        }
        
        // Free/Standard
        if lowercased.contains("free") || lowercased.contains("standard") {
            return ("Free", Color(red: 0.91, green: 0.93, blue: 0.94), Color(red: 0.42, green: 0.46, blue: 0.49))
        }
        
        // Default: use display name
        let displayName = planName
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        return (displayName, Color(red: 0.91, green: 0.93, blue: 0.94), Color(red: 0.42, green: 0.46, blue: 0.49))
    }
    
    var body: some View {
        Text(tierConfig.name)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(tierConfig.textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tierConfig.bgColor)
            .clipShape(Capsule())
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
    
    private var tierConfig: (name: String, bgColor: Color, textColor: Color) {
        let tierId = info.tierId.lowercased()
        let tierName = info.tierDisplayName.lowercased()
        
        // Check for Ultra tier (highest priority)
        if tierId.contains("ultra") || tierName.contains("ultra") {
            return ("Ultra", Color(red: 1.0, green: 0.95, blue: 0.8), Color(red: 0.52, green: 0.39, blue: 0.02))
        }
        
        // Check for Pro tier
        if tierId.contains("pro") || tierName.contains("pro") {
            return ("Pro", Color(red: 0.8, green: 0.9, blue: 1.0), Color(red: 0.0, green: 0.25, blue: 0.52))
        }
        
        // Check for Free/Standard tier
        if tierId.contains("standard") || tierId.contains("free") || 
           tierName.contains("standard") || tierName.contains("free") {
            return ("Free", Color(red: 0.91, green: 0.93, blue: 0.94), Color(red: 0.42, green: 0.46, blue: 0.49))
        }
        
        // Fallback: use the display name from API
        return (info.tierDisplayName, Color(red: 0.91, green: 0.93, blue: 0.94), Color(red: 0.42, green: 0.46, blue: 0.49))
    }
    
    var body: some View {
        Text(tierConfig.name)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(tierConfig.textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tierConfig.bgColor)
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

// MARK: - Antigravity Group Row (non-expandable)

private struct AntigravityGroupRow: View {
    let group: AntigravityDisplayGroup
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var usedPercent: Double {
        100 - group.percentage
    }
    
    private var statusColor: Color {
        if usedPercent < 70 { return .green }
        if usedPercent < 90 { return .yellow }
        return .red
    }
    
    private var remainingPercent: Double {
        max(0, min(100, group.percentage))
    }
    
    private var groupIcon: String {
        if group.name.contains("Claude") { return "brain.head.profile" }
        if group.name.contains("Image") { return "photo" }
        if group.name.contains("Flash") { return "bolt.fill" }
        return "sparkles" // Gemini Pro
    }
    
    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayPercent = displayMode == .used ? usedPercent : remainingPercent
        
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Group icon and name
                HStack(spacing: 6) {
                    Image(systemName: groupIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(group.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                
                // Model count badge
                if group.models.count > 1 {
                    Text("\(group.models.count)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
                
                Spacer()
                
                // Usage info
                HStack(spacing: 10) {
                    Text(String(format: "%.0f%% %@", displayPercent, displayMode.suffixKey.localized()))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(statusColor)
                    
                    // Reset time from first model
                    if let firstModel = group.models.first,
                       firstModel.formattedResetTime != "—" && !firstModel.formattedResetTime.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.caption2)
                            Text(firstModel.formattedResetTime)
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
            
            // Progress bar
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
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // Models Grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(sortedModels) { model in
                        ModelDetailCard(model: model)
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - Model Detail Card (for sheet)

private struct ModelDetailCard: View {
    let model: ModelQuota
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    
    private var usedPercent: Double {
        model.usedPercentage
    }
    
    private var remainingPercent: Double {
        max(0, min(100, model.percentage))
    }
    
    private var statusColor: Color {
        if usedPercent >= 90 { return .red }
        if usedPercent >= 70 { return .yellow }
        return .green
    }
    
    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayPercent = displayMode == .used ? usedPercent : remainingPercent
        
        VStack(alignment: .leading, spacing: 10) {
            // Model name (raw name)
            Text(model.name)
                .font(.caption)
                .fontDesign(.monospaced)
                .lineLimit(1)
            
            // Progress bar
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(statusColor.gradient)
                        .frame(width: proxy.size.width * (remainingPercent / 100))
                }
            }
            .frame(height: 6)
            
            // Footer: Percentage + Reset time
            HStack {
                Text(String(format: "%.0f%% %@", displayPercent, displayMode.suffixKey.localized()))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(statusColor)
                
                Spacer()
                
                if model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(model.formattedResetTime)
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    
    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    
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
