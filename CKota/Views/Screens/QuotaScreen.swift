//
//  QuotaScreen.swift
//  CKota
//
//  Redesigned Quota UI with 2-column grid, avatar icons, and mockup-matching design
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

        // From proxy auth files (Full Mode)
        for file in viewModel.authFiles {
            if let provider = file.providerType {
                providers.insert(provider)
            }
        }

        // From direct auth files (Quota-Only Mode)
        for file in viewModel.directAuthFiles {
            providers.insert(file.provider)
        }

        // From quota data
        for provider in viewModel.providerQuotas.keys {
            providers.insert(provider)
        }

        return providers.sorted { $0.displayName < $1.displayName }
    }

    /// Get account count for a provider
    private func accountCount(for provider: AIProvider) -> Int {
        var accounts = Set<String>()

        // From proxy auth files (Full Mode)
        for file in viewModel.authFiles where file.providerType == provider {
            accounts.insert(file.quotaLookupKey)
        }

        // From direct auth files (Quota-Only Mode)
        for file in viewModel.directAuthFiles where file.provider == provider {
            accounts.insert(file.email ?? file.filename)
        }

        // From quota data
        if let quotaAccounts = viewModel.providerQuotas[provider] {
            for key in quotaAccounts.keys {
                accounts.insert(key)
            }
        }

        return accounts.count
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
            if modeManager.isFullMode, !viewModel.proxyManager.proxyStatus.running {
                ContentUnavailableView(
                    "empty.proxyNotRunning".localized(),
                    systemImage: "bolt.slash",
                    description: Text("empty.startProxyToView".localized())
                )
            } else if !hasAnyData {
                ContentUnavailableView(
                    "empty.noAccounts".localized(),
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("empty.addProviderAccounts".localized())
                )
            } else {
                mainContent
            }
        }
        .navigationTitle("nav.analytics".localized())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        if modeManager.isQuotaOnlyMode {
                            await viewModel.refreshQuotasDirectly()
                        } else {
                            await viewModel.refreshAllQuotas()
                        }
                    }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel
                    .isLoadingQuotas || (modeManager.isFullMode && !viewModel.proxyManager.proxyStatus.running))
                .accessibilityLabel("Refresh quota data")
                .accessibilityHint("Double tap to fetch latest quota information")
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
        .onReceive(NotificationCenter.default.publisher(for: .switchToNextTab)) { _ in
            guard viewModel.currentPage == .analytics else { return }
            switchToNextProvider()
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToPreviousTab)) { _ in
            guard viewModel.currentPage == .analytics else { return }
            switchToNextProvider(reverse: true)
        }
    }

    // MARK: - Provider Navigation

    private func switchToNextProvider(reverse: Bool = false) {
        guard !availableProviders.isEmpty else { return }
        guard let current = selectedProvider,
              let currentIndex = availableProviders.firstIndex(of: current)
        else {
            selectedProvider = availableProviders.first
            return
        }
        let nextIndex: Int = if reverse {
            (currentIndex - 1 + availableProviders.count) % availableProviders.count
        } else {
            (currentIndex + 1) % availableProviders.count
        }
        withAnimation(.ckStandard) {
            selectedProvider = availableProviders[nextIndex]
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Provider Filter Chips
            if availableProviders.count > 0 {
                providerFilterChips
                    .padding(.horizontal, CKLayout.contentPadding)
                    .padding(.top, .ckLG)
                    .padding(.bottom, .ckSM)
            }

            // Selected Provider Content
            ScrollView {
                if let provider = selectedProvider ?? availableProviders.first {
                    ProviderQuotaView(
                        provider: provider,
                        authFiles: viewModel.authFiles.filter { $0.providerType == provider },
                        directAuthFiles: viewModel.directAuthFiles.filter { $0.provider == provider },
                        quotaData: viewModel.providerQuotas[provider] ?? [:],
                        subscriptionInfos: viewModel.subscriptionInfos,
                        isLoading: viewModel.isLoadingQuotas
                    )
                    .padding(CKLayout.contentPadding)
                } else {
                    ContentUnavailableView(
                        "empty.noQuotaData".localized(),
                        systemImage: "chart.bar.xaxis",
                        description: Text("empty.refreshToLoad".localized())
                    )
                    .padding(CKLayout.contentPadding)
                }
            }
        }
    }

    // MARK: - Provider Filter Chips (Mockup Style)

    private var providerFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: .ckSM) {
                ForEach(availableProviders, id: \.self) { provider in
                    ProviderFilterChip(
                        provider: provider,
                        accountCount: accountCount(for: provider),
                        isSelected: selectedProvider == provider
                    ) {
                        withAnimation(.ckStandard) {
                            selectedProvider = provider
                        }
                    }
                }
            }
            .padding(.horizontal, .ckXS)
        }
    }
}

