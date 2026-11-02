import Foundation

/// A deliberately narrow export format: no Keychain values, IDs, notification
/// watches, process data or application-private defaults are serialized.
public struct ServerSettingsBackup: Codable, Equatable, Sendable {
    public static let formatName = "NVBeacon.servers"
    public static let currentVersion = 1
    public static let maximumFileBytes = 1_048_576
    public static let maximumServers = 100

    public struct Entry: Codable, Equatable, Sendable {
        public let name: String
        public let sshTarget: String
        public let sshPort: String
        public let sshIdentityFilePath: String
        public let sshAuthenticationMode: SSHAuthenticationMode
        public let sshConnectionReuseMode: SSHConnectionReuseMode
        public let remoteCommand: String
        public let memoryCommand: String

        public init(name: String, sshTarget: String, sshPort: String,
                    sshIdentityFilePath: String, sshAuthenticationMode: SSHAuthenticationMode,
                    sshConnectionReuseMode: SSHConnectionReuseMode,
                    remoteCommand: String, memoryCommand: String) {
            self.name = name
            self.sshTarget = sshTarget
            self.sshPort = sshPort
            self.sshIdentityFilePath = sshIdentityFilePath
            self.sshAuthenticationMode = sshAuthenticationMode
            self.sshConnectionReuseMode = sshConnectionReuseMode
            self.remoteCommand = remoteCommand
            self.memoryCommand = memoryCommand
        }

        public var displayName: String { name.isEmpty ? sshTarget : name }

    }

    public enum BackupError: LocalizedError, Equatable {
        case unsupportedFormat
        case invalidServer
        case invalidServerCount
        case fileTooLarge

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat: "This is not a supported NVBeacon server backup."
            case .invalidServer: "The backup contains an invalid SSH target or port."
            case .invalidServerCount: "A server backup must contain between 1 and 100 servers."
            case .fileTooLarge: "The server backup is too large (maximum 1 MB)."
            }
        }
    }

    public let format: String
    public let version: Int
    public let servers: [Entry]

    public init(servers: [Entry]) {
        format = Self.formatName
        version = Self.currentVersion
        self.servers = servers
    }

    public func validate() throws {
        guard format == Self.formatName, version == Self.currentVersion else {
            throw BackupError.unsupportedFormat
        }
        guard (1...Self.maximumServers).contains(servers.count) else { throw BackupError.invalidServerCount }
        for entry in servers {
            let target = entry.sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, !target.hasPrefix("-"),
                  !target.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
            else { throw BackupError.invalidServer }
            if !entry.sshPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let port = Int(entry.sshPort.trimmingCharacters(in: .whitespacesAndNewlines)),
                      (1...65535).contains(port) else { throw BackupError.invalidServer }
            }
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumFileBytes else { throw BackupError.fileTooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileBytes else { throw BackupError.fileTooLarge }
        let backup: Self
        do {
            backup = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw BackupError.unsupportedFormat
        }
        try backup.validate()
        return backup
    }

}
