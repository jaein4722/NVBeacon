import Foundation
import NVBeaconCore

/// Keeps SSH connections open between polls ("Reuse connection", the macOS default).
///
/// macOS shares one `ControlMaster` connection for everything; Windows ssh cannot,
/// so each server gets up to two long-lived connections, each running one command
/// at a time:
/// - `.polling`: the summary poll and the uid lookup.
/// - `.details`: GPU History's pmon sample (which runs alongside the summary),
///   process details and process-exit checks, so they never wait for a poll.
///
/// A connection that drops is reopened by the next command. If it drops while a
/// command is running on a connection that already worked, the command is retried
/// once on a new connection (the server may have closed an idle connection).
public final class SSHConnectionPool: @unchecked Sendable {
    public enum Lane: Sendable, Hashable { case polling, details }

    private struct Key: Hashable {
        let serverID: String
        let lane: Lane
    }

    public let sshExecutable: String
    public let timeout: Duration
    /// Connections unused for this long are closed before the next command.
    public let idleLimit: Duration
    private let lock = NSLock()
    private var sessions: [Key: PersistentSSHSession] = [:]
    private var isClosed = false

    public init(sshExecutable: String = SSHTransport.defaultSSHExecutable, timeout: Duration = .seconds(15),
                idleLimit: Duration = .seconds(300)) {
        self.sshExecutable = sshExecutable
        self.timeout = timeout
        self.idleLimit = idleLimit
    }

    public func transport(target: String, port: Int?, identityFile: String?, authentication: SSHAuthentication,
                          serverID: String, lane: Lane) -> PooledSSHTransport {
        PooledSSHTransport(pool: self, serverID: serverID, lane: lane, target: target, port: port,
                           identityFile: identityFile, authentication: authentication)
    }

    func execute(_ command: String, transport: PooledSSHTransport) async throws -> RemoteCommandOutput {
        guard SSHTransport.isValidTarget(transport.target) else { throw SSHTransportError.invalidTarget(transport.target) }
        guard FileManager.default.fileExists(atPath: sshExecutable) else { throw SSHTransportError.sshNotFound(sshExecutable) }
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { [self] in
                continuation.resume(with: Result { try executeBlocking(command, transport: transport) })
            }
        }
    }

    private func executeBlocking(_ command: String, transport: PooledSSHTransport) throws -> RemoteCommandOutput {
        let key = Key(serverID: transport.serverID, lane: transport.lane)
        for attempt in 0..<2 {
            let session = try session(for: key, transport: transport)
            switch try session.execute(command, timeout: timeout) {
            case .completed(let output):
                return output
            case .connectionLost(let wasUsed, let output):
                discard(session, for: key)
                if wasUsed, attempt == 0 { continue }
                return output
            case .timedOut:
                discard(session, for: key)
                throw SSHTransportError.timedOut(Int(timeout.components.seconds))
            case .outputLimitExceeded:
                discard(session, for: key)
                throw SSHTransportError.outputLimitExceeded(8 * 1024 * 1024)
            }
        }
        throw SSHTransportError.timedOut(Int(timeout.components.seconds))
    }

    private func session(for key: Key, transport: PooledSSHTransport) throws -> PersistentSSHSession {
        var stale: [PersistentSSHSession] = []
        defer { stale.forEach { $0.close() } }
        return try lock.withLock {
            guard !isClosed else { throw CancellationError() }
            for (otherKey, other) in sessions where other.idleTime > idleLimit || !other.isUsable {
                stale.append(other)
                sessions[otherKey] = nil
            }
            let arguments = SSHTransport.sessionArguments(target: transport.target, port: transport.port,
                                                          identityFile: transport.identityFile,
                                                          authentication: transport.authentication)
            let environment = transport.authentication.environment
            if let existing = sessions[key] {
                // The pool outlives settings edits: a server that now connects differently gets a new connection.
                if existing.arguments == arguments, existing.environment == environment { return existing }
                stale.append(existing)
            }
            let session = PersistentSSHSession(executable: sshExecutable, arguments: arguments, environment: environment)
            sessions[key] = session
            return session
        }
    }

    private func discard(_ session: PersistentSSHSession, for key: Key) {
        lock.withLock { if sessions[key] === session { sessions[key] = nil } }
        session.close()
    }

    /// Closes a server's connections, e.g. after its password changed.
    public func close(serverID: String) {
        let closing = lock.withLock { () -> [PersistentSSHSession] in
            let keys = sessions.keys.filter { $0.serverID == serverID }
            defer { keys.forEach { sessions[$0] = nil } }
            return keys.compactMap { sessions[$0] }
        }
        closing.forEach { $0.close() }
    }

    /// Closes every connection; later commands fail. Used when polling stops.
    public func closeAll() {
        let closing = lock.withLock { () -> [PersistentSSHSession] in
            isClosed = true
            defer { sessions = [:] }
            return Array(sessions.values)
        }
        closing.forEach { $0.close() }
    }

    public var openConnectionCount: Int { lock.withLock { sessions.count } }
}

/// One server's lane of an `SSHConnectionPool`, as a Core command executor.
public struct PooledSSHTransport: RemoteCommandExecuting {
    let pool: SSHConnectionPool
    public let serverID: String
    public let lane: SSHConnectionPool.Lane
    public let target: String
    public let port: Int?
    public let identityFile: String?
    public let authentication: SSHAuthentication

    public func execute(_ command: String) async throws -> RemoteCommandOutput {
        try await pool.execute(command, transport: self)
    }
}
