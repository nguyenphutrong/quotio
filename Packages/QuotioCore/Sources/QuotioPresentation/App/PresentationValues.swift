import Foundation
import QuotioDomain
import SwiftUI

public enum AppConstants {
    public static let maxInstalledVersions = 3
    public static let defaultProxyPort: UInt16 = 17080
    public static let maxMenuBarItems = 3
}

public enum NavigationPage: String, CaseIterable, Identifiable, Sendable {
    case dashboard = "Dashboard"
    case quota = "Quota"
    case providers = "Providers"
    case agents = "Agents"
    case apiKeys = "API Keys"
    case logs = "Logs"
    case settings = "Settings"
    case about = "About"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .quota: "chart.bar.fill"
        case .providers: "person.2.badge.key"
        case .agents: "terminal"
        case .apiKeys: "key.horizontal"
        case .logs: "doc.text"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

public enum AccountSorting {
    public static func prioritizingActive<T>(_ items: [T], isActive: (T) -> Bool) -> [T] {
        var active: [T] = []
        var inactive: [T] = []
        for item in items {
            if isActive(item) {
                active.append(item)
            } else {
                inactive.append(item)
            }
        }
        return active.isEmpty ? items : active + inactive
    }
}

public extension QuotaAnalyticsRow {
    static func noData(id: String, title: String) -> QuotaAnalyticsRow {
        QuotaAnalyticsRow(id: id, title: title, value: "No data", isAvailable: false)
    }
}

public extension Int {
    var formattedCompact: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 1_000 { return String(format: "%.1fK", Double(self) / 1_000) }
        return "\(self)"
    }
}

public enum ProxyURLValidationResult: Equatable, Sendable {
    case valid
    case empty
    case invalidScheme
    case invalidURL
    case missingHost
    case missingPort
    case invalidPort

    public var isValid: Bool { self == .valid || self == .empty }

    public var localizationKey: String? {
        switch self {
        case .valid, .empty: nil
        case .invalidScheme: "settings.proxy.error.invalidScheme"
        case .invalidURL: "settings.proxy.error.invalidURL"
        case .missingHost: "settings.proxy.error.missingHost"
        case .missingPort: "settings.proxy.error.missingPort"
        case .invalidPort: "settings.proxy.error.invalidPort"
        }
    }
}

public enum ProxyURLValidator {
    public static let supportedSchemes = ["socks5", "http", "https"]

    public static func validate(_ urlString: String) -> ProxyURLValidationResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard supportedSchemes.contains(where: { trimmed.lowercased().hasPrefix("\($0)://") }) else {
            return .invalidScheme
        }
        guard let url = URL(string: trimmed) else { return .invalidURL }
        guard let host = url.host, !host.isEmpty else { return .missingHost }
        if url.scheme?.lowercased() == "socks5", url.port == nil { return .missingPort }
        if let port = url.port, !(1...65535).contains(port) { return .invalidPort }
        return .valid
    }

    public static func sanitize(_ urlString: String) -> String {
        var value = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

@MainActor
public extension CloudflareTunnelStatus {
    var displayName: String {
        switch self {
        case .idle: "tunnel.status.idle".localized()
        case .starting: "tunnel.status.starting".localized()
        case .active: "tunnel.status.active".localized()
        case .stopping: "tunnel.status.stopping".localized()
        case .error: "tunnel.status.error".localized()
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .starting, .stopping: .orange
        case .active: .green
        case .error: .red
        }
    }

    var icon: String {
        switch self {
        case .idle, .active: "globe"
        case .starting, .stopping: "arrow.triangle.2.circlepath"
        case .error: "exclamationmark.triangle"
        }
    }
}
