import Testing
@testable import NVBeacon

@Test func systemLanguageFollowsTheFirstSupportedPreferredLanguage() {
    func resolved(_ languages: [String]) -> AppInterfaceLanguage {
        AppInterfaceLanguage.resolved(from: .system, preferredLanguages: languages)
    }
    #expect(resolved(["en-US", "ko-KR"]) == .english)
    #expect(resolved(["ko-KR", "en-US"]) == .korean)
    #expect(resolved(["ja-JP", "ko-KR"]) == .korean)
    #expect(resolved(["ja-JP", "fr-FR"]) == .english)
    #expect(resolved([]) == .english)
    #expect(AppInterfaceLanguage.resolved(from: .korean, preferredLanguages: ["en-US"]) == .korean)
}
