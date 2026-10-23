import Foundation
import QuotioDomain

@MainActor
enum StatusBarCommand: Equatable {
    case refreshAll
    case refreshProvider(QuotaProvider)
    case refreshAccount(QuotaAccountID)
    case selectProvider(QuotaProvider?)
    case pairIPhone
    case openApp
    case openProviderSettings(QuotaProvider?)
    case openHistory(QuotaAccountID)
    case quit
}

@MainActor
public struct StatusBarCommandHandlers {
    fileprivate let refreshAll: @MainActor @Sendable () async -> Void
    fileprivate let refreshProvider: @MainActor @Sendable (QuotaProvider) async -> Void
    fileprivate let refreshAccount: @MainActor @Sendable (QuotaAccountID) async -> Void
    fileprivate let selectProvider: (QuotaProvider?) -> Void
    fileprivate let pairIPhone: () -> Void
    fileprivate let openApp: () -> Void
    fileprivate let openProviderSettings: (QuotaProvider?) -> Void
    fileprivate let quit: () -> Void
    fileprivate let menuNeedsRebuild: () -> Void
    fileprivate let openHistory: (QuotaAccountID) -> Void
    fileprivate let loadHistory: @MainActor @Sendable (QuotaAccountID, String, QuotaHistoryRange) async -> QuotaHistoryChart?

    public init(
        refreshAll: @escaping @MainActor @Sendable () async -> Void,
        refreshProvider: @escaping @MainActor @Sendable (QuotaProvider) async -> Void,
        refreshAccount: @escaping @MainActor @Sendable (QuotaAccountID) async -> Void,
        selectProvider: @escaping (QuotaProvider?) -> Void,
        pairIPhone: @escaping () -> Void,
        openApp: @escaping () -> Void,
        openProviderSettings: @escaping (QuotaProvider?) -> Void,
        quit: @escaping () -> Void,
        menuNeedsRebuild: @escaping () -> Void,
        openHistory: @escaping (QuotaAccountID) -> Void = { _ in },
        loadHistory: @escaping @MainActor @Sendable (QuotaAccountID, String, QuotaHistoryRange) async -> QuotaHistoryChart? = { _, _, _ in nil }
    ) {
        self.refreshAll = refreshAll
        self.refreshProvider = refreshProvider
        self.refreshAccount = refreshAccount
        self.selectProvider = selectProvider
        self.pairIPhone = pairIPhone
        self.openApp = openApp
        self.openProviderSettings = openProviderSettings
        self.quit = quit
        self.menuNeedsRebuild = menuNeedsRebuild
        self.openHistory = openHistory
        self.loadHistory = loadHistory
    }
}

@MainActor
public final class StatusBarCommandDispatcher {
    private let handlers: StatusBarCommandHandlers

    public init(handlers: StatusBarCommandHandlers) {
        self.handlers = handlers
    }

    @discardableResult
    func dispatch(_ command: StatusBarCommand) -> Task<Void, Never>? {
        switch command {
        case .refreshAll:
            return perform(handlers.refreshAll)
        case .refreshProvider(let provider):
            return perform { [handlers] in await handlers.refreshProvider(provider) }
        case .refreshAccount(let account):
            return perform { [handlers] in await handlers.refreshAccount(account) }
        case .selectProvider(let provider):
            handlers.selectProvider(provider)
        case .pairIPhone:
            handlers.pairIPhone()
        case .openApp:
            handlers.openApp()
        case .openProviderSettings(let provider):
            handlers.openProviderSettings(provider)
        case .openHistory(let account):
            handlers.openHistory(account)
        case .quit:
            handlers.quit()
        }
        return nil
    }

    /// Recorded remaining values for one limit, oldest first. History is a
    /// nicety here, so any failure reads as none.
    func history(account: QuotaAccountID, metricID: String, range: QuotaHistoryRange) async -> [QuotaHistoryPoint] {
        guard let chart = await handlers.loadHistory(account, metricID, range) else { return [] }
        return chart.bins.compactMap { bin in
            bin.latest.remainingPercent.map { QuotaHistoryPoint(date: bin.lastObservedAt, remaining: $0) }
        }
    }

    private func perform(_ action: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        Task { [handlers] in
            await action()
            handlers.menuNeedsRebuild()
        }
    }
}
