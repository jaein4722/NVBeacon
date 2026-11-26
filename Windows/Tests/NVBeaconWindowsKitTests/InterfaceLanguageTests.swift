import Foundation
import NVBeaconCore
import Testing
@testable import NVBeaconWindowsKit

@Test func interfaceTextsComeFromTheSharedFiles() {
    #expect(InterfaceLanguage.translations.languages.map(\.code).contains("ko"))
    #expect(InterfaceLanguage(code: "ko").text("%@ finished", "python") == "python 종료")
    #expect(InterfaceLanguage.english.text("%@ finished", "python") == "python finished")
    #expect(InterfaceLanguage.resolved(from: .korean).code == "ko")
    #expect(InterfaceLanguage.resolved(from: .simplifiedChinese).code == "zh-Hans")
}

/// Every literal key the Windows app and its pages look up must be in en.json.
@Test func everyKeyUsedOnWindowsIsInTheEnglishFile() throws {
    let windows = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let english = try #require(InterfaceLanguage.translations.strings(for: "en"))
    let folders = ["Sources/NVBeacon", "Sources/NVBeacon/UI", "Sources/NVBeaconWindowsKit"].map { windows.appendingPathComponent($0) }
    let swiftCall = try Regex(#"\.text\("((?:[^"\\]|\\.)*)"[,)]"#)
    let scriptCall = try Regex(#"(?:^|[^\w.$])t\("((?:[^"\\]|\\.)*)"[,)]"#)
    var missing: [String] = []
    for folder in folders {
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let call: Regex<AnyRegexOutput>
            switch url.pathExtension {
            case "swift": call = swiftCall
            case "js": call = scriptCall
            default: continue
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            for match in source.matches(of: call) {
                guard let literal = match.output[1].substring.map(String.init) else { continue }
                let key = literal.replacingOccurrences(of: #"\""#, with: "\"").replacingOccurrences(of: #"\n"#, with: "\n")
                if english[key] == nil { missing.append("\(url.lastPathComponent): \(key)") }
            }
        }
    }
    #expect(missing.isEmpty, "Keys missing from Shared/Localization/en.json: \(missing)")
}
