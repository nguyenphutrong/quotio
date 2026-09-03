import Foundation
import Observation
import QuotioApplication
import QuotioDomain

final class LegacyWarmupExecutor: WarmupExecuting, WarmupExecutionAvailabilityChecking, @unchecked Sendable {
    private let client: @MainActor @Sendable () -> ManagementAPIClient?
    private let service = WarmupService()

    init(client: @escaping @MainActor @Sendable () -> ManagementAPIClient?) {
        self.client = client
    }

    func isWarmupExecutionAvailable() async -> Bool {
        await client() != nil
    }

    func fetchModels(authFileName: String) async throws -> [String] {
        guard let client = await client() else { return [] }
        return try await service.fetchModels(
            managementClient: client,
            authFileName: authFileName
        ).map(\.id)
    }

    func warmup(authIndex: String, model: String) async throws {
        guard let client = await client() else { return }
        try await service.warmup(
            managementClient: client,
            authIndex: authIndex,
            model: model
        )
    }
}

@MainActor
@Observable
final class WarmupScreenModel {
    private(set) var snapshot = WarmupSnapshot()

    @ObservationIgnored private let scheduler: WarmupSchedulerService
    @ObservationIgnored private let settings: WarmupSettingsManager
    @ObservationIgnored private var authFiles: () -> [AuthFile]
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(
        scheduler: WarmupSchedulerService,
        settings: WarmupSettingsManager,
        authFiles: @escaping () -> [AuthFile]
    ) {
        self.scheduler = scheduler
        self.settings = settings
        self.authFiles = authFiles
        observe()
        settings.onEnabledAccountsChanged = { [weak self] _ in
            Task { @MainActor [weak self] in await self?.configure() }
        }
        settings.onWarmupCadenceChanged = { [weak self] _ in
            Task { @MainActor [weak self] in await self?.configure() }
        }
        settings.onWarmupScheduleChanged = { [weak self] in
            Task { @MainActor [weak self] in await self?.configure() }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    func setAuthFilesProvider(_ provider: @escaping () -> [AuthFile]) {
        authFiles = provider
    }

    func configure() async {
        await scheduler.configure(targets: targets())
    }

    func isEnabled(for provider: AIProvider, accountKey: String) -> Bool {
        settings.isEnabled(provider: provider, accountKey: accountKey)
    }

    func setEnabled(_ enabled: Bool, provider: AIProvider, accountKey: String) {
        guard provider == .antigravity,
              settings.isEnabled(provider: provider, accountKey: accountKey) != enabled else { return }
        settings.setEnabled(enabled, provider: provider, accountKey: accountKey)
    }

    func status(provider: AIProvider, accountKey: String) -> WarmupStatus {
        snapshot.statuses[QuotaAccountID(provider: provider, accountKey: accountKey)]
            ?? WarmupStatus()
    }

    func availableModels(provider: AIProvider, accountKey: String) async -> [String] {
        guard let target = target(provider: provider, accountKey: accountKey) else { return [] }
        return await scheduler.availableModels(for: target)
    }

    func runDueCycle() async {
        await scheduler.runDueCycle()
    }

    func shutdown() async {
        observationTask?.cancel()
        observationTask = nil
        await scheduler.cancelForTermination()
    }

    private func observe() {
        let scheduler = scheduler
        observationTask = Task { [weak self] in
            let snapshots = await scheduler.states()
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                self?.snapshot = snapshot
            }
        }
    }

    private func targets() -> [WarmupTarget] {
        settings.enabledAccountIds.compactMap(WarmupSettingsManager.parseAccountId)
            .compactMap { target(provider: $0.provider, accountKey: $0.accountKey) }
    }

    private func target(provider: AIProvider, accountKey: String) -> WarmupTarget? {
        guard provider == .antigravity else { return nil }
        let file = authFiles().first {
            $0.providerType == provider && $0.quotaLookupKey == accountKey
        }
        return WarmupTarget(
            account: QuotaAccountID(provider: provider, accountKey: accountKey),
            authIndex: file?.authIndex,
            authFileName: file?.name,
            selectedModels: settings.selectedModels(provider: provider, accountKey: accountKey),
            scheduleMode: settings.warmupScheduleMode(provider: provider, accountKey: accountKey),
            cadence: settings.warmupCadence(provider: provider, accountKey: accountKey),
            dailyMinutes: settings.warmupDailyMinutes(provider: provider, accountKey: accountKey)
        )
    }
}
