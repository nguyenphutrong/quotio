import Foundation
import QuotioDomain

public struct WarmupTarget: Equatable, Sendable {
    public let account: QuotaAccountID
    public let authIndex: String?
    public let authFileName: String?
    public let selectedModels: [String]
    public let scheduleMode: WarmupScheduleMode
    public let cadence: WarmupCadence
    public let dailyMinutes: Int

    public init(
        account: QuotaAccountID,
        authIndex: String? = nil,
        authFileName: String? = nil,
        selectedModels: [String] = [],
        scheduleMode: WarmupScheduleMode = .interval,
        cadence: WarmupCadence = .oneHour,
        dailyMinutes: Int = 540
    ) {
        self.account = account
        self.authIndex = authIndex
        self.authFileName = authFileName
        self.selectedModels = selectedModels
        self.scheduleMode = scheduleMode
        self.cadence = cadence
        self.dailyMinutes = min(max(dailyMinutes, 0), 1_439)
    }
}

public enum WarmupModelState: String, Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed
}

public enum WarmupExecutionFailure: Equatable, Sendable {
    case failed
}

public struct WarmupStatus: Equatable, Sendable {
    public var isRunning: Bool
    public var lastRun: Date?
    public var nextRun: Date?
    public var lastFailure: WarmupExecutionFailure?
    public var progressCompleted: Int
    public var progressTotal: Int
    public var currentModel: String?
    public var modelStates: [String: WarmupModelState]

    public init(
        isRunning: Bool = false,
        lastRun: Date? = nil,
        nextRun: Date? = nil,
        lastFailure: WarmupExecutionFailure? = nil,
        progressCompleted: Int = 0,
        progressTotal: Int = 0,
        currentModel: String? = nil,
        modelStates: [String: WarmupModelState] = [:]
    ) {
        self.isRunning = isRunning
        self.lastRun = lastRun
        self.nextRun = nextRun
        self.lastFailure = lastFailure
        self.progressCompleted = progressCompleted
        self.progressTotal = progressTotal
        self.currentModel = currentModel
        self.modelStates = modelStates
    }
}

public struct WarmupSnapshot: Equatable, Sendable {
    public var statuses: [QuotaAccountID: WarmupStatus]

    public init(statuses: [QuotaAccountID: WarmupStatus] = [:]) {
        self.statuses = statuses
    }
}

public protocol WarmupExecuting: Sendable {
    func fetchModels(authFileName: String) async throws -> [String]
    func warmup(authIndex: String, model: String) async throws
}

public protocol WarmupExecutionAvailabilityChecking: Sendable {
    func isWarmupExecutionAvailable() async -> Bool
}

