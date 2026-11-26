import Foundation

/// A server's SSH connection settings. Conforming types get `connectionFingerprint`.
public protocol SSHConnectionFingerprinting {
    var sshTarget: String { get }
    var sshPort: String { get }
    var sshIdentityFilePath: String { get }
    var sshAuthenticationMode: SSHAuthenticationMode { get }
}

extension SSHConnectionFingerprinting {
    /// Identifies where and how a client connects, so watches and GPU history survive
    /// a rename but not a change of target, port, key or authentication mode.
    /// Clients save it with watches and history: keep the format unchanged.
    public var connectionFingerprint: String {
        [sshTarget, sshPort, sshIdentityFilePath, sshAuthenticationMode.rawValue].joined(separator: "|")
    }
}
