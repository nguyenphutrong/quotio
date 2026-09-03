import Observation

@MainActor
@Observable
final class AntigravityAccountScreenModel {
    let switcher: AntigravityAccountSwitcher
    @ObservationIgnored private var didSwitchHandler: (@MainActor () async -> Void)?

    init(switcher: AntigravityAccountSwitcher) {
        self.switcher = switcher
    }

    func setDidSwitchHandler(_ handler: @escaping @MainActor () async -> Void) {
        didSwitchHandler = handler
    }

    func detectActiveAccount() async {
        await switcher.detectActiveAccount()
    }

    func isActive(email: String) -> Bool {
        switcher.isActiveAccount(email: email)
    }

    func switchAccount(email: String) async {
        await switcher.executeSwitchForEmail(email)
        if case .success = switcher.switchState {
            await didSwitchHandler?()
        }
    }

    func cancel() {
        switcher.cancelSwitch()
    }

    func dismissResult() {
        switcher.dismissResult()
    }
}
