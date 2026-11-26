import Foundation

/// The interface language a user picked: follow the system, or one language file.
///
/// Stored as one string. The three languages that existed before the shared files
/// keep their old names ("english", "korean", "simplifiedChinese") so settings saved
/// by this version still load in older versions; any other language is stored as its
/// file's language code ("ja", "pt-BR").
public enum LanguagePreference: Hashable, Codable, Sendable {
    case system
    case language(String)

    public static let english = LanguagePreference.language("en")
    public static let korean = LanguagePreference.language("ko")
    public static let simplifiedChinese = LanguagePreference.language("zh-Hans")

    private static let legacyNames = ["en": "english", "ko": "korean", "zh-Hans": "simplifiedChinese"]

    /// The stored form, also used as the value of the Windows settings picker.
    public var storedValue: String {
        switch self {
        case .system: "system"
        case .language(let code): Self.legacyNames[code] ?? code
        }
    }

    public init(storedValue: String) {
        if storedValue == "system" || storedValue.isEmpty {
            self = .system
        } else if let code = Self.legacyNames.first(where: { $0.value == storedValue })?.key {
            self = .language(code)
        } else {
            self = .language(storedValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(storedValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedValue)
    }
}

/// The shared interface strings: one JSON file per language in `Shared/Localization`,
/// read once at startup by each client.
///
/// A file is `{"name": "<language name in that language>", "strings": {key: text}}`
/// and its file name is the language code (`ko.json`, `zh-Hans.json`). Keys are the
/// English text; a key that needs context to tell two meanings apart has the form
/// `context::English text`. `en.json` lists every key and is the fallback for any key
/// a translation lacks.
///
/// Texts with arguments use `%@` (or `%lld` for integers, as in iOS string files),
/// `%1$@` to reorder arguments, and `%%` for a literal percent sign. Texts without
/// arguments are shown as written.
public struct Translations: Sendable {
    public static let sourceLanguage = "en"
    public static let contextSeparator = "::"

    public struct Language: Hashable, Identifiable, Sendable {
        /// The language code, which is also the file name.
        public let code: String
        /// The language's own name for itself, shown in language pickers.
        public let name: String
        public var id: String { code }
    }

    public struct File: Codable, Equatable, Sendable {
        public var name: String
        public var strings: [String: String]

        public init(name: String, strings: [String: String]) {
            self.name = name
            self.strings = strings
        }
    }

    /// English first, then the other languages by code.
    public let languages: [Language]
    private let tables: [String: [String: String]]

    public init(files: [String: File]) {
        var files = files
        if files[Self.sourceLanguage] == nil {
            files[Self.sourceLanguage] = File(name: "English", strings: [:])
        }
        tables = files.mapValues(\.strings)
        languages = files
            .map { Language(code: $0.key, name: $0.value.name) }
            .sorted { lhs, rhs in
                if lhs.code == Self.sourceLanguage { return rhs.code != Self.sourceLanguage }
                if rhs.code == Self.sourceLanguage { return false }
                return lhs.code < rhs.code
            }
    }

    public static let empty = Translations(files: [:])

    /// Reads every `<code>.json` in the folder. Unreadable files are skipped, so a
    /// broken translation never stops the app; English text is used instead.
    public static func load(from directory: URL) -> Translations {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var files: [String: File] = [:]
        for url in urls where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let file = try? JSONDecoder().decode(File.self, from: data)
            else { continue }
            files[url.deletingPathExtension().lastPathComponent] = file
        }
        return Translations(files: files)
    }

    /// The first of the folders that holds `en.json`, loaded; empty when none does.
    public static func load(fromFirstOf directories: [URL]) -> Translations {
        for directory in directories
        where FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(sourceLanguage).json").path) {
            return load(from: directory)
        }
        return .empty
    }

    public func strings(for code: String) -> [String: String]? { tables[code] }

    public func language(_ code: String) -> Language? { languages.first { $0.code == code } }

    // MARK: Lookup

    /// The text for `key` in the language, falling back to English and then to the key
    /// itself (without any context prefix).
    public func text(_ key: String, language code: String, arguments: [String] = []) -> String {
        let template = tables[code]?[key] ?? tables[Self.sourceLanguage]?[key] ?? Self.englishText(ofKey: key)
        return Self.format(template, arguments)
    }

    /// The table a client hands to code that cannot read the files itself (the Windows
    /// WebView pages): every English key with the language's text, or English.
    public func resolvedStrings(for code: String) -> [String: String] {
        var result = tables[Self.sourceLanguage] ?? [:]
        if code != Self.sourceLanguage, let table = tables[code] {
            result.merge(table) { _, translated in translated }
        }
        return result
    }

    /// `"metric::Unavailable"` → `"Unavailable"`.
    public static func englishText(ofKey key: String) -> String {
        guard let range = key.range(of: contextSeparator) else { return key }
        return String(key[range.upperBound...])
    }

    // MARK: Language resolution

