import AppKit
import Observation
import QuotioApplication
import QuotioPresentation

@MainActor
@Observable
final class PasteboardAdapter {
    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

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