// MARK: - Provider Filter Chip (Mockup-Matching Design)

private struct ProviderFilterChip: View {
    let provider: AIProvider
    let accountCount: Int
    let isSelected: Bool
    let action: () -> Void

    // Selected tabs: card background with provider-colored border (adapts to dark mode)
    private var chipBackground: some ShapeStyle {
        isSelected ? AnyShapeStyle(Color.ckCard) : AnyShapeStyle(Color.ckMuted)
    }

    private var chipForeground: Color {
        isSelected ? provider.color : .ckForeground
    }

    private var chipBorderColor: Color {
        isSelected ? provider.color : .ckBorder
    }

    private var badgeBackground: some ShapeStyle {
        isSelected ? AnyShapeStyle(provider.color) : AnyShapeStyle(Color.ckWarning)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: .ckSM) {
                // Provider icon
                ProviderIcon(provider: provider, size: 18)

                // Provider name
                Text(provider.displayName)
                    .font(.ckBodyMedium)

                // Account count badge
                Text("\(accountCount)")
                    .font(.ckCaption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(badgeBackground)
                    )
            }
            .padding(.horizontal, .ckLG)
            .padding(.vertical, .ckSM)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(chipBackground)
                    .overlay(
                        // Border when selected (strokeBorder draws inside)
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(chipBorderColor, lineWidth: 1.5)
                    )
            )
            .foregroundStyle(chipForeground)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.displayName), \(accountCount) account\(accountCount == 1 ? "" : "s")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
        .ckCursorPointer()
    }
}

// MARK: - Provider Quota View

private struct ProviderQuotaView: View {
    let provider: AIProvider
    let authFiles: [AuthFile]
    let directAuthFiles: [DirectAuthFile] // For Quota-Only Mode
    let quotaData: [String: ProviderQuotaData]
    let subscriptionInfos: [String: SubscriptionInfo]
    let isLoading: Bool

    /// Get all accounts (from auth files, direct auth files, or quota data keys)
    private var allAccounts: [AccountInfo] {
        var accounts: [AccountInfo] = []
        var seenKeys = Set<String>()

        // From proxy auth files (Full Mode)
        for file in authFiles {
            let key = file.quotaLookupKey

            // Try multiple lookup keys to find quota data
            let matchedQuotaData: ProviderQuotaData? = {
                // 1. Try quotaLookupKey
                if let data = quotaData[key] {
                    return data
                }

                // 2. Try email directly
                if let email = file.email, let data = quotaData[email] {
                    return data
                }

                // 3. Try name-derived key (strip prefix and .json)
                var nameKey = file.name
                if nameKey.hasSuffix(".json") {
                    nameKey = String(nameKey.dropLast(".json".count))
                }
                let prefixes = ["claude-", "antigravity-"]
                for prefix in prefixes where nameKey.hasPrefix(prefix) {
                    nameKey = String(nameKey.dropFirst(prefix.count))
                    break
                }
                if let data = quotaData[nameKey] {
                    return data
                }

                return nil
            }()

            seenKeys.insert(key)
            if let email = file.email { seenKeys.insert(email) }

            accounts.append(AccountInfo(
                key: key,
                email: file.email ?? file.name,
                status: file.status,
                statusColor: file.statusColor,
                authFile: file,
                quotaData: matchedQuotaData,
                // Only show subscription info for Antigravity (it's provider-specific)
                subscriptionInfo: provider == .antigravity ? subscriptionInfos[key] : nil
            ))
        }

        // From direct auth files (Quota-Only Mode)
        for file in directAuthFiles {
            let key = file.email ?? file.filename
            if seenKeys.contains(key) { continue }
            seenKeys.insert(key)

            accounts.append(AccountInfo(
                key: key,
                email: file.email ?? file.filename,
                status: "loading", // Will be updated when quota loads
                statusColor: .gray,
                authFile: nil,
                quotaData: quotaData[key],
                subscriptionInfo: provider == .antigravity ? subscriptionInfos[key] : nil
            ))
        }

        // From quota data (if not already added from auth files)
        for (key, data) in quotaData {
            if seenKeys.contains(key) { continue }
            seenKeys.insert(key)

            accounts.append(AccountInfo(
                key: key,
                email: key,
                status: "unknown",
                statusColor: .gray,
                authFile: nil,
                quotaData: data,
                subscriptionInfo: nil
            ))
        }

        return accounts.sorted { $0.email < $1.email }
    }

