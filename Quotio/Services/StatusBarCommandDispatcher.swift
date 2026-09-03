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
struct StatusBarCommandHandlers {
    let refreshAll: @MainActor @Sendable () async -> Void
    let refreshProvider: @MainActor @Sendable (QuotaProvider) async -> Void
    let refreshAccount: @MainActor @Sendable (QuotaAccountID) async -> Void
    let toggleProxy: @MainActor @Sendable () async -> Void
    let toggleTunnel: @MainActor @Sendable (UInt16) async -> Void
    let copyText: (String) -> Void
    let switchAntigravityAccount: @MainActor @Sendable (String) async -> Void
    let isAntigravityIDERunning: () -> Bool
    let confirmAntigravitySwitch: (_ email: String, _ isIDERunning: Bool) -> Bool
    let openApp: () -> Void
    let quit: () -> Void
    let menuNeedsRebuild: () -> Void
}

@MainActor
final class StatusBarCommandDispatcher {
    private let handlers: StatusBarCommandHandlers

    init(handlers: StatusBarCommandHandlers) {
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
