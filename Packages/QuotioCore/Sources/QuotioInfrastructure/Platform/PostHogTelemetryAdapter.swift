import Foundation
import PostHog
import QuotioApplication
import QuotioDomain

@MainActor
public final class PostHogTelemetryAdapter: TelemetryTracking {
    private let bundle: Bundle
    private var isConfigured = false

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public func configure() -> Bool {
        if isConfigured {
            if PostHogSDK.shared.isOptOut() {
                PostHogSDK.shared.optIn()
            }
            return true
        }

        let token = configurationValue(for: "PostHogProjectToken")
        let host = configurationValue(for: "PostHogHost")
        guard !token.isEmpty, !host.isEmpty, !token.contains("$(") else { return false }

        let config = PostHogConfig(projectToken: token, host: host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.setDefaultPersonProperties = false
        config.errorTrackingConfig.autoCapture = false
        config.setBeforeSend { event in
            guard let properties = Self.sanitizedProperties(
                for: event.event,
                properties: event.properties
            ) else { return nil }
            event.properties = properties
            return event
        }
        PostHogSDK.shared.setup(config)
        isConfigured = true
        return true
    }

    public func identify(_ anonymousInstallID: String, properties: [String: String]) {
        guard isConfigured, TelemetryPayload.allowsProperties(properties) else {
            return
        }
        PostHogSDK.shared.identify(anonymousInstallID)
        PostHogSDK.shared.register(properties)
    }

    public func capture(_ payload: TelemetryPayload) {
        guard isConfigured,
              Set(payload.properties.keys) == TelemetryPayload.allowedPropertyNames else {
            return
        }
        PostHogSDK.shared.capture(payload.event.rawValue, properties: payload.properties)
    }

    public func flush() {
        guard isConfigured else { return }
        PostHogSDK.shared.flush()
    }

    public func stopAndReset() {
        guard isConfigured else { return }
        PostHogSDK.shared.optOut()
        PostHogSDK.shared.reset()
        PostHogSDK.shared.close()
        isConfigured = false
    }

    private func configurationValue(for key: String) -> String {
        (bundle.infoDictionary?[key] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func sanitizedProperties(
        for event: String,
        properties: [String: Any]
    ) -> [String: Any]? {
        if event == "$identify" {
            return [:]
        }
        guard TelemetryEvent(rawValue: event) != nil else { return nil }

        let strings = properties.reduce(into: [String: String]()) { result, property in
            guard TelemetryPayload.allowedPropertyNames.contains(property.key),
                  let value = property.value as? String else {
                return
            }
            result[property.key] = value
        }
        guard TelemetryPayload.allowsProperties(strings) else { return nil }
        return strings
    }
}

public struct BundleTelemetryRuntimeContextProvider: TelemetryRuntimeContextProviding {
    private let bundle: Bundle
    private let operatingSystemVersion: @Sendable () -> String

    public init(
        bundle: Bundle = .main,
        operatingSystemVersion: @escaping @Sendable () -> String = {
            ProcessInfo.processInfo.operatingSystemVersionString
        }
    ) {
        self.bundle = bundle
        self.operatingSystemVersion = operatingSystemVersion
    }

    public func context(updateChannel: UpdateChannel) -> TelemetryRuntimeContext? {
        TelemetryRuntimeContext(
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
            buildNumber: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown.bundle",
            macOSVersion: operatingSystemVersion(),
            updateChannel: updateChannel
        )
    }
}
