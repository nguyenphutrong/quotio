import Foundation
import QuotioDomain

@MainActor
enum StatusBarCommand: Equatable {
    case refreshAll
    case refreshProvider(QuotaProvider)
    case refreshAccount(QuotaAccountID)
    case toggleProxy
    case toggleTunnel(port: UInt16)
    case copyProxyURL(String)
    case copyTunnelURL(String)
    case useAntigravityAccount(email: String)
    case providerSelectionChanged
    case openApp
    case quit
}

@MainActor
public struct StatusBarCommandHandlers {
    fileprivate let refreshAll: @MainActor @Sendable () async -> Void
    fileprivate let refreshProvider: @MainActor @Sendable (QuotaProvider) async -> Void
    fileprivate let refreshAccount: @MainActor @Sendable (QuotaAccountID) async -> Void
    fileprivate let toggleProxy: @MainActor @Sendable () async -> Void
    fileprivate let toggleTunnel: @MainActor @Sendable (UInt16) async -> Void
    fileprivate let copyText: (String) -> Void
    fileprivate let switchAntigravityAccount: @MainActor @Sendable (String) async -> Void
    fileprivate let isAntigravityIDERunning: () -> Bool
    fileprivate let confirmAntigravitySwitch: (_ email: String, _ isIDERunning: Bool) -> Bool
    fileprivate let openApp: () -> Void
    fileprivate let quit: () -> Void
    fileprivate let menuNeedsRebuild: () -> Void

    public init(
        refreshAll: @escaping @MainActor @Sendable () async -> Void,
        refreshProvider: @escaping @MainActor @Sendable (QuotaProvider) async -> Void,
        refreshAccount: @escaping @MainActor @Sendable (QuotaAccountID) async -> Void,
        toggleProxy: @escaping @MainActor @Sendable () async -> Void,
        toggleTunnel: @escaping @MainActor @Sendable (UInt16) async -> Void,
        copyText: @escaping (String) -> Void,
        switchAntigravityAccount: @escaping @MainActor @Sendable (String) async -> Void,
        isAntigravityIDERunning: @escaping () -> Bool,
        confirmAntigravitySwitch: @escaping (_ email: String, _ isIDERunning: Bool) -> Bool,
        openApp: @escaping () -> Void,
        quit: @escaping () -> Void,
        menuNeedsRebuild: @escaping () -> Void
    ) {
        self.refreshAll = refreshAll
        self.refreshProvider = refreshProvider
        self.refreshAccount = refreshAccount
        self.toggleProxy = toggleProxy
        self.toggleTunnel = toggleTunnel
        self.copyText = copyText
        self.switchAntigravityAccount = switchAntigravityAccount
        self.isAntigravityIDERunning = isAntigravityIDERunning
        self.confirmAntigravitySwitch = confirmAntigravitySwitch
        self.openApp = openApp
        self.quit = quit
        self.menuNeedsRebuild = menuNeedsRebuild
    }
}

@MainActor
public final class StatusBarCommandDispatcher {
    private let handlers: StatusBarCommandHandlers

    public init(handlers: StatusBarCommandHandlers) {
        self.handlers = handlers
    }

    func dispatch(_ command: StatusBarCommand) {
        switch command {
        case .refreshAll:
            perform(handlers.refreshAll)
        case .refreshProvider(let provider):
            perform { [handlers] in await handlers.refreshProvider(provider) }
        case .refreshAccount(let account):
            perform { [handlers] in await handlers.refreshAccount(account) }
        case .toggleProxy:
            perform(handlers.toggleProxy)
        case .toggleTunnel(let port):
            perform { [handlers] in await handlers.toggleTunnel(port) }
        case .copyProxyURL(let url), .copyTunnelURL(let url):
            handlers.copyText(url)
        case .useAntigravityAccount(let email):
            guard handlers.confirmAntigravitySwitch(email, handlers.isAntigravityIDERunning()) else {
                return
            }
            perform { [handlers] in await handlers.switchAntigravityAccount(email) }
        case .providerSelectionChanged:
            handlers.menuNeedsRebuild()
        case .openApp:
            handlers.openApp()
        case .quit:
            handlers.quit()
        }
    }

    private func perform(_ action: @escaping @MainActor @Sendable () async -> Void) {
        Task { [handlers] in
            await action()
            handlers.menuNeedsRebuild()
        }
    }
}
