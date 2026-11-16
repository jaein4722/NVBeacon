import Foundation

/// A concrete `Host` entry from the user's OpenSSH config, offered as a saved host in Settings.
public struct SSHConfigHost: Codable, Equatable, Sendable {
    public let alias: String
    public var hostName: String?
    public var user: String?
    public var port: String?
    public var identityFile: String?
}

/// Reads %USERPROFILE%\.ssh\config, the file Win32-OpenSSH uses. Only literal
/// aliases are listed; wildcard and negated patterns are skipped, and `Include`
/// is not followed (the macOS loader behaves the same way for listing).
public enum SSHConfigHosts {
    public static var configFile: URL {
        let home = ProcessInfo.processInfo.environment["USERPROFILE"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home).appendingPathComponent(".ssh").appendingPathComponent("config")
    }

    public static func load(from url: URL = configFile) -> [SSHConfigHost] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    public static func parse(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: [Int] = []   // indexes of hosts the current block applies to
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let (key, value) = split(line)
            switch key.lowercased() {
            case "host":
                current = []
                for alias in value.split(whereSeparator: \.isWhitespace).map(String.init)
                where !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!") {
                    if let existing = hosts.firstIndex(where: { $0.alias == alias }) {
                        current.append(existing)
                    } else {
                        hosts.append(SSHConfigHost(alias: alias))
                        current.append(hosts.count - 1)
                    }
                }
            case "match":
                current = []
            case "hostname":
                for index in current where hosts[index].hostName == nil { hosts[index].hostName = value }
            case "user":
                for index in current where hosts[index].user == nil { hosts[index].user = value }
            case "port":
                for index in current where hosts[index].port == nil { hosts[index].port = value }
            case "identityfile":
                for index in current where hosts[index].identityFile == nil { hosts[index].identityFile = value }
            default:
                break
            }
        }
        return hosts
    }

    private static func split(_ line: String) -> (String, String) {
        // "Key value", "Key=value" or "Key = value"; values may be quoted.
        guard let separator = line.firstIndex(where: { $0 == "=" || $0.isWhitespace }) else { return (line, "") }
        let key = String(line[..<separator])
        var value = line[separator...].drop { $0 == "=" || $0.isWhitespace }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = value.dropFirst().dropLast() }
        return (key, String(value))
    }
}
