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

        init(_ server: ServerConfig, collectsMemory: Bool) {
            id = server.id
            target = server.sshTarget
            port = server.sshPort
            identityFile = server.sshIdentityFilePath
            authentication = server.sshAuthenticationMode
            connectionReuse = server.sshConnectionReuseMode
            gpuCommand = server.remoteCommand
            memoryCommand = collectsMemory ? server.memoryCommand : ""
        }
    }

    let interval: Int
    let highlightsMyProcesses: Bool
    let hostMetrics: HostMetricsOptions
    let servers: [Server]

    init(_ settings: AppSettings) {
        let hostMetrics = settings.hostMetricsOptions
        interval = settings.pollIntervalSeconds
        highlightsMyProcesses = settings.highlightsMyProcesses
        self.hostMetrics = hostMetrics
        servers = settings.pollableServers.map { Server($0, collectsMemory: hostMetrics.memory) }.sorted { $0.id < $1.id }
    }
}
