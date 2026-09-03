import Foundation

public struct ApplicationUpdateSnapshot: Equatable, Sendable {
    public var isInitialized: Bool
    public var isChecking: Bool
    public var canCheck: Bool
    public var lastCheckDate: Date?
    public var channel: UpdateChannel

    public init(
        isInitialized: Bool = false,
        isChecking: Bool = false,
        canCheck: Bool = false,
        lastCheckDate: Date? = nil,
        channel: UpdateChannel = .stable
    ) {
        self.isInitialized = isInitialized
        self.isChecking = isChecking
        self.canCheck = canCheck
        self.lastCheckDate = lastCheckDate
        self.channel = channel
    }
}

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown(Int)

    public var isEnabled: Bool {
        self == .enabled || self == .requiresApproval
    }
}

public enum LaunchAtLoginFailure: Error, Equatable, Sendable {
    case registrationFailed(String)
    case unregistrationFailed(String)
}

public struct LaunchAtLoginSnapshot: Equatable, Sendable {
    public var status: LaunchAtLoginStatus
    public var isInApplicationsFolder: Bool

    public init(status: LaunchAtLoginStatus, isInApplicationsFolder: Bool) {
        self.status = status
        self.isInApplicationsFolder = isInApplicationsFolder
    }
}

public enum NotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

public enum SemanticNotification: Equatable, Sendable {
    case quotaLow(provider: String, account: String, remainingPercent: Double)
    case accountCooling(provider: String, account: String)
    case proxyCrashed(exitCode: Int32)
    case proxyStarted
    case proxyUpdateAvailable(version: String)
    case proxyUpdateSucceeded(version: String)
    case proxyUpdateFailed(version: String, failure: ProxyFailure)
    case proxyRolledBack(version: String)
}

public struct NotificationSettingsSnapshot: Equatable, Sendable {
    public var preferences: NotificationPreferences
    public var authorizationStatus: NotificationAuthorizationStatus

    public init(
        preferences: NotificationPreferences,
        authorizationStatus: NotificationAuthorizationStatus = .notDetermined
    ) {
        self.preferences = preferences
        self.authorizationStatus = authorizationStatus
    }
}

public enum TelemetryEvent: String, CaseIterable, Equatable, Sendable {
    case appStarted = "app_started"
    case firstOptedInLaunch = "first_opted_in_launch"
    case appVersionActive = "app_version_active"
}

public struct TelemetryRuntimeContext: Equatable, Sendable {
    public let appVersion: String
    public let buildNumber: String
    public let bundleIdentifier: String
    public let macOSVersion: String
    public let updateChannel: UpdateChannel

    public init?(
        appVersion: String,
        buildNumber: String,
        bundleIdentifier: String,
        macOSVersion: String,
        updateChannel: UpdateChannel
    ) {
        guard Self.isSafeVersion(appVersion),
              Self.isSafeVersion(buildNumber),
              Self.isSafeBundleIdentifier(bundleIdentifier),
              Self.isSafeOperatingSystemVersion(macOSVersion) else {
            return nil
        }
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.bundleIdentifier = bundleIdentifier
        self.macOSVersion = macOSVersion
        self.updateChannel = updateChannel
    }

    fileprivate static func isSafeVersion(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789.-+").contains($0)
            }
    }

    fileprivate static func isSafeBundleIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 255
            && value.contains(".")
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
            }
    }

    fileprivate static func isSafeOperatingSystemVersion(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 128
            && !SensitiveTelemetryValue.containsSensitiveContent(value)
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics
                    .union(.whitespaces)
                    .union(CharacterSet(charactersIn: ".,()-_"))
                    .contains($0)
            }
    }
}

public struct TelemetryPayload: Equatable, Sendable {
    public static let allowedPropertyNames: Set<String> = [
        "anonymous_install_id",
        "app_version",
        "build_number",
        "bundle_id",
        "macos_version",
        "update_channel",
    ]

    public let event: TelemetryEvent
    public let properties: [String: String]

    public init?(event: TelemetryEvent, anonymousInstallID: String, context: TelemetryRuntimeContext) {
        guard UUID(uuidString: anonymousInstallID) != nil else { return nil }
        let properties = [
            "anonymous_install_id": anonymousInstallID.lowercased(),
            "app_version": context.appVersion,
            "build_number": context.buildNumber,
            "bundle_id": context.bundleIdentifier,
            "macos_version": context.macOSVersion,
            "update_channel": context.updateChannel.rawValue,
        ]
        guard Self.allowsProperties(properties) else { return nil }
        self.event = event
        self.properties = properties
    }

    public static func allowsProperties(_ properties: [String: String]) -> Bool {
        guard Set(properties.keys) == allowedPropertyNames,
              let anonymousInstallID = properties["anonymous_install_id"],
              UUID(uuidString: anonymousInstallID) != nil,
              let appVersion = properties["app_version"],
              TelemetryRuntimeContext.isSafeVersion(appVersion),
              let buildNumber = properties["build_number"],
              TelemetryRuntimeContext.isSafeVersion(buildNumber),
              let bundleIdentifier = properties["bundle_id"],
              TelemetryRuntimeContext.isSafeBundleIdentifier(bundleIdentifier),
              let macOSVersion = properties["macos_version"],
              TelemetryRuntimeContext.isSafeOperatingSystemVersion(macOSVersion),
              let updateChannel = properties["update_channel"],
              UpdateChannel(rawValue: updateChannel) != nil else {
            return false
        }
        return true
    }
}

private enum SensitiveTelemetryValue {
    static func containsSensitiveContent(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let forbiddenFragments = [
            "authorization:", "bearer ", "token=", "api_key", "apikey", "cookie:",
            "file://", "http://", "https://", "/users/", "/volumes/", "/private/",
            "-----begin", "{\"", "[\"",
        ]
        return forbiddenFragments.contains(where: normalized.contains)
    }
}
