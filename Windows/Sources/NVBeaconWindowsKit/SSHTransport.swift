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

/// How ssh authenticates. Password authentication answers ssh's prompt through
/// `SSH_ASKPASS`: NVBeacon.exe started by ssh reads the saved password itself
/// (see `AskPass`), so the password never appears in arguments, environment or files.
public enum SSHAuthentication: Sendable, Equatable {
    case key
    case password(account: String, askPassExecutable: String)

    /// Matches the macOS app's options for each mode.
    var options: [String] {
        switch self {
        case .key:
            ["-o", "BatchMode=yes",
             "-o", "PreferredAuthentications=publickey",
             "-o", "PasswordAuthentication=no",
             "-o", "KbdInteractiveAuthentication=no"]
        case .password:
            ["-o", "BatchMode=no",
             "-o", "NumberOfPasswordPrompts=1",
             "-o", "PreferredAuthentications=password,keyboard-interactive,publickey"]
        }
    }

    var environment: [String: String] {
        switch self {
        case .key:
            [:]
        case .password(let account, let askPassExecutable):
            ["SSH_ASKPASS": askPassExecutable,
             "SSH_ASKPASS_REQUIRE": "force",
             // Not required by Win32-OpenSSH with "force", but harmless and what other ports expect.
             "DISPLAY": "nvbeacon:0",
             AskPass.accountVariable: account]
        }
    }
}

/// The OpenSSH client version, read once per executable from `ssh -V`.
public struct SSHClientVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Password login needs `SSH_ASKPASS_REQUIRE=force` (OpenSSH 8.4). Older clients,
    /// such as the OpenSSH 8.1 built into Windows 10, ask on a console NVBeacon cannot answer.
    public static let passwordLoginMinimum = SSHClientVersion(major: 8, minor: 4)

    public var description: String { "\(major).\(minor)" }

    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.major, lhs.minor) < (rhs.major, rhs.minor) }

    /// `OpenSSH_for_Windows_9.5p2, LibreSSL 3.8.2` → 9.5.
    public static func parse(_ text: String) -> SSHClientVersion? {
        guard let range = text.range(of: "OpenSSH_") else { return nil }
        var rest = text[range.upperBound...]
        if rest.hasPrefix("for_Windows_") { rest = rest.dropFirst("for_Windows_".count) }
        let numbers = rest.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        return SSHClientVersion(major: numbers[0], minor: numbers[1])
    }

    private static let cache = NSLock()
    nonisolated(unsafe) private static var known: [String: SSHClientVersion] = [:]

    /// nil when ssh cannot be run or its version is not recognized.
    public static func of(executable: String = SSHTransport.defaultSSHExecutable) async -> SSHClientVersion? {
        if let version = cache.withLock({ known[executable] }) { return version }
        guard let output = try? await WindowsProcessRunner.run(executable: executable, arguments: ["-V"], timeout: .seconds(5)),
              let version = parse(String(decoding: output.standardError + output.standardOutput, as: UTF8.self)) else { return nil }
        cache.withLock { known[executable] = version }
        return version
    }
}

/// Runs Core's remote commands through the Windows OpenSSH client (`ssh.exe`),
/// opening a new connection for every command ("New connection every refresh").
/// `SSHConnectionPool` keeps connections open instead.
public struct SSHTransport: RemoteCommandExecuting {
    public let target: String
    public let port: Int?
    public let identityFile: String?
    public let authentication: SSHAuthentication
    public let sshExecutable: String
    public let timeout: Duration

    public init(target: String, port: Int? = nil, identityFile: String? = nil, authentication: SSHAuthentication = .key,
                sshExecutable: String = SSHTransport.defaultSSHExecutable, timeout: Duration = .seconds(15)) {
        self.target = target
        self.port = port
        let trimmed = identityFile?.trimmingCharacters(in: .whitespaces) ?? ""
        self.identityFile = trimmed.isEmpty ? nil : trimmed
        self.authentication = authentication
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
                arguments: Self.arguments(target: target, port: port, identityFile: identityFile,
                                          authentication: authentication, remoteCommand: command),
                environment: authentication.environment,
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

    /// Mirrors the macOS app's options (`SSHMetricsFetcher.buildSSHArguments`).
    public static func arguments(target: String, port: Int? = nil, identityFile: String? = nil,
                                 authentication: SSHAuthentication = .key, remoteCommand: String) -> [String] {
        connectionOptions(port: port, identityFile: identityFile, authentication: authentication)
            + [target] + loginShellArguments(remoteCommand)
    }

    /// The long-lived connection behind `SSHConnectionPool`: no PTY, a remote `sh -s`.
    public static func sessionArguments(target: String, port: Int? = nil, identityFile: String? = nil,
                                        authentication: SSHAuthentication = .key) -> [String] {
        ["-T"] + connectionOptions(port: port, identityFile: identityFile, authentication: authentication)
            + [target, SSHSessionFraming.remoteShellCommand]
    }

    static func connectionOptions(port: Int?, identityFile: String?, authentication: SSHAuthentication) -> [String] {
        var arguments = [
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1",
            "-o", "TCPKeepAlive=yes",
        ] + authentication.options
        if let identityFile { arguments += ["-i", identityFile] }
        if let port { arguments += ["-p", String(port)] }
        return arguments
    }

    /// The words ssh joins and hands to the remote login shell, which runs `/bin/sh -l`.
    /// Same words as the macOS `SSHMetricsFetcher.loginShellArguments`, so both clients
    /// send byte-identical remote commands; `RemoteShell.portable` keeps the script
    /// intact through csh, tcsh and fish login shells.
    public static func loginShellArguments(_ remoteCommand: String) -> [String] {
        ["/bin/sh", "-lc", shellQuoted(RemoteShell.portable(remoteCommand))]
    }

    static func shellQuoted(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
