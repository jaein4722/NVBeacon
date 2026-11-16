import Foundation
import NVBeaconCore

public enum SSHTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidTarget(String)
    case sshNotFound(String)
    case timedOut(Int)
    case outputLimitExceeded(Int)

    public var description: String {
        switch self {
        case .invalidTarget(let target): "Invalid SSH target: \(target)"
        case .sshNotFound(let path): "OpenSSH client not found at \(path)"
        case .timedOut(let seconds): "SSH command timed out after \(seconds) s"
        case .outputLimitExceeded(let bytes): "Remote output exceeded \(bytes / 1024 / 1024) MiB"
        }
    }
}

/// Runs Core's remote commands through the Windows OpenSSH client (`ssh.exe`).
///
/// Win32-OpenSSH has no `ControlMaster`, so every command opens a new connection.
/// Only key and agent authentication is supported for now (`BatchMode=yes`).
public struct SSHTransport: RemoteCommandExecuting {
    public let target: String
    public let sshExecutable: String
    public let timeout: Duration

    public init(target: String, sshExecutable: String = SSHTransport.defaultSSHExecutable, timeout: Duration = .seconds(15)) {
        self.target = target
        self.sshExecutable = sshExecutable
        self.timeout = timeout
    }

    public static var defaultSSHExecutable: String {
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
        return systemRoot + #"\System32\OpenSSH\ssh.exe"#
    }

    public func execute(_ command: String) async throws -> RemoteCommandOutput {
        guard Self.isValidTarget(target) else { throw SSHTransportError.invalidTarget(target) }
        guard FileManager.default.fileExists(atPath: sshExecutable) else {
            throw SSHTransportError.sshNotFound(sshExecutable)
        }
        let output: ProcessOutput
        do {
            output = try await WindowsProcessRunner.run(
                executable: sshExecutable,
                arguments: Self.arguments(target: target, remoteCommand: command),
                timeout: timeout
            )
        } catch ProcessRunError.timedOut(let seconds) {
            throw SSHTransportError.timedOut(seconds)
        } catch ProcessRunError.outputLimitExceeded(let bytes) {
            throw SSHTransportError.outputLimitExceeded(bytes)
        }
        return RemoteCommandOutput(
            standardOutput: String(decoding: output.standardOutput, as: UTF8.self),
            standardError: Self.decodeStandardError(output.standardError)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            exitStatus: Int32(bitPattern: output.exitCode)
        )
    }

    /// ssh writes non-ASCII bytes in its own messages as `\ooo` octal escapes, and on
    /// Windows those bytes are system messages in the ANSI code page (CP949 on Korean
    /// Windows), not UTF-8. Undo the escapes, then decode as UTF-8 or the ANSI code page.
    public static func decodeStandardError(_ bytes: [UInt8]) -> String {
        var unescaped: [UInt8] = []
        unescaped.reserveCapacity(bytes.count)
        var index = 0
        let octal = UInt8(ascii: "0")...UInt8(ascii: "7")
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\"), index + 3 < bytes.count,
               octal.contains(bytes[index + 1]), octal.contains(bytes[index + 2]), octal.contains(bytes[index + 3]) {
                let value = (Int(bytes[index + 1] - 48) << 6) | (Int(bytes[index + 2] - 48) << 3) | Int(bytes[index + 3] - 48)
                if value <= 0xFF {
                    unescaped.append(UInt8(value))
                    index += 4
                    continue
                }
            }
            unescaped.append(bytes[index])
            index += 1
        }
        if let text = String(validating: unescaped, as: UTF8.self) { return text }
        return ANSICodePage.decode(unescaped)
    }

    /// A target that starts with `-` would be read by ssh as an option.
    public static func isValidTarget(_ target: String) -> Bool {
        !target.isEmpty && !target.hasPrefix("-") && !target.contains(where: \.isWhitespace)
    }

    /// Mirrors the macOS app's options, without connection reuse or password auth.
    public static func arguments(target: String, remoteCommand: String) -> [String] {
        [
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "TCPKeepAlive=yes",
            "-o", "BatchMode=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            target,
        ] + loginShellArguments(remoteCommand)
    }

    // The three functions below are copied from the macOS `SSHMetricsFetcher` so
    // both clients send byte-identical remote commands. They belong in Core.

    /// The words ssh joins and hands to the remote login shell, which runs `/bin/sh -l`.
    public static func loginShellArguments(_ remoteCommand: String) -> [String] {
        ["/bin/sh", "-lc", shellQuoted(loginShellPortable(remoteCommand))]
    }

    /// ssh passes the command to the user's login shell before `/bin/sh` sees it.
    /// csh/tcsh reject newlines inside single quotes, and fish treats `\\` and `\'`
    /// there as escapes. A script containing any of those characters is therefore sent
    /// on one line as `printf %b` octal escapes, which every login shell leaves intact.
    public static func loginShellPortable(_ script: String) -> String {
        let escapes: [Unicode.Scalar: String] = ["\\": "\\0134", "\n": "\\0012", "\r": "\\0015", "'": "\\0047", "!": "\\0041"]
        guard script.unicodeScalars.contains(where: { escapes[$0] != nil }) else { return script }
        var encoded = ""
        for scalar in script.unicodeScalars {
            if let escape = escapes[scalar] { encoded += escape } else { encoded.unicodeScalars.append(scalar) }
        }
        return "exec /bin/sh -c \"$(printf '%b' '\(encoded)')\""
    }

    static func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
