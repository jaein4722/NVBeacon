import Foundation

struct SSHConfigHost: Identifiable, Equatable {
    let alias: String
    let hostName: String?
    let user: String?
    let port: String?
    let identityFilePath: String?

    var id: String { alias }

    var displayName: String {
        if let hostName, !hostName.isEmpty {
            return "\(alias) (\(hostName))"
        }

        return alias
    }

    func detailSummary(in language: AppInterfaceLanguage) -> String {
        var parts = [String]()

        if let user, !user.isEmpty {
            parts.append(language.text("User \(user)", "사용자 \(user)"))
        }

        if let hostName, !hostName.isEmpty {
            parts.append(language.text("Host \(hostName)", "호스트 \(hostName)"))
        }

        if let port, !port.isEmpty {
            parts.append("Port \(port)")
        }

        if let identityFilePath, !identityFilePath.isEmpty {
            parts.append(language.text("Identity \(identityFilePath)", "Identity \(identityFilePath)"))
        }

        return parts.joined(separator: " · ")
    }

    func apply(to settings: AppSettings) -> AppSettings {
        var copy = settings
        copy.sshTarget = alias
        copy.sshPort = port ?? ""
        copy.sshIdentityFilePath = identityFilePath ?? ""
        return copy.normalized()
    }

    func backfillingMissingFields(in settings: AppSettings) -> AppSettings {
        var copy = settings

        if copy.sshPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.sshPort = port ?? ""
        }

        if copy.sshIdentityFilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.sshIdentityFilePath = identityFilePath ?? ""
        }

        return copy.normalized()
    }
}

enum SSHConfigLoader {
    static func loadHosts() -> [SSHConfigHost] {
        let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            return []
        }

        return parse(contents)
    }

    static func parse(_ contents: String) -> [SSHConfigHost] {
        struct PendingHost {
            var aliases = [String]()
            var hostName: String?
            var user: String?
            var port: String?
            var identityFilePath: String?
        }

        var pending = PendingHost()
        var hosts = [SSHConfigHost]()

        func flushPending() {
            guard !pending.aliases.isEmpty else { return }

            for alias in pending.aliases {
                hosts.append(
                    SSHConfigHost(
                        alias: alias,
                        hostName: pending.hostName,
                        user: pending.user,
                        port: pending.port,
                        identityFilePath: pending.identityFilePath
                    )
                )
            }

            pending = PendingHost()
        }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = String(rawLine)

            if let commentIndex = line.firstIndex(of: "#") {
                line = String(line[..<commentIndex])
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            guard let key = parts.first?.lowercased() else { continue }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

            switch key {
            case "host":
                flushPending()
                pending.aliases = value
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .filter { !$0.contains("*") && !$0.contains("?") && !$0.contains("!") }
            case "hostname":
                pending.hostName = value
            case "user":
                pending.user = value
            case "port":
                pending.port = value
            case "identityfile":
                pending.identityFilePath = NSString(string: value).expandingTildeInPath
            default:
                continue
            }
        }

        flushPending()
        return hosts.sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }
}
