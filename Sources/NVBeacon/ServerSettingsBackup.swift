import Foundation

/// A deliberately narrow export format: no Keychain values, IDs, notification
/// watches, process data or application-private defaults are serialized.
struct ServerSettingsBackup: Codable, Equatable, Sendable {
    static let formatName = "NVBeacon.servers"
    static let currentVersion = 1
    static let maximumFileBytes = 1_048_576
    static let maximumServers = 100

    struct Entry: Codable, Equatable, Sendable {
        let name: String
        let sshTarget: String
        let sshPort: String
        let sshIdentityFilePath: String
        let sshAuthenticationMode: SSHAuthenticationMode
        let sshConnectionReuseMode: SSHConnectionReuseMode
        let remoteCommand: String
        let memoryCommand: String

        init(_ server: ServerConfig) {
            name = server.name
            sshTarget = server.sshTarget
            sshPort = server.sshPort
            sshIdentityFilePath = server.sshIdentityFilePath
            sshAuthenticationMode = server.sshAuthenticationMode
            sshConnectionReuseMode = server.sshConnectionReuseMode
            remoteCommand = server.remoteCommand
            memoryCommand = server.memoryCommand
        }

        var displayName: String { name.isEmpty ? sshTarget : name }

        func makeServer() -> ServerConfig {
            // Fresh IDs keep imports separate from existing credentials/watches.
            // Review/import alone must never start executing imported commands.
            ServerConfig(
                name: name,
                sshTarget: sshTarget,
                sshPort: sshPort,
                sshIdentityFilePath: sshIdentityFilePath,
                sshAuthenticationMode: sshAuthenticationMode,
                sshConnectionReuseMode: sshConnectionReuseMode,
                remoteCommand: remoteCommand,
                memoryCommand: memoryCommand,
                isEnabled: false
            ).normalized()
        }
    }

    enum BackupError: LocalizedError, Equatable {
        case unsupportedFormat
        case invalidServer
        case invalidServerCount
        case fileTooLarge

        var errorDescription: String? {
            let language = AppLocalizer.currentLanguage()
            switch self {
            case .unsupportedFormat:
                return language.text("This is not a supported NVBeacon server backup.", "지원되는 NVBeacon 서버 백업 파일이 아닙니다.")
            case .invalidServer:
                return language.text("The backup contains an invalid SSH target or port.", "백업에 올바르지 않은 SSH 대상 또는 포트가 있습니다.")
            case .invalidServerCount:
                return language.text("A server backup must contain between 1 and 100 servers.", "서버 백업에는 1개 이상 100개 이하의 서버가 있어야 합니다.")
            case .fileTooLarge:
                return language.text("The server backup is too large (maximum 1 MB).", "서버 백업 파일이 너무 큽니다(최대 1MB).")
            }
        }
    }

    let format: String
    let version: Int
    let servers: [Entry]

    init(settings: AppSettings) {
        format = Self.formatName
        version = Self.currentVersion
        servers = settings.normalized().configuredServers.map(Entry.init)
    }

    private func validate() throws {
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

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumFileBytes else { throw BackupError.fileTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
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

    static func read(from url: URL) throws -> Self {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileBytes else { throw BackupError.fileTooLarge }
        return try decode(Data(contentsOf: url))
    }

    func addingServers(to settings: AppSettings) throws -> AppSettings {
        try validate()
        var result = settings.normalized()
        result.servers.append(contentsOf: servers.map { $0.makeServer() })
        return result.normalized()
    }
}
