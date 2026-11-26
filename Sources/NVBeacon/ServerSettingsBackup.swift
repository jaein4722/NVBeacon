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
                language.text("Could not resolve the SSH endpoint for %@. Check the SSH configuration.", name)
            case .requiresProxy(let name, let option):
                language.text("%@ requires %@. The backup format cannot store that route.", name, option)
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
        case .unsupportedFormat: language.text("This is not a supported NVBeacon server backup.")
        case .invalidServer: language.text("The backup contains an invalid SSH target or port.")
        case .invalidServerCount: language.text("A server backup must contain between 1 and 100 servers.")
        case .fileTooLarge: language.text("The server backup is too large (maximum 1 MB).")
        }
    }
}