    // 2-column grid layout
    private let columns = [
        GridItem(.flexible(), spacing: CKLayout.cardGap),
        GridItem(.flexible(), spacing: CKLayout.cardGap),
    ]

    var body: some View {
        VStack(spacing: .ckLG) {
            // Account Cards - 2 Column Grid
            if allAccounts.isEmpty, isLoading {
                QuotaLoadingView()
            } else if allAccounts.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, spacing: CKLayout.cardGap) {
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
    }

    private var emptyState: some View {
        VStack(spacing: .ckMD) {
            Image(systemName: "chart.bar.xaxis")
                .font(.largeTitle)
                .foregroundStyle(Color.ckMutedForeground)
            Text("quota.noDataYet".localized())
                .font(.ckCallout)
                .foregroundStyle(Color.ckMutedForeground)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, .ckXXL)
        .ckCard()
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

// MARK: - Account Quota Card V2 (Mockup-Matching Design)

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

    /// Determine status from quota data first, then fall back to auth file status
    private var statusType: CKStatusDot.Status {
        // If we have quota data, derive status from it
        if let data = account.quotaData {
            // Check if forbidden/exhausted (token expired or rate limited)
            if data.isForbidden {
                return .exhausted
            }

            // If we have model data, derive status from percentages
            if !data.models.isEmpty {
                // Find the lowest remaining percentage
                let lowestPercent = data.models.map(\.percentage).min() ?? 100

                if lowestPercent <= 0 {
                    return .exhausted
                } else if lowestPercent < 20 {
                    return .cooling
                } else {
                    return .ready
                }
            }
        }

        // Fall back to auth file status
        switch account.status.lowercased() {
        case "ready", "active": return .ready
        case "cooling": return .cooling
        case "error", "exhausted": return .exhausted
        case "loading": return isLoading ? .ready : .unknown // Show ready (loading pulse) while loading
        default: return .unknown
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .ckLG) {
            // Account Header with Avatar
            accountHeader

            // Usage Section
            if isLoading {
                QuotaLoadingView()
            } else if hasQuotaData {
                usageSection
            } else if let data = account.quotaData, data.isForbidden {
                // Token expired or rate limited
                Text("quota.tokenExpired".localized())
                    .font(.ckCallout)
                    .foregroundStyle(Color.ckDestructive)
            } else if let message = account.authFile?.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.ckCallout)
                    .foregroundStyle(Color.ckMutedForeground)
            }
        }
        .ckCard()
        .ckCardHover()
    }

    // MARK: - Account Header with Avatar

