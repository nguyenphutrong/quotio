import Foundation

public struct RuntimeIdentity: Equatable, Sendable {
    public static let productionBundleIdentifier = "app.bytrong.quotio"
    public static let betaBundleIdentifier = "app.bytrong.quotio.beta"
    public static let production = RuntimeIdentity(bundleIdentifier: productionBundleIdentifier)
    public let bundleIdentifier: String

    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }

    public var isProduction: Bool { bundleIdentifier == Self.productionBundleIdentifier }
    public var applicationSupportDirectoryName: String { isProduction ? "Quotio" : bundleIdentifier }
    public var defaultProxyPort: UInt16 { isProduction ? 8317 : 8318 }
    public var allowsLegacyAccountMigration: Bool { isProduction }
    public var applicationUpdatePolicy: ApplicationUpdatePolicy {
        isProduction || bundleIdentifier == Self.betaBundleIdentifier ? .sparkle : .manualDownload
    }

    public func applicationSupportDirectory(in root: URL) -> URL {
        root.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    public func proxyAuthDirectory(home: URL, applicationSupport: URL) -> URL {
        isProduction ? home.appendingPathComponent(".cli-proxy-api", isDirectory: true)
            : applicationSupportDirectory(in: applicationSupport).appendingPathComponent("auth", isDirectory: true)
    }

    public func antigravityProfileDirectory(home: URL, applicationSupport: URL) -> URL {
        isProduction ? home.appendingPathComponent(".quotio/antigravity-profiles", isDirectory: true)
            : applicationSupportDirectory(in: applicationSupport).appendingPathComponent("antigravity-profiles", isDirectory: true)
    }
}
