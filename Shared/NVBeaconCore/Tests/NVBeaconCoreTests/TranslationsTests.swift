import Foundation
import Testing
@testable import NVBeaconCore

private let fixture = Translations(files: [
    "en": .init(name: "English", strings: [
        "Settings": "Settings",
        "%@ finished": "%@ finished",
        "%lld/%lld servers reporting": "%lld/%lld servers reporting",
        "metric::Unavailable": "Unavailable",
        "Only English": "Only English",
    ]),
    "ko": .init(name: "한국어", strings: [
        "Settings": "설정",
        "%@ finished": "%@ 종료",
        "%lld/%lld servers reporting": "활성 서버 %2$lld대 중 %1$lld대 응답",
        "metric::Unavailable": "측정 불가",
    ]),
    "zh-Hans": .init(name: "简体中文", strings: ["Settings": "设置"]),
])

@Test func lookupUsesTheLanguageThenEnglishThenTheKey() {
    #expect(fixture.text("Settings", language: "ko") == "설정")
    #expect(fixture.text("Settings", language: "zh-Hans") == "设置")
    #expect(fixture.text("Only English", language: "ko") == "Only English")
    #expect(fixture.text("Not in any file", language: "ko") == "Not in any file")
    #expect(fixture.text("metric::Unavailable", language: "ko") == "측정 불가")
    #expect(fixture.text("metric::Unavailable", language: "zh-Hans") == "Unavailable")
    #expect(fixture.text("other::Missing", language: "en") == "Missing")
    #expect(fixture.text("Settings", language: "fr") == "Settings")
}

@Test func argumentsFillPlaceholdersInOrderOrByPosition() {
    #expect(fixture.text("%@ finished", language: "ko", arguments: ["train.py"]) == "train.py 종료")
    #expect(fixture.text("%lld/%lld servers reporting", language: "en", arguments: ["2", "3"]) == "2/3 servers reporting")
    #expect(fixture.text("%lld/%lld servers reporting", language: "ko", arguments: ["2", "3"]) == "활성 서버 3대 중 2대 응답")
    #expect(Translations.format("%lld%% utilization", ["40"]) == "40% utilization")
    #expect(Translations.format("0–100% · Default 10%", []) == "0–100% · Default 10%")
    #expect(Translations.format("%@ uses 100%", ["GPU 0"]) == "GPU 0 uses 100%")
    #expect(Translations.format("%@ and %@", ["a"]) == "a and ")
    // An argument is inserted as is, even when it contains a placeholder.
    #expect(Translations.format("Path: %@ (%@)", ["%@", "x"]) == "Path: %@ (x)")
}

@Test func placeholdersAreNumberedLikeFormatArguments() {
    #expect(Translations.placeholders(in: "No arguments, 100%") == [:])
    #expect(Translations.placeholders(in: "%@ of %lld") == [1: "@", 2: "d"])
    #expect(Translations.placeholders(in: "%2$lld중 %1$@") == [1: "@", 2: "d"])
    #expect(Translations.placeholders(in: "%lld%% · %d") == [1: "d", 2: "d"])
}

@Test func languagesListEnglishFirstWithTheirOwnNames() {
    #expect(fixture.languages.map(\.code) == ["en", "ko", "zh-Hans"])
    #expect(fixture.languages.map(\.name) == ["English", "한국어", "简体中文"])
    #expect(Translations.empty.languages.map(\.code) == ["en"])
}

@Test func systemLanguageFollowsTheFirstSupportedPreferredLanguage() {
    func resolved(_ languages: [String]) -> String {
        fixture.resolve(.system, preferredLanguages: languages)
    }
    #expect(resolved(["en-US", "ko-KR"]) == "en")
    #expect(resolved(["ko-KR", "en-US"]) == "ko")
    #expect(resolved(["ko_KR"]) == "ko")
    #expect(resolved(["ja-JP", "ko-KR"]) == "ko")
    #expect(resolved(["zh-Hans-CN", "en-US"]) == "zh-Hans")
    #expect(resolved(["zh-CN", "en-US"]) == "zh-Hans")
    #expect(resolved(["zh-SG", "en-US"]) == "zh-Hans")
    #expect(resolved(["zh", "en-US"]) == "zh-Hans")
    #expect(resolved(["zh-Hant-TW", "ko-KR", "zh-Hans"]) == "ko")
    #expect(resolved(["zh-HK", "zh-TW", "en-US"]) == "en")
    #expect(resolved(["en-US", "zh-Hans"]) == "en")
    #expect(resolved(["ja-JP", "fr-FR"]) == "en")
    #expect(resolved([]) == "en")
}

