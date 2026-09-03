import Observation
import QuotioApplication
import QuotioDomain

@MainActor
@Observable
public final class AntigravityAccountScreenModel {
    public private(set) var snapshot = AntigravitySwitchSnapshot()
    public private(set) var isIDERunning = false

    @ObservationIgnored private let switcher: any AntigravityAccountSwitching
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var didSwitchHandler: (@MainActor () async -> Void)?

    public init(switcher: any AntigravityAccountSwitching) {
        self.switcher = switcher
        observationTask = Task { [weak self, switcher] in
            let snapshots = await switcher.snapshots()
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                self?.snapshot = snapshot
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    public func setDidSwitchHandler(_ handler: @escaping @MainActor () async -> Void) {
        didSwitchHandler = handler
    }

    func detectActiveAccount() async {
        async let activeAccount = switcher.detectActiveAccount()
        async let running = switcher.isIDERunning()
        _ = await activeAccount
        isIDERunning = await running
    }

    func refreshIDERunningState() async {
        isIDERunning = await switcher.isIDERunning()
    }

    func isActive(email: String) -> Bool {
        snapshot.activeAccount?.matches(email: email) == true
    }

    public func switchAccount(email: String) async {
        await switcher.switchAccount(email: email)
        snapshot = await switcher.snapshot()
        isIDERunning = await switcher.isIDERunning()
        if case .success = snapshot.state {
            await didSwitchHandler?()
        }
    }

    func cancel() {
        Task { await switcher.cancelSwitch() }
    }

    func dismissResult() {
        Task { await switcher.cancelSwitch() }
    }
}

extension AntigravitySwitchFailure {
    var displayMessage: String {
        switch self {
        case .authFileNotFound(let accountEmail):
            "Auth file not found for \(accountEmail)"
        case .authFileUnreadable:
            "Failed to read auth file"
        case .credentialRefreshFailed:
            "Failed to refresh the account credential"
        case .databaseBackupFailed:
            "Failed to back up the Antigravity database"
        case .credentialInjectionFailed:
            "Failed to update the Antigravity credential"
        case .ideRestartFailed:
            "Failed to restart Antigravity IDE"
        }
    }
}
