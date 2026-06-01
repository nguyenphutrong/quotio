//
//  QuotaViewModel.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation
import SwiftUI
import AppKit
import Observation

@MainActor
@Observable
final class QuotaViewModel {
    let proxyManager: CLIProxyManager
    @ObservationIgnored private var _apiClient: ManagementAPIClient?
    
    var apiClient: ManagementAPIClient? { _apiClient }
    @ObservationIgnored private let notificationManager = NotificationManager.shared
    @ObservationIgnored private let modeManager = OperatingModeManager.shared
    @ObservationIgnored private let refreshSettings = RefreshSettingsManager.shared
    @ObservationIgnored private let warmupSettings = WarmupSettingsManager.shared
    @ObservationIgnored private let warmupService = WarmupService()
    private var warmupNextRun: [WarmupAccountKey: Date] = [:]
    private var warmupStatuses: [WarmupAccountKey: WarmupStatus] = [:]
    @ObservationIgnored private var warmupModelCache: [WarmupAccountKey: (models: [WarmupModelInfo], fetchedAt: Date)] = [:]
    @ObservationIgnored private let warmupModelCacheTTL: TimeInterval = 28800
    
    /// Tunnel manager for Cloudflare Tunnel integration
    let tunnelManager = TunnelManager.shared
    
    @ObservationIgnored private var lastKnownAccountStatuses: [String: String] = [:]
    
    var currentPage: NavigationPage = .dashboard
    var authFiles: [AuthFile] = []
    var usageStats: UsageStats?
    var apiKeys: [String] = []
    var isLoading = false
    var isLoadingQuotas = false
    var errorMessage: String?
    var oauthState: OAuthState?

    /// OAuth launch mode for controlling browser behavior
    enum OAuthLaunchMode {
        /// User manually opens the link (shows "Open Link" button)
        case manual
        /// Automatically open browser when URL is available
        case autoOpen
    }

    /// Notification name for quota data updates (used for menu bar refresh)
    static let quotaDataDidChangeNotification = Notification.Name("QuotaViewModel.quotaDataDidChange")
    
    /// Last quota refresh time.
    var lastQuotaRefreshTime: Date?
    
    @ObservationIgnored private var _agentSetupViewModel: AgentSetupViewModel?
    var agentSetupViewModel: AgentSetupViewModel {
        if let vm = _agentSetupViewModel {
            return vm
        }
        let vm = AgentSetupViewModel()
        vm.setup(proxyManager: proxyManager, quotaViewModel: self)
        _agentSetupViewModel = vm
        return vm
    }
    
    /// Quota data per provider per account (email -> QuotaData)
    var providerQuotas: [AIProvider: [String: ProviderQuotaData]] = [:]
    
    /// Subscription info per provider per account (provider -> email -> SubscriptionInfo)
    var subscriptionInfos: [AIProvider: [String: SubscriptionInfo]] = [:]
    
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var warmupTask: Task<Void, Never>?
    @ObservationIgnored private var isStartingProxyFlow = false
    @ObservationIgnored private var lastLogTimestamp: Int?
    @ObservationIgnored private var isWarmupRunning = false
    @ObservationIgnored private var warmupRunningAccounts: Set<WarmupAccountKey> = []

    struct WarmupStatus: Sendable {
        var isRunning: Bool = false
        var lastRun: Date?
        var nextRun: Date?
        var lastError: String?
        var progressCompleted: Int = 0
        var progressTotal: Int = 0
        var currentModel: String?
        var modelStates: [String: WarmupModelState] = [:]
    }

    enum WarmupModelState: String, Sendable {
        case pending
        case running
        case succeeded
        case failed
    }
    
    // MARK: - IDE Quota Persistence Keys

    /// Key for tracking when auth files last changed (for model cache invalidation)
    static let authFilesChangedKey = "quotio.authFiles.lastChanged"

    /// Post notification to trigger UI updates (works even when window is closed)
    private func notifyQuotaDataChanged() {
        NotificationCenter.default.post(name: Self.quotaDataDidChangeNotification, object: nil)
    }

    init() {
        self.proxyManager = CLIProxyManager.shared
        setupRefreshCadenceCallback()
        setupWarmupCallback()
        restartWarmupScheduler()
    }

