import Foundation
import Observation
import QuotioApplication
import QuotioDomain

@MainActor
private enum PresentationLocalization {
    static var bundle = Bundle.main

    static func updateBundle(_ newBundle: Bundle) {
        bundle = newBundle
    }

    static func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }
}

@MainActor
@Observable
public final class LanguageManager {
    @ObservationIgnored private let repository: any LanguagePreferencesRepository
    @ObservationIgnored private var didChangeHandler: (@MainActor (AppLanguage) -> Void)?

    public private(set) var currentLanguage: AppLanguage {
        didSet {
            guard oldValue != currentLanguage else { return }
            repository.save(LanguagePreferences(language: currentLanguage))
            PresentationLocalization.updateBundle(currentLanguage.bundle)
            didChangeHandler?(currentLanguage)
        }
    }

    public var locale: Locale { currentLanguage.locale }
    public var bundle: Bundle { currentLanguage.bundle }

    public init(repository: any LanguagePreferencesRepository) {
        self.repository = repository
        currentLanguage = repository.load().language
        PresentationLocalization.updateBundle(currentLanguage.bundle)
    }

    public func setLanguage(_ language: AppLanguage) {
        currentLanguage = language
    }

    public func setDidChangeHandler(_ handler: (@MainActor (AppLanguage) -> Void)?) {
        didChangeHandler = handler
    }

    public func localized(_ key: String) -> String {
        NSLocalizedString(key, bundle: currentLanguage.bundle, comment: "")
    }
}

public extension String {
    @MainActor
    func localized() -> String {
        PresentationLocalization.localized(self)
    }

    @MainActor
    func localizedStatic() -> String {
        localized()
    }
}

public extension AppLanguage {
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
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}
