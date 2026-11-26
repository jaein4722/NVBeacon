import Foundation

enum AppInterfaceLanguage: String, Sendable {
    case english
    case korean
    case simplifiedChinese

    static func resolved(from preference: AppLanguagePreference, preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        switch preference {
        case .system:
            for identifier in preferredLanguages {
                let language = Locale.Language(identifier: identifier)
                switch language.languageCode?.identifier {
                case "en":
                    return .english
                case "ko":
                    return .korean
                case "zh" where language.script?.identifier == "Hans":
                    return .simplifiedChinese
                default:
                    continue
                }
            }
            return .english
        case .english:
            return .english
        case .korean:
            return .korean
        case .simplifiedChinese:
            return .simplifiedChinese
        }
    }

    func text(_ english: String, _ korean: String, _ simplifiedChinese: String) -> String {
        switch self {
        case .english:
            return english
        case .korean:
            return korean
        case .simplifiedChinese:
            return simplifiedChinese
        }
    }

    var locale: Locale {
        switch self {
        case .english:
            return Locale(identifier: "en_US_POSIX")
        case .korean:
            return Locale(identifier: "ko_KR")
        case .simplifiedChinese:
            return Locale(identifier: "zh_CN")
        }
    }
}

enum AppLanguagePreference: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case system
    case english
    case korean
    case simplifiedChinese

    var id: String { rawValue }

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .system:
            return language.text("System", "시스템", "跟随系统")
        case .english:
            return "English"
        case .korean:
            return language.text("Korean", "한국어", "韩语")
        case .simplifiedChinese:
            return "简体中文"
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .system:
            return language.text(
                "Follow your macOS preferred languages, using the first one NVBeacon supports. Otherwise English is used.",
                "macOS 선호 언어 순서에서 NVBeacon이 지원하는 첫 번째 언어를 따릅니다. 없으면 영어로 표시합니다.",
                "按 macOS 的语言偏好顺序使用 NVBeacon 支持的第一种语言，否则使用英语。"
            )
        case .english:
            return language.text(
                "Show the NVBeacon interface in English.",
                "NVBeacon 인터페이스를 영어로 표시합니다.",
                "以英语显示 NVBeacon 界面。"
            )
        case .korean:
            return language.text(
                "Show the NVBeacon interface in Korean.",
                "NVBeacon 인터페이스를 한국어로 표시합니다.",
                "以韩语显示 NVBeacon 界面。"
            )
        case .simplifiedChinese:
            return language.text(
                "Show the NVBeacon interface in Simplified Chinese.",
                "NVBeacon 인터페이스를 중국어 간체로 표시합니다.",
                "以简体中文显示 NVBeacon 界面。"
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