    /// The language to show for a preference. An explicit language without a file falls
    /// back to the system languages; with no supported system language, English.
    public func resolve(_ preference: LanguagePreference, preferredLanguages: [String]) -> String {
        if case .language(let code) = preference, tables[code] != nil {
            return code
        }
        for identifier in preferredLanguages {
            if let code = bestMatch(for: identifier) { return code }
        }
        return Self.sourceLanguage
    }

    /// The most specific available language that `identifier` (a system language such
    /// as `zh-Hans-CN`, `zh-TW` or `ko_KR`) belongs to.
    func bestMatch(for identifier: String) -> String? {
        let wanted = LanguageTag(identifier)
        var best: (code: String, specificity: Int)?
        for language in languages {
            let tag = LanguageTag(language.code)
            guard tag.isMatched(by: wanted) else { continue }
            if best == nil || tag.specificity > best!.specificity {
                best = (language.code, tag.specificity)
            }
        }
        return best?.code
    }

    // MARK: Formatting

    /// Fills `%@`, `%d`, `%ld`, `%lld` and positional `%1$@` with the arguments, and
    /// turns `%%` into `%`. A text without arguments is returned as written.
    public static func format(_ template: String, _ arguments: [String]) -> String {
        guard !arguments.isEmpty, template.contains("%") else { return template }
        var output = ""
        var nextIndex = 0
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            guard character == "%" else {
                output.append(character)
                index = template.index(after: index)
                continue
            }
            if let placeholder = Placeholder(in: template, at: index) {
                let argumentIndex = placeholder.position.map { $0 - 1 } ?? nextIndex
                if placeholder.position == nil { nextIndex += 1 }
                output += arguments.indices.contains(argumentIndex) ? arguments[argumentIndex] : ""
                index = placeholder.end
            } else if template.index(after: index) < template.endIndex, template[template.index(after: index)] == "%" {
                output.append("%")
                index = template.index(index, offsetBy: 2)
            } else {
                output.append("%")
                index = template.index(after: index)
            }
        }
        return output
    }

    /// The placeholders of a text as `argument number → kind` (`"@"` or `"d"`), used to
    /// check that a translation takes the same arguments as English.
    public static func placeholders(in template: String) -> [Int: String] {
        var result: [Int: String] = [:]
        var nextNumber = 1
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "%" {
                if let placeholder = Placeholder(in: template, at: index) {
                    let number = placeholder.position ?? nextNumber
                    if placeholder.position == nil { nextNumber += 1 }
                    result[number] = placeholder.kind
                    index = placeholder.end
                    continue
                }
                let next = template.index(after: index)
                if next < template.endIndex, template[next] == "%" {
                    index = template.index(after: next)
                    continue
                }
            }
            index = template.index(after: index)
        }
        return result
    }

    private struct Placeholder {
        let position: Int?
        let kind: String
        let end: String.Index

        init?(in text: String, at start: String.Index) {
            var index = text.index(after: start)
            var digits = ""
            while index < text.endIndex, let digit = text[index].wholeNumberValue, text[index].isASCII {
                digits.append(String(digit))
                index = text.index(after: index)
            }
            var position: Int?
            if !digits.isEmpty {
                guard index < text.endIndex, text[index] == "$", let number = Int(digits), number > 0 else { return nil }
                position = number
                index = text.index(after: index)
            }
            let rest = text[index...]
            for (specifier, kind) in [("@", "@"), ("lld", "d"), ("ld", "d"), ("d", "d")] where rest.hasPrefix(specifier) {
                self.position = position
                self.kind = kind
                self.end = text.index(index, offsetBy: specifier.count)
                return
            }
            return nil
        }
    }
}

/// The parts of a BCP 47 language tag the language picker cares about.
struct LanguageTag {
    let language: String
    let script: String?
    let region: String?

    init(_ identifier: String) {
        let parts = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        language = parts.first?.lowercased() ?? ""
        var script: String?
        var region: String?
        for part in parts.dropFirst() {
            let letters = part.allSatisfy(\.isLetter)
            let digits = part.allSatisfy(\.isNumber)
            if part.count == 4, letters, script == nil, region == nil {
                script = part.prefix(1).uppercased() + part.dropFirst().lowercased()
            } else if region == nil, (part.count == 2 && letters) || (part.count == 3 && digits) {
                region = part.uppercased()
            }
        }
        // Chinese without a script: Traditional in Taiwan, Hong Kong and Macau, else Simplified.
        if language == "zh", script == nil {
            script = ["TW", "HK", "MO"].contains(region ?? "") ? "Hant" : "Hans"
        }
        self.script = script
        self.region = region
    }

    var specificity: Int { (script == nil ? 0 : 1) + (region == nil ? 0 : 1) }

    /// Whether a system language belongs to this (available) language: same language,
    /// and the same script and region where this tag names one.
    func isMatched(by wanted: LanguageTag) -> Bool {
        guard language == wanted.language else { return false }
        if let script, script != wanted.script { return false }
        if let region, region != wanted.region { return false }
        return true
    }
}
