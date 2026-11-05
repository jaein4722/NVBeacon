import Foundation

/// Only encode this envelope for delivery over the approved pairing connection.
/// Server JSON backup/export has a separate schema and never receives this type.
public struct TransferBatch: Sendable {
    public static let maximumBytes = 8 * 1024 * 1024
    public let id: UUID
    public let servers: [TransferServer]
    public let credentials: [UUID: TransferCredential]

    public init(id: UUID, servers: [TransferServer], credentials: [UUID: TransferCredential]) {
        self.id = id
        self.servers = servers
        self.credentials = credentials
    }

    private struct Envelope: Codable {
        let version: Int
        let id: UUID
        let servers: [TransferServer]
        let credentials: [UUID: TransferCredential]
    }

    public func encoded() throws -> Data {
        try validate()
        let wire = Envelope(version: 1, id: id, servers: servers, credentials: credentials)
        let data = try JSONEncoder().encode(wire)
        guard data.count <= Self.maximumBytes else { throw TransferPayloadError.invalid }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw TransferPayloadError.invalid }
        guard let wire = try? JSONDecoder().decode(Envelope.self, from: data), wire.version == 1 else {
            throw TransferPayloadError.invalid
        }
        let result = Self(id: wire.id, servers: wire.servers, credentials: wire.credentials)
        try result.validate()
        return result
    }

    public func validate() throws {
        guard (1...100).contains(servers.count), credentials.count <= servers.count,
              Set(servers.map(\.id)).count == servers.count,
              Set(servers.compactMap(\.credentialID)) == Set(credentials.keys) else {
            throw TransferPayloadError.invalid
        }
        for server in servers {
            let incomplete = server.setupIssue?.isEmpty == false
            guard (1...65535).contains(server.port),
                  ["passwordBased", "keyBased"].contains(server.authentication),
                  !server.host.hasPrefix("-"), !server.host.contains("/"), !server.host.contains("@"),
                  !server.host.contains(where: { $0.isWhitespace || $0.isNewline }),
                  server.host.rangeOfCharacter(from: .controlCharacters) == nil,
                  server.username.rangeOfCharacter(from: .controlCharacters) == nil,
                  incomplete || (!server.host.isEmpty && !server.username.isEmpty),
                  !server.gpuCommand.isEmpty else { throw TransferPayloadError.invalid }
            if let reference = server.credentialID {
                guard let credential = credentials[reference], credential.kind == server.authentication,
                      !credential.secret.isEmpty, credential.secret.utf8.count <= 65_536,
                      credential.passphrase.utf8.count <= 65_536,
                      credential.kind == "keyBased" || credential.passphrase.isEmpty
                else { throw TransferPayloadError.invalid }
            } else if !incomplete { throw TransferPayloadError.invalid }
        }
    }
}

public enum TransferPayloadError: LocalizedError {
    case invalid
    public var errorDescription: String? { "The transfer contains invalid or unsupported server data." }
}

public struct TransferServer: Codable, Sendable {
    public let id: UUID
    public let name, host, username: String
    public let port: Int
    public let authentication, gpuCommand, memoryCommand: String
    public let hostCommand: String?
    public let credentialID: UUID?
    public let setupIssue: String?
    public let connectionReuseMode: String?

    public init(id: UUID, name: String, host: String, username: String, port: Int,
                authentication: String, gpuCommand: String, memoryCommand: String,
                hostCommand: String?, credentialID: UUID?, setupIssue: String?, connectionReuseMode: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.port = port
        self.authentication = authentication
        self.gpuCommand = gpuCommand
        self.memoryCommand = memoryCommand
        self.hostCommand = hostCommand
        self.credentialID = credentialID
        self.setupIssue = setupIssue
        self.connectionReuseMode = connectionReuseMode
    }
}

public struct TransferCredential: Codable, Sendable {
    public let kind, secret, passphrase: String
    public init(kind: String, secret: String, passphrase: String = "") {
        self.kind = kind
        self.secret = secret
        self.passphrase = passphrase
    }
}
