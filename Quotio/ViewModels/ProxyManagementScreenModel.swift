import Foundation
import Observation
import QuotioApplication
import QuotioDomain
import QuotioPresentation

@MainActor
@Observable
final class ProxyManagementScreenModel {
    static let authFilesChangedKey = "quotio.authFiles.lastChanged"
    private static let disabledAuthFilesKey = "persisted.disabledAuthFiles"

    let proxy: ProxyScreenModel
    let accounts: AccountsScreenModel
    let oauth: OAuthScreenModel
    let tunnel: TunnelScreenModel
    let agentSetup: AgentSetupScreenModel

    private(set) var authFiles: [AuthFile] = []
    private(set) var usageStats: UsageStats?
    private(set) var apiKeys: [String] = []
    private(set) var isLoading = false
    var errorMessage: String?

    var apiClient: ManagementAPIClient? { managementClient }

    @ObservationIgnored private let authWorkaroundService: LegacyAntigravityAuthWorkaroundService
    @ObservationIgnored private let notificationManager: NotificationManager
    @ObservationIgnored private let refreshSettings: RefreshSettingsManager
    @ObservationIgnored private let tunnelPreferences: any TunnelPreferencesRepository
    @ObservationIgnored private var managementClient: ManagementAPIClient?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var lastKnownAccountStatuses: [String: String] = [:]
    @ObservationIgnored private var refreshQuotas: (@MainActor (_ force: Bool) async -> Void)?

    init(
        proxy: ProxyScreenModel,
        accounts: AccountsScreenModel,
        oauth: OAuthScreenModel,
        tunnel: TunnelScreenModel,
        agentSetup: AgentSetupScreenModel,
        authWorkaroundService: LegacyAntigravityAuthWorkaroundService = LegacyAntigravityAuthWorkaroundService(),
        notificationManager: NotificationManager,
        refreshSettings: RefreshSettingsManager,
        tunnelPreferences: any TunnelPreferencesRepository
    ) {
        self.proxy = proxy
        self.accounts = accounts
        self.oauth = oauth
        self.tunnel = tunnel
        self.agentSetup = agentSetup
        self.authWorkaroundService = authWorkaroundService
        self.notificationManager = notificationManager
        self.refreshSettings = refreshSettings
        self.tunnelPreferences = tunnelPreferences
    }

    deinit {
        refreshTask?.cancel()
    }

    var directAuthFiles: [DirectAuthFile] {
        accounts.authFiles.compactMap(DirectAuthFile.init)
    }

    var authFilesByProvider: [AIProvider: [AuthFile]] {
        Dictionary(grouping: authFiles.compactMap { file in
            file.providerType.map { ($0, file) }
        }, by: \.0).mapValues { $0.map(\.1) }
    }

    var connectedProviders: [AIProvider] {
        Array(Set(authFiles.compactMap(\.providerType))).sorted {
            $0.displayName < $1.displayName
        }
    }

    var disconnectedProviders: [AIProvider] {
        AIProvider.allCases.filter { !connectedProviders.contains($0) }
    }

    var totalAccounts: Int { authFiles.count }
    var readyAccounts: Int { authFiles.filter(\.isReady).count }

    func setQuotaRefresh(_ action: @escaping @MainActor (_ force: Bool) async -> Void) {
        refreshQuotas = action
    }

    func initialize() async {
        await proxy.initialize()
        if proxy.proxyStatus.running {
            setupAPIClient()
            startAutomaticRefresh()
            await refreshData(refreshQuota: false)
        }

        let autoStart = UserDefaults.standard.bool(forKey: "autoStartProxy")
        if autoStart, proxy.isBinaryInstalled, !proxy.proxyStatus.running {
            await startProxy()
        }
    }

