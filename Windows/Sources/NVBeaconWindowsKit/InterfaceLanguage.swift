import Foundation
import NVBeaconCore
import WinSDK

/// The language the app is shown in, with its texts from the shared translation files
/// (`Shared/Localization`). The pages get the same table from `WebViewHost`.
public struct InterfaceLanguage: Equatable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }

    public static let english = InterfaceLanguage(code: Translations.sourceLanguage)

    /// Read once: the Localization folder next to NVBeacon.exe, or the source tree in
    /// development builds and tests.
    public static let translations = Translations.load(fromFirstOf: [
        executableFolder.appendingPathComponent("Localization"),
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Shared/Localization"),
    ])

    /// The setting, or the Windows display language for System.
    public static func resolved(from preference: LanguagePreference) -> InterfaceLanguage {
        InterfaceLanguage(code: translations.resolve(preference, preferredLanguages: systemLanguages))
    }

    /// The text for a key of the shared files; arguments fill its `%@` placeholders.
    public func text(_ key: String, _ arguments: Any...) -> String {
        Self.translations.text(key, language: code, arguments: arguments.map { String(describing: $0) })
    }

    /// The Windows display language as a locale name, such as "ko-KR" or "zh-CN".
    static var systemLanguages: [String] {
        var buffer = [WCHAR](repeating: 0, count: Int(LOCALE_NAME_MAX_LENGTH))
        let length = LCIDToLocaleName(LCID(GetUserDefaultUILanguage()), &buffer, Int32(buffer.count), 0)
        guard length > 1 else { return [] }
        return [String(decoding: buffer[0..<Int(length - 1)], as: UTF16.self)]
    }

    private static var executableFolder: URL {
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        return URL(fileURLWithPath: String(decoding: buffer[0..<Int(length)], as: UTF16.self)).deletingLastPathComponent()
    }
}
