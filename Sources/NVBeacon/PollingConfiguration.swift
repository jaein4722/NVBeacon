import Foundation

/// Only values that change remote collection belong here. Appearance, server
/// names/order, busy indicators and alert thresholds do not restart collection.
struct PollingConfiguration: Equatable, Sendable {
    struct Server: Equatable, Sendable {
        let id: String
        let target: String
        let port: String
        let identityFile: String
        let authentication: SSHAuthenticationMode
        let connectionReuse: SSHConnectionReuseMode
        let gpuCommand: String
        let memoryCommand: String

        init(_ server: ServerConfig) {
            id = server.id
            target = server.sshTarget
            port = server.sshPort
            identityFile = server.sshIdentityFilePath
            authentication = server.sshAuthenticationMode
            connectionReuse = server.sshConnectionReuseMode
            gpuCommand = server.remoteCommand
            memoryCommand = server.memoryCommand
        }
    }

    let interval: Int
    let highlightsMyProcesses: Bool
    let showsNetworkUsage: Bool
    let servers: [Server]

    init(_ settings: AppSettings) {
        interval = settings.pollIntervalSeconds
        highlightsMyProcesses = settings.highlightsMyProcesses
        showsNetworkUsage = settings.showsNetworkUsage
        servers = settings.pollableServers.map(Server.init).sorted { $0.id < $1.id }
    }
}
