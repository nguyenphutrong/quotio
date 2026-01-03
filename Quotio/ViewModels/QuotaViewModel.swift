//
//  QuotaViewModel.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation
import SwiftUI
import AppKit

@MainActor
@Observable
final class QuotaViewModel {
    let proxyManager: CLIProxyManager
    private var apiClient: ManagementAPIClient?
    private let antigravityFetcher = AntigravityQuotaFetcher()
    private let openAIFetcher = OpenAIQuotaFetcher()
    private let copilotFetcher = CopilotQuotaFetcher()
    private let directAuthService = DirectAuthFileService()
    private let notificationManager = NotificationManager.shared
    private let modeManager = AppModeManager.shared
    private let refreshSettings = RefreshSettingsManager.shared
    
    /// Request tracker for monitoring API requests through ProxyBridge
    let requestTracker = RequestTracker.shared
    
    // Quota-Only Mode Fetchers (CLI-based)
    private let claudeCodeFetcher = ClaudeCodeQuotaFetcher()
    private let cursorFetcher = CursorQuotaFetcher()
    private let codexCLIFetcher = CodexCLIQuotaFetcher()
    private let geminiCLIFetcher = GeminiCLIQuotaFetcher()
    private let traeFetcher = TraeQuotaFetcher()
    
    private var lastKnownAccountStatuses: [String: String] = [:]
    
    var currentPage: NavigationPage = .dashboard
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
    
    /// IDE Scan state
    var showIDEScanSheet = false
    private let ideScanSettings = IDEScanSettingsManager.shared
    
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
    
    /// Antigravity account switcher (for IDE token injection)
    let antigravitySwitcher = AntigravityAccountSwitcher.shared
    
    private var refreshTask: Task<Void, Never>?
    private var lastLogTimestamp: Int?
    
    // MARK: - IDE Quota Persistence Keys
    
    private static let ideQuotasKey = "persisted.ideQuotas"
    private static let ideProvidersToSave: Set<AIProvider> = [.cursor, .trae]
    
    init() {
        self.proxyManager = CLIProxyManager.shared
        loadPersistedIDEQuotas()
        setupRefreshCadenceCallback()
    }
    