    /// Direct Swift quota fetchers were removed; quota configuration now lives in cpa-plusplus.
    func updateProxyConfiguration() async {
    }

    private func setupRefreshCadenceCallback() {
        refreshSettings.onRefreshCadenceChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartAutoRefresh()
            }
        }
    }
    
    private func setupWarmupCallback() {
        warmupSettings.onEnabledAccountsChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartWarmupScheduler()
            }
        }
        warmupSettings.onWarmupCadenceChanged = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartWarmupScheduler()
            }
        }
        warmupSettings.onWarmupScheduleChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.restartWarmupScheduler()
            }
        }
    }
    
    private func restartAutoRefresh() {
        if proxyManager.proxyStatus.running || modeManager.isRemoteProxyMode {
            startAutoRefresh()
        }
    }
    
    // MARK: - Mode-Aware Initialization

    func initialize() async {
        if modeManager.isRemoteProxyMode {
            await initializeRemoteMode()
        } else {
            await initializeFullMode()
        }
    }

    private func initializeFullMode() async {
        await ensureProxyRunning()
    }
    
    private func initializeRemoteMode() async {
        guard modeManager.hasValidRemoteConfig,
              let config = modeManager.remoteConfig,
              let managementKey = modeManager.remoteManagementKey else {
            modeManager.setConnectionStatus(.error("No valid remote configuration"))
            return
        }
        
        modeManager.setConnectionStatus(.connecting)
        
        await setupRemoteAPIClient(config: config, managementKey: managementKey)
        
        guard let client = apiClient else {
            modeManager.setConnectionStatus(.error("Failed to create API client"))
            return
        }
        
        do {
            let info = try await client.checkServer()
            modeManager.setServerInfo(info)
            modeManager.markConnected()
            await refreshData()
            startAutoRefresh()
        } catch {
            modeManager.setServerInfo(nil)
            modeManager.setConnectionStatus(.error(error.localizedDescription))
        }
    }
    
    private func setupRemoteAPIClient(config: RemoteConnectionConfig, managementKey: String) async {
        if let existingClient = _apiClient {
            await existingClient.invalidate()
        }
        
        _apiClient = ManagementAPIClient(config: config, managementKey: managementKey)
    }
    
    func reconnectRemote() async {
        guard modeManager.isRemoteProxyMode else { return }
        await initializeRemoteMode()
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
            let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: file.menuBarAccountKey)
            if !seen.contains(item.id) {
                seen.insert(item.id)
                availableItems.append(item)
            }
        }
        
        menuBarSettings.autoSelectNewAccounts(availableItems: availableItems)
    }
    
    func syncMenuBarSelection() {
        pruneMenuBarItems()
        autoSelectMenuBarItems()
    }
    
    // MARK: - Warmup

    func isWarmupEnabled(for provider: AIProvider, accountKey: String) -> Bool {
        warmupSettings.isEnabled(provider: provider, accountKey: accountKey)
    }

    func warmupStatus(provider: AIProvider, accountKey: String) -> WarmupStatus {
        let key = WarmupAccountKey(provider: provider, accountKey: accountKey)
        return warmupStatuses[key] ?? WarmupStatus()
    }

    func warmupNextRunDate(provider: AIProvider, accountKey: String) -> Date? {
        let key = WarmupAccountKey(provider: provider, accountKey: accountKey)
        return warmupNextRun[key]
    }

    func toggleWarmup(for provider: AIProvider, accountKey: String) {
        guard provider == .antigravity else {
            // Warmup not supported for this provider; no log.
            return
        }
        warmupSettings.toggle(provider: provider, accountKey: accountKey)
        // Warmup toggle state changed; no log.
    }

    func setWarmupEnabled(_ enabled: Bool, provider: AIProvider, accountKey: String) {
        guard provider == .antigravity else {
            // Warmup not supported for this provider; no log.
            return
        }
        if warmupSettings.isEnabled(provider: provider, accountKey: accountKey) == enabled {
            return
        }
        warmupSettings.setEnabled(enabled, provider: provider, accountKey: accountKey)
        // Warmup toggle state changed; no log.
    }

    private func nextDailyRunDate(minutes: Int, now: Date) -> Date {
        let calendar = Calendar.current
        let hour = minutes / 60
        let minute = minutes % 60
        let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if today > now {
            return today
        }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    private func restartWarmupScheduler() {
        warmupTask?.cancel()
        
        guard !warmupSettings.enabledAccountIds.isEmpty else { return }
        
        let now = Date()
        warmupNextRun = [:]
        for target in warmupTargets() {
            let mode = warmupSettings.warmupScheduleMode(provider: target.provider, accountKey: target.accountKey)
            switch mode {
            case .interval:
                warmupNextRun[target] = now
            case .daily:
                let minutes = warmupSettings.warmupDailyMinutes(provider: target.provider, accountKey: target.accountKey)
                warmupNextRun[target] = nextDailyRunDate(minutes: minutes, now: now)
            }
            updateWarmupStatus(for: target) { status in
                status.nextRun = warmupNextRun[target]
            }
        }
        guard !warmupNextRun.isEmpty else { return }
        
        warmupTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let next = warmupNextRun.values.min() else { return }
                let delay = max(next.timeIntervalSince(Date()), 1)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await runWarmupCycle()
            }
        }
    }

    private func runWarmupCycle() async {
        guard !isWarmupRunning else { return }
        let targets = warmupTargets()
        guard !targets.isEmpty else { return }
        
        guard proxyManager.proxyStatus.running else {
            let now = Date()
            for target in targets {
                let mode = warmupSettings.warmupScheduleMode(provider: target.provider, accountKey: target.accountKey)
                switch mode {
                case .interval:
                    let cadence = warmupSettings.warmupCadence(provider: target.provider, accountKey: target.accountKey)
                    warmupNextRun[target] = now.addingTimeInterval(cadence.intervalSeconds)
                case .daily:
                    let minutes = warmupSettings.warmupDailyMinutes(provider: target.provider, accountKey: target.accountKey)
                    warmupNextRun[target] = nextDailyRunDate(minutes: minutes, now: now)
                }
                updateWarmupStatus(for: target) { status in
                    status.nextRun = warmupNextRun[target]
                }
            }
            return
        }
        
        isWarmupRunning = true
        defer { isWarmupRunning = false }
        
        // Warmup cycle started; no log.
        
        let now = Date()
        let dueTargets = targets.filter { target in
            guard let next = warmupNextRun[target] else { return false }
            return next <= now
        }
        
        for target in dueTargets {
            if Task.isCancelled { break }
            await warmupAccount(
                provider: target.provider,
                accountKey: target.accountKey
            )
            let mode = warmupSettings.warmupScheduleMode(provider: target.provider, accountKey: target.accountKey)
            switch mode {
            case .interval:
                let cadence = warmupSettings.warmupCadence(provider: target.provider, accountKey: target.accountKey)
                warmupNextRun[target] = Date().addingTimeInterval(cadence.intervalSeconds)
            case .daily:
                let minutes = warmupSettings.warmupDailyMinutes(provider: target.provider, accountKey: target.accountKey)
                warmupNextRun[target] = nextDailyRunDate(minutes: minutes, now: Date())
            }
            updateWarmupStatus(for: target) { status in
                status.nextRun = warmupNextRun[target]
                status.lastError = nil
            }
        }

        for target in targets where !dueTargets.contains(target) {
            updateWarmupStatus(for: target) { status in
                status.lastError = nil
            }
        }
    }

    private func warmupAccount(provider: AIProvider, accountKey: String) async {
        guard provider == .antigravity else {
            // Warmup not supported for this provider; no log.
            return
        }
        let account = WarmupAccountKey(provider: provider, accountKey: accountKey)
        guard warmupRunningAccounts.insert(account).inserted else {
            // Warmup already running for this account; no log.
            return
        }
        defer { warmupRunningAccounts.remove(account) }
        guard proxyManager.proxyStatus.running else {
            // Warmup skipped when proxy is not running; no log.
            return
        }
        
        guard let apiClient else {
            // Warmup skipped when management client is missing; no log.
            return
        }
        
        guard let authInfo = warmupAuthInfo(provider: provider, accountKey: accountKey) else {
            // Warmup skipped when auth index is missing; no log.
            return
        }
        
        let availableModels = await fetchWarmupModels(
            provider: provider,
            accountKey: accountKey,
            authFileName: authInfo.authFileName,
            apiClient: apiClient
        )
        guard !availableModels.isEmpty else {
            // Warmup skipped when no models are available; no log.
            return
        }
        await warmupAccount(
            provider: provider,
            accountKey: accountKey,
            availableModels: availableModels,
            authIndex: authInfo.authIndex,
            apiClient: apiClient
        )
    }

    private func warmupAccount(
        provider: AIProvider,
        accountKey: String,
        availableModels: [WarmupModelInfo],
        authIndex: String,
        apiClient: ManagementAPIClient
    ) async {
        guard provider == .antigravity else {
            // Warmup not supported for this provider; no log.
            return
        }
        let availableIds = availableModels.map(\.id)
        let selectedModels = warmupSettings.selectedModels(provider: provider, accountKey: accountKey)
        let models = selectedModels.filter { availableIds.contains($0) }
        guard !models.isEmpty else {
            // Warmup skipped when no matching models; no log.
            return
        }
        let account = WarmupAccountKey(provider: provider, accountKey: accountKey)
        updateWarmupStatus(for: account) { status in
            status.isRunning = true
            status.lastError = nil
            status.progressTotal = models.count
            status.progressCompleted = 0
            status.currentModel = nil
            for model in models {
                status.modelStates[model] = .pending
            }
        }
        
        for model in models {
            if Task.isCancelled { break }
            do {
                updateWarmupStatus(for: account) { status in
                    status.currentModel = model
                    status.modelStates[model] = .running
                }
                try await warmupService.warmup(
                    managementClient: apiClient,
                    authIndex: authIndex,
                    model: model
                )
                updateWarmupStatus(for: account) { status in
                    status.progressCompleted += 1
                    status.modelStates[model] = .succeeded
                }
            } catch {
                updateWarmupStatus(for: account) { status in
                    status.progressCompleted += 1
                    status.modelStates[model] = .failed
                    status.lastError = error.localizedDescription
                }
            }
        }
        updateWarmupStatus(for: account) { status in
            status.isRunning = false
            status.currentModel = nil
            status.lastRun = Date()
        }
    }

    private func fetchWarmupModels(
        provider: AIProvider,
        accountKey: String,
        authFileName: String,
        apiClient: ManagementAPIClient
    ) async -> [WarmupModelInfo] {
        do {
            let key = WarmupAccountKey(provider: provider, accountKey: accountKey)
            if let cached = warmupModelCache[key] {
                let age = Date().timeIntervalSince(cached.fetchedAt)
                if age <= warmupModelCacheTTL {
                    return cached.models
                }
            }
            let models = try await warmupService.fetchModels(managementClient: apiClient, authFileName: authFileName)
            warmupModelCache[key] = (models: models, fetchedAt: Date())
            // Warmup fetched models; no log.
            return models
        } catch {
            // Warmup fetch failed; no log.
            return []
        }
    }

    func warmupAvailableModels(provider: AIProvider, accountKey: String) async -> [String] {
        guard provider == .antigravity else { return [] }
        guard let apiClient else { return [] }
        guard let authInfo = warmupAuthInfo(provider: provider, accountKey: accountKey) else { return [] }
        let models = await fetchWarmupModels(
            provider: provider,
            accountKey: accountKey,
            authFileName: authInfo.authFileName,
            apiClient: apiClient
        )
        return models.map(\.id).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func warmupAuthInfo(provider: AIProvider, accountKey: String) -> (authIndex: String, authFileName: String)? {
        guard let authFile = authFiles.first(where: {
            $0.providerType == provider && $0.quotaLookupKey == accountKey
        }) else {
            // Warmup skipped when auth file is missing; no log.
            return nil
        }
        
        guard let authIndex = authFile.authIndex, !authIndex.isEmpty else {
            // Warmup skipped when auth index is missing; no log.
            return nil
        }
        
        let name = authFile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            // Warmup skipped when auth file name is missing; no log.
            return nil
        }
        
        return (authIndex: authIndex, authFileName: name)
    }

    private func warmupTargets() -> [WarmupAccountKey] {
        let keys = warmupSettings.enabledAccountIds.compactMap { id in
            WarmupSettingsManager.parseAccountId(id)
        }
        return keys.filter { $0.provider == .antigravity }.sorted { lhs, rhs in
            if lhs.provider.displayName == rhs.provider.displayName {
                return lhs.accountKey < rhs.accountKey
            }
            return lhs.provider.displayName < rhs.provider.displayName
        }
    }

    // Warmup logging intentionally disabled.
    
    private func updateWarmupStatus(for key: WarmupAccountKey, update: (inout WarmupStatus) -> Void) {
        var status = warmupStatuses[key] ?? WarmupStatus()
        update(&status)
        warmupStatuses[key] = status
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

    func ensureProxyRunning(forceRestart: Bool = false) async {
        guard modeManager.isLocalProxyMode else { return }
        guard proxyManager.isBinaryInstalled else { return }

        if forceRestart {
            await restartProxy()
        } else if !proxyManager.proxyStatus.running {
            await startProxy()
        }
    }
    
    func startProxy() async {
        guard !isStartingProxyFlow else { return }
        guard modeManager.isLocalProxyMode else { return }
        isStartingProxyFlow = true

        defer {
            isStartingProxyFlow = false
        }

        do {
            try await proxyManager.start()
            setupAPIClient()
            if let apiClient {
                modeManager.setServerInfo(try? await apiClient.checkServer())
            }
            startAutoRefresh()
            restartWarmupScheduler()

            await refreshData()

            await runWarmupCycle()

            let autoStartTunnel = UserDefaults.standard.bool(forKey: "autoStartTunnel")
            if autoStartTunnel && tunnelManager.installation.isInstalled {
                await tunnelManager.startTunnel(port: proxyManager.port)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restartProxy() async {
        guard modeManager.isLocalProxyMode else { return }
        guard proxyManager.isBinaryInstalled else { return }
        guard !isStartingProxyFlow else { return }

        if proxyManager.proxyStatus.running {
            refreshTask?.cancel()
            refreshTask = nil

            if tunnelManager.tunnelState.isActive || tunnelManager.tunnelState.status == .starting {
                await tunnelManager.stopTunnel()
            }
            modeManager.setServerInfo(nil)
            restartWarmupScheduler()

            let clientToInvalidate = _apiClient
            _apiClient = nil
            await clientToInvalidate?.invalidate()

            await proxyManager.stopAndWait()
        }

        await startProxy()
    }
    
    func stopProxy() {
        refreshTask?.cancel()
        refreshTask = nil

        if tunnelManager.tunnelState.isActive || tunnelManager.tunnelState.status == .starting {
            Task { @MainActor in
                await tunnelManager.stopTunnel()
            }
        }

        proxyManager.stop()
        modeManager.setServerInfo(nil)
        restartWarmupScheduler()
        
        // Invalidate URLSession to close all connections
        // Capture client reference before setting to nil to avoid race condition
        let clientToInvalidate = _apiClient
        _apiClient = nil
        
        if let client = clientToInvalidate {
            Task {
                await client.invalidate()
            }
        }
    }

    private func setupAPIClient() {
        _apiClient = ManagementAPIClient(
            baseURL: proxyManager.managementURL,
            authKey: proxyManager.managementKey
        )
    }

    private func quotaRefreshAPIClient() async -> ManagementAPIClient? {
        if let apiClient {
            return apiClient
        }

        if modeManager.isLocalProxyMode {
            guard proxyManager.isBinaryInstalled else {
                errorMessage = "quota.error.bundleMissing".localized()
                return nil
            }

            if !proxyManager.proxyStatus.running {
                await ensureProxyRunning()
            }

            if proxyManager.proxyStatus.running {
                setupAPIClient()
                return _apiClient
            }

            errorMessage = proxyManager.lastError ?? "quota.error.startLocal".localized()
            return nil
        }

        if modeManager.isRemoteProxyMode {
            errorMessage = "quota.error.remoteDisconnected".localized()
            return nil
        }

        errorMessage = "quota.error.connectToCPA".localized()
        return nil
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
                    Log.quota("Refresh failed, consecutive failures: \(consecutiveFailures)")
                    
                    if consecutiveFailures >= maxFailuresBeforeRecovery {
                        Log.quota("Attempting proxy recovery...")
                        await attemptProxyRecovery()
                        consecutiveFailures = 0
                    }
                } else {
                    if consecutiveFailures > 0 {
                        Log.quota("Refresh succeeded, resetting failure count")
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
            refreshTask?.cancel()
            refreshTask = nil

            Log.quota("Attempting proxy recovery...")
            await proxyManager.stopAndWait()
            Log.quota("Proxy recovery stop completed, starting proxy")
            try? await Task.sleep(nanoseconds: 300_000_000)
            await startProxy()
        }
    }
    
    @ObservationIgnored private var lastQuotaRefresh: Date?
    
    private var quotaRefreshInterval: TimeInterval {
        refreshSettings.refreshCadence.intervalSeconds ?? 60
    }
    
    func refreshData() async {
        guard let client = apiClient else { return }
        
        do {
            // Serialize requests to avoid connection contention (issue #37)
            // This reduces pressure on the connection pool
            let newAuthFiles = try await client.fetchAuthFiles()

            // Only update timestamp if auth files actually changed (account added/removed)
            let oldNames = Set(self.authFiles.map { $0.name })
            let newNames = Set(newAuthFiles.map { $0.name })
            if oldNames != newNames {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.authFilesChangedKey)
            }

            self.authFiles = newAuthFiles

            do {
                self.usageStats = try await client.fetchUsageStats()
            } catch APIError.httpError(404) {
                self.usageStats = nil
                Log.quota("Usage stats endpoint is not supported by this CLIProxyAPI version")
            }

            self.apiKeys = try await client.fetchAPIKeys()
            
            // Clear any previous error on success
            errorMessage = nil
            
            checkAccountStatusChanges()
            
            // Prune menu bar items for accounts that no longer exist
            pruneMenuBarItems()
            
            let shouldRefreshQuotas: Bool
            if let lastRefresh = lastQuotaRefresh {
                shouldRefreshQuotas = Date().timeIntervalSince(lastRefresh) >= quotaRefreshInterval
            } else {
                shouldRefreshQuotas = true
            }
            
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
        if proxyManager.proxyStatus.running || modeManager.isRemoteProxyMode {
            await refreshData()
        } else {
            await refreshAllQuotas()
        }
        lastQuotaRefreshTime = Date()
    }
    
    func refreshAllQuotas() async {
        guard !isLoadingQuotas else { return }

        isLoadingQuotas = true
        defer {
            isLoadingQuotas = false
            notifyQuotaDataChanged()
        }
        lastQuotaRefresh = Date()

        guard let apiClient = await quotaRefreshAPIClient() else { return }

        do {
            providerQuotas = try await apiClient.refreshQuota().providerQuotas()
            errorMessage = nil
            checkQuotaNotifications()
            pruneMenuBarItems()
            autoSelectMenuBarItems()
        } catch APIError.httpError(404) {
            errorMessage = "quota.error.refreshUnsupported".localized()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Unified quota refresh now delegates to cpa-plusplus Management API.
    func refreshQuotasUnified() async {
        lastQuotaRefreshTime = Date()
        await refreshAllQuotas()
    }

    func refreshQuotaForProvider(_ provider: AIProvider) async {
        await refreshQuota(provider: provider, authID: nil)
    }

    func refreshQuota(provider: AIProvider, authID: String?) async {
        guard let apiClient = await quotaRefreshAPIClient() else { return }

        do {
            providerQuotas = try await apiClient.refreshQuota(provider: provider, authID: authID).providerQuotas()
            errorMessage = nil
            pruneMenuBarItems()
            notifyQuotaDataChanged()
        } catch APIError.httpError(404) {
            errorMessage = "quota.error.providerRefreshUnsupported".localized()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refresh all auto-detected providers (those that don't support manual auth)
    func refreshAutoDetectedProviders() async {
        let autoDetectedProviders = AIProvider.allCases.filter { !$0.supportsManualAuth }
        
        for provider in autoDetectedProviders {
            await refreshQuotaForProvider(provider)
        }
    }
    
    func startOAuth(for provider: AIProvider, projectId: String? = nil, method: ProviderOAuthMethod? = nil, launchMode: OAuthLaunchMode = .manual) async {
        guard let client = apiClient else {
            oauthState = OAuthState(provider: provider, status: .failed, error: "Proxy not running. Please start the proxy first.")
            return
        }

        oauthState = OAuthState(provider: provider, status: .waiting)
        
        do {
            let session = try await client.startProviderOAuth(
                provider: provider,
                method: method ?? defaultOAuthMethod(for: provider),
                options: oauthOptions(for: provider, projectId: projectId)
            )

            oauthState = OAuthState(provider: provider, session: session)

            if launchMode == .autoOpen,
               let urlString = session.authURL ?? session.verificationURI,
               let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }

            await pollOAuthSession(sessionID: session.sessionID, provider: provider)
        } catch {
            oauthState = OAuthState(provider: provider, status: .failed, error: error.localizedDescription)
        }
    }

    private func defaultOAuthMethod(for provider: AIProvider) -> ProviderOAuthMethod? {
        provider == .kiro ? .signinLocalhost : nil
    }
    
    private func pollOAuthSession(sessionID: String, provider: AIProvider) async {
        guard let client = apiClient else { return }
        
        while !Task.isCancelled {
            do {
                let session = try await client.fetchProviderOAuthSession(sessionID)
                oauthState = OAuthState(provider: provider, session: session)

                if session.status == .completed {
                    await refreshData()
                    return
                }
                if session.status.isTerminal {
                    return
                }

                let interval = max(1, min(session.intervalSeconds ?? 2, 15))
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            } catch {
                oauthState = OAuthState(provider: provider, status: .failed, sessionID: sessionID, error: error.localizedDescription)
                return
            }
        }
    }
    
    func cancelOAuth() {
        guard let sessionID = oauthState?.sessionID, let client = apiClient else {
            oauthState = nil
            return
        }
        Task {
            _ = try? await client.cancelProviderOAuthSession(sessionID)
        }
        oauthState = nil
    }

    private func oauthOptions(for provider: AIProvider, projectId: String?) -> [String: String] {
        [:]
    }
    
    func deleteAuthFile(_ file: AuthFile) async {
        guard let client = apiClient else { return }

        do {
            try await client.deleteAuthFile(name: file.name)

            let accountKey = file.quotaLookupKey.isEmpty ? file.name : file.quotaLookupKey

            // Remove quota data for this account
            if let provider = file.providerType {
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

    func toggleAuthFileDisabled(_ file: AuthFile) async {
        guard let client = apiClient else {
            Log.error("toggleAuthFileDisabled: No API client available")
            return
        }

        let newDisabled = !file.disabled

        do {
            Log.debug("toggleAuthFileDisabled: Setting \(file.name) disabled=\(newDisabled)")
            try await client.setAuthFileDisabled(name: file.name, disabled: newDisabled)

            Log.debug("toggleAuthFileDisabled: Success, refreshing data")
            await refreshData()
        } catch {
            Log.error("toggleAuthFileDisabled: Failed - \(error.localizedDescription)")
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
            let item = MenuBarQuotaItem(provider: provider.rawValue, accountKey: file.menuBarAccountKey)
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
    var sessionID: String?
    var state: String?
    var error: String?
    var authURL: String?
    var verificationURI: String?
    var userCode: String?
    var expiresAt: String?
    var intervalSeconds: Int?

    init(provider: AIProvider, status: OAuthStatus, sessionID: String? = nil, state: String? = nil, error: String? = nil, authURL: String? = nil, verificationURI: String? = nil, userCode: String? = nil, expiresAt: String? = nil, intervalSeconds: Int? = nil) {
        self.provider = provider
        self.status = status
        self.sessionID = sessionID
        self.state = state
        self.error = error
        self.authURL = authURL
        self.verificationURI = verificationURI
        self.userCode = userCode
        self.expiresAt = expiresAt
        self.intervalSeconds = intervalSeconds
    }

    init(provider: AIProvider, session: ProviderOAuthSession) {
        self.init(
            provider: provider,
            status: OAuthStatus(session.status),
            sessionID: session.sessionID,
            state: session.state,
            error: session.error,
            authURL: session.authURL,
            verificationURI: session.verificationURI,
            userCode: session.userCode,
            expiresAt: session.expiresAt,
            intervalSeconds: session.intervalSeconds
        )
    }
    
    enum OAuthStatus {
        case waiting, polling, success, failed, expired, cancelled

        init(_ sessionStatus: ProviderOAuthSessionStatus) {
            switch sessionStatus {
            case .starting:
                self = .waiting
            case .awaitingCallback, .awaitingDeviceConfirmation:
                self = .polling
            case .completed:
                self = .success
            case .failed:
                self = .failed
            case .expired:
                self = .expired
            case .cancelled:
                self = .cancelled
            }
        }
    }
}
