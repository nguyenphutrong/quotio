//
//  TelemetryService.swift
//  Quotio
//
//  Opt-in anonymous usage and crash diagnostics via PostHog.
//

import Foundation
import PostHog

@MainActor
final class TelemetryService {
    static let shared = TelemetryService()

    private let settings = TelemetrySettings.shared
    private var isConfigured = false
    private var isStarted = false

    private init() {}

    func configureIfAllowed() {
        guard settings.shareAnonymousUsage else {
            settings.resetAnonymousInstallID()
            return
        }

        startIfPossible()
    }

    func applySharingPreference() {
        if settings.shareAnonymousUsage {
            startIfPossible()
        } else {
            if isStarted {
                PostHogSDK.shared.optOut()
                PostHogSDK.shared.reset()
                PostHogSDK.shared.close()
            }
            isStarted = false
            isConfigured = false
            settings.resetAnonymousInstallID()
        }
    }

    /// Stops PostHog before a full app reset deletes its on-disk store.
    ///
    /// PostHog 3.64.1 persists the anonymous/device identity, config and the
    /// pending event queues under
    /// `~/Library/Application Support/<bundle-id>/<project-token>` and flushes
    /// them on a background timer. Without closing the SDK first, that timer can
    /// re-create the directory after `AppResetService` removed it, so the
    /// "fresh install" would keep the old anonymous identity (issue #373).
    ///
    /// `close()` tears down the queues and timers; the in-memory identity is
    /// dropped first so no further event can be written while shutting down.
    func shutdownForReset() {
        guard isConfigured || isStarted else { return }

        PostHogSDK.shared.optOut()
        PostHogSDK.shared.reset()
        PostHogSDK.shared.close()
        isStarted = false
        isConfigured = false
    }

    private func startIfPossible() {
        guard let config = makeConfiguration() else { return }
        let installID = settings.ensureAnonymousInstallID()

        if !isConfigured {
            PostHogSDK.shared.setup(config)
            isConfigured = true
            isStarted = true
        } else if PostHogSDK.shared.isOptOut() {
            PostHogSDK.shared.optIn()
        }

        PostHogSDK.shared.identify(installID)
        PostHogSDK.shared.register(baseProperties(installID: installID))

        if !settings.hasSentFirstOptInLaunch {
            capture(.firstOptedInLaunch)
            settings.hasSentFirstOptInLaunch = true
        }

        capture(.appStarted)
        capture(.appVersionActive)
        PostHogSDK.shared.flush()
    }

    private func capture(_ event: TelemetryEvent) {
        guard settings.shareAnonymousUsage, isStarted, let installID = settings.anonymousInstallID else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: baseProperties(installID: installID))
    }

    private func makeConfiguration() -> PostHogConfig? {
        let token = stringFromInfoDictionary("PostHogProjectToken")
        let host = stringFromInfoDictionary("PostHogHost")

        guard !token.isEmpty, !host.isEmpty, !token.contains("$(") else {
            return nil
        }

        let config = PostHogConfig(projectToken: token, host: host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.setDefaultPersonProperties = false
        config.errorTrackingConfig.autoCapture = true
        config.setBeforeSend { event in
            guard TelemetryEvent.allowedRawValues.contains(event.event) || event.event == "$identify" || event.event == "$exception" else {
                return nil
            }

            event.properties = TelemetryPayloadSanitizer.sanitize(event.properties)
            return event
        }
        return config
    }

    private func baseProperties(installID: String) -> [String: Any] {
        [
            "anonymous_install_id": installID,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build_number": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "macos_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "update_channel": UpdaterService.shared.updateChannel.rawValue
        ]
    }

    private func stringFromInfoDictionary(_ key: String) -> String {
        let value = Bundle.main.infoDictionary?[key] as? String ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum TelemetryEvent: String, CaseIterable {
    case appStarted = "app_started"
    case firstOptedInLaunch = "first_opted_in_launch"
    case appVersionActive = "app_version_active"

    static let allowedRawValues = Set(allCases.map(\.rawValue))
}

private enum TelemetryPayloadSanitizer {
    static func sanitize(_ properties: [String: Any]) -> [String: Any] {
        properties.mapValues(sanitizeValue)
    }

    private static func sanitizeValue(_ value: Any) -> Any {
        if let string = value as? String {
            return sanitizeString(string)
        }

        if let dictionary = value as? [String: Any] {
            return sanitize(dictionary)
        }

        if let array = value as? [Any] {
            return array.map(sanitizeValue)
        }

        return value
    }

    private static func sanitizeString(_ value: String) -> String {
        if value.hasPrefix("file://") {
            return "[redacted_path]"
        }

        if value.hasPrefix("/") {
            return (value as NSString).lastPathComponent
        }

        if value.contains("/Users/") || value.contains("/Volumes/") || value.contains("/private/") {
            return "[redacted_path]"
        }

        return value
    }
}
