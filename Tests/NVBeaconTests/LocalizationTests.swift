import Foundation
import Testing
@testable import NVBeacon
import NVBeaconCore

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

    #expect(language.text("Settings") == "设置")
    #expect(language.locale.identifier == "zh_CN")
    #expect(restoredPreference.title(in: .english) == "简体中文")
}

@Test func languagePickerListsSystemAndEveryLanguageFile() {
    let choices = AppLanguagePreference.choices
    #expect(choices.first == .system)
    #expect(choices.contains(.english) && choices.contains(.korean) && choices.contains(.simplifiedChinese))
    #expect(AppLanguagePreference.korean.title(in: .english) == "한국어")
    #expect(AppLanguagePreference.system.title(in: .korean) == "시스템")
}

@Test func lookupsFillArgumentsAndFallBackToEnglish() {
    #expect(AppInterfaceLanguage.korean.text("My processes: %@", "alice") == "내 프로세스: alice")
    #expect(AppInterfaceLanguage.english.text("My processes: %@", "alice") == "My processes: alice")
    #expect(AppInterfaceLanguage(code: "fr").text("Settings") == "Settings")
    #expect(AppInterfaceLanguage.korean.text("measurement::Unavailable") == "측정 불가")
    #expect(AppInterfaceLanguage.korean.text("Unavailable") == "사용 불가")
}

/// Every literal key the app looks up must be in en.json; a typo would show the key.
@Test func everyKeyUsedByTheAppIsInTheEnglishFile() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let english = try #require(AppInterfaceLanguage.translations.strings(for: "en"))
    let sources = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources/NVBeacon"), includingPropertiesForKeys: nil)
    let call = try Regex(#"(?:^|[^\w.])t\("((?:[^"\\]|\\.)*)"|\.text\("((?:[^"\\]|\\.)*)""#)
    var missing: [String] = []
    for url in sources where url.pathExtension == "swift" {
        let source = try String(contentsOf: url, encoding: .utf8)
        for match in source.matches(of: call) {
            guard let literal = (match.output[1].substring ?? match.output[2].substring).map(String.init) else { continue }
            let key = literal.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\n"#, with: "\n")
                .replacingOccurrences(of: #"\\"#, with: "\\")
            // A context prefix such as "error::" completed at run time.
            if key.hasSuffix(Translations.contextSeparator) { continue }
            if english[key] == nil { missing.append("\(url.lastPathComponent): \(key)") }
        }
    }
    #expect(missing.isEmpty, "Keys missing from Shared/Localization/en.json: \(missing)")
}