    private func setupRefreshCadenceCallback() {
        refreshSettings.onRefreshCadenceChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartAutoRefresh()
            }
        }
    }
    
    private func restartAutoRefresh() {
        if modeManager.isQuotaOnlyMode {
            startQuotaOnlyAutoRefresh()
        } else if proxyManager.proxyStatus.running {
            startAutoRefresh()
        } else {
            startQuotaAutoRefreshWithoutProxy()
        }
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
        // Always refresh quotas directly first (works without proxy)
        await refreshQuotasUnified()
        
        let autoStartProxy = UserDefaults.standard.bool(forKey: "autoStartProxy")
        if autoStartProxy && proxyManager.isBinaryInstalled {
            await startProxy()
            
            // Check for proxy upgrade after starting
            await checkForProxyUpgrade()
        } else {
            // If not auto-starting proxy, start quota auto-refresh
            startQuotaAutoRefreshWithoutProxy()
        }
    }
    
    /// Check for proxy upgrade (non-blocking)
    private func checkForProxyUpgrade() async {
        await proxyManager.checkForUpgrade()
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
    /// Note: Cursor and Trae are NOT auto-refreshed - user must use "Scan for IDEs" (issue #29)
    func refreshQuotasDirectly() async {
        guard !isLoadingQuotas else { return }
        
        isLoadingQuotas = true
        lastQuotaRefreshTime = Date()
        
        // Fetch from available fetchers in parallel
        // Note: Cursor and Trae removed from auto-refresh to address privacy concerns (issue #29)
        // User must explicitly scan for IDEs to detect Cursor/Trae quotas
        async let antigravity: () = refreshAntigravityQuotasInternal()
        async let openai: () = refreshOpenAIQuotasInternal()
        async let copilot: () = refreshCopilotQuotasInternal()
        async let claudeCode: () = refreshClaudeCodeQuotasInternal()
        async let codexCLI: () = refreshCodexCLIQuotasInternal()
        async let geminiCLI: () = refreshGeminiCLIQuotasInternal()
        
        _ = await (antigravity, openai, copilot, claudeCode, codexCLI, geminiCLI)
        
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
        
        menuBarSettings.autoSelectNewAccounts(availableItems: availableItems)
    }
    
    /// Refresh Claude Code quota using CLI
    private func refreshClaudeCodeQuotasInternal() async {
        let quotas = await claudeCodeFetcher.fetchAsProviderQuota()
        if quotas.isEmpty {
            // Only remove if no other source has Claude data
            if providerQuotas[.claude]?.isEmpty ?? true {
                providerQuotas.removeValue(forKey: .claude)
            }
        } else {
            // Merge with existing data (don't overwrite proxy data)
            if var existing = providerQuotas[.claude] {
                for (email, quota) in quotas {
                    existing[email] = quota
                }
                providerQuotas[.claude] = existing
            } else {
                providerQuotas[.claude] = quotas
            }
        }
    }
    
    /// Refresh Cursor quota using browser cookies
    private func refreshCursorQuotasInternal() async {
        let quotas = await cursorFetcher.fetchAsProviderQuota()
        if quotas.isEmpty {
            // No Cursor auth found - remove from providerQuotas
            providerQuotas.removeValue(forKey: .cursor)
        } else {
            providerQuotas[.cursor] = quotas
        }
    }
    
    /// Refresh Codex quota using CLI auth file (~/.codex/auth.json)
    private func refreshCodexCLIQuotasInternal() async {
        // Only use CLI fetcher if proxy is not available or in quota-only mode
        // The openAIFetcher handles Codex via proxy auth files
        guard modeManager.isQuotaOnlyMode else { return }
        
        let quotas = await codexCLIFetcher.fetchAsProviderQuota()
        if !quotas.isEmpty {
            // Merge with existing codex quotas (from proxy if any)
            if var existing = providerQuotas[.codex] {
                for (email, quota) in quotas {
                    existing[email] = quota
                }
                providerQuotas[.codex] = existing
            } else {
                providerQuotas[.codex] = quotas
            }
        }
    }
    
    /// Refresh Gemini quota using CLI auth file (~/.gemini/oauth_creds.json)
    private func refreshGeminiCLIQuotasInternal() async {
        // Only use CLI fetcher in quota-only mode
        guard modeManager.isQuotaOnlyMode else { return }
        
        let quotas = await geminiCLIFetcher.fetchAsProviderQuota()
        if !quotas.isEmpty {
            if var existing = providerQuotas[.gemini] {
                for (email, quota) in quotas {
                    existing[email] = quota
                }
                providerQuotas[.gemini] = existing
            } else {
                providerQuotas[.gemini] = quotas
            }
        }
    }
    
    /// Refresh Trae quota using SQLite database
    private func refreshTraeQuotasInternal() async {
        let quotas = await traeFetcher.fetchAsProviderQuota()
        if quotas.isEmpty {
            providerQuotas.removeValue(forKey: .trae)
        } else {
            providerQuotas[.trae] = quotas
        }
    }
    
    /// Start auto-refresh for quota-only mode
    private func startQuotaOnlyAutoRefresh() {
        refreshTask?.cancel()
        
        guard let intervalNs = refreshSettings.refreshCadence.intervalNanoseconds else {
            // Manual mode - no auto-refresh
            return
        }
        
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                await refreshQuotasDirectly()
            }
        }
    }
    
    /// Start auto-refresh for quota when proxy is not running (Full Mode)
    private func startQuotaAutoRefreshWithoutProxy() {
        refreshTask?.cancel()
        
        guard let intervalNs = refreshSettings.refreshCadence.intervalNanoseconds else {
            return
        }
        
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if !proxyManager.proxyStatus.running {
                    await refreshQuotasUnified()
                }
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
        Array(Set(authFiles.compactMap { $0.providerType })).sorted { $0.displayName < $1.displayName }
    }
    
    var disconnectedProviders: [AIProvider] {
        AIProvider.allCases.filter { provider in
            !connectedProviders.contains(provider)
        }
    }
    
    var totalAccounts: Int { authFiles.count }
    var readyAccounts: Int { authFiles.filter { $0.isReady }.count }
    
    func startProxy() async {
        do {
            // Wire up ProxyBridge callback to RequestTracker before starting
            proxyManager.proxyBridge.onRequestCompleted = { [weak self] metadata in
                self?.requestTracker.addRequest(from: metadata)
            }
            
            try await proxyManager.start()
            setupAPIClient()
            startAutoRefresh()
            
            // Start RequestTracker
            requestTracker.start()
            
            await refreshData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    func stopProxy() {
        refreshTask?.cancel()
        refreshTask = nil
        
        // Stop RequestTracker
        requestTracker.stop()
        
        proxyManager.stop()
        
        // Invalidate URLSession to close all connections
        // Capture client reference before setting to nil to avoid race condition
        let clientToInvalidate = apiClient
        apiClient = nil
        
        if let client = clientToInvalidate {
            Task {
                await client.invalidate()
            }
        }
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
        
        guard let intervalNs = refreshSettings.refreshCadence.intervalNanoseconds else {
            return
        }
        
        refreshTask = Task {
            var consecutiveFailures = 0
            let maxFailuresBeforeRecovery = max(3, Int(180_000_000_000 / intervalNs))
            
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                
                await refreshData()
                
                if errorMessage != nil {
                    consecutiveFailures += 1
                    print("[QuotaVM] Refresh failed, consecutive failures: \(consecutiveFailures)")
                    
                    if consecutiveFailures >= maxFailuresBeforeRecovery {
                        print("[QuotaVM] Attempting proxy recovery...")
                        await attemptProxyRecovery()
                        consecutiveFailures = 0
                    }
                } else {
                    if consecutiveFailures > 0 {
                        print("[QuotaVM] Refresh succeeded, resetting failure count")
                    }
                    consecutiveFailures = 0
                }
            }
        }
    }
    
    /// Attempt to recover an unresponsive proxy
    private func attemptProxyRecovery() async {
        // Check if process is still running
        if proxyManager.proxyStatus.running {
            // Proxy process is running but not responding - likely hung
            // Stop and restart
            stopProxy()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
            await startProxy()
        }
    }
    
    private var lastQuotaRefresh: Date?
    
    private var quotaRefreshInterval: TimeInterval {
        refreshSettings.refreshCadence.intervalSeconds ?? 60
    }
    
    func refreshData() async {
        guard let client = apiClient else { return }
        
        do {
            // Serialize requests to avoid connection contention (issue #37)
            // This reduces pressure on the connection pool
            self.authFiles = try await client.fetchAuthFiles()
            self.usageStats = try await client.fetchUsageStats()
            self.apiKeys = try await client.fetchAPIKeys()
            
            // Clear any previous error on success
            errorMessage = nil
            
            checkAccountStatusChanges()
            
            // Prune menu bar items for accounts that no longer exist
            pruneMenuBarItems()
            
            let shouldRefreshQuotas = lastQuotaRefresh == nil || 
                Date().timeIntervalSince(lastQuotaRefresh!) >= quotaRefreshInterval
            
            if shouldRefreshQuotas && !isLoadingQuotas {
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
    
    func manualRefresh() async {
        if modeManager.isQuotaOnlyMode {
            await refreshQuotasDirectly()
        } else if proxyManager.proxyStatus.running {
            await refreshData()
        } else {
            await refreshQuotasUnified()
        }
        lastQuotaRefreshTime = Date()
    }
    
    func refreshAllQuotas() async {
        guard !isLoadingQuotas else { return }
        
        isLoadingQuotas = true
        lastQuotaRefresh = Date()
        
        // Note: Cursor and Trae removed from auto-refresh (issue #29)
        // User must use "Scan for IDEs" to detect these
        async let antigravity: () = refreshAntigravityQuotasInternal()
        async let openai: () = refreshOpenAIQuotasInternal()
        async let copilot: () = refreshCopilotQuotasInternal()
        async let claudeCode: () = refreshClaudeCodeQuotasInternal()
        
        _ = await (antigravity, openai, copilot, claudeCode)
        
        checkQuotaNotifications()
        autoSelectMenuBarItems()
        
        isLoadingQuotas = false
    }
    
    /// Unified quota refresh - works in both Full Mode and Quota-Only Mode
    /// In Full Mode: uses direct fetchers (works without proxy)
    /// In Quota-Only Mode: uses direct fetchers + CLI fetchers
    /// Note: Cursor and Trae require explicit user scan (issue #29)
    func refreshQuotasUnified() async {
        guard !isLoadingQuotas else { return }
        
        isLoadingQuotas = true
        lastQuotaRefreshTime = Date()
        lastQuotaRefresh = Date()
        
        // Refresh direct fetchers (these don't need proxy)
        // Note: Cursor and Trae removed - require explicit scan (issue #29)
        async let antigravity: () = refreshAntigravityQuotasInternal()
        async let openai: () = refreshOpenAIQuotasInternal()
        async let copilot: () = refreshCopilotQuotasInternal()
        async let claudeCode: () = refreshClaudeCodeQuotasInternal()
        
        // In Quota-Only Mode, also include CLI fetchers
        if modeManager.isQuotaOnlyMode {
            async let codexCLI: () = refreshCodexCLIQuotasInternal()
            async let geminiCLI: () = refreshGeminiCLIQuotasInternal()
            _ = await (antigravity, openai, copilot, claudeCode, codexCLI, geminiCLI)
        } else {
            _ = await (antigravity, openai, copilot, claudeCode)
        }
        
        checkQuotaNotifications()
        autoSelectMenuBarItems()
        
        isLoadingQuotas = false
    }
    
    private func refreshAntigravityQuotasInternal() async {
        // Fetch both quotas and subscriptions in one call (avoids duplicate API calls)
        let (quotas, subscriptions) = await antigravityFetcher.fetchAllAntigravityData()
        
        providerQuotas[.antigravity] = quotas
        
        // Merge instead of replace to preserve data if API fails
        for (email, info) in subscriptions {
            subscriptionInfos[email] = info
        }
        
        // Detect active account in IDE (reads email directly from database)
        await antigravitySwitcher.detectActiveAccount()
    }
    
    /// Refresh Antigravity quotas without re-detecting active account
    /// Used after switching accounts (active account already set by switch operation)
    private func refreshAntigravityQuotasWithoutDetect() async {
        let (quotas, subscriptions) = await antigravityFetcher.fetchAllAntigravityData()
        
        providerQuotas[.antigravity] = quotas
        
        for (email, info) in subscriptions {
            subscriptionInfos[email] = info
        }
        // Note: Don't call detectActiveAccount() here - already set by switch operation
    }
    
    // MARK: - Antigravity Account Switching
    
    /// Check if an Antigravity account is currently active in the IDE
    /// Simply compares email from database with the given email
    func isAntigravityAccountActive(email: String) -> Bool {
        return antigravitySwitcher.isActiveAccount(email: email)
    }
    
    /// Switch Antigravity account in the IDE
    func switchAntigravityAccount(email: String) async {
        await antigravitySwitcher.executeSwitchForEmail(email)
        
        // Refresh to update active account
        if case .success = antigravitySwitcher.switchState {
            // Refresh quotas but don't re-detect active account
            // (already set in executeSwitchForEmail)
            await refreshAntigravityQuotasWithoutDetect()
        }
    }
    
    /// Begin the switch confirmation flow
    func beginAntigravitySwitch(accountId: String, email: String) {
        antigravitySwitcher.beginSwitch(accountId: accountId, accountEmail: email)
    }
    
    /// Cancel the switch operation
    func cancelAntigravitySwitch() {
        antigravitySwitcher.cancelSwitch()
    }
    
    /// Dismiss switch result
    func dismissAntigravitySwitchResult() {
        antigravitySwitcher.dismissResult()
    }
    
    private func refreshOpenAIQuotasInternal() async {
        let quotas = await openAIFetcher.fetchAllCodexQuotas()
        providerQuotas[.codex] = quotas
    }
    
    private func refreshCopilotQuotasInternal() async {
        let quotas = await copilotFetcher.fetchAllCopilotQuotas()
        providerQuotas[.copilot] = quotas
    }
    
    func refreshQuotaForProvider(_ provider: AIProvider) async {
        switch provider {
        case .antigravity:
            await refreshAntigravityQuotasInternal()
        case .codex:
            await refreshOpenAIQuotasInternal()
            await refreshCodexCLIQuotasInternal()
        case .copilot:
            await refreshCopilotQuotasInternal()
        case .claude:
            await refreshClaudeCodeQuotasInternal()
        case .cursor:
            await refreshCursorQuotasInternal()
        case .gemini:
            await refreshGeminiCLIQuotasInternal()
        case .trae:
            await refreshTraeQuotasInternal()
        default:
            break
        }
        
        // Prune menu bar items after refresh to remove deleted accounts
        pruneMenuBarItems()
    }
    
    /// Refresh all auto-detected providers (those that don't support manual auth)
    func refreshAutoDetectedProviders() async {
        let autoDetectedProviders = AIProvider.allCases.filter { !$0.supportsManualAuth }
        
        for provider in autoDetectedProviders {
            await refreshQuotaForProvider(provider)
        }
    }
    
    func refreshLogs() async {
        guard let client = apiClient else { return }
        
        do {
            let response = try await client.fetchLogs(after: lastLogTimestamp)
            if let lines = response.lines {
                let newEntries: [LogEntry] = lines.map { line in
                    let level: LogEntry.LogLevel
                    if line.contains("error") || line.contains("ERROR") {
                        level = .error
                    } else if line.contains("warn") || line.contains("WARN") {
                        level = .warn
                    } else if line.contains("debug") || line.contains("DEBUG") {
                        level = .debug
                    } else {
                        level = .info
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
    
    func startOAuth(for provider: AIProvider, projectId: String? = nil, authMethod: AuthCommand? = nil) async {
        // GitHub Copilot uses Device Code Flow via CLI binary, not Management API
        if provider == .copilot {
            await startCopilotAuth()
            return
        }
        
        // Kiro uses CLI-based auth with multiple options
        if provider == .kiro {
            await startKiroAuth(method: authMethod ?? .kiroGoogleLogin)
            return
        }

        guard let client = apiClient else {
            oauthState = OAuthState(provider: provider, status: .error, error: "Proxy not running. Please start the proxy first.")
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
    
    /// Start GitHub Copilot authentication using Device Code Flow
    private func startCopilotAuth() async {
        oauthState = OAuthState(provider: .copilot, status: .waiting)
        
        let result = await proxyManager.runAuthCommand(.copilotLogin)
        
        if result.success {
            if let deviceCode = result.deviceCode {
                oauthState = OAuthState(provider: .copilot, status: .polling, state: deviceCode, error: result.message)
            } else {
                oauthState = OAuthState(provider: .copilot, status: .polling, error: result.message)
            }
            
            await pollCopilotAuthCompletion()
        } else {
            oauthState = OAuthState(provider: .copilot, status: .error, error: result.message)
        }
    }
    
    private func startKiroAuth(method: AuthCommand) async {
        oauthState = OAuthState(provider: .kiro, status: .waiting)
        
        let result = await proxyManager.runAuthCommand(method)
        
        if result.success {
            if let deviceCode = result.deviceCode {
                oauthState = OAuthState(provider: .kiro, status: .polling, state: deviceCode, error: result.message)
            } else {
                oauthState = OAuthState(provider: .kiro, status: .polling, error: result.message)
            }
            
            await pollKiroAuthCompletion()
        } else {
            oauthState = OAuthState(provider: .kiro, status: .error, error: result.message)
        }
    }
    
    /// Poll for Copilot auth completion by monitoring auth files
    private func pollCopilotAuthCompletion() async {
        let startFileCount = authFiles.filter { $0.provider == "github-copilot" || $0.provider == "copilot" }.count
        
        for _ in 0..<90 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
            await refreshData()
            
            let currentFileCount = authFiles.filter { $0.provider == "github-copilot" || $0.provider == "copilot" }.count
            if currentFileCount > startFileCount {
                oauthState = OAuthState(provider: .copilot, status: .success)
                return
            }
        }
        
        oauthState = OAuthState(provider: .copilot, status: .error, error: "Authentication timeout")
    }
    
    private func pollKiroAuthCompletion() async {
        let startFileCount = authFiles.filter { $0.provider == "kiro" }.count
        
        for _ in 0..<90 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
            await refreshData()
            
            let currentFileCount = authFiles.filter { $0.provider == "kiro" }.count
            if currentFileCount > startFileCount {
                oauthState = OAuthState(provider: .kiro, status: .success)
                return
            }
        }
        
        oauthState = OAuthState(provider: .kiro, status: .error, error: "Authentication timeout")
    }
    
    private func pollOAuthStatus(state: String, provider: AIProvider) async {
        guard let client = apiClient else { return }
        
        for _ in 0..<60 {
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
            
            // Remove quota data for this account
            if let provider = file.providerType {
                let accountKey = file.quotaLookupKey.isEmpty ? file.name : file.quotaLookupKey
                providerQuotas[provider]?.removeValue(forKey: accountKey)
                
                // Also try with email if different
                if let email = file.email, email != accountKey {
                    providerQuotas[provider]?.removeValue(forKey: email)
                }
            }
            
            // Prune menu bar items that no longer exist
            pruneMenuBarItems()
            
            await refreshData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    /// Remove menu bar items that no longer have valid quota data
    private func pruneMenuBarItems() {
        var validItems: [MenuBarQuotaItem] = []
        var seen = Set<String>()
        
        // Collect valid items from current quota data
        for (provider, accountQuotas) in providerQuotas {
            for (accountKey, _) in accountQuotas {
                let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: accountKey)
                if !seen.contains(item.id) {
                    seen.insert(item.id)
                    validItems.append(item)
                }
            }
        }
        
        // Add items from auth files
        for file in authFiles {
            guard let provider = file.providerType else { continue }
            let accountKey = file.quotaLookupKey.isEmpty ? file.name : file.quotaLookupKey
            let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: accountKey)
            if !seen.contains(item.id) {
                seen.insert(item.id)
                validItems.append(item)
            }
        }
        
        // Add items from direct auth files (quota-only mode)
        for file in directAuthFiles {
            let item = MenuBarQuotaItem(provider: file.provider.rawValue, accountKey: file.email ?? file.filename)
            if !seen.contains(item.id) {
                seen.insert(item.id)
                validItems.append(item)
            }
        }
        
        menuBarSettings.pruneInvalidItems(validItems: validItems)
    }

    func importVertexServiceAccount(url: URL) async {
        guard let client = apiClient else {
            errorMessage = "Proxy not running"
            return
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            guard url.startAccessingSecurityScopedResource() else {
                throw NSError(domain: "Quotio", code: 403, userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
            }
            let data = try Data(contentsOf: url)
            url.stopAccessingSecurityScopedResource()
            
            try await client.uploadVertexServiceAccount(data: data)
            await refreshData()
            errorMessage = nil
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
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
            
            if file.status == "cooling" && previousStatus != "cooling" {
                notificationManager.notifyAccountCooling(
                    provider: file.providerType?.displayName ?? file.provider,
                    account: file.email ?? file.name
                )
            } else if file.status == "ready" && previousStatus == "cooling" {
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
    
    // MARK: - IDE Scan with Consent
    
    /// Scan IDEs with explicit user consent - addresses issue #29
    /// Only scans what the user has opted into
    func scanIDEsWithConsent(options: IDEScanOptions) async {
        ideScanSettings.setScanningState(true)
        
        var cursorFound = false
        var cursorEmail: String?
        var traeFound = false
        var traeEmail: String?
        var cliToolsFound: [String] = []
        
        // Scan Cursor if opted in
        if options.scanCursor {
            let quotas = await cursorFetcher.fetchAsProviderQuota()
            if !quotas.isEmpty {
                cursorFound = true
                cursorEmail = quotas.keys.first
                providerQuotas[.cursor] = quotas
            } else {
                // Clear stale data when not found (consistent with refreshCursorQuotasInternal)
                providerQuotas.removeValue(forKey: .cursor)
            }
        }
        
        // Scan Trae if opted in
        if options.scanTrae {
            let quotas = await traeFetcher.fetchAsProviderQuota()
            if !quotas.isEmpty {
                traeFound = true
                traeEmail = quotas.keys.first
                providerQuotas[.trae] = quotas
            } else {
                // Clear stale data when not found (consistent with refreshTraeQuotasInternal)
                providerQuotas.removeValue(forKey: .trae)
            }
        }
        
        // Scan CLI tools if opted in
        if options.scanCLITools {
            let cliNames = ["claude", "codex", "gemini", "gh"]
            for name in cliNames {
                if await CLIExecutor.shared.isCLIInstalled(name: name) {
                    cliToolsFound.append(name)
                }
            }
        }
        
        let result = IDEScanResult(
            cursorFound: cursorFound,
            cursorEmail: cursorEmail,
            traeFound: traeFound,
            traeEmail: traeEmail,
            cliToolsFound: cliToolsFound,
            timestamp: Date()
        )
        
        ideScanSettings.updateScanResult(result)
        ideScanSettings.setScanningState(false)
        
        // Persist IDE quota data for Cursor and Trae
        savePersistedIDEQuotas()
        
        // Update menu bar items
        autoSelectMenuBarItems()
    }
    
    // MARK: - IDE Quota Persistence
    
    /// Save Cursor and Trae quota data to UserDefaults for persistence across app restarts
    private func savePersistedIDEQuotas() {
        var dataToSave: [String: [String: ProviderQuotaData]] = [:]
        
        for provider in Self.ideProvidersToSave {
            if let quotas = providerQuotas[provider], !quotas.isEmpty {
                dataToSave[provider.rawValue] = quotas
            }
        }
        
        if dataToSave.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.ideQuotasKey)
            return
        }
        
        do {
            let encoded = try JSONEncoder().encode(dataToSave)
            UserDefaults.standard.set(encoded, forKey: Self.ideQuotasKey)
        } catch {
            print("Failed to save IDE quotas: \(error)")
        }
    }
    
    /// Load persisted Cursor and Trae quota data from UserDefaults
    private func loadPersistedIDEQuotas() {
        guard let data = UserDefaults.standard.data(forKey: Self.ideQuotasKey) else { return }
        
        do {
            let decoded = try JSONDecoder().decode([String: [String: ProviderQuotaData]].self, from: data)
            
            for (providerRaw, quotas) in decoded {
                if let provider = AIProvider(rawValue: providerRaw),
                   Self.ideProvidersToSave.contains(provider) {
                    providerQuotas[provider] = quotas
                }
            }
        } catch {
            print("Failed to load IDE quotas: \(error)")
            // Clear corrupted data
            UserDefaults.standard.removeObject(forKey: Self.ideQuotasKey)
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
               !quotaData.models.isEmpty {
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