@Test func explicitLanguagesWinUnlessTheirFileIsMissing() {
    #expect(fixture.resolve(.korean, preferredLanguages: ["en-US"]) == "ko")
    #expect(fixture.resolve(.english, preferredLanguages: ["zh-Hans"]) == "en")
    #expect(fixture.resolve(.simplifiedChinese, preferredLanguages: ["en-US"]) == "zh-Hans")
    #expect(fixture.resolve(.language("ja"), preferredLanguages: ["ko-KR"]) == "ko")
}

@Test func regionalFilesArePreferredOverTheBaseLanguage() {
    let translations = Translations(files: [
        "en": .init(name: "English", strings: [:]),
        "pt": .init(name: "Português", strings: [:]),
        "pt-BR": .init(name: "Português (Brasil)", strings: [:]),
    ])
    #expect(translations.resolve(.system, preferredLanguages: ["pt-BR"]) == "pt-BR")
    #expect(translations.resolve(.system, preferredLanguages: ["pt-PT"]) == "pt")
}

@Test func languagePreferenceKeepsTheNamesOlderVersionsRead() throws {
    let preferences: [LanguagePreference] = [.system, .english, .korean, .simplifiedChinese, .language("ja")]
    let encoded = try String(decoding: JSONEncoder().encode(preferences), as: UTF8.self)
    #expect(encoded == #"["system","english","korean","simplifiedChinese","ja"]"#)
    #expect(try JSONDecoder().decode([LanguagePreference].self, from: Data(encoded.utf8)) == preferences)
    #expect(LanguagePreference(storedValue: "zh-Hans") == .simplifiedChinese)
    #expect(LanguagePreference(storedValue: "") == .system)
}

@Test func resolvedStringsMergeTheLanguageOverEnglish() {
    let strings = fixture.resolvedStrings(for: "zh-Hans")
    #expect(strings["Settings"] == "设置")
    #expect(strings["Only English"] == "Only English")
    #expect(strings["metric::Unavailable"] == "Unavailable")
    #expect(fixture.resolvedStrings(for: "fr") == fixture.strings(for: "en"))
}

@Test func loadingSkipsBrokenFilesAndFindsTheFirstFolderWithEnglish() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-translations-\(UUID().uuidString)")
    let empty = root.appendingPathComponent("empty")
    let full = root.appendingPathComponent("full")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"name": "English", "strings": {"Settings": "Settings"}}"#.utf8).write(to: full.appendingPathComponent("en.json"))
    try Data(#"{"name": "한국어", "strings": {"Settings": "설정"}}"#.utf8).write(to: full.appendingPathComponent("ko.json"))
    try Data("not json".utf8).write(to: full.appendingPathComponent("ja.json"))
    try Data("ignored".utf8).write(to: full.appendingPathComponent("README.md"))

    let translations = Translations.load(fromFirstOf: [empty, full])
    #expect(translations.languages.map(\.code) == ["en", "ko"])
    #expect(translations.text("Settings", language: "ko") == "설정")
    #expect(Translations.load(fromFirstOf: [empty]).languages.map(\.code) == ["en"])
}

// MARK: The shared files in Shared/Localization

private let localizationFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Localization")

private func sharedFiles() throws -> [String: Translations.File] {
    let urls = try FileManager.default.contentsOfDirectory(at: localizationFolder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
    var files: [String: Translations.File] = [:]
    for url in urls {
        files[url.deletingPathExtension().lastPathComponent] = try JSONDecoder().decode(Translations.File.self, from: Data(contentsOf: url))
    }
    return files
}

@Test func sharedFilesHaveEnglishAndTheShippedLanguages() throws {
    let files = try sharedFiles()
    #expect(Set(files.keys).isSuperset(of: ["en", "ko", "zh-Hans"]))
    for (code, file) in files {
        #expect(!file.name.isEmpty, "\(code).json has no name")
        #expect(LanguageTag(code).language.count >= 2, "\(code).json is not named after a language code")
    }
}

@Test func englishFileUsesKeysAsTextExceptForContext() throws {
    let english = try #require(try sharedFiles()["en"]).strings
    for (key, text) in english {
        #expect(text == Translations.englishText(ofKey: key), "en.json: \(key) → \(text)")
    }
}

@Test func translationsOnlyUseEnglishKeysAndTheSamePlaceholders() throws {
    let files = try sharedFiles()
    let english = try #require(files["en"]).strings
    for (code, file) in files where code != Translations.sourceLanguage {
        for (key, text) in file.strings {
            guard let source = english[key] else {
                Issue.record("\(code).json has a key that is not in en.json: \(key)")
                continue
            }
            #expect(!text.isEmpty, "\(code).json: empty text for \(key)")
            #expect(Translations.placeholders(in: text) == Translations.placeholders(in: source),
                    "\(code).json: placeholders differ for \(key) → \(text)")
        }
    }
}
