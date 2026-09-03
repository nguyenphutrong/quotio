import QuotioDomain

public actor ProxyUpdatePollingController {
    private let proxy: any ProxyControlling
    private let notifications: any NotificationRequesting
    private let notificationRecord: any ProxyUpdateNotificationRecording
    private let sleeper: any Sleeping
    private let initialDelay: Duration
    private let pollingInterval: Duration
    private var pollingTask: Task<Void, Never>?

    public init(
        proxy: any ProxyControlling,
        notifications: any NotificationRequesting,
        notificationRecord: any ProxyUpdateNotificationRecording,
        sleeper: any Sleeping,
        initialDelay: Duration = .seconds(5),
        pollingInterval: Duration = .seconds(300)
    ) {
        self.proxy = proxy
        self.notifications = notifications
        self.notificationRecord = notificationRecord
        self.sleeper = sleeper
        self.initialDelay = initialDelay
        self.pollingInterval = pollingInterval
    }

    deinit {
        pollingTask?.cancel()
    }

    public func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await sleeper.sleep(for: initialDelay)
                while !Task.isCancelled {
                    await proxy.checkForUpgrade()
                    let snapshot = await proxy.snapshot()
                    if let version = snapshot.availableUpgrade?.version,
                       notificationRecord.lastNotifiedVersion() != version {
                        notificationRecord.saveLastNotifiedVersion(version)
                        await notifications.submit(.proxyUpdateAvailable(version: version))
                    }
                    try await sleeper.sleep(for: pollingInterval)
                }
            } catch {
                return
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
