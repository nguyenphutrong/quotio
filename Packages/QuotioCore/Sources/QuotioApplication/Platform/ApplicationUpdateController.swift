import QuotioDomain

@MainActor
public final class ApplicationUpdateController: ApplicationUpdateControlling {
    private let checker: any ApplicationUpdateChecking
    private let preferencesRepository: any UpdatePreferencesRepository
    private let icon: any UpdaterIconApplying
    private var channel: UpdateChannel
    private var didChangeHandler: (@MainActor (ApplicationUpdateSnapshot) -> Void)?

    public init(
        checker: any ApplicationUpdateChecking,
        preferencesRepository: any UpdatePreferencesRepository,
        icon: any UpdaterIconApplying
    ) {
        self.checker = checker
        self.preferencesRepository = preferencesRepository
        self.icon = icon
        self.channel = preferencesRepository.load().channel
        checker.setDidChangeHandler { [weak self] in
            self?.publish()
        }
        checker.setAllowsPrereleaseUpdates(channel == .beta)
        icon.applyUpdateChannel(channel)
    }

    public var snapshot: ApplicationUpdateSnapshot {
        ApplicationUpdateSnapshot(
            isInitialized: checker.isInitialized,
            isChecking: checker.isChecking,
            canCheck: checker.canCheck,
            lastCheckDate: checker.lastCheckDate,
            channel: channel
        )
    }

    public var automaticallyChecksForUpdates: Bool {
        get { checker.automaticallyChecksForUpdates }
        set { checker.automaticallyChecksForUpdates = newValue }
    }

    public func initializeIfNeeded() {
        checker.initializeIfNeeded()
        publish()
    }

    public func checkForUpdates() {
        checker.checkForUpdates()
        publish()
    }

    public func checkForUpdatesInBackground() {
        checker.checkForUpdatesInBackground()
        publish()
    }

    public func setChannel(_ channel: UpdateChannel) {
        guard self.channel != channel else { return }
        self.channel = channel
        preferencesRepository.save(UpdatePreferences(channel: channel))
        checker.setAllowsPrereleaseUpdates(channel == .beta)
        checker.resetUpdateCycle()
        icon.applyUpdateChannel(channel)
        publish()
    }

    public func setDidChangeHandler(
        _ handler: (@MainActor (ApplicationUpdateSnapshot) -> Void)?
    ) {
        didChangeHandler = handler
        handler?(snapshot)
    }

    private func publish() {
        didChangeHandler?(snapshot)
    }
}
