//
//  ProvidersScreen.swift
//  CKota
//
//  Providers screen with CK design system styling.
//

import AppKit
import SwiftUI

struct ProvidersScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var selectedProvider: AIProvider?
    private let modeManager = AppModeManager.shared

    /// Check if we should show content
    private var shouldShowContent: Bool {
        if modeManager.isQuotaOnlyMode {
            return true // Always show in quota-only mode
        }
        return viewModel.proxyManager.proxyStatus.running
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .ckXL) {
                if modeManager.isFullMode, !viewModel.proxyManager.proxyStatus.running {
                    // Full mode: Proxy not running
                    proxyNotRunningCard
                } else if modeManager.isQuotaOnlyMode {
                    // Quota-only mode: Show direct auth files and add providers
                    quotaOnlyContent
                } else {
                    // Full mode: Show connected accounts
                    fullModeContent
                }
            }
            .padding(CKLayout.contentPadding)
        }
        .background(Color.ckBackground)
        .navigationTitle(modeManager.isQuotaOnlyMode ? "nav.accounts".localized() : "nav.providers".localized())
        .sheet(item: $selectedProvider) { provider in
            OAuthSheet(provider: provider) {
                selectedProvider = nil
                viewModel.oauthState = nil
            }
            .environment(viewModel)
        }
        .task {
            await viewModel.loadDirectAuthFiles()
        }
    }

    // MARK: - Proxy Not Running Card

    private var proxyNotRunningCard: some View {
        VStack(spacing: .ckMD) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Color.ckWarning)

            Text("empty.proxyNotRunning".localized())
                .font(.ckHeadline)
                .foregroundStyle(Color.ckForeground)

            Text("providers.startProxyFirst".localized())
                .font(.ckBody)
                .foregroundStyle(Color.ckMutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.ckXXL)
        .ckCard()
    }

    // MARK: - Full Mode Content

    /// Accounts detected from local auth files (via quota fetching) that are NOT in the proxy's authFiles
    private var autoDetectedProviderAccounts: [(
        provider: AIProvider,
        accountKey: String,
        quotaData: ProviderQuotaData?
    )] {
        var accounts: [(provider: AIProvider, accountKey: String, quotaData: ProviderQuotaData?)] = []

        // Get all (provider, accountKey) pairs already in authFiles
        // Include both quotaLookupKey and email to handle different lookup patterns
        var existingAccounts = Set<String>()
        for file in viewModel.authFiles {
            guard let provider = file.providerType else { continue }
            let providerPrefix = provider.rawValue

            // Add quotaLookupKey
            existingAccounts.insert("\(providerPrefix):\(file.quotaLookupKey)")

            // Also add email if available (may differ from quotaLookupKey)
            if let email = file.email, !email.isEmpty {
                existingAccounts.insert("\(providerPrefix):\(email)")
            }

            // Also add the name-derived key (strip prefix and .json)
            var nameKey = file.name
            if nameKey.hasSuffix(".json") {
                nameKey = String(nameKey.dropLast(".json".count))
            }
            let prefixes = ["claude-", "antigravity-"]
            for prefix in prefixes where nameKey.hasPrefix(prefix) {
                nameKey = String(nameKey.dropFirst(prefix.count))
                break
            }
            existingAccounts.insert("\(providerPrefix):\(nameKey)")
        }

        for (provider, quotas) in viewModel.providerQuotas {
            for (accountKey, quotaData) in quotas {
                // Only include if this provider+account combo is not already in authFiles
                let key = "\(provider.rawValue):\(accountKey)"
                if !existingAccounts.contains(key) {
                    accounts.append((provider: provider, accountKey: accountKey, quotaData: quotaData))
                }
            }
        }
        return accounts
    }

    @ViewBuilder
    private var fullModeContent: some View {
        // Connected Accounts
        providerCard(
            title: "providers.connectedAccounts".localized(),
            icon: "checkmark.seal.fill",
            count: viewModel.authFiles.count,
            showHint: !viewModel.authFiles.isEmpty
        ) {
            if viewModel.authFiles.isEmpty {
                emptyStateView(
                    icon: "person.crop.circle.badge.questionmark",
                    message: "providers.noAccountsYet".localized()
                )
            } else {
                ForEach(viewModel.authFiles, id: \.id) { file in
                    if file.id != viewModel.authFiles.first?.id {
                        Divider()
                            .padding(.horizontal, .ckMD)
                    }
                    // Try multiple lookup keys to find quota data
                    let quotaData: ProviderQuotaData? = {
                        guard let provider = file.providerType else { return nil }
                        let providerQuotas = viewModel.providerQuotas[provider] ?? [:]

                        // 1. Try quotaLookupKey (computed property)
                        if let data = providerQuotas[file.quotaLookupKey] {
                            return data
                        }

                        // 2. Try email directly
                        if let email = file.email, let data = providerQuotas[email] {
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
                        if let data = providerQuotas[nameKey] {
                            return data
                        }

                        return nil
                    }()
                    AuthFileRow(
                        file: file,
                        quotaData: quotaData,
                        isLoading: viewModel.isLoadingQuotas
                    ) {
                        Task { await viewModel.deleteAuthFile(file) }
                    }
                }
            }
        }

        // Auto-detected Accounts (Claude Code, Cursor, etc. - from local auth files)
        if !autoDetectedProviderAccounts.isEmpty {
            providerCard(
                title: "providers.autoDetected".localized(),
                icon: "sparkle.magnifyingglass",
                count: autoDetectedProviderAccounts.count,
                showHint: true
            ) {
                ForEach(autoDetectedProviderAccounts, id: \.accountKey) { account in
                    if account.accountKey != autoDetectedProviderAccounts.first?.accountKey {
                        Divider()
                            .padding(.horizontal, .ckMD)
                    }
                    AutoDetectedAccountRow(
                        provider: account.provider,
                        accountKey: account.accountKey,
                        quotaData: account.quotaData,
                        isLoading: viewModel.isLoadingQuotas,
                        onDelete: {
                            Task {
                                await viewModel.deleteLocalAuthFile(
                                    provider: account.provider,
                                    accountKey: account.accountKey
                                )
                            }
                        }
                    )
                }
            }
        }

        // Add Provider
        addProviderCard
    }

    // MARK: - Quota-Only Mode Content

    @ViewBuilder
    private var quotaOnlyContent: some View {
        // Tracked Accounts (from direct auth files)
        providerCard(
            title: "providers.trackedAccounts".localized(),
            icon: "person.2.badge.key",
            count: viewModel.directAuthFiles.count,
            showHint: !viewModel.directAuthFiles.isEmpty,
            headerAction: {
                Button {
                    Task { await viewModel.loadDirectAuthFiles() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.ckAccent)
                }
                .buttonStyle(.plain)
                .ckCursorPointer()
            }
        ) {
            if viewModel.directAuthFiles.isEmpty {
                emptyStateView(
                    icon: "person.crop.circle.badge.questionmark",
                    message: "providers.noAccountsFound".localized(),
                    hint: "providers.quotaOnlyHint".localized()
                )
            } else {
                ForEach(viewModel.directAuthFiles) { file in
                    if file.id != viewModel.directAuthFiles.first?.id {
                        Divider()
                            .padding(.horizontal, .ckMD)
                    }
                    let accountKey = file.email ?? file.filename
                    let quotaData = viewModel.providerQuotas[file.provider]?[accountKey]
                    DirectAuthFileRow(
                        file: file,
                        quotaData: quotaData,
                        isLoading: viewModel.isLoadingQuotas
                    )
                }
            }
        }

        // Add Provider (for OAuth)
        addProviderCard
    }

    // MARK: - Provider Card

    private func providerCard(
        title: String,
        icon: String,
        count: Int,
        showHint: Bool = false,
        @ViewBuilder headerAction: () -> some View = { EmptyView() },
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: .ckMD) {
            // Header
            HStack(spacing: .ckSM) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ckAccent)

                Text("\(title) (\(count))")
                    .font(.ckHeadline)

                Spacer()

                headerAction()
            }

            // Content with table border (rows handle own padding)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(Color.ckBackground)
            .clipShape(RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM))
            .overlay(
                RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM)
                    .stroke(Color.ckBorder, lineWidth: 1)
            )

            // Hint text outside table - aligned with row content
            if showHint {
                MenuBarHintView()
                    .padding(.horizontal, .ckMD)
                    .padding(.top, .ckSM)
            }
        }
        .ckCard()
    }

    // MARK: - Add Provider Card

    /// Providers that can be added manually (excludes quota-tracking-only providers like Cursor)
    private var addableProviders: [AIProvider] {
        if modeManager.isFullMode {
            // In Full Mode, only show providers that support manual auth
            AIProvider.allCases.filter(\.supportsManualAuth)
        } else {
            // In Quota-Only mode, show providers that support quota tracking AND can be added manually
            // Cursor is auto-detected from local database, so it shouldn't be in "Add Provider"
            AIProvider.allCases.filter { $0.supportsQuotaOnlyMode && $0.supportsManualAuth }
        }
    }

    private var addProviderCard: some View {
        VStack(alignment: .leading, spacing: .ckMD) {
            // Header
            HStack(spacing: .ckSM) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.ckAccent)

                Text("providers.addProvider".localized())
                    .font(.ckHeadline)
            }

            // Provider list with table border
            VStack(spacing: 0) {
                ForEach(addableProviders) { provider in
                    if provider != addableProviders.first {
                        Divider()
                            .padding(.horizontal, .ckMD)
                    }

                    Button {
                        viewModel.oauthState = nil
                        selectedProvider = provider
                    } label: {
                        HStack(spacing: .ckMD) {
                            ProviderIcon(provider: provider, size: 32)

                            Text(provider.displayName)
                                .font(.ckBodyMedium)
                                .foregroundStyle(Color.ckForeground)

                            Spacer()

                            providerAccountCountBadge(for: provider)

                            Image(systemName: "plus.circle")
                                .foregroundStyle(Color.ckMutedForeground)
                        }
                        .padding(.horizontal, .ckMD)
                        .padding(.vertical, .ckSM)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .ckCursorPointer()
                }
            }
            .background(Color.ckBackground)
            .clipShape(RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM))
            .overlay(
                RoundedRectangle(cornerRadius: CKLayout.cardRadiusSM)
                    .stroke(Color.ckBorder, lineWidth: 1)
            )
        }
        .ckCard()
    }

    @ViewBuilder
    private func providerAccountCountBadge(for provider: AIProvider) -> some View {
        let count: Int = if modeManager.isFullMode {
            viewModel.authFilesByProvider[provider]?.count ?? 0
        } else {
            viewModel.directAuthFiles.filter { $0.provider == provider }.count
        }

        if count > 0 {
            Text("\(count)")
                .font(.ckCaption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(provider.color.opacity(0.15))
                .foregroundStyle(provider.color)
                .clipShape(Capsule())
        }
    }

    // MARK: - Empty State View

    private func emptyStateView(icon: String, message: String, hint: String? = nil) -> some View {
        VStack(spacing: .ckMD) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(Color.ckMutedForeground.opacity(0.6))

            Text(message)
                .font(.ckBody)
                .foregroundStyle(Color.ckMutedForeground)

            if let hint {
                Text(hint)
                    .font(.ckCaption)
                    .foregroundStyle(Color.ckMutedForeground.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, .ckXL)
    }
}

// MARK: - Direct Auth File Row (for Quota-Only Mode)

struct DirectAuthFileRow: View {
    let file: DirectAuthFile
    let quotaData: ProviderQuotaData?
    let isLoading: Bool

    @State private var settings = MenuBarSettingsManager.shared
    @State private var showWarning = false

    private var menuBarItem: MenuBarQuotaItem {
        MenuBarQuotaItem(provider: file.provider.rawValue, accountKey: file.email ?? file.filename)
    }

    private var isSelected: Bool {
        settings.isSelected(menuBarItem)
    }

    /// Determine status from quota data
    private var status: CKStatusDot.Status {
        // If loading and no data yet, show ready with pulse
        if isLoading, quotaData == nil {
            return .ready
        }

        guard let data = quotaData else { return .unknown }

        if data.isForbidden { return .exhausted }

        if !data.models.isEmpty {
            let lowestPercent = data.models.map(\.percentage).min() ?? 100
            if lowestPercent <= 0 { return .exhausted }
            if lowestPercent < 20 { return .cooling }
            return .ready
        }

        return .unknown
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
        HStack(spacing: .ckMD) {
            ProviderIcon(provider: file.provider, size: 32)

            VStack(alignment: .leading, spacing: .ckXXS) {
                Text(file.email ?? file.filename)
                    .font(.ckBodyMedium)
                    .foregroundStyle(Color.ckForeground)

                HStack(spacing: .ckXS) {
                    Text(file.provider.displayName)
                        .font(.ckCaption)
                        .foregroundStyle(Color.ckMutedForeground)

                    CKStatusDot(status: status, showLabel: true, showPulse: isLoading && quotaData == nil)
                }
            }

            Spacer()

            MenuBarBadge(
                isSelected: isSelected,
                onTap: handleToggle
            )
        }
        .padding(.horizontal, .ckMD)
        .padding(.vertical, .ckSM)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
    let quotaData: ProviderQuotaData?
    let isLoading: Bool
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

    /// Determine status from quota data first, then fall back to auth file status
    private var status: CKStatusDot.Status {
        // If we have quota data, derive status from it
        if let data = quotaData {
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

        // If loading and no quota data, show ready with loading pulse
        if isLoading, quotaData == nil {
            return .ready
        }

        // Fall back to auth file status
        switch file.status.lowercased() {
        case "ready" where !file.disabled: return .ready
        case "cooling": return .cooling
        case "error", "exhausted": return .exhausted
        default: return file.unavailable ? .exhausted : .unknown
        }
    }

    var body: some View {
        HStack(spacing: .ckMD) {
            if let provider = file.providerType {
                ProviderIcon(provider: provider, size: 32)
            } else {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.ckMutedForeground)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: .ckXXS) {
                Text(file.email ?? file.name)
                    .font(.ckBodyMedium)
                    .foregroundStyle(Color.ckForeground)

                HStack(spacing: .ckXS) {
                    Text(file.providerType?.displayName ?? "[\(file.provider)]")
                        .font(.ckCaption)
                        .foregroundStyle(Color.ckMutedForeground)

                    CKStatusDot(status: status, showLabel: true, showPulse: isLoading && quotaData == nil)
                }
            }

            Spacer()

            if file.disabled {
                Text("providers.disabled".localized())
                    .font(.ckCaption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.ckMuted)
                    .foregroundStyle(Color.ckMutedForeground)
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
                    .foregroundStyle(Color.ckDestructive)
            }
            .buttonStyle(.plain)
            .help("action.delete".localized())
            .ckCursorPointer()
        }
        .padding(.horizontal, .ckMD)
        .padding(.vertical, .ckSM)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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

// MARK: - Auto-detected Account Row (for Claude Code, Cursor, etc.)

struct AutoDetectedAccountRow: View {
    let provider: AIProvider
    let accountKey: String
    let quotaData: ProviderQuotaData?
    let isLoading: Bool
    let onDelete: (() -> Void)?
    @State private var settings = MenuBarSettingsManager.shared
    @State private var showWarning = false
    @State private var showDeleteConfirm = false

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

    /// Determine status from quota data
    private var status: CKStatusDot.Status {
        // If loading and no data yet, show ready with loading pulse
        if isLoading, quotaData == nil {
            return .ready
        }

        guard let data = quotaData else { return .unknown }

        if data.isForbidden {
            return .exhausted
        }

        if !data.models.isEmpty {
            let lowestPercent = data.models.map(\.percentage).min() ?? 100
            if lowestPercent <= 0 {
                return .exhausted
            } else if lowestPercent < 20 {
                return .cooling
            } else {
                return .ready
            }
        }

        return .unknown
    }

    var body: some View {
        HStack(spacing: .ckMD) {
            ProviderIcon(provider: provider, size: 32)

            VStack(alignment: .leading, spacing: .ckXXS) {
                Text(accountKey)
                    .font(.ckBodyMedium)
                    .foregroundStyle(Color.ckForeground)

                HStack(spacing: .ckXS) {
                    Text(provider.displayName)
                        .font(.ckCaption)
                        .foregroundStyle(Color.ckMutedForeground)

                    CKStatusDot(status: status, showLabel: true, showPulse: isLoading && quotaData == nil)
                }
            }

            Spacer()

            MenuBarBadge(
                isSelected: isSelected,
                onTap: handleToggle
            )

            if onDelete != nil {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Color.ckDestructive)
                }
                .buttonStyle(.plain)
                .help("action.delete".localized())
                .ckCursorPointer()
            }
        }
        .padding(.horizontal, .ckMD)
        .padding(.vertical, .ckSM)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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

            if onDelete != nil {
                Divider()
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("action.delete".localized(), systemImage: "trash")
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
        .alert("providers.deleteAccount".localized(), isPresented: $showDeleteConfirm) {
            Button("action.delete".localized(), role: .destructive) {
                onDelete?()
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("providers.deleteAccountMessage".localized())
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
                    .fill(isSelected ? Color.ckAccent.opacity(0.1) : Color.clear)
                    .frame(width: 28, height: 28)

                Image(systemName: isSelected ? "chart.bar.fill" : "chart.bar")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.ckAccent : Color.ckMutedForeground)
            }
        }
        .buttonStyle(.plain)
        .ckCursorPointer()
    }
}

// MARK: - Menu Bar Hint View

struct MenuBarHintView: View {
    var body: some View {
        HStack(spacing: .ckXS) {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(Color.ckAccent)
                .font(.system(size: 10))
            Text("menubar.hint".localized())
                .font(.ckCaption)
                .foregroundStyle(Color.ckMutedForeground)
        }
    }
}

// MARK: - OAuth Sheet

struct OAuthSheet: View {
    @Environment(QuotaViewModel.self) private var viewModel
    let provider: AIProvider
    let onDismiss: () -> Void

    @State private var hasStartedAuth = false

    private var isPolling: Bool {
        viewModel.oauthState?.status == .polling || viewModel.oauthState?.status == .waiting
    }

    private var isSuccess: Bool {
        viewModel.oauthState?.status == .success
    }

    private var isError: Bool {
        viewModel.oauthState?.status == .error
    }

    var body: some View {
        VStack(spacing: 28) {
            ProviderIcon(provider: provider, size: 64)

            VStack(spacing: 8) {
                Text("oauth.connect".localized() + " " + provider.displayName)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.ckForeground)

                Text("oauth.authenticateWith".localized() + " " + provider.displayName)
                    .font(.ckBody)
                    .foregroundStyle(Color.ckMutedForeground)
            }

            if let state = viewModel.oauthState, state.provider == provider {
                OAuthStatusView(status: state.status, error: state.error, provider: provider)
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
                            await viewModel.startOAuth(for: provider)
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
                            await viewModel.startOAuth(for: provider)
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
        .background(Color.ckCard)
        .animation(.ckStandard, value: viewModel.oauthState?.status)
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
    let provider: AIProvider

    var body: some View {
        Group {
            switch status {
            case .waiting:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("oauth.openingBrowser".localized())
                        .font(.ckBody)
                        .foregroundStyle(Color.ckMutedForeground)
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

                    Text("oauth.waitingForAuth".localized())
                        .font(.ckBodyMedium)
                        .foregroundStyle(Color.ckForeground)

                    Text("oauth.completeBrowser".localized())
                        .font(.ckCaption)
                        .foregroundStyle(Color.ckMutedForeground)
                }
                .padding(.vertical, 16)

            case .success:
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.ckSuccess)

                    Text("oauth.success".localized())
                        .font(.ckHeadline)
                        .foregroundStyle(Color.ckSuccess)

                    Text("oauth.closingSheet".localized())
                        .font(.ckCaption)
                        .foregroundStyle(Color.ckMutedForeground)
                }
                .padding(.vertical, 16)

            case .error:
                VStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.ckDestructive)

                    Text("oauth.failed".localized())
                        .font(.ckHeadline)
                        .foregroundStyle(Color.ckDestructive)

                    if let error {
                        Text(error)
                            .font(.ckCaption)
                            .foregroundStyle(Color.ckMutedForeground)
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
