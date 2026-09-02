//
//  LanguageManager.swift
//  Quotio
//
//  Modern SwiftUI localization using String Catalogs (.xcstrings)
//

import QuotioApplication
import QuotioDomain
import QuotioInfrastructure
import SwiftUI

// MARK: - Language Manager

@MainActor
@Observable
final class LanguageManager {

    static let shared = LanguageManager(
        repository: UserDefaultsLanguagePreferencesRepository()
    )

    @ObservationIgnored private let repository: any LanguagePreferencesRepository

    private(set) var currentLanguage: AppLanguage {
        didSet {
            guard oldValue != currentLanguage else { return }
            repository.save(LanguagePreferences(language: currentLanguage))
        }
    }

    var locale: Locale { currentLanguage.locale }
    var bundle: Bundle { currentLanguage.bundle }

    init(repository: any LanguagePreferencesRepository) {
        self.repository = repository
        self.currentLanguage = repository.load().language
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
    
    /// Nonisolated localization for use in computed properties on enums/structs.
    /// Reads stored preference directly without MainActor isolation.
    nonisolated func localizedStatic() -> String {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
        let migrated = (saved == "zh") ? "zh-Hans" : saved
        
        if let path = Bundle.main.path(forResource: migrated, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return NSLocalizedString(self, bundle: bundle, comment: "")
        }
        return NSLocalizedString(self, bundle: .main, comment: "")
    }
}