    func startProxy() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        do {
            try await proxy.start()
            setupAPIClient()
            startAutomaticRefresh()
            await refreshData(refreshQuota: false)
            await syncDisabledStatesToBackend()
            await refreshData(refreshQuota: false)
            await refreshQuotas?(true)
            Task { await proxy.checkForUpgrade() }

            if tunnelPreferences.load().autoStartTunnel, tunnel.installation.isInstalled {
                await tunnel.startTunnel(port: proxy.port)
            }
        } catch {
            errorMessage = proxy.errorMessage(for: error)
        }
    }

    func stopProxy() {
        Task { await oauth.cancel() }
        refreshTask?.cancel()
        refreshTask = nil
        if tunnel.tunnelState.isActive || tunnel.tunnelState.status == .starting {
            Task { await tunnel.stopTunnel() }
        }
        proxy.stop()

        let client = managementClient
        managementClient = nil
        if let client {
            Task { await client.invalidate() }
        }
    }

    func toggleProxy() async {
        if proxy.proxyStatus.running {
            stopProxy()
        } else {
            await startProxy()
        }
    }

    func refreshData(refreshQuota: Bool = true) async {
        guard let client = managementClient else { return }
        do {
            let fetchedAuthFiles = try await client.fetchAuthFiles()
            let previousNames = Set(authFiles.map(\.name))
            let currentNames = Set(fetchedAuthFiles.map(\.name))
            if previousNames != currentNames {
                UserDefaults.standard.set(
                    Date().timeIntervalSince1970,
                    forKey: Self.authFilesChangedKey
                )
            }
            authFiles = fetchedAuthFiles
            do {
                usageStats = try await client.fetchUsageStats()
            } catch APIError.httpError(404) {
                usageStats = nil
            }
            apiKeys = try await client.fetchAPIKeys()
            errorMessage = nil
            checkAccountStatusChanges()
            if refreshQuota {
                await refreshQuotas?(false)
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadDirectAuthFiles() async {
        await accounts.reloadAuthFiles()
    }

    func deleteAuthFile(_ file: AuthFile) async {
        guard let client = managementClient else { return }
        do {
            try await client.deleteAuthFile(name: file.name)
            var disabled = loadDisabledAuthFiles()
            disabled.remove(file.name)
            disabled.remove(file.quotaLookupKey)
            if let email = file.email { disabled.remove(email) }
            saveDisabledAuthFiles(disabled)
            await refreshData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importAuthFile(from url: URL) async throws {
        if let client = managementClient {
            let content = try await accounts.readAuthFileForImport(from: url)
            try await client.uploadAuthFile(name: url.lastPathComponent, content: content)
            await refreshData()
        } else {
            try await accounts.importAuthFile(from: url)
        }
    }

    func exportAuthFile(name: String, to url: URL) async throws {
        if let client = managementClient {
            let content = try await client.downloadAuthFile(name: name)
            try await accounts.writeDownloadedAuthFile(content, to: url)
        } else {
            try await accounts.exportAuthFile(name: name, to: url)
        }
    }

    func toggleAuthFileDisabled(_ file: AuthFile) async {
        guard let client = managementClient else { return }
        let disabled = !file.disabled
        do {
            try await client.setAuthFileDisabled(name: file.name, disabled: disabled)
            var stored = loadDisabledAuthFiles()
            if disabled {
                stored.insert(file.name)
            } else {
                stored.remove(file.name)
            }
            saveDisabledAuthFiles(stored)
            await refreshData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importVertexServiceAccount(url: URL) async {
        guard let client = managementClient else {
            errorMessage = "Proxy not running"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            guard url.startAccessingSecurityScopedResource() else {
                throw NSError(
                    domain: "Quotio",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
                )
            }
            defer { url.stopAccessingSecurityScopedResource() }
            try await client.uploadVertexServiceAccount(data: Data(contentsOf: url))
            await refreshData()
            errorMessage = nil
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func addAPIKey(_ key: String) async {
        guard let client = managementClient,
              !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await client.addAPIKey(key)
            apiKeys = try await client.fetchAPIKeys()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateAPIKey(old: String, new: String) async {
        guard let client = managementClient,
              !new.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try await client.updateAPIKey(old: old, new: new)
            apiKeys = try await client.fetchAPIKeys()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAPIKey(_ key: String) async {
        guard let client = managementClient else { return }
        do {
            try await client.deleteAPIKey(value: key)
            apiKeys = try await client.fetchAPIKeys()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var upstreamCompatibilityWarning: String {
        "Copilot and Kiro auth flows may not work with the upstream CLIProxyAPI binary."
    }

    func isLegacyAuthWarningNeeded(for provider: AIProvider) -> Bool {
        provider == .copilot || provider == .kiro
    }

    func applyBaseURLWorkaround() {
        Task {
            await authWorkaroundService.apply(in: proxy.authDir)
            if proxy.proxyStatus.running { try? await proxy.restart() }
        }
    }

    func removeBaseURLWorkaround() {
        Task {
            await authWorkaroundService.remove(in: proxy.authDir)
            if proxy.proxyStatus.running { try? await proxy.restart() }
        }
    }

    func shutdown() async {
        refreshTask?.cancel()
        refreshTask = nil
        if let managementClient { await managementClient.invalidate() }
        managementClient = nil
        await proxy.shutdown()
    }

    private func setupAPIClient() {
        managementClient = ManagementAPIClient(
            baseURL: proxy.managementURL,
            authKey: proxy.managementKey
        )
    }

    private func startAutomaticRefresh() {
        refreshTask?.cancel()
        guard let interval = refreshSettings.refreshCadence.intervalNanoseconds else {
            refreshTask = nil
            return
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self?.refreshData(refreshQuota: false)
            }
        }
    }

    private func loadDisabledAuthFiles() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.disabledAuthFilesKey) ?? [])
    }

    private func saveDisabledAuthFiles(_ names: Set<String>) {
        UserDefaults.standard.set(Array(names), forKey: Self.disabledAuthFilesKey)
    }

    private func syncDisabledStatesToBackend() async {
        guard let client = managementClient else { return }
        for name in loadDisabledAuthFiles() where authFiles.contains(where: { $0.name == name }) {
            try? await client.setAuthFileDisabled(name: name, disabled: true)
        }
    }

    private func checkAccountStatusChanges() {
        for file in authFiles {
            let accountKey = "\(file.provider)_\(file.email ?? file.name)"
            let previous = lastKnownAccountStatuses[accountKey]
            if file.status == "cooling", previous != "cooling" {
                notificationManager.notifyAccountCooling(
                    provider: file.providerType?.displayName ?? file.provider,
                    account: file.email ?? file.name
                )
            } else if file.status == "ready", previous == "cooling" {
                notificationManager.clearCoolingNotification(
                    provider: file.provider,
                    account: file.email ?? file.name
                )
            }
            lastKnownAccountStatuses[accountKey] = file.status
        }
    }
}
