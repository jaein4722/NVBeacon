import Foundation

/// The server list, until a settings window exists: command-line targets, or one
/// SSH target per line in `%APPDATA%\NVBeacon\servers.txt` (`#` starts a comment).
public struct LaunchOptions: Equatable, Sendable {
    public var targets: [String]
    public var interval: Duration
    public var once: Bool

    public static let defaultInterval: Duration = .seconds(10)

    public init(targets: [String] = [], interval: Duration = defaultInterval, once: Bool = false) {
        self.targets = targets
        self.interval = interval
        self.once = once
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case invalidInterval(String)
        case invalidTarget(String)

        public var description: String {
            switch self {
            case .invalidInterval(let value): "--interval takes 1-300 seconds, got \(value)"
            case .invalidTarget(let value): "Invalid SSH target: \(value)"
            }
        }
    }

    /// `[--interval SECONDS] [--once] [TARGET ...]`
    public static func parse(_ arguments: [String]) throws -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--interval":
                let value = index + 1 < arguments.count ? arguments[index + 1] : ""
                guard let seconds = Int(value), (1...300).contains(seconds) else { throw ParseError.invalidInterval(value) }
                options.interval = .seconds(seconds)
                index += 1
            case "--once":
                options.once = true
            default:
                guard SSHTransport.isValidTarget(argument) else { throw ParseError.invalidTarget(argument) }
                options.targets.append(argument)
            }
            index += 1
        }
        return options
    }

    public static var serverFile: URL {
        let appData = ProcessInfo.processInfo.environment["APPDATA"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Roaming").path
        return URL(fileURLWithPath: appData).appendingPathComponent("NVBeacon").appendingPathComponent("servers.txt")
    }

    public static func targets(fromServerFile contents: String) -> [String] {
        contents.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let target = text.trimmingCharacters(in: .whitespaces)
            return SSHTransport.isValidTarget(target) ? target : nil
        }
    }

    /// Creates the file with instructions if it does not exist yet.
    public static func loadServerFile() -> [String] {
        let url = serverFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let template = """
            # NVBeacon servers: one SSH target per line, for example
            #   gpu-box           (a Host alias from %USERPROFILE%\\.ssh\\config)
            #   alice@gpu.example.com
            # Key or ssh-agent authentication only. Connect once from a terminal
            # first so the host key is in known_hosts.

            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
        return (try? String(contentsOf: url, encoding: .utf8)).map(targets(fromServerFile:)) ?? []
    }
}
