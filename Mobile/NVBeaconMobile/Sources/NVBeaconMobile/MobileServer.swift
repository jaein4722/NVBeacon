import Foundation
import NVBeaconCore

public struct MobileServer: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = ""
    public var host = ""
    public var username = ""
    public var port = 22
    public var authentication: SSHAuthenticationMode = .keyBased
    public var connectionReuseMode: SSHConnectionReuseMode?
    public var reusesConnection: Bool { connectionReuseMode != .newConnectionEachRefresh }
    public var isEnabled = true
    public var gpuCommand = RemoteMetricCommands.defaultGPUCommand
    public var memoryCommand = RemoteMetricCommands.defaultMemoryCommand
    public var hostCommand: String?
    public var transferSetupIssue: String?
    // Trust is scoped to this exact endpoint. It is never exported or imported.
    public var trustedHostKey: String?
    public var trustedEndpoint: String?

    public init() {}
    public var displayName: String { name.isEmpty ? host : name }
    public var endpoint: String { "[\(host.lowercased())]:\(port)" }
    public var pinnedHostKey: String? { trustedEndpoint == endpoint ? trustedHostKey : nil }

    public func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !result.host.isEmpty, !result.host.hasPrefix("-"),
              !result.host.contains("@"), !result.host.contains("/"),
              !result.host.unicodeScalars.contains(where: forbidden.contains),
              !result.username.isEmpty, !result.username.hasPrefix("-"),
              !result.username.unicodeScalars.contains(where: forbidden.contains),
              (1...65535).contains(port), !gpuCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MobileError.invalidServer }
        if result.trustedEndpoint != result.endpoint {
            result.trustedHostKey = nil
            result.trustedEndpoint = nil
        }
        return result
    }

    public static func importing(_ entry: ServerSettingsBackup.Entry) -> Self {
        var server = Self()
        server.name = entry.name
        let parts = entry.sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@", maxSplits: 1)
        if parts.count == 2 {
            server.username = String(parts[0])
            server.host = String(parts[1])
        } else {
            server.host = String(parts.first ?? "")
        }
        server.port = Int(entry.sshPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22
        server.authentication = entry.sshAuthenticationMode
        server.connectionReuseMode = entry.sshConnectionReuseMode
        server.gpuCommand = entry.remoteCommand
        server.memoryCommand = entry.memoryCommand
        server.hostCommand = entry.hostCommand == RemoteMetricCommands.hostInfo(memoryCommand: entry.memoryCommand)
            ? nil : entry.hostCommand
        server.isEnabled = false
        return server
    }

    public var backupEntry: ServerSettingsBackup.Entry {
        .init(name: name, sshTarget: username.isEmpty ? host : "\(username)@\(host)", sshPort: String(port),
              sshIdentityFilePath: "", sshAuthenticationMode: authentication,
              sshConnectionReuseMode: connectionReuseMode ?? .reuseWhenPossible,
              remoteCommand: gpuCommand, memoryCommand: memoryCommand, hostCommand: hostCommand)
    }
}

public struct MobileCredential: Codable, Equatable, Sendable {
    public var secret: String
    public var passphrase: String
    public init(secret: String = "", passphrase: String = "") {
        self.secret = secret
        self.passphrase = passphrase
    }
}

public enum MobileError: LocalizedError, Equatable, Sendable {
    case invalidServer, missingCredential, unsupportedKey, timedOut, outputTooLarge, connectionClosed, invalidMetrics, authenticationFailed
    case invalidKeyFile, unsupportedKeyProtection, unsupportedRSAKeySize, keyPassphraseRequired, cannotUnlockKey
    case hostKeyRequired(key: String, fingerprint: String)
    case hostKeyChanged(fingerprint: String)
    case keychain(Int32)
    case commandFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter a hostname or IP address, username, valid port, and GPU command. OpenSSH aliases must be replaced with a reachable address."
        case .missingCredential: "Add this server’s password or SSH private key in Edit Server."
        case .unsupportedKey: "Choose an OpenSSH private key or an unencrypted RSA, ECDSA or Ed25519 PEM private key."
        case .invalidKeyFile: "The private key is invalid or damaged."
        case .unsupportedKeyProtection: "Unsupported OpenSSH key protection. Use AES-CTR and bcrypt with up to 256 rounds."
        case .unsupportedRSAKeySize: "Use an RSA key between 2048 and 8192 bits."
        case .keyPassphraseRequired: "Enter the passphrase for this private key."
        case .cannotUnlockKey: "Could not unlock the private key. Check its passphrase and contents."
        case .timedOut: "The SSH request timed out. Check the server address and VPN connection."
        case .outputTooLarge: "SSH output exceeded the 2 MiB limit."
        case .connectionClosed: "The SSH connection closed before the command completed."
        case .invalidMetrics: "Could not read GPU metrics. Check that nvidia-smi is installed and the GPU command returns the expected CSV format."
        case .authenticationFailed: "SSH authentication failed. Check the username, credential, and authentication methods allowed by the server."
        case .hostKeyRequired: "Verify the server’s SSH host key before connecting."
        case .hostKeyChanged: "The SSH host key has changed. Verify the change with your server administrator before resetting trust in Edit Server."
        case .keychain: "Could not access the device Keychain."
        case .commandFailed(let status, let message): "Remote command failed (\(status)). \(message.prefix(500))"
        }
    }
}
