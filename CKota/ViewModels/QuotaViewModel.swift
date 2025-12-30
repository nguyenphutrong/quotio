//
//  QuotaViewModel.swift
//  CKota - CLIProxyAPI GUI Wrapper
//

import AppKit
import Foundation
import SwiftUI

@MainActor
@Observable
final class QuotaViewModel {
    let proxyManager: CLIProxyManager
    private var apiClient: ManagementAPIClient?
    private let antigravityFetcher = AntigravityQuotaFetcher()
    private let claudeCodeFetcher = ClaudeCodeQuotaFetcher()
    private let directAuthService = DirectAuthFileService()
    private let notificationManager = NotificationManager.shared
    private let modeManager = AppModeManager.shared

    private var lastKnownAccountStatuses: [String: String] = [:]

    var currentPage: NavigationPage = .home
    var authFiles: [AuthFile] = []
    var usageStats: UsageStats?
    var logs: [LogEntry] = []
    var apiKeys: [String] = []
    var isLoading = false
    var isLoadingQuotas = false
    var errorMessage: String?
    var oauthState: OAuthState?

    /// Direct auth files for quota-only mode
    var directAuthFiles: [DirectAuthFile] = []

    /// Last quota refresh time (for quota-only mode display)
    var lastQuotaRefreshTime: Date?

    private var _agentSetupViewModel: AgentSetupViewModel?
    var agentSetupViewModel: AgentSetupViewModel {
        if let vm = _agentSetupViewModel {
            return vm
        }
        let vm = AgentSetupViewModel()
        vm.setup(proxyManager: proxyManager)
        _agentSetupViewModel = vm
        return vm
    }

    /// Quota data per provider per account (email -> QuotaData)
    var providerQuotas: [AIProvider: [String: ProviderQuotaData]] = [:]

    /// Subscription info per account (email -> SubscriptionInfo)
    var subscriptionInfos: [String: SubscriptionInfo] = [:]

    private var refreshTask: Task<Void, Never>?
    private var lastLogTimestamp: Int?

    init() {
        self.proxyManager = CLIProxyManager.shared
    }

    // MARK: - Mode-Aware Initialization

    /// Initialize the app based on current mode
    func initialize() async {
        if modeManager.isQuotaOnlyMode {
            await initializeQuotaOnlyMode()
        } else {
            await initializeFullMode()
        }
    }

    /// Initialize for Full Mode (with proxy)
    private func initializeFullMode() async {
        // Always try to connect - start() will detect external proxy (e.g., CCS) automatically
        // If external proxy running, we connect without needing binary installed
        // If no external proxy, we start our own (requires binary + autoStartProxy)
        let autoStartProxy = UserDefaults.standard.bool(forKey: "autoStartProxy")
        let hasExternalProxy = await proxyManager.hasExternalProxyRunning()

        if autoStartProxy || hasExternalProxy {
            await startProxy()
        }
    }

    /// Initialize for Quota-Only Mode (no proxy)
    private func initializeQuotaOnlyMode() async {
        // Load auth files directly from filesystem
        await loadDirectAuthFiles()

        // Fetch quotas directly
        await refreshQuotasDirectly()

        // Start auto-refresh for quota-only mode
        startQuotaOnlyAutoRefresh()
    }

    // MARK: - Direct Auth File Management (Quota-Only Mode)

    /// Load auth files directly from filesystem
    func loadDirectAuthFiles() async {
        directAuthFiles = await directAuthService.scanAllAuthFiles()
    }

    /// Refresh quotas directly without proxy (for Quota-Only Mode)
    func refreshQuotasDirectly() async {
        guard !isLoadingQuotas else { return }

        isLoadingQuotas = true
        lastQuotaRefreshTime = Date()

        // Fetch from all available fetchers in parallel
        async let antigravity: () = refreshAntigravityQuotasInternal()
        async let claudeCode: () = refreshClaudeCodeQuotasInternal()

        _ = await (antigravity, claudeCode)

        checkQuotaNotifications()
        autoSelectMenuBarItems()

        isLoadingQuotas = false
    }

    private func autoSelectMenuBarItems() {
        var availableItems: [MenuBarQuotaItem] = []
        var seen = Set<String>()

        for (provider, accountQuotas) in providerQuotas {
            for (accountKey, _) in accountQuotas {
                let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: accountKey)
                if !seen.contains(item.id) {
                    seen.insert(item.id)
                    availableItems.append(item)
                }
            }
        }

