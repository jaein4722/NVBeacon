import Foundation

enum AppInterfaceLanguage: String, Sendable {
    case english
    case korean

    static func resolved(from preference: AppLanguagePreference, preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        switch preference {
        case .system:
            return preferredLanguages.contains { $0.lowercased().hasPrefix("ko") } ? .korean : .english
        case .english:
            return .english
        case .korean:
            return .korean
        }
    }

    func text(_ english: String, _ korean: String) -> String {
        switch self {
        case .english:
            return english
        case .korean:
            return korean
        }
    }

    var locale: Locale {
        switch self {
        case .english:
            return Locale(identifier: "en_US_POSIX")
        case .korean:
            return Locale(identifier: "ko_KR")
        }
    }
}

enum AppLanguagePreference: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case system
    case english
    case korean

    var id: String { rawValue }

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .system:
            return language.text("System", "시스템")
        case .english:
            return "English"
        case .korean:
            return language.text("Korean", "한국어")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .system:
            return language.text(
                "Follow the current macOS language. Unsupported system languages fall back to English.",
                "현재 macOS 언어를 따릅니다. 지원하지 않는 언어는 영어로 표시합니다."
            )
        case .english:
            return language.text(
                "Show the NVBeacon interface in English.",
                "NVBeacon 인터페이스를 영어로 표시합니다."
            )
        case .korean:
            return language.text(
                "Show the NVBeacon interface in Korean.",
                "NVBeacon 인터페이스를 한국어로 표시합니다."
            )
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
