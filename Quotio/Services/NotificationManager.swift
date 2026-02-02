//
//  NotificationManager.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//

import Foundation
import UserNotifications

/// Notification types for tracking which notifications have been sent
enum NotificationType: String {
    case quotaLow = "quotaLow"
    case accountCooling = "accountCooling"
    case proxyCrashed = "proxyCrashed"
    case proxyStarted = "proxyStarted"
    case proxyStopped = "proxyStopped"
    case upgradeAvailable = "upgradeAvailable"
    case upgradeSuccess = "upgradeSuccess"
    case upgradeFailed = "upgradeFailed"
    case rollback = "rollback"
}

/// Manages macOS notifications for quota alerts, cooling status, and proxy crashes
@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()
    
    private(set) var isAuthorized = false
    private var sentNotifications: Set<String> = []
    
    // Settings stored in UserDefaults
    var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "notificationsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
    }
    
    var quotaAlertThreshold: Double {
        get { 
            let value = UserDefaults.standard.double(forKey: "quotaAlertThreshold")
            return value > 0 ? value : 20.0 // Default 20%
        }
        set { UserDefaults.standard.set(newValue, forKey: "quotaAlertThreshold") }
    }
    
    var notifyOnQuotaLow: Bool {
        get { UserDefaults.standard.object(forKey: "notifyOnQuotaLow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyOnQuotaLow") }
    }
    
    var notifyOnCooling: Bool {
        get { UserDefaults.standard.object(forKey: "notifyOnCooling") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyOnCooling") }
    }
    
    var notifyOnProxyCrash: Bool {
        get { UserDefaults.standard.object(forKey: "notifyOnProxyCrash") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyOnProxyCrash") }
    }
    
    var notifyOnUpgradeAvailable: Bool {
        get { UserDefaults.standard.object(forKey: "notifyOnUpgradeAvailable") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyOnUpgradeAvailable") }
    }

    private init() {
        // Enable notifications by default on first launch
        if UserDefaults.standard.object(forKey: "notificationsEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "notificationsEnabled")
        }
        
        Task {
            await requestAuthorization()
        }
    }
    
    // MARK: - Authorization
    
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
        } catch {
            isAuthorized = false
        }
    }
    
    func checkAuthorizationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }
    
    // MARK: - Notification Sending
    
    /// Send notification for low quota warning
    /// - Parameters:
    ///   - provider: The AI provider name
    ///   - account: The account email/identifier
    ///   - remainingPercent: Remaining quota percentage (0-100)
    func notifyQuotaLow(provider: String, account: String, remainingPercent: Double) {
        guard notificationsEnabled && notifyOnQuotaLow && isAuthorized else { return }
        guard remainingPercent <= quotaAlertThreshold else { return }
        
        // Prevent duplicate notifications for same account
        let notificationId = "quota_\(provider)_\(account)"
        guard !sentNotifications.contains(notificationId) else { return }
        sentNotifications.insert(notificationId)
        
        let title = LanguageManager.shared.localized("notification.quotaLow.title")
        let bodyFormat = LanguageManager.shared.localized("notification.quotaLow.body")
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(format: bodyFormat, provider, account, Int(remainingPercent))
        content.sound = .default
        content.categoryIdentifier = NotificationType.quotaLow.rawValue
        
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: nil // Deliver immediately
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Send notification when an account enters cooling status
    /// - Parameters:
    ///   - provider: The AI provider name
    ///   - account: The account email/identifier
    func notifyAccountCooling(provider: String, account: String) {
        guard notificationsEnabled && notifyOnCooling && isAuthorized else { return }
        
        // Prevent duplicate notifications for same account
        let notificationId = "cooling_\(provider)_\(account)"
        guard !sentNotifications.contains(notificationId) else { return }
        sentNotifications.insert(notificationId)
        
        let title = LanguageManager.shared.localized("notification.cooling.title")
        let bodyFormat = LanguageManager.shared.localized("notification.cooling.body")
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(format: bodyFormat, provider, account)
        content.sound = .default
        content.categoryIdentifier = NotificationType.accountCooling.rawValue
        
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Send notification when proxy process crashes
    /// - Parameter exitCode: The exit code of the crashed process
    func notifyProxyCrashed(exitCode: Int32) {
        guard notificationsEnabled && notifyOnProxyCrash && isAuthorized else { return }
        
        let title = LanguageManager.shared.localized("notification.proxyCrash.title")
        let bodyFormat = LanguageManager.shared.localized("notification.proxyCrash.body")
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(format: bodyFormat, exitCode)
        content.sound = .defaultCritical
        content.categoryIdentifier = NotificationType.proxyCrashed.rawValue
        
        let request = UNNotificationRequest(
            identifier: "proxy_crash_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Send notification when proxy starts successfully
    func notifyProxyStarted() {
        guard notificationsEnabled && isAuthorized else { return }
        
        let title = LanguageManager.shared.localized("notification.proxyStarted.title")
        let body = LanguageManager.shared.localized("notification.proxyStarted.body")
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "proxy_started",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - State Management
    
    /// Clear notification tracking for an account (call when quota is restored)
    func clearQuotaNotification(provider: String, account: String) {
        sentNotifications.remove("quota_\(provider)_\(account)")
    }
    
    /// Clear cooling notification tracking for an account (call when account is ready again)
    func clearCoolingNotification(provider: String, account: String) {
        sentNotifications.remove("cooling_\(provider)_\(account)")
    }
    
    /// Clear all notification tracking (call on app restart or when appropriate)
    func clearAllNotificationTracking() {
        sentNotifications.removeAll()
    }
    
    /// Remove all pending notifications
    func removeAllPendingNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    
    /// Remove all delivered notifications
    func removeAllDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    
    // MARK: - Upgrade Notifications
    
    /// Send notification when a new proxy version is available
    /// - Parameter version: The new version available for upgrade
    func notifyUpgradeAvailable(version: String) {
        guard notificationsEnabled && notifyOnUpgradeAvailable && isAuthorized else { return }
        
        // Prevent duplicate notifications for same version
        let notificationId = "upgrade_available_\(version)"
        guard !sentNotifications.contains(notificationId) else { return }
        sentNotifications.insert(notificationId)
        
        let title = LanguageManager.shared.localized("notification.upgradeAvailable.title")
        let bodyFormat = LanguageManager.shared.localized("notification.upgradeAvailable.body")
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(format: bodyFormat, version)
        content.sound = .default
        content.categoryIdentifier = NotificationType.upgradeAvailable.rawValue
        
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Clear upgrade available notification tracking (call when user upgrades or dismisses)
    func clearUpgradeAvailableNotification(version: String) {
        sentNotifications.remove("upgrade_available_\(version)")
    }
    
    /// Suppress upgrade notification for a version (call after successful upgrade to prevent duplicate notifications)
    func suppressUpgradeNotification(version: String) {
        sentNotifications.insert("upgrade_available_\(version)")
    }
    
    /// Send notification when proxy upgrade succeeds
    /// - Parameter version: The new version that was installed
    func notifyUpgradeSuccess(version: String) {
        guard notificationsEnabled && isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "notification.upgrade.success.title".localized()
        content.body = String(format: "notification.upgrade.success.body".localized(), version)
        content.sound = .default
        content.categoryIdentifier = NotificationType.upgradeSuccess.rawValue
        
        let request = UNNotificationRequest(
            identifier: "upgrade_success_\(version)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Send notification when proxy upgrade fails
    /// - Parameters:
    ///   - version: The version that failed to install
    ///   - reason: The reason for failure
    func notifyUpgradeFailed(version: String, reason: String) {
        guard notificationsEnabled && isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "notification.upgrade.failed.title".localized()
        content.body = String(format: "notification.upgrade.failed.body".localized(), version, reason)
        content.sound = .defaultCritical
        content.categoryIdentifier = NotificationType.upgradeFailed.rawValue
        
        let request = UNNotificationRequest(
            identifier: "upgrade_failed_\(version)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Send notification when rollback occurs
    /// - Parameter toVersion: The version that was restored
    func notifyRollback(toVersion: String) {
        guard notificationsEnabled && isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "notification.rollback.title".localized()
        content.body = String(format: "notification.rollback.body".localized(), toVersion)
        content.sound = .default
        content.categoryIdentifier = NotificationType.rollback.rawValue
        
        let request = UNNotificationRequest(
            identifier: "rollback_\(toVersion)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
}
