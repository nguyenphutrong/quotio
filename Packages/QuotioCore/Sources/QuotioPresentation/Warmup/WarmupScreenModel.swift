import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class WarmupScreenModel {
    private(set) var snapshot = WarmupSnapshot()

    @ObservationIgnored private let scheduler: WarmupSchedulerService
    @ObservationIgnored private let settings: WarmupSettingsManager
    @ObservationIgnored private var authFiles: () -> [ManagedAuthFile]
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    public init(
        scheduler: WarmupSchedulerService,
        settings: WarmupSettingsManager,
        authFiles: @escaping () -> [ManagedAuthFile]
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

    func setAuthFilesProvider(_ provider: @escaping () -> [ManagedAuthFile]) {
        authFiles = provider
    }

    public func configure() async {
        await scheduler.configure(targets: targets())
    }

    func isEnabled(for provider: QuotaProvider, accountKey: String) -> Bool {
        settings.isEnabled(provider: provider, accountKey: accountKey)
    }

    func setEnabled(_ enabled: Bool, provider: QuotaProvider, accountKey: String) {
        guard provider == .antigravity,
              settings.isEnabled(provider: provider, accountKey: accountKey) != enabled else { return }
        settings.setEnabled(enabled, provider: provider, accountKey: accountKey)
    }

    func status(provider: QuotaProvider, accountKey: String) -> WarmupStatus {
        snapshot.statuses[QuotaAccountID(provider: provider, accountKey: accountKey)]
            ?? WarmupStatus()
    }

    func availableModels(provider: QuotaProvider, accountKey: String) async -> [String] {
        guard let target = target(provider: provider, accountKey: accountKey) else { return [] }
        return await scheduler.availableModels(for: target)
    }

    func runDueCycle() async {
        await scheduler.runDueCycle()
    }

    public func shutdown() async {
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

    private func target(provider: QuotaProvider, accountKey: String) -> WarmupTarget? {
        guard provider == .antigravity else { return nil }
        let file = authFiles().first {
            $0.providerID == provider && $0.quotaLookupKey == accountKey
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
