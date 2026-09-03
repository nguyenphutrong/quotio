import AppKit
import QuotioApplication
import QuotioPresentation

@MainActor
final class ProxyTunnelRemoteAccessAdapter: TunnelRemoteAccessControlling {
    private let proxy: ProxyScreenModel

    init(proxy: ProxyScreenModel) {
        self.proxy = proxy
    }

    func setRemoteAccessEnabled(_ enabled: Bool) async {
        await proxy.updateConfigAllowRemote(enabled)
    }
}
