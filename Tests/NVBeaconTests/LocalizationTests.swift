import Foundation
import Testing
@testable import NVBeacon

@Test func systemLanguageFollowsTheFirstSupportedPreferredLanguage() {
    func resolved(_ languages: [String]) -> AppInterfaceLanguage {
        AppInterfaceLanguage.resolved(from: .system, preferredLanguages: languages)
    }
    #expect(resolved(["en-US", "ko-KR"]) == .english)
    #expect(resolved(["ko-KR", "en-US"]) == .korean)
    #expect(resolved(["ja-JP", "ko-KR"]) == .korean)
    #expect(resolved(["zh-Hans-CN", "en-US"]) == .simplifiedChinese)
    #expect(resolved(["zh-CN", "en-US"]) == .simplifiedChinese)
    #expect(resolved(["zh-SG", "en-US"]) == .simplifiedChinese)
    #expect(resolved(["zh", "en-US"]) == .simplifiedChinese)
    #expect(resolved(["zh-Hant-TW", "ko-KR", "zh-Hans"]) == .korean)
    #expect(resolved(["zh-HK", "zh-TW", "en-US"]) == .english)
    #expect(resolved(["en-US", "zh-Hans"]) == .english)
    #expect(resolved(["ja-JP", "fr-FR"]) == .english)
    #expect(resolved([]) == .english)
    #expect(AppInterfaceLanguage.resolved(from: .korean, preferredLanguages: ["en-US"]) == .korean)
    #expect(AppInterfaceLanguage.resolved(from: .english, preferredLanguages: ["zh-Hans"]) == .english)
    #expect(AppInterfaceLanguage.resolved(from: .simplifiedChinese, preferredLanguages: ["en-US"]) == .simplifiedChinese)
}

@Test func simplifiedChineseCanBeSelectedAndUsesChineseText() throws {
    let encoded = try JSONEncoder().encode(AppLanguagePreference.simplifiedChinese)
    let restoredPreference = try JSONDecoder().decode(AppLanguagePreference.self, from: encoded)
    let language = AppInterfaceLanguage.resolved(from: restoredPreference)

    #expect(language.text("Settings", "설정", "设置") == "设置")
    #expect(language.locale.identifier == "zh_CN")
    #expect(restoredPreference.title(in: .english) == "简体中文")
}
