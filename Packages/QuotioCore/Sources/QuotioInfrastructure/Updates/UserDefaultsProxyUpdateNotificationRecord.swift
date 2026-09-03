import Foundation
import QuotioApplication

public final class UserDefaultsProxyUpdateNotificationRecord:
    ProxyUpdateNotificationRecording,
    @unchecked Sendable
{
    private static let notifiedVersionKey = "notifiedCLIProxyVersion"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func lastNotifiedVersion() -> String? {
        defaults.string(forKey: Self.notifiedVersionKey)
    }

    public func saveLastNotifiedVersion(_ version: String) {
        defaults.set(version, forKey: Self.notifiedVersionKey)
    }
}
