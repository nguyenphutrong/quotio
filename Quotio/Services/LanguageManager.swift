//
//  LanguageManager.swift
//  Quotio
//
//  Modern SwiftUI localization using String Catalogs (.xcstrings)
//

import SwiftUI

// MARK: - Supported Languages

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case english = "en"
    case vietnamese = "vi"
    case chinese = "zh-Hans"
    case french = "fr"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        case .chinese: return "简体中文"
        case .french: return "Français"
        }
    }

    var flag: String {
        switch self {
        case .english: return "🇺🇸"
        case .vietnamese: return "🇻🇳"
        case .chinese: return "🇨🇳"
        case .french: return "🇫🇷"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var bundle: Bundle {
        if let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }
}

// MARK: - Language Manager

@MainActor
@Observable
final class LanguageManager {

    static let shared = LanguageManager()

    private(set) var currentLanguage: AppLanguage {
        didSet {
            guard oldValue != currentLanguage else { return }
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "appLanguage")
        }
    }

    var locale: Locale { currentLanguage.locale }
    var bundle: Bundle { currentLanguage.bundle }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        self.currentLanguage = AppLanguage(rawValue: saved) ?? .english
    }

    func setLanguage(_ language: AppLanguage) {
        currentLanguage = language
    }

    func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: currentLanguage.bundle, comment: "")
    }
}

// MARK: - String Extension

extension String {
    @MainActor
    func localized() -> String {
        LanguageManager.shared.localized(self)
    }
}
