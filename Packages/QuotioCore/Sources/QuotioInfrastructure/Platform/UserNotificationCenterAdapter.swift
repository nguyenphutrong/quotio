import Foundation
import QuotioApplication
import QuotioDomain
import UserNotifications

@MainActor
public final class UserNotificationCenterAdapter: NotificationDelivering {
    public typealias Localizer = @MainActor @Sendable (String) -> String

    private let center: UNUserNotificationCenter
    private let localize: Localizer
    private let now: @Sendable () -> Date

    public init(
        center: UNUserNotificationCenter = .current(),
        localize: @escaping Localizer,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.center = center
        self.localize = localize
        self.now = now
    }

    public func requestAuthorization() async -> NotificationAuthorizationStatus {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    public func authorizationStatus() async -> NotificationAuthorizationStatus {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:
            return .authorized
        case .denied, .provisional, .ephemeral:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    public func deliver(_ notification: SemanticNotification) {
        let content = UNMutableNotificationContent()
        let identifier: String

        switch notification {
        case .quotaLow(let provider, let account, let remainingPercent):
            identifier = "quota_\(provider)_\(account)"
            content.title = localize("notification.quotaLow.title")
            content.body = String(
                format: localize("notification.quotaLow.body"),
                provider,
                account,
                Int(remainingPercent)
            )
            content.categoryIdentifier = "quotaLow"
            content.sound = .default
        case .accountCooling(let provider, let account):
            identifier = "cooling_\(provider)_\(account)"
            content.title = localize("notification.cooling.title")
            content.body = String(format: localize("notification.cooling.body"), provider, account)
            content.categoryIdentifier = "accountCooling"
            content.sound = .default
        case .proxyCrashed(let exitCode):
            identifier = "proxy_crash_\(now().timeIntervalSince1970)"
            content.title = localize("notification.proxyCrash.title")
            content.body = String(format: localize("notification.proxyCrash.body"), exitCode)
            content.categoryIdentifier = "proxyCrashed"
            content.sound = .defaultCritical
        case .proxyStarted:
            identifier = "proxy_started"
            content.title = localize("notification.proxyStarted.title")
            content.body = localize("notification.proxyStarted.body")
            content.sound = .default
        case .proxyUpdateAvailable(let version):
            identifier = "upgrade_available_\(version)"
            content.title = localize("notification.upgradeAvailable.title")
            content.body = String(format: localize("notification.upgradeAvailable.body"), version)
            content.categoryIdentifier = "upgradeAvailable"
            content.sound = .default
        case .proxyUpdateSucceeded(let version):
            identifier = "upgrade_success_\(version)"
            content.title = localize("notification.upgrade.success.title")
            content.body = String(format: localize("notification.upgrade.success.body"), version)
            content.categoryIdentifier = "upgradeSuccess"
            content.sound = .default
        case .proxyUpdateFailed(let version, let reason):
            identifier = "upgrade_failed_\(version)"
            content.title = localize("notification.upgrade.failed.title")
            content.body = String(format: localize("notification.upgrade.failed.body"), version, reason)
            content.categoryIdentifier = "upgradeFailed"
            content.sound = .defaultCritical
        case .proxyRolledBack(let version):
            identifier = "rollback_\(version)"
            content.title = localize("notification.rollback.title")
            content.body = String(format: localize("notification.rollback.body"), version)
            content.categoryIdentifier = "rollback"
            content.sound = .default
        }

        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    public func removeAllPending() {
        center.removeAllPendingNotificationRequests()
    }

    public func removeAllDelivered() {
        center.removeAllDeliveredNotifications()
    }
}
