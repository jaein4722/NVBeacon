import Foundation

// The shared format is pure data. This adapter alone accesses macOS-scoped files
// and maps archived settings to new local server/credential identities.
extension ServerSettingsBackup {
    init(settings: AppSettings) {
        self.init(servers: settings.normalized().configuredServers.map(Entry.init))
    }

    static func portableExport(settings: AppSettings, configFile: URL? = nil) async throws -> Self {
        let servers = settings.normalized().configuredServers
        try Self(servers: servers.map(Entry.init)).validate()
        var entries: [Entry] = []
        for server in servers {
            let endpoint = try await EffectiveSSHProfile.resolve(server, settings: settings, configFile: configFile)
            if let proxy = endpoint.proxy { throw ExportError.requiresProxy(server.displayName, proxy) }
            var resolved = server
            resolved.name = server.displayName
            resolved.sshTarget = "\(endpoint.user)@\(endpoint.host)"
            resolved.sshPort = String(endpoint.port)
            entries.append(Entry(resolved))
        }
        let backup = Self(servers: entries)
        try backup.validate()
        return backup
    }

    enum ExportError: Error, Equatable {
        case unresolved(String)
        case requiresProxy(String, String)

        func message(in language: AppInterfaceLanguage) -> String {
            switch self {
            case .unresolved(let name):
                language.text("Could not resolve the SSH endpoint for \(name). Check the SSH configuration.",
                              "\(name)의 SSH 주소를 확인할 수 없습니다. SSH 설정을 확인하세요.")
            case .requiresProxy(let name, let option):
                language.text("\(name) requires \(option). The backup format cannot store that route.",
                              "\(name) 연결에는 \(option) 설정이 필요합니다. 이 경유 경로는 백업 형식에 저장할 수 없습니다.")
            }
        }
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

extension ServerSettingsBackup.Entry {
    init(_ server: ServerConfig) {
        self.init(name: server.name, sshTarget: server.sshTarget, sshPort: server.sshPort,
                  sshIdentityFilePath: server.sshIdentityFilePath,
                  sshAuthenticationMode: server.sshAuthenticationMode,
                  sshConnectionReuseMode: server.sshConnectionReuseMode,
                  remoteCommand: server.remoteCommand, memoryCommand: server.memoryCommand, hostCommand: server.hostCommand)
    }

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
            hostCommand: hostCommand,
            isEnabled: false
        ).normalized()
    }
}

extension ServerSettingsBackup.BackupError {
    func message(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .unsupportedFormat: language.text("This is not a supported NVBeacon server backup.", "지원되는 NVBeacon 서버 백업 파일이 아닙니다.")
        case .invalidServer: language.text("The backup contains an invalid SSH target or port.", "백업에 올바르지 않은 SSH 대상 또는 포트가 있습니다.")
        case .invalidServerCount: language.text("A server backup must contain between 1 and 100 servers.", "서버 백업에는 1개 이상 100개 이하의 서버가 있어야 합니다.")
        case .fileTooLarge: language.text("The server backup is too large (maximum 1 MB).", "서버 백업 파일이 너무 큽니다(최대 1MB).")
        }
    }
}
