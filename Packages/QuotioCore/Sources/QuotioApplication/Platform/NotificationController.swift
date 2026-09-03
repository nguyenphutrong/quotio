import QuotioDomain

@MainActor
public final class NotificationController: NotificationRequesting {
    private let repository: any NotificationPreferencesRepository
    private let delivery: any NotificationDelivering
    private var sentNotifications: Set<String> = []
    private var didChangeHandler: (@MainActor (NotificationSettingsSnapshot) -> Void)?

    public private(set) var snapshot: NotificationSettingsSnapshot

    public init(
        repository: any NotificationPreferencesRepository,
        delivery: any NotificationDelivering
    ) {
        self.repository = repository
        self.delivery = delivery
        self.snapshot = NotificationSettingsSnapshot(preferences: repository.load())
    }

    public func requestAuthorization() async {
        snapshot.authorizationStatus = await delivery.requestAuthorization()
        publish()
    }

    public func refreshAuthorizationStatus() async {
        snapshot.authorizationStatus = await delivery.authorizationStatus()
        publish()
    }

    public func submit(_ notification: SemanticNotification) {
        let preferences = snapshot.preferences
        guard preferences.notificationsEnabled,
              snapshot.authorizationStatus == .authorized,
              isEnabled(notification, preferences: preferences),
              meetsThreshold(notification, preferences: preferences) else {
            return
        }

        if let key = trackingKey(for: notification) {
            guard sentNotifications.insert(key).inserted else { return }
        }
        delivery.deliver(notification)
    }

    public func clearQuotaNotification(provider: String, account: String) {
        sentNotifications.remove("quota_\(provider)_\(account)")
    }

    public func clearCoolingNotification(provider: String, account: String) {
        sentNotifications.remove("cooling_\(provider)_\(account)")
    }

    public func clearUpdateNotification(version: String) {
        sentNotifications.remove("upgrade_available_\(version)")
    }

    public func suppressUpdateNotification(version: String) {
        sentNotifications.insert("upgrade_available_\(version)")
    }

    public func clearAllTracking() {
        sentNotifications.removeAll()
    }

    public func updatePreferences(_ preferences: NotificationPreferences) {
        snapshot.preferences = preferences
        repository.save(preferences)
        publish()
    }

    public func setDidChangeHandler(
        _ handler: (@MainActor (NotificationSettingsSnapshot) -> Void)?
    ) {
        didChangeHandler = handler
        handler?(snapshot)
    }

    public func removeAllPendingNotifications() {
        delivery.removeAllPending()
    }

    public func removeAllDeliveredNotifications() {
        delivery.removeAllDelivered()
    }

    private func isEnabled(
        _ notification: SemanticNotification,
        preferences: NotificationPreferences
    ) -> Bool {
        switch notification {
        case .quotaLow:
            preferences.notifyOnQuotaLow
        case .accountCooling:
            preferences.notifyOnCooling
        case .proxyCrashed:
            preferences.notifyOnProxyCrash
        case .proxyUpdateAvailable:
            preferences.notifyOnUpgradeAvailable
        case .proxyStarted, .proxyUpdateSucceeded, .proxyUpdateFailed, .proxyRolledBack:
            true
        }
    }

    private func meetsThreshold(
        _ notification: SemanticNotification,
        preferences: NotificationPreferences
    ) -> Bool {
        guard case .quotaLow(_, _, let remainingPercent) = notification else { return true }
        return remainingPercent <= preferences.quotaAlertThreshold
    }

    private func trackingKey(for notification: SemanticNotification) -> String? {
        switch notification {
        case .quotaLow(let provider, let account, _):
            "quota_\(provider)_\(account)"
        case .accountCooling(let provider, let account):
            "cooling_\(provider)_\(account)"
        case .proxyUpdateAvailable(let version):
            "upgrade_available_\(version)"
        case .proxyCrashed, .proxyStarted, .proxyUpdateSucceeded, .proxyUpdateFailed, .proxyRolledBack:
            nil
        }
    }

    private func publish() {
        didChangeHandler?(snapshot)
    }
}

public actor ProxyNotificationRelay: ProxyNotificationDelivering {
    private weak var notifications: (any NotificationRequesting)?

    public init(notifications: any NotificationRequesting) {
        self.notifications = notifications
    }

    public func deliver(_ notification: ProxyNotification) async {
        guard let notifications else { return }
        switch notification {
        case .crashed(let exitCode):
            await notifications.submit(.proxyCrashed(exitCode: exitCode))
        case .upgradeSucceeded(let version):
            await notifications.submit(.proxyUpdateSucceeded(version: version))
        case .upgradeFailed(let version, let reason):
            await notifications.submit(.proxyUpdateFailed(version: version, reason: reason))
        case .rolledBack(let version):
            await notifications.submit(.proxyRolledBack(version: version))
        case .suppressUpgrade(let version):
            await notifications.suppressUpdateNotification(version: version)
        }
    }
}
