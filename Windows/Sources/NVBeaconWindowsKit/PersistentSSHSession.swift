import Foundation
import NVBeaconCore

/// The text protocol spoken with a remote `/bin/sh -s` kept open over one ssh connection.
///
/// Win32-OpenSSH has no working `ControlMaster`, so instead of one connection with
/// many channels, NVBeacon keeps one shell per connection and frames each command:
///
///     printf '__NVB_%s__\n' 'B_<nonce>'
///     SHLVL=0 "${SHELL:-/bin/sh}" -c '<the words ssh would have sent>' </dev/null
///     printf '\n__NVB_%s_%s__\n' 'E_<nonce>' "$?"          (stdout)
///     printf '\n__NVB_%s__\n' 'E_<nonce>' >&2               (stderr)
///
/// - The command runs exactly as sshd would run it: through the login shell with
///   `-c`, so the remote side sees the same command line as a fresh connection.
///   `SHLVL=0` lets bash treat it as started by sshd again (it then reads
///   `~/.bashrc` as it does for a fresh connection).
/// - The marker text never appears literally in what is sent, so nothing echoed
///   can be mistaken for a marker, and each command gets a new random nonce.
/// - A syntax error or `exit` inside the command only ends that child shell.
/// - `</dev/null` keeps the command from reading the next request.
public enum SSHSessionFraming {
    /// The remote command of the long-lived connection.
    public static let remoteShellCommand = "exec /bin/sh -s"

    public static func makeNonce() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Printed on both streams once the shell runs. Login noise before it is dropped.
    public static func readyRequest(nonce: String) -> String {
        "printf '__NVB_%s__\\n' 'R_\(nonce)'; printf '__NVB_%s__\\n' 'R_\(nonce)' >&2\n"
    }

    public static func request(command: String, nonce: String) -> String {
        let words = SSHTransport.loginShellArguments(command).joined(separator: " ")
        return "printf '__NVB_%s__\\n' 'B_\(nonce)'; "
            + "SHLVL=0 \"${SHELL:-/bin/sh}\" -c \(SSHTransport.shellQuoted(words)) </dev/null; "
            + "printf '\\n__NVB_%s_%s__\\n' 'E_\(nonce)' \"$?\"; "
            + "printf '\\n__NVB_%s__\\n' 'E_\(nonce)' >&2\n"
    }

    /// Drops everything up to and including the ready marker on both streams.
    /// Returns false until both markers have arrived.
    public static func consumeReady(output: inout [UInt8], errorOutput: inout [UInt8], nonce: String) -> Bool {
        let marker = Array("__NVB_R_\(nonce)__\n".utf8)
        guard let outEnd = range(of: marker, in: output)?.upperBound,
              let errEnd = range(of: marker, in: errorOutput)?.upperBound else { return false }
        output.removeFirst(outEnd)
        errorOutput.removeFirst(errEnd)
        return true
    }

    public struct Response: Equatable, Sendable {
        public let standardOutput: [UInt8]
        public let standardError: [UInt8]
        public let exitStatus: Int32
    }

    /// Extracts one complete response and removes it from the buffers, or returns
    /// nil (leaving the buffers alone) until both end markers have arrived.
    public static func consumeResponse(output: inout [UInt8], errorOutput: inout [UInt8], nonce: String) -> Response? {
        let begin = Array("__NVB_B_\(nonce)__\n".utf8)
        let end = Array("\n__NVB_E_\(nonce)_".utf8)
        let errorEnd = Array("\n__NVB_E_\(nonce)__\n".utf8)
        guard let beginRange = range(of: begin, in: output),
              let endRange = range(of: end, in: output, from: beginRange.upperBound),
              let errorRange = range(of: errorEnd, in: errorOutput) else { return nil }
        // "<digits>__\n" follows the end marker.
        var index = endRange.upperBound
        var digits = ""
        while index < output.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(output[index]) {
            digits.append(Character(Unicode.Scalar(output[index])))
            index += 1
        }
        let tail = Array("__\n".utf8)
        guard index + tail.count <= output.count else { return nil }
        guard Array(output[index..<index + tail.count]) == tail, let status = Int32(digits) else { return nil }
        let response = Response(standardOutput: Array(output[beginRange.upperBound..<endRange.lowerBound]),
                                standardError: Array(errorOutput[..<errorRange.lowerBound]),
                                exitStatus: status)
        output.removeFirst(index + tail.count)
        errorOutput.removeFirst(errorRange.upperBound)
        return response
    }

    static func range(of needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count - start >= needle.count else { return nil }
        let first = needle[0]
        var index = start
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first, haystack[index..<index + needle.count].elementsEqual(needle) {
                return index..<index + needle.count
            }
            index += 1
        }
        return nil
    }
}

/// One ssh.exe connection running a remote `/bin/sh -s`, used for one command at a time.
final class PersistentSSHSession: @unchecked Sendable {
    enum Outcome {
        case completed(RemoteCommandOutput)
        /// ssh ended before the command finished. `output` holds ssh's exit status
        /// and messages, the same as a failed fresh connection would report.
        case connectionLost(wasUsed: Bool, output: RemoteCommandOutput)
        case timedOut
        case outputLimitExceeded
    }

