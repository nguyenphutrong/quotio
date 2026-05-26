//
//  ProxyVersionModels.swift
//  Quotio - CLIProxyAPI GUI Wrapper
//
//  Models for managed proxy versioning and compatibility checking.
//

import Foundation

// MARK: - Proxy Binary Source

nonisolated enum ProxyBinarySource: String, Codable, CaseIterable, Identifiable, Sendable {
    case cpaPlusPlus = "cpa-plusplus"

    static let userDefaultsKey = "selectedProxyBinarySource"
    static let devBinaryPathEnvironmentKey = "CPA_PLUSPLUS_BINARY_PATH"
    static let binaryName = "cpa-plusplus"
    static let legacyBinaryName = "CLIProxyAPI"

    var id: String { rawValue }

    var storageDirectoryName: String {
        switch self {
        case .cpaPlusPlus: return "cpa-plusplus"
        }
    }

    var displayName: String {
        switch self {
        case .cpaPlusPlus:
            return "cpa-plusplus"
        }
    }

    var shortDescription: String {
        switch self {
        case .cpaPlusPlus:
            return "Fork-managed proxy server"
        }
    }

    var selectionDescription: String {
        switch self {
        case .cpaPlusPlus:
            return "cpa-plusplus"
        }
    }

    var detailDescription: String {
        switch self {
        case .cpaPlusPlus:
            return "Managed through the cpa-plusplus Management API."
        }
    }

    var installActionTitle: String {
        switch self {
        case .cpaPlusPlus:
            return "Rebuild Quotio"
        }
    }

    var notInstalledTitle: String {
        switch self {
        case .cpaPlusPlus:
            return "Bundled cpa-plusplus Missing"
        }
    }

    var installDescription: String {
        switch self {
        case .cpaPlusPlus:
            return "Quotio includes a tested cpa-plusplus binary. Rebuild the app or set CPA_PLUSPLUS_BINARY_PATH for local development."
        }
    }

    var binaryName: String {
        switch self {
        case .cpaPlusPlus:
            return Self.binaryName
        }
    }

    var installHint: String {
        switch self {
        case .cpaPlusPlus:
            return "Bundled cpa-plusplus is missing. Rebuild Quotio or set CPA_PLUSPLUS_BINARY_PATH for local development."
        }
    }
}

// MARK: - Compatibility Check Result

nonisolated enum CompatibilityCheckResult: Sendable {
    case compatible
    case proxyNotResponding
    case proxyNotRunning
    case connectionError(String)

    var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .compatible:
            return "Proxy is compatible"
        case .proxyNotResponding:
            return "Proxy is not responding to API requests"
        case .proxyNotRunning:
            return "Proxy is not running"
        case .connectionError(let message):
            return "Connection error: \(message)"
        }
    }
}