        for file in authFiles {
            guard let provider = file.providerType else { continue }
            let accountKey = file.quotaLookupKey.isEmpty ? file.name : file.quotaLookupKey
            let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: accountKey)
            if !seen.contains(item.id) {
                seen.insert(item.id)
                availableItems.append(item)
            }
        }

        for file in directAuthFiles {
            let item = MenuBarQuotaItem(provider: file.provider.rawValue, accountKey: file.email ?? file.filename)
            if !seen.contains(item.id) {
                seen.insert(item.id)
                availableItems.append(item)
            }
        }

        // Remove stale items that no longer exist
        menuBarSettings.pruneInvalidItems(validItems: availableItems)
        menuBarSettings.autoSelectNewAccounts(availableItems: availableItems)
    }

    /// Refresh Claude Code quota using paths from proxy authFiles
    private func refreshClaudeCodeQuotasInternal() async {
        // Get Claude auth file paths from proxy's authFiles
        let claudeAuthPaths = authFiles
            .filter { $0.provider == "claude" }
            .compactMap(\.path)

        let quotas: [String: ProviderQuotaData] = if !claudeAuthPaths.isEmpty {
            // Use paths from proxy API
            await claudeCodeFetcher.fetchFromPaths(claudeAuthPaths)
        } else {
            // Fallback to scanning default directory
            await claudeCodeFetcher.fetchAsProviderQuota()
        }

        // Only update if we got results (don't overwrite existing data on cancelled/failed fetch)
        if !quotas.isEmpty {
            providerQuotas[.claude] = quotas
            print("[DEBUG] Claude quota keys: \(quotas.keys.sorted())")
        } else if providerQuotas[.claude] == nil {
            // Initialize empty dict if nothing exists
            providerQuotas[.claude] = [:]
        }
    }

    /// Debug: Print auth file info for Claude accounts
    func debugPrintClaudeAuthFiles() {
        let claudeFiles = authFiles.filter { $0.provider == "claude" }
        for file in claudeFiles {
            print(
                "[DEBUG] Claude authFile - name: '\(file.name)', email: '\(file.email ?? "nil")', quotaLookupKey: '\(file.quotaLookupKey)', path: '\(file.path ?? "nil")'"
            )
        }
        if let claudeQuotas = providerQuotas[.claude] {
            print("[DEBUG] Claude providerQuotas keys: \(claudeQuotas.keys.sorted())")
        } else {
            print("[DEBUG] Claude providerQuotas: nil/empty")
        }
    }

    /// Start auto-refresh for quota-only mode
    private func startQuotaOnlyAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                // Refresh every 1 minute
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await refreshQuotasDirectly()
            }
        }
    }

    var authFilesByProvider: [AIProvider: [AuthFile]] {
        var result: [AIProvider: [AuthFile]] = [:]
        for file in authFiles {
            if let provider = file.providerType {
                result[provider, default: []].append(file)
            }
        }
        return result
    }

    var connectedProviders: [AIProvider] {
        Array(Set(authFiles.compactMap(\.providerType))).sorted { $0.displayName < $1.displayName }
    }

    var disconnectedProviders: [AIProvider] {
        AIProvider.allCases.filter { provider in
            !connectedProviders.contains(provider)
        }
    }

    var totalAccounts: Int { authFiles.count }
    var readyAccounts: Int { authFiles.filter(\.isReady).count }

    func startProxy() async {
        do {
            try await proxyManager.start()
            setupAPIClient()
            startAutoRefresh()
            await refreshData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopProxy() {
        refreshTask?.cancel()
        refreshTask = nil
        proxyManager.stop()
        apiClient = nil
    }

    func toggleProxy() async {
        if proxyManager.proxyStatus.running {
            stopProxy()
        } else {
            await startProxy()
        }
    }

    private func setupAPIClient() {
        apiClient = ManagementAPIClient(
            baseURL: proxyManager.managementURL,
            authKey: proxyManager.managementKey
        )
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await refreshData()
            }
        }
    }

    private var lastQuotaRefresh: Date?
    // 1-minute interval for quota refresh
    private let quotaRefreshInterval: TimeInterval = 60

    func refreshData() async {
        guard let client = apiClient else { return }

        do {
            async let files = client.fetchAuthFiles()
            async let stats = client.fetchUsageStats()
            async let keys = client.fetchAPIKeys()

            authFiles = try await files
            usageStats = try await stats
            apiKeys = try await keys

            checkAccountStatusChanges()

            let shouldRefreshQuotas = lastQuotaRefresh == nil ||
                Date().timeIntervalSince(lastQuotaRefresh!) >= quotaRefreshInterval

            if shouldRefreshQuotas, !isLoadingQuotas {
                Task {
                    await refreshAllQuotas()
                }
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshAllQuotas() async {
        guard !isLoadingQuotas else { return }

        isLoadingQuotas = true
        lastQuotaRefresh = Date()

        async let antigravity: () = refreshAntigravityQuotasInternal()
        async let claudeCode: () = refreshClaudeCodeQuotasInternal()

        _ = await (antigravity, claudeCode)

        checkQuotaNotifications()
        autoSelectMenuBarItems()

        // Debug: print Claude auth file info
        debugPrintClaudeAuthFiles()

        isLoadingQuotas = false
    }

    private func refreshAntigravityQuotasInternal() async {
        let quotas = await antigravityFetcher.fetchAllAntigravityQuotas()
        print(
            "[DEBUG] QuotaViewModel: Antigravity quotas fetched - count: \(quotas.count), keys: \(quotas.keys.sorted())"
        )

        // Only update if we got results (don't overwrite existing data on cancelled/failed fetch)
        if !quotas.isEmpty {
            providerQuotas[.antigravity] = quotas
        } else if providerQuotas[.antigravity] == nil {
            // Initialize empty dict if nothing exists
            providerQuotas[.antigravity] = [:]
        }

        let subscriptions = await antigravityFetcher.fetchAllSubscriptionInfo()
        if !subscriptions.isEmpty {
            subscriptionInfos = subscriptions
        }
    }

    func refreshQuotaForProvider(_ provider: AIProvider) async {
        switch provider {
        case .antigravity:
            await refreshAntigravityQuotasInternal()
        case .claude:
            await refreshClaudeCodeQuotasInternal()
        }
    }

    func refreshLogs() async {
        guard let client = apiClient else { return }

        do {
            let response = try await client.fetchLogs(after: lastLogTimestamp)
            if let lines = response.lines {
                let newEntries: [LogEntry] = lines.map { line in
                    let level: LogEntry.LogLevel = if line.contains("error") || line.contains("ERROR") {
                        .error
                    } else if line.contains("warn") || line.contains("WARN") {
                        .warn
                    } else if line.contains("debug") || line.contains("DEBUG") {
                        .debug
                    } else {
                        .info
                    }
                    return LogEntry(timestamp: Date(), level: level, message: line)
                }
                logs.append(contentsOf: newEntries)
                if logs.count > 500 {
                    logs = Array(logs.suffix(500))
                }
            }
            lastLogTimestamp = response.latestTimestamp
        } catch {
            // Silently ignore log fetch errors
        }
    }

    func startOAuth(for provider: AIProvider, projectId: String? = nil) async {
        guard let client = apiClient else {
            errorMessage = "Proxy not running"
            return
        }

        oauthState = OAuthState(provider: provider, status: .waiting)

        do {
            let response = try await client.getOAuthURL(for: provider, projectId: projectId)

            guard response.status == "ok", let urlString = response.url, let state = response.state else {
                oauthState = OAuthState(provider: provider, status: .error, error: response.error)
                return
            }

            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }

            oauthState = OAuthState(provider: provider, status: .polling, state: state)
            await pollOAuthStatus(state: state, provider: provider)

        } catch {
            oauthState = OAuthState(provider: provider, status: .error, error: error.localizedDescription)
        }
    }

    private func pollOAuthStatus(state: String, provider: AIProvider) async {
        guard let client = apiClient else { return }

        for _ in 0 ..< 60 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            do {
                let response = try await client.pollOAuthStatus(state: state)

                switch response.status {
                case "ok":
                    oauthState = OAuthState(provider: provider, status: .success)
                    await refreshData()
                    return
                case "error":
                    oauthState = OAuthState(provider: provider, status: .error, error: response.error)
                    return
                default:
                    continue
                }
            } catch {
                continue
            }
        }

        oauthState = OAuthState(provider: provider, status: .error, error: "OAuth timeout")
    }

    func cancelOAuth() {
        oauthState = nil
    }

    func deleteAuthFile(_ file: AuthFile) async {
        guard let client = apiClient else { return }

        do {
            try await client.deleteAuthFile(name: file.name)
            await refreshData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearLogs() async {
        guard let client = apiClient else { return }

        do {
            try await client.clearLogs()
            logs.removeAll()
            lastLogTimestamp = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Local Auth File Management

    /// Auth directories to check (CCS path first, then legacy)
    private static let authDirectories = [
        "~/.ccs/cliproxy/auth", // CCS managed (preferred)
        "~/.cli-proxy-api", // Legacy fallback
    ]

    /// Delete a local auth file (for auto-detected accounts like Claude Code)
    func deleteLocalAuthFile(provider: AIProvider, accountKey: String) async {
        let fileManager = FileManager.default

        // Construct the expected filename based on provider and accountKey
        // Format: provider-email.json (e.g., claude-user@example.com.json)
        let filename = "\(provider.rawValue)-\(accountKey).json"

        // Try to delete from all known auth directories
        var deleted = false
        for dir in Self.authDirectories {
            let expandedPath = NSString(string: dir).expandingTildeInPath
            let filePath = (expandedPath as NSString).appendingPathComponent(filename)

            if fileManager.fileExists(atPath: filePath) {
                do {
                    try fileManager.removeItem(atPath: filePath)
                    deleted = true
                } catch {
                    errorMessage = "Failed to delete auth file: \(error.localizedDescription)"
                }
            }
        }

        if deleted {
            // Remove from providerQuotas
            providerQuotas[provider]?[accountKey] = nil

            // If no more accounts for this provider, remove the provider entry
            if providerQuotas[provider]?.isEmpty == true {
                providerQuotas[provider] = nil
            }

            // Refresh quotas to update UI
            await refreshAllQuotas()
        }
    }

    func fetchAPIKeys() async {
        guard let client = apiClient else { return }

        do {
            apiKeys = try await client.fetchAPIKeys()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addAPIKey(_ key: String) async {
        guard let client = apiClient else { return }
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        do {
            try await client.addAPIKey(key)
            await fetchAPIKeys()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateAPIKey(old: String, new: String) async {
        guard let client = apiClient else { return }
        guard !new.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        do {
            try await client.updateAPIKey(old: old, new: new)
            await fetchAPIKeys()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAPIKey(_ key: String) async {
        guard let client = apiClient else { return }

        do {
            try await client.deleteAPIKey(value: key)
            await fetchAPIKeys()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Notification Helpers

    private func checkAccountStatusChanges() {
        for file in authFiles {
            let accountKey = "\(file.provider)_\(file.email ?? file.name)"
            let previousStatus = lastKnownAccountStatuses[accountKey]

            if file.status == "cooling", previousStatus != "cooling" {
                notificationManager.notifyAccountCooling(
                    provider: file.providerType?.displayName ?? file.provider,
                    account: file.email ?? file.name
                )
            } else if file.status == "ready", previousStatus == "cooling" {
                notificationManager.clearCoolingNotification(
                    provider: file.provider,
                    account: file.email ?? file.name
                )
            }

            lastKnownAccountStatuses[accountKey] = file.status
        }
    }

    func checkQuotaNotifications() {
        for (provider, accountQuotas) in providerQuotas {
            for (account, quotaData) in accountQuotas {
                guard !quotaData.models.isEmpty else { continue }

                // Filter out models with unknown percentage (-1 means unavailable/unknown)
                let validPercentages = quotaData.models.map(\.percentage).filter { $0 >= 0 }
                guard !validPercentages.isEmpty else { continue }

                let minRemainingPercent = validPercentages.min() ?? 100.0

                if minRemainingPercent <= notificationManager.quotaAlertThreshold {
                    notificationManager.notifyQuotaLow(
                        provider: provider.displayName,
                        account: account,
                        remainingPercent: minRemainingPercent
                    )
                } else {
                    notificationManager.clearQuotaNotification(
                        provider: provider.rawValue,
                        account: account
                    )
                }
            }
        }
    }

    // MARK: - Menu Bar Quota Items

    var menuBarSettings: MenuBarSettingsManager {
        MenuBarSettingsManager.shared
    }

    var menuBarQuotaItems: [MenuBarQuotaDisplayItem] {
        let settings = menuBarSettings
        guard settings.showQuotaInMenuBar else { return [] }

        var items: [MenuBarQuotaDisplayItem] = []

        for selectedItem in settings.selectedItems {
            guard let provider = selectedItem.aiProvider else { continue }

            let shortAccount = shortenAccountKey(selectedItem.accountKey)

            if let accountQuotas = providerQuotas[provider],
               let quotaData = accountQuotas[selectedItem.accountKey],
               !quotaData.models.isEmpty
            {
                // Filter out -1 (unknown) percentages when calculating lowest
                let validPercentages = quotaData.models.map(\.percentage).filter { $0 >= 0 }
                let lowestPercent = validPercentages.min() ?? (quotaData.models.first?.percentage ?? -1)
                items.append(MenuBarQuotaDisplayItem(
                    id: selectedItem.id,
                    providerSymbol: provider.menuBarSymbol,
                    accountShort: shortAccount,
                    percentage: lowestPercent,
                    provider: provider
                ))
            } else {
                items.append(MenuBarQuotaDisplayItem(
                    id: selectedItem.id,
                    providerSymbol: provider.menuBarSymbol,
                    accountShort: shortAccount,
                    percentage: -1,
                    provider: provider
                ))
            }
        }

        return items
    }

    private func shortenAccountKey(_ key: String) -> String {
        if let atIndex = key.firstIndex(of: "@") {
            let user = String(key[..<atIndex].prefix(4))
            let domainStart = key.index(after: atIndex)
            let domain = String(key[domainStart...].prefix(1))
            return "\(user)@\(domain)"
        }
        return String(key.prefix(6))
    }
}

struct OAuthState {
    let provider: AIProvider
    var status: OAuthStatus
    var state: String?
    var error: String?

    enum OAuthStatus {
        case waiting, polling, success, error
    }
}
