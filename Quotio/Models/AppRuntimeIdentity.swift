//
//  AppRuntimeIdentity.swift
//  Quotio
//

import Foundation

nonisolated enum AppRuntimeIdentity {
    static let defaultBundleIdentifier = "dev.quotio.desktop"
    static let defaultDisplayName = "Quotio"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? defaultBundleIdentifier
    }

    static var displayName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }

        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }

        return defaultDisplayName
    }

    static var windowTitle: String { displayName }

    static var applicationSupportDirectoryName: String { displayName }

    static var updatesEnabled: Bool {
        guard let rawValue = Bundle.main.object(forInfoDictionaryKey: "QuotioUpdatesEnabled") as? String else {
            return true
        }

        return ["yes", "true", "1"].contains(rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static var isBeta: Bool {
        bundleIdentifier.hasSuffix(".beta") || displayName.localizedCaseInsensitiveContains("beta")
    }

    static var isStable: Bool {
        !isBeta
    }

    static func applicationSupportDirectoryURL(fileManager: FileManager = .default) -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory not found")
        }

        return appSupport.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    static func keychainService(suffix: String) -> String {
        "\(bundleIdentifier).\(suffix)"
    }
}