    private var accountHeader: some View {
        HStack(spacing: .ckMD) {
            // Circular Avatar with provider icon
            ZStack {
                // Card background with subtle border (adapts to dark mode)
                Circle()
                    .fill(Color.ckCard)
                    .overlay(
                        Circle()
                            .stroke(Color.ckBorder, lineWidth: 1)
                    )
                    .frame(width: CKLayout.avatarSize, height: CKLayout.avatarSize)

                // Provider icon
                ProviderIcon(provider: provider, size: 20)
            }

            // Email and Status
            VStack(alignment: .leading, spacing: .ckXXS) {
                Text(account.email)
                    .font(.ckHeadline)
                    .lineLimit(1)

                // Status indicator using design system
                CKStatusDot(status: statusType, showLabel: true, showPulse: statusType == .ready)
            }

            Spacer()

            // Refresh button with rotation animation when loading
            Button {
                Task {
                    isRefreshing = true
                    await viewModel.refreshQuotaForProvider(provider)
                    isRefreshing = false
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.ckCallout)
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(
                        isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                        value: isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ckMutedForeground)
            .disabled(isRefreshing || isLoading)
            .ckCursorPointer()
        }
    }

    // MARK: - Usage Section

    @ViewBuilder
    private var usageSection: some View {
        if let data = account.quotaData {
            VStack(alignment: .leading, spacing: .ckSM) {
                // "Usage" label
                Text("Usage")
                    .font(.ckCaption)
                    .foregroundStyle(Color.ckMutedForeground)
                    .textCase(.uppercase)
                    .tracking(0.5)

                // Usage table with border
                VStack(spacing: 0) {
                    // For Claude Code: use standard displayName (already maps to "5h Burst", "Weekly")
                    if provider == .claude {
                        let sortedModels = data.models.sorted { $0.name < $1.name }
                        ForEach(Array(sortedModels.enumerated()), id: \.element.id) { index, model in
                            UsageRowV2(
                                name: model.displayName,
                                usedPercent: model.usedPercentage,
                                resetTime: model.formattedResetTime
                            )
                            .padding(.ckMD)
                            if index < sortedModels.count - 1 {
                                Divider()
                            }
                        }
                    }
                    // For Antigravity: show grouped models if available
                    else if provider == .antigravity, data.hasGroupedModels {
                        let groupedModels = data.groupedModels
                        ForEach(Array(groupedModels.enumerated()), id: \.element.id) { index, groupedModel in
                            UsageRowV2(
                                name: groupedModel.displayName,
                                icon: groupedModel.group.icon,
                                usedPercent: 100 - groupedModel.percentage,
                                resetTime: groupedModel.formattedResetTime
                            )
                            .padding(.ckMD)
                            if index < groupedModels.count - 1 {
                                Divider()
                            }
                        }
                    }
                    // Default: show model names
                    else {
                        let sortedModels = data.models.sorted { $0.name < $1.name }
                        ForEach(Array(sortedModels.enumerated()), id: \.element.id) { index, model in
                            UsageRowV2(
                                name: model.displayName,
                                icon: nil,
                                usedPercent: model.usedPercentage,
                                resetTime: model.formattedResetTime
                            )
                            .padding(.ckMD)
                            if index < sortedModels.count - 1 {
                                Divider()
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
    }
}

// MARK: - Usage Row V2 (Mockup-Matching Design)

private struct UsageRowV2: View {
    let name: String
    var icon: String?
    let usedPercent: Double
    let resetTime: String

    @State private var settings = MenuBarSettingsManager.shared

    private var isUnknown: Bool {
        usedPercent < 0 || usedPercent > 100
    }

    private var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    /// Color based on remaining percentage (matching CKProgressBar thresholds)
    private var statusColor: Color {
        let remaining = remainingPercent / 100
        switch remaining {
        case 0 ..< 0.20: return .ckDestructive
        case 0.20 ..< 0.35: return .ckWarning
        default: return .ckSuccess
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .ckSM) {
            HStack {
                // Model name with optional icon
                HStack(spacing: .ckXS) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.caption)
                            .foregroundStyle(Color.ckMutedForeground)
                    }
                    Text(name)
                        .font(.ckCallout)
                        .foregroundStyle(Color.ckForeground)
                }

                Spacer()

                // Percentage and reset time
                HStack(spacing: .ckSM) {
                    if !isUnknown {
                        Text(String(format: "%.0f%% left", remainingPercent))
                            .font(.ckCallout)
                            .fontWeight(.medium)
                            .foregroundStyle(statusColor)
                    } else {
                        Text("—")
                            .font(.ckCallout)
                            .foregroundStyle(Color.ckMutedForeground)
                    }

                    // Reset time badge
                    if resetTime != "—", !resetTime.isEmpty {
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                            Text(resetTime)
                                .font(.ckCaption)
                        }
                        .foregroundStyle(Color.ckMutedForeground)
                    }
                }
            }

            // Progress bar showing remaining quota
            if !isUnknown {
                CKProgressBar(value: remainingPercent / 100, height: CKLayout.progressBarHeightSM)
            }
        }
    }
}

// MARK: - Loading View

private struct QuotaLoadingView: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: .ckMD) {
            ForEach(0 ..< 2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: .ckSM) {
                    HStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.ckMuted)
                            .frame(width: 80, height: 12)
                        Spacer()
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.ckMuted)
                            .frame(width: 50, height: 12)
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.ckMuted)
                        .frame(height: CKLayout.progressBarHeightSM)
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
        .frame(width: 700, height: 500)
}