    private let executable: String
    let arguments: [String]
    let environment: [String: String]
    private let outputLimit: Int
    private let requestLock = NSLock()
    private let stateLock = NSLock()
    private var child: ChildProcess?
    private var isReady = false
    private var isClosed = false
    private var completedCommands = 0
    private var lastUsedAt = ContinuousClock.now

    init(executable: String, arguments: [String], environment: [String: String], outputLimit: Int = 8 * 1024 * 1024) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.outputLimit = outputLimit
    }

    var idleTime: Duration { stateLock.withLock { ContinuousClock.now - lastUsedAt } }

    /// Usable for another command: not closed, and ssh still running (or not started).
    var isUsable: Bool {
        stateLock.withLock { !isClosed && !(child?.hasExited ?? false) }
    }

    /// Blocks the calling thread. Commands are serialized per session.
    func execute(_ command: String, timeout: Duration) throws -> Outcome {
        requestLock.lock()
        defer { requestLock.unlock() }
        stateLock.withLock { lastUsedAt = .now }
        defer { stateLock.withLock { lastUsedAt = .now } }

        let wasUsed = stateLock.withLock { completedCommands > 0 }
        let child: ChildProcess
        if let existing = stateLock.withLock({ self.child }) {
            child = existing
        } else {
            guard !stateLock.withLock({ isClosed }) else { return .connectionLost(wasUsed: false, output: closedOutput) }
            child = try ChildProcess.launch(executable: executable, arguments: arguments, environment: environment)
            let attached = stateLock.withLock { () -> Bool in
                guard !isClosed else { return false }
                self.child = child
                return true
            }
            guard attached else {
                child.terminate()
                return .connectionLost(wasUsed: false, output: closedOutput)
            }
        }

        if !stateLock.withLock({ isReady }) {
            let nonce = SSHSessionFraming.makeNonce()
            _ = child.write(Array(SSHSessionFraming.readyRequest(nonce: nonce).utf8))
            enum Startup { case ready, failed(RemoteCommandOutput) }
            let startup = child.wait(until: .now + timeout) { output, errorOutput, exitCode -> Startup? in
                if SSHSessionFraming.consumeReady(output: &output, errorOutput: &errorOutput, nonce: nonce) { return .ready }
                if let exitCode { return .failed(Self.lostOutput(errorOutput, exitCode: exitCode)) }
                return nil
            }
            switch startup {
            case .none:
                close()
                return .timedOut
            case .failed(let output)?:
                close()
                return .connectionLost(wasUsed: false, output: output)
            case .ready?:
                stateLock.withLock { isReady = true }
            }
        }

        let nonce = SSHSessionFraming.makeNonce()
        guard child.write(Array(SSHSessionFraming.request(command: command, nonce: nonce).utf8)) else {
            let output = child.wait(until: .now + .seconds(2)) { _, errorOutput, exitCode in
                exitCode.map { Self.lostOutput(errorOutput, exitCode: $0) }
            } ?? Self.lostOutput([], exitCode: 255)
            close()
            return .connectionLost(wasUsed: wasUsed, output: output)
        }
        enum Waited { case response(SSHSessionFraming.Response), lost(RemoteCommandOutput), tooLarge }
        let limit = outputLimit
        let waited = child.wait(until: .now + timeout) { output, errorOutput, exitCode -> Waited? in
            if let response = SSHSessionFraming.consumeResponse(output: &output, errorOutput: &errorOutput, nonce: nonce) {
                return .response(response)
            }
            if output.count + errorOutput.count > limit { return .tooLarge }
            if let exitCode { return .lost(Self.lostOutput(errorOutput, exitCode: exitCode)) }
            return nil
        }
        switch waited {
        case .none:
            close()
            return .timedOut
        case .tooLarge?:
            close()
            return .outputLimitExceeded
        case .lost(let output)?:
            close()
            return .connectionLost(wasUsed: wasUsed, output: output)
        case .response(let response)?:
            stateLock.withLock { completedCommands += 1 }
            return .completed(RemoteCommandOutput(
                standardOutput: String(decoding: response.standardOutput, as: UTF8.self),
                standardError: SSHTransport.decodeStandardError(response.standardError)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                exitStatus: response.exitStatus))
        }
    }

    /// Ends the connection: closing stdin lets the remote shell exit, and ssh is
    /// terminated if it has not ended shortly after.
    func close() {
        let child: ChildProcess? = stateLock.withLock {
            isClosed = true
            defer { self.child = nil }
            return self.child
        }
        guard let child else { return }
        child.closeInput()
        Thread.detachNewThread {
            if child.wait(until: .now + .seconds(2), { _, _, exitCode in exitCode }) == nil { child.terminate() }
        }
    }

    private var closedOutput: RemoteCommandOutput {
        RemoteCommandOutput(standardOutput: "", standardError: "The SSH connection was closed.", exitStatus: 255)
    }

    private static func lostOutput(_ errorOutput: [UInt8], exitCode: UInt32) -> RemoteCommandOutput {
        let message = SSHTransport.decodeStandardError(errorOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = Int32(bitPattern: exitCode)
        return RemoteCommandOutput(standardOutput: "",
                                   standardError: message.isEmpty ? "The SSH connection closed unexpectedly." : message,
                                   exitStatus: status == 0 ? 255 : status)
    }
}
