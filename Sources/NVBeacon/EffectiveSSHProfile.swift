import Foundation

/// Evaluated on explicit export/transfer only. Keep aliases live for monitoring.
struct EffectiveSSHProfile {
    let host: String
    let user: String
    let port: Int
    let proxy: String?
    let identityFiles: [String]

    static func resolve(_ server: ServerConfig, settings: AppSettings, configFile: URL? = nil) async throws -> Self {
        try ServerSettingsBackup(servers: [.init(server)]).validate()
        var args = ["-G"]
        if let configFile { args += ["-F", configFile.path] }
        let connection = server.connectionSettings(from: settings)
        args += SSHMetricsFetcher.buildSSHArguments(
            settings: connection,
            prefersPasswordAuth: server.sshAuthenticationMode == .passwordBased,
            remoteCommand: RemoteMetricCommands.summary(summaryCommand: server.remoteCommand,
                hostMetrics: connection.hostMetricsOptions, hostCommand: server.hostCommand)
        )
        let output = try await ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: args, timeout: 5, outputLimit: 1_048_576)
        guard output.exitStatus == 0 else { throw ServerSettingsBackup.ExportError.unresolved(server.displayName) }
        var fields: [String: String] = [:]
        var identityFiles: [String] = []
        for line in output.standardOutput.split(whereSeparator: \.isNewline) {
            let pair = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard pair.count == 2 else { continue }
            let value = String(pair[1])
            if pair[0] == "identityfile" { identityFiles.append(value) }
            else { fields[String(pair[0])] = value }
        }
        let invalid = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "@"))
        guard let user = fields["user"], !user.isEmpty, !user.unicodeScalars.contains(where: invalid.contains),
              let host = fields["hostname"], !host.isEmpty, !host.unicodeScalars.contains(where: invalid.contains),
              let port = fields["port"].flatMap(Int.init), (1...65535).contains(port)
        else { throw ServerSettingsBackup.ExportError.unresolved(server.displayName) }
        let proxy = ["proxyjump", "proxycommand"].first { fields[$0].map { $0.lowercased() != "none" } ?? false }
        return Self(host: host, user: user, port: port, proxy: proxy, identityFiles: identityFiles)
    }
}
