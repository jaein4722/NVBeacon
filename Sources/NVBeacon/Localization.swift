import Foundation
import NVBeaconCore

typealias AppLanguagePreference = NVBeaconCore.LanguagePreference

/// The language the interface is shown in: one of the files in `Shared/Localization`.
struct AppInterfaceLanguage: Hashable, Sendable {
    let code: String

    static let english = AppInterfaceLanguage(code: "en")
    static let korean = AppInterfaceLanguage(code: "ko")
    static let simplifiedChinese = AppInterfaceLanguage(code: "zh-Hans")

    /// Read once: from the app bundle, or from the source tree for `swift run` and tests.
    static let translations = Translations.load(fromFirstOf: [
        Bundle.main.resourceURL?.appendingPathComponent("Localization"),
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/Localization"),
    ].compactMap { $0 })

    static func resolved(from preference: AppLanguagePreference, preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        Self(code: translations.resolve(preference, preferredLanguages: preferredLanguages))
    }

    /// The text for a key of the shared files; arguments fill its `%@` placeholders.
    func text(_ key: String, _ arguments: Any...) -> String {
        text(key, arguments: arguments)
    }

    func text(_ key: String, arguments: [Any]) -> String {
        Self.translations.text(key, language: code, arguments: arguments.map { String(describing: $0) })
    }

    var locale: Locale {
        switch code {
        case "en":
            return Locale(identifier: "en_US_POSIX")
        case "ko":
            return Locale(identifier: "ko_KR")
        case "zh-Hans":
            return Locale(identifier: "zh_CN")
        default:
            return Locale(identifier: code)
        }
    }
}

extension AppLanguagePreference {
    /// System, then every language that has a file.
    static var choices: [AppLanguagePreference] {
        [.system] + AppInterfaceLanguage.translations.languages.map { .language($0.code) }
    }

    /// Languages are listed by their own names, as in the macOS language list.
    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .system:
            return language.text("System")
        case .language(let code):
            return AppInterfaceLanguage.translations.language(code)?.name ?? code
        }
    }
}

enum AppLocalizer {
    static func currentLanguage(from userDefaults: UserDefaults = .standard) -> AppInterfaceLanguage {
        guard
            let data = userDefaults.data(forKey: "nvbeacon.settings"),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .resolved(from: .system)
        }

        return settings.resolvedLanguage
    }
}

extension AppSettings {
    var resolvedLanguage: AppInterfaceLanguage {
        AppInterfaceLanguage.resolved(from: languagePreference)
    }
}
