import QuotioApplication
import QuotioDomain
import SwiftUI

struct QuotaDisplayHelper {
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

    /// Percentage for ring rendering. Unlike `displayPercent(remainingPercent:)`
    /// this keeps the "no data" sentinel instead of clamping it into a real
    /// value, so `RingProgressView` can render its unknown state.
    func ringPercent(remainingPercent: Double) -> Double {
        remainingPercent < 0
            ? RingProgressView.unknownPercent
            : displayPercent(remainingPercent: remainingPercent)
    }
}

struct ProviderQuotaView: View {
    @Environment(AccountsScreenModel.self) private var accountsModel
    @Environment(AntigravityAccountScreenModel.self) private var antigravityAccounts
    let provider: QuotaProvider
    let authFiles: [ManagedAuthFile]
    let quotaData: [String: ProviderQuota]
    let subscriptionInfos: [String: QuotaSubscriptionInfo]
    let aliases: [String: String]
    let isLoading: Bool

    /// Get all accounts (from auth files or quota data keys)
    private var allAccounts: [AccountInfo] {
        let accounts = AccountInfo.merged(
            provider: provider,
            authFiles: authFiles,
            quotaData: quotaData,
            subscriptionInfos: subscriptionInfos,
            directAccounts: accountsModel.accounts,
            aliases: aliases
        )
        let sorted = accounts.sorted { $0.email < $1.email }

        // Float the account currently in use (Antigravity IDE) to the top,
        // keeping the alphabetical order as the tie-breaker.
        guard provider == .antigravity else { return sorted }
        return AccountSorting.prioritizingActive(sorted) {
            antigravityAccounts.isActive(email: $0.email)
        }
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

struct AccountInfo {
    static func merged(
        provider: QuotaProvider,
        authFiles: [ManagedAuthFile],
        quotaData: [String: ProviderQuota],
        subscriptionInfos: [String: QuotaSubscriptionInfo],
        directAccounts: [Account],
        aliases: [String: String]
    ) -> [AccountInfo] {
        var accounts: [AccountInfo] = []

        // From auth files
        var seen = Set<String>()
        for file in authFiles {
            let key = aliases[file.quotaLookupKey] ?? file.quotaLookupKey
            guard seen.insert(key).inserted else { continue }
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
        // Only Codex needs direct-auth email backfill because its quota key is
        // filename-based to distinguish same-email Plus/Team accounts.
        let directAuthEmailsByKey: [String: String] = provider == .codex
            ? directAccounts
                .filter { $0.provider == .codex }
                .reduce(into: [:]) { $0[$1.accountKey] = $1.displayName }
            : [:]
        for (key, data) in quotaData {
            if !existingKeys.contains(key) {
                accounts.append(AccountInfo(
                    key: key,
                    email: data.accountDisplayName ?? directAuthEmailsByKey[key] ?? key,
                    status: "active",
                    statusColor: .green,
                    authFile: nil,
                    quotaData: data,
                    subscriptionInfo: subscriptionInfos[key]
                ))
            }
        }

        return accounts
    }


    let key: String
    let email: String
    let status: String
    let statusColor: Color
    let authFile: ManagedAuthFile?
    let quotaData: ProviderQuota?
    let subscriptionInfo: QuotaSubscriptionInfo?
}

// MARK: - Account Quota Card V2

private struct AccountQuotaCardV2: View {
    @Environment(QuotaScreenModel.self) private var quota
    @Environment(QuotaFeatureController.self) private var quotaController
    @Environment(WarmupScreenModel.self) private var warmup
    @Environment(AntigravityAccountScreenModel.self) private var antigravityAccounts
    @Environment(PlatformActionScreenModel.self) private var platformActions

    @Environment(QuotaHistoryServiceModel.self) private var history
    @Environment(MenuBarSettingsManager.self) private var settings
    let provider: QuotaProvider
    let account: AccountInfo
    let isLoading: Bool

    @State private var showSwitchSheet = false
    @State private var showModelsDetailSheet = false
    @State private var historyModel: QuotaHistoryScreenModel?
    @FocusState private var historyButtonFocused: Bool

    private var accountID: QuotaAccountID {
        QuotaAccountID(provider: provider, accountKey: account.key)
    }

    private var isRefreshing: Bool {
        quota.isRefreshing(account: accountID)
    }

    /// Check if OAuth is in progress for this provider
    private var isReauthenticating: Bool {
        guard let oauthState = quotaController.oauthState else { return false }
        return oauthState.provider == provider &&
               (oauthState.status == .waiting || oauthState.status == .polling)
    }

    /// Get auth URL if available during reauthentication
    private var reauthURL: URL? {
        guard let oauthState = quotaController.oauthState,
              oauthState.provider == provider,
              let urlString = oauthState.authURL else { return nil }
        return URL(string: urlString)
    }
    @State private var showWarmupSheet = false

    private var hasQuotaData: Bool {
        guard let data = account.quotaData else { return false }
        return !data.models.isEmpty
    }

    private var isWarmupEnabled: Bool {
        warmup.isEnabled(for: provider, accountKey: account.key)
    }

    /// Check if this Antigravity account is active in IDE
    private var isActiveInIDE: Bool {
        provider == .antigravity && antigravityAccounts.isActive(email: account.email)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            accountHeader

            if isLoading {
                QuotaLoadingView()
            } else if hasQuotaData {
                usageSection
            } else if let message = account.authFile?.humanReadableStatus {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                historyModel = history.makeScreen(accountID: account.key, provider: provider)
            } label: {
                Label("history.title".localized(), systemImage: "chart.bar.xaxis")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .focused($historyButtonFocused)
            .help("history.title".localized())
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
        .sheet(item: $historyModel, onDismiss: { historyButtonFocused = true }) { model in
            QuotaHistorySheet(model: model, accountName: account.email, providerName: provider.displayName,
                              displayMode: settings.quotaDisplayMode, hideSensitiveInfo: settings.hideSensitiveInfo)
                .onChange(of: history.changeRevision) { _, _ in model.reload() }
        }
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

                    SensitiveAccountText(value: account.email, isSensitive: settings.hideSensitiveInfo)
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
                        await quotaController.refresh(account: accountID)
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
                            Text("action.refresh".localized())
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
                .disabled(
                    quota.isRefreshBlocked(for: accountID)
                        || !quota.supportsScopedRefresh(for: provider)
                )
                .help("action.refreshQuota".localized())

                if let data = account.quotaData, data.isForbidden {
                    if provider == .claude {
                        // When reauthenticating with authURL available, show "Open Link" button
                        if isReauthenticating, let url = reauthURL {
                            Button {
                                platformActions.open(url)
                            } label: {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Image(systemName: "safari")
                                        .font(.caption)
                                }
                                .foregroundStyle(.orange)
                                .frame(width: 56, height: 28)
                                .background(Color.orange.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help("oauth.openLink".localized())
                        } else {
                            Button {
                                Task {
                                    await quotaController.startOAuth(for: .claude, launchMode: .autoOpen)
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
                        }
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
        }
    }

    // MARK: - Usage Section

    private var isQuotaUnavailable: Bool {
        guard let data = account.quotaData else { return false }
        return data.models.allSatisfy { $0.percentage < 0 && !$0.isStandaloneMetric }
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
        if let data = account.quotaData {
            standardContentByStyle(data: data)
        }
    }

    @ViewBuilder
    private func standardContentByStyle(data: ProviderQuota) -> some View {
        let isCard = displayStyle == .card
        let meterModels = data.models.filter { !$0.isStandaloneMetric }
        let standaloneModels = data.models.filter(\.isStandaloneMetric)
        VStack(spacing: 12) {
            if !meterModels.isEmpty {
                meterContentByStyle(models: meterModels)
            }

            if isCard {
                meterContentByStyle(models: standaloneModels)
            } else {
                ForEach(standaloneModels) { model in
                    StandaloneMetricRow(model: model)
                }
            }
        }
    }

    @ViewBuilder
    private func meterContentByStyle(models: [QuotaMetric]) -> some View {
        switch displayStyle {
        case .lowestBar:
            StandardLowestBarLayout(models: models)
        case .ring:
            StandardRingLayout(models: models)
        case .card:
            VStack(spacing: 12) {
                ForEach(models) { model in
                    UsageRowV2(
                        name: model.displayName,
                        icon: nil,
                        usedPercent: model.usedPercentage,
                        used: model.used,
                        limit: model.limit,
                        formattedUsage: model.presentation == nil ? nil : model.formattedUsage,
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
            return (planName, .purple)
        }

        // Check for Plus
        if lowercased.contains("plus") {
            return (planName, .blue)
        }

        // Check for Team
        if lowercased.contains("team") {
            return (planName, .orange)
        }

        // Check for Enterprise
        if lowercased.contains("enterprise") {
            return (planName, .red)
        }

        // Free/Standard
        if lowercased.contains("free") || lowercased.contains("standard") {
            return (planName, .secondary)
        }

        return (planName, .secondary)
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

    private var displayName: String { planName }

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
    let info: QuotaSubscriptionInfo

    private var tierConfig: (name: String, color: Color) {
        let tierId = info.tierId.lowercased()
        let tierName = info.tierDisplayName.lowercased()

        // Check for Ultra tier (highest priority)
        if tierId.contains("ultra") || tierName.contains("ultra") {
            return (info.tierDisplayName, .orange)
        }

        // Check for Pro tier
        if tierId.contains("pro") || tierName.contains("pro") {
            return (info.tierDisplayName, .purple)
        }

        // Check for Free/Standard tier
        if tierId.contains("standard") || tierId.contains("free") ||
           tierName.contains("standard") || tierName.contains("free") {
            return (info.tierDisplayName, .secondary)
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

// MARK: - Standard Lowest Bar Layout

private struct StandardLowestBarLayout: View {
    let models: [QuotaMetric]

    @Environment(MenuBarSettingsManager.self) private var settings
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var sorted: [QuotaMetric] {
        models.sorted { $0.percentage < $1.percentage }
    }

    private var lowest: QuotaMetric? {
        sorted.first
    }

    private var others: [QuotaMetric] {
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
    let models: [QuotaMetric]

    @Environment(MenuBarSettingsManager.self) private var settings
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var columns: [GridItem] {
        let count = min(max(models.count, 1), 4)
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private func ringPercent(for remainingPercent: Double) -> Double {
        displayHelper.ringPercent(remainingPercent: remainingPercent)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(models) { model in
                VStack(spacing: 6) {
                    RingProgressView(
                        percent: ringPercent(for: model.percentage),
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
    let models: [QuotaMetric]

    @Environment(\.dismiss) private var dismiss

    @Environment(MenuBarSettingsManager.self) private var settings

    private var sortedModels: [QuotaMetric] {
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
                    SensitiveAccountText(value: email, isSensitive: settings.hideSensitiveInfo)
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
    let model: QuotaMetric

    @Environment(MenuBarSettingsManager.self) private var settings
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
    let formattedUsage: String?
    let resetTime: String
    let tooltip: String?

    @Environment(MenuBarSettingsManager.self) private var settings
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

                if let formattedUsage {
                    Text(formattedUsage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                } else if let used = used {
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

private struct StandaloneMetricRow: View {
    let model: QuotaMetric

    var body: some View {
        HStack(spacing: 10) {
            Text(model.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
            Text(model.formattedUsage ?? "—")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .help(model.tooltip ?? "")
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
