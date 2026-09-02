import AppKit
import Foundation
import QuotioDomain
import SwiftUI

typealias OperatingMode = QuotioDomain.OperatingMode
typealias MenuBarQuotaItem = QuotioDomain.MenuBarQuotaItem
typealias MenuBarColorMode = QuotioDomain.MenuBarColorMode
typealias QuotaDisplayMode = QuotioDomain.QuotaDisplayMode
typealias QuotaDisplayStyle = QuotioDomain.QuotaDisplayStyle
typealias RefreshCadence = QuotioDomain.RefreshCadence
typealias TotalUsageMode = QuotioDomain.TotalUsageMode
typealias ModelAggregationMode = QuotioDomain.ModelAggregationMode
typealias WarmupCadence = QuotioDomain.WarmupCadence
typealias WarmupScheduleMode = QuotioDomain.WarmupScheduleMode
typealias IDEScanOptions = QuotioDomain.IDEScanOptions
typealias IDEScanResult = QuotioDomain.IDEScanResult
typealias AppearanceMode = QuotioDomain.AppearanceMode
typealias AppLanguage = QuotioDomain.AppLanguage
typealias UpdateChannel = QuotioDomain.UpdateChannel

extension OperatingMode {
    var displayName: String {
        switch self {
        case .monitor: "onboarding.mode.monitor.title".localizedStatic()
        case .localProxy: "onboarding.mode.localProxy.title".localizedStatic()
        }
    }

    var description: String {
        switch self {
        case .monitor: "onboarding.mode.monitor.description".localizedStatic()
        case .localProxy: "onboarding.mode.localProxy.description".localizedStatic()
        }
    }

    var icon: String {
        switch self {
        case .monitor: "chart.bar.fill"
        case .localProxy: "server.rack"
        }
    }

    var color: Color {
        switch self {
        case .monitor: .green
        case .localProxy: .blue
        }
    }

    var badge: String? {
        self == .monitor ? "onboarding.mode.badge.default".localizedStatic() : nil
    }

    var features: [String] {
        switch self {
        case .monitor:
            [
                "onboarding.mode.monitor.feature1".localizedStatic(),
                "onboarding.mode.monitor.feature2".localizedStatic(),
                "onboarding.mode.monitor.feature3".localizedStatic(),
            ]
        case .localProxy:
            [
                "onboarding.mode.localProxy.feature1".localizedStatic(),
                "onboarding.mode.localProxy.feature2".localizedStatic(),
                "onboarding.mode.localProxy.feature3".localizedStatic(),
            ]
        }
    }

    var visiblePages: [NavigationPage] {
        switch self {
        case .monitor: [.dashboard, .quota, .providers, .settings, .about]
        case .localProxy: [.dashboard, .quota, .providers, .agents, .apiKeys, .logs, .settings, .about]
        }
    }
}

extension MenuBarQuotaItem {
    var aiProvider: AIProvider? {
        provider == "copilot" ? .copilot : AIProvider(rawValue: provider)
    }

    var providerSymbol: String {
        aiProvider?.menuBarSymbol ?? "?"
    }
}

extension AppearanceMode {
    var localizationKey: String {
        switch self {
        case .system: "settings.appearance.system"
        case .light: "settings.appearance.light"
        case .dark: "settings.appearance.dark"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension MenuBarColorMode {
    var localizationKey: String {
        switch self {
        case .colored: "settings.menubar.colored"
        case .monochrome: "settings.menubar.monochrome"
        }
    }
}

extension QuotaDisplayMode {
    var localizationKey: String {
        switch self {
        case .used: "settings.quota.displayMode.used"
        case .remaining: "settings.quota.displayMode.remaining"
        }
    }

    var suffixKey: String {
        switch self {
        case .used: "settings.quota.used"
        case .remaining: "settings.quota.left"
        }
    }
}

extension QuotaDisplayStyle {
    var localizationKey: String {
        switch self {
        case .card: "settings.quota.style.card"
        case .lowestBar: "settings.quota.style.lowestBar"
        case .ring: "settings.quota.style.ring"
        }
    }

    var iconName: String {
        switch self {
        case .card: "rectangle.portrait"
        case .lowestBar: "chart.bar.fill"
        case .ring: "circle.dotted"
        }
    }
}

extension RefreshCadence {
    var localizationKey: String {
        switch self {
        case .manual: "settings.refresh.manual"
        case .oneMinute: "settings.refresh.1min"
        case .twoMinutes: "settings.refresh.2min"
        case .fiveMinutes: "settings.refresh.5min"
        case .tenMinutes: "settings.refresh.10min"
        case .fifteenMinutes: "settings.refresh.15min"
        }
    }
}

extension TotalUsageMode {
    var localizationKey: String {
        switch self {
        case .sessionOnly: "settings.usageDisplay.totalMode.sessionOnly"
        case .combined: "settings.usageDisplay.totalMode.combined"
        }
    }
}

extension ModelAggregationMode {
    var localizationKey: String {
        switch self {
        case .lowest: "settings.usageDisplay.modelAggregation.lowest"
        case .average: "settings.usageDisplay.modelAggregation.average"
        }
    }
}

extension WarmupCadence {
    var localizationKey: String {
        switch self {
        case .fifteenMinutes: "warmup.interval.15min"
        case .thirtyMinutes: "warmup.interval.30min"
        case .oneHour: "warmup.interval.1h"
        case .twoHours: "warmup.interval.2h"
        case .threeHours: "warmup.interval.3h"
        case .fourHours: "warmup.interval.4h"
        }
    }
}

extension WarmupScheduleMode {
    var localizationKey: String {
        switch self {
        case .interval: "warmup.schedule.interval"
        case .daily: "warmup.schedule.daily"
        }
    }
}

extension IDEScanOptions {
    var accessedPaths: [String] {
        var paths: [String] = []
        if scanCursor {
            paths.append("~/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        }
        if scanTrae {
            paths.append("~/Library/Application Support/Trae/User/globalStorage/storage.json")
        }
        if scanCLITools {
            paths.append("/usr/local/bin, /opt/homebrew/bin (via 'which' command)")
        }
        return paths
    }

    var privacyNoticeItems: [(icon: String, title: String, detail: String)] {
        var items: [(icon: String, title: String, detail: String)] = []
        if scanCursor {
            items.append(("cursor", "Cursor IDE", "~/Library/Application Support/Cursor/"))
        }
        if scanTrae {
            items.append(("trae", "Trae IDE", "~/Library/Application Support/Trae/"))
        }
        if scanCLITools {
            items.append(("terminal", "CLI Tools", "Uses 'which' command to find installed tools"))
        }
        return items
    }
}

extension AppLanguage {
    var displayName: String {
        switch self {
        case .english: "English"
        case .vietnamese: "Tiếng Việt"
        case .chinese: "简体中文"
        case .french: "Français"
        }
    }

    var flag: String {
        switch self {
        case .english: "🇺🇸"
        case .vietnamese: "🇻🇳"
        case .chinese: "🇨🇳"
        case .french: "🇫🇷"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    var bundle: Bundle {
        if let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        #if DEBUG
        Log.debug("LanguageManager: Bundle not found for \\(rawValue), falling back to main bundle")
        #endif
        return .main
    }
}

extension UpdateChannel {
    var displayName: String {
        switch self {
        case .stable: "settings.updateChannel.stable".localizedStatic()
        case .beta: "settings.updateChannel.beta".localizedStatic()
        }
    }

    var icon: String {
        switch self {
        case .stable: "checkmark.shield"
        case .beta: "flask.fill"
        }
    }
}