public actor WarmupSchedulerService: LifecycleCancelling {
    private struct CachedModels: Sendable {
        let models: [String]
        let fetchedAt: Date
    }

    private let executor: any WarmupExecuting
    private let availability: any WarmupExecutionAvailabilityChecking
    private let clock: any DateProviding
    private let sleeper: any Sleeping
    private let calendar: Calendar
    private let modelCacheTTL: TimeInterval
    private var targets: [QuotaAccountID: WarmupTarget] = [:]
    private var nextRun: [QuotaAccountID: Date] = [:]
    private var modelCache: [QuotaAccountID: CachedModels] = [:]
    private var runningAccounts: Set<QuotaAccountID> = []
    private var isRunningCycle = false
    private var schedulerTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<WarmupSnapshot>.Continuation] = [:]
    private(set) public var snapshot = WarmupSnapshot()

    public init(
        executor: any WarmupExecuting,
        availability: any WarmupExecutionAvailabilityChecking,
        clock: any DateProviding,
        sleeper: any Sleeping,
        calendar: Calendar = .current,
        modelCacheTTL: TimeInterval = 28_800
    ) {
        self.executor = executor
        self.availability = availability
        self.clock = clock
        self.sleeper = sleeper
        self.calendar = calendar
        self.modelCacheTTL = modelCacheTTL
    }

    public func states() -> AsyncStream<WarmupSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(snapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func configure(targets configuredTargets: [WarmupTarget]) {
        schedulerTask?.cancel()
        targets = Dictionary(
            configuredTargets
                .filter { $0.account.provider == .antigravity }
                .map { ($0.account, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let now = clock.now()
        nextRun = targets.reduce(into: [:]) { result, entry in
            result[entry.key] = scheduledDate(for: entry.value, after: now, initial: true)
        }
        for (account, date) in nextRun {
            updateStatus(for: account) { $0.nextRun = date }
        }
        publish()

        guard !nextRun.isEmpty else {
            schedulerTask = nil
            return
        }
        schedulerTask = Task { [weak self] in
            await self?.runScheduleLoop()
        }
    }

    public func status(for account: QuotaAccountID) -> WarmupStatus {
        snapshot.statuses[account] ?? WarmupStatus()
    }

    public func availableModels(for target: WarmupTarget) async -> [String] {
        guard target.account.provider == .antigravity,
              let authFileName = normalized(target.authFileName) else { return [] }
        return await models(for: target.account, authFileName: authFileName)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func runDueCycle() async {
        guard !isRunningCycle, !targets.isEmpty else { return }
        let now = clock.now()

        guard await availability.isWarmupExecutionAvailable() else {
            for target in sortedTargets() {
                let date = scheduledDate(for: target, after: now, initial: false)
                nextRun[target.account] = date
                updateStatus(for: target.account) { $0.nextRun = date }
            }
            publish()
            return
        }

        isRunningCycle = true
        defer { isRunningCycle = false }
        let dueTargets = sortedTargets().filter {
            guard let date = nextRun[$0.account] else { return false }
            return date <= now
        }

        for target in dueTargets {
            guard !Task.isCancelled else { break }
            await warmup(target)
            let finishedAt = clock.now()
            let date = scheduledDate(for: target, after: finishedAt, initial: false)
            nextRun[target.account] = date
            updateStatus(for: target.account) { $0.nextRun = date }
            publish()
        }
    }

    public func cancelForTermination() {
        schedulerTask?.cancel()
        schedulerTask = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func runScheduleLoop() async {
        while !Task.isCancelled {
            guard let date = nextRun.values.min() else { return }
            let delay = max(date.timeIntervalSince(clock.now()), 1)
            do {
                try await sleeper.sleep(for: .milliseconds(Int64(delay * 1_000)))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await runDueCycle()
        }
    }

    private func warmup(_ target: WarmupTarget) async {
        guard runningAccounts.insert(target.account).inserted else { return }
        defer { runningAccounts.remove(target.account) }
        guard await availability.isWarmupExecutionAvailable(),
              let authIndex = normalized(target.authIndex),
              let authFileName = normalized(target.authFileName) else { return }

        let available = await models(for: target.account, authFileName: authFileName)
        let models = target.selectedModels.filter { available.contains($0) }
        guard !models.isEmpty else { return }

        updateStatus(for: target.account) { status in
            status.isRunning = true
            status.lastFailure = nil
            status.progressCompleted = 0
            status.progressTotal = models.count
            status.currentModel = nil
            for model in models {
                status.modelStates[model] = .pending
            }
        }
        publish()

        for model in models {
            guard !Task.isCancelled else { break }
            updateStatus(for: target.account) {
                $0.currentModel = model
                $0.modelStates[model] = .running
            }
            publish()
            do {
                try await executor.warmup(authIndex: authIndex, model: model)
                updateStatus(for: target.account) {
                    $0.progressCompleted += 1
                    $0.modelStates[model] = .succeeded
                }
            } catch {
                updateStatus(for: target.account) {
                    $0.progressCompleted += 1
                    $0.modelStates[model] = .failed
                    $0.lastFailure = .failed
                }
            }
            publish()
        }
        updateStatus(for: target.account) {
            $0.isRunning = false
            $0.currentModel = nil
            $0.lastRun = clock.now()
        }
        publish()
    }

    private func models(for account: QuotaAccountID, authFileName: String) async -> [String] {
        let now = clock.now()
        if let cached = modelCache[account],
           now.timeIntervalSince(cached.fetchedAt) <= modelCacheTTL {
            return cached.models
        }
        do {
            let models = try await executor.fetchModels(authFileName: authFileName)
            modelCache[account] = CachedModels(models: models, fetchedAt: clock.now())
            return models
        } catch {
            return []
        }
    }

    private func scheduledDate(
        for target: WarmupTarget,
        after date: Date,
        initial: Bool
    ) -> Date {
        switch target.scheduleMode {
        case .interval:
            return initial ? date : date.addingTimeInterval(target.cadence.intervalSeconds)
        case .daily:
            let hour = target.dailyMinutes / 60
            let minute = target.dailyMinutes % 60
            let today = calendar.date(
                bySettingHour: hour,
                minute: minute,
                second: 0,
                of: date
            ) ?? date
            if today > date { return today }
            return calendar.date(byAdding: .day, value: 1, to: today) ?? today
        }
    }

    private func sortedTargets() -> [WarmupTarget] {
        targets.values.sorted { $0.account.accountKey < $1.account.accountKey }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func updateStatus(
        for account: QuotaAccountID,
        update: (inout WarmupStatus) -> Void
    ) {
        var status = snapshot.statuses[account] ?? WarmupStatus()
        update(&status)
        snapshot.statuses[account] = status
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
