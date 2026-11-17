import Foundation
import NVBeaconCore
import Testing
@testable import NVBeaconWindowsKit

// MARK: Framing

@Test func responseIsExtractedBetweenMarkersAndNoiseIsDropped() {
    let nonce = "abc123"
    var output = Array("motd noise\n__NVB_B_abc123__\nline 1\nline 2\n\n__NVB_E_abc123_3__\nnext".utf8)
    var errorOutput = Array("warning: something\n\n__NVB_E_abc123__\nrest".utf8)
    let response = SSHSessionFraming.consumeResponse(output: &output, errorOutput: &errorOutput, nonce: nonce)
    #expect(response == SSHSessionFraming.Response(standardOutput: Array("line 1\nline 2\n".utf8),
                                                   standardError: Array("warning: something\n".utf8), exitStatus: 3))
    #expect(output == Array("next".utf8))
    #expect(errorOutput == Array("rest".utf8))
}

@Test func responseWaitsForBothStreamsAndTheWholeMarker() {
    let nonce = "n1"
    var output = Array("__NVB_B_n1__\nabc\n__NVB_E_n1_0_".utf8)   // end marker cut short
    var errorOutput = Array("\n__NVB_E_n1__\n".utf8)
    #expect(SSHSessionFraming.consumeResponse(output: &output, errorOutput: &errorOutput, nonce: nonce) == nil)
    output += Array("_\n".utf8)
    var noError: [UInt8] = []
    #expect(SSHSessionFraming.consumeResponse(output: &output, errorOutput: &noError, nonce: nonce) == nil)
    let response = SSHSessionFraming.consumeResponse(output: &output, errorOutput: &errorOutput, nonce: nonce)
    #expect(response?.standardOutput == Array("abc".utf8))
    #expect(response?.exitStatus == 0)
}

@Test func readyMarkerDropsLoginNoiseOnBothStreams() {
    var output = Array("Welcome to Ubuntu\n__NVB_R_x__\n".utf8)
    var errorOutput = Array("Last login: ...\n__NVB_R_x__\nlater".utf8)
    #expect(SSHSessionFraming.consumeReady(output: &output, errorOutput: &errorOutput, nonce: "x"))
    #expect(output.isEmpty)
    #expect(errorOutput == Array("later".utf8))
}

@Test func requestNeverContainsTheMarkerTextItWaitsFor() {
    let nonce = SSHSessionFraming.makeNonce()
    let request = SSHSessionFraming.request(command: "echo hi\nprintf '%s' \"it's\"", nonce: nonce)
    #expect(!request.contains("__NVB_B_\(nonce)"))
    #expect(!request.contains("__NVB_E_\(nonce)"))
    #expect(request.hasSuffix("\n"))
    #expect(request.dropLast().contains("\n") == false, "one line per request")
    // The command goes to the login shell as the same words a fresh connection sends.
    let words = SSHTransport.loginShellArguments("echo hi\nprintf '%s' \"it's\"").joined(separator: " ")
    #expect(request.contains(SSHTransport.shellQuoted(words)))
}

@Test func sessionArgumentsKeepOneShellWithoutAPTY() {
    let key = SSHTransport.sessionArguments(target: "lab", port: 2222, identityFile: #"C:\keys\id"#)
    #expect(key.first == "-T")
    #expect(Array(key.suffix(2)) == ["lab", "exec /bin/sh -s"])
    #expect(key.contains("BatchMode=yes"))
    let password = SSHTransport.sessionArguments(target: "lab", authentication: .password(account: "A", askPassExecutable: #"C:\NVBeacon.exe"#))
    #expect(password.contains("BatchMode=no"))
    #expect(password.contains("NumberOfPasswordPrompts=1"))
    #expect(!password.contains("BatchMode=yes"))
    let environment = SSHAuthentication.password(account: "A", askPassExecutable: #"C:\NVBeacon.exe"#).environment
    #expect(environment["SSH_ASKPASS_REQUIRE"] == "force")
    #expect(environment[AskPass.accountVariable] == "A")
    #expect(!environment.values.contains { $0.lowercased().contains("password") }, "the password itself is never in the environment")
}

// MARK: A real long-lived shell (Git for Windows' sh stands in for ssh)

private let gitShell = #"C:\Program Files\Git\usr\bin\sh.exe"#

@Test(.enabled(if: FileManager.default.fileExists(atPath: gitShell)))
func persistentShellRunsCommandsOneAfterAnother() throws {
    let session = PersistentSSHSession(executable: gitShell, arguments: ["-s"], environment: ["SHELL": "/bin/sh"])
    defer { session.close() }
    func run(_ command: String) throws -> RemoteCommandOutput {
        guard case .completed(let output) = try session.execute(command, timeout: .seconds(20)) else {
            Issue.record("command did not complete: \(command)")
            return RemoteCommandOutput(standardOutput: "", standardError: "", exitStatus: -1)
        }
        return output
    }
    #expect(try run("echo hello").standardOutput == "hello\n")
    let failing = try run("echo out; echo err >&2; exit 3")
    #expect(failing.standardOutput == "out\n")
    #expect(failing.standardError == "err")
    #expect(failing.exitStatus == 3)
    // A syntax error ends only the command's own shell, not the session.
    #expect(try run("if then fi").exitStatus != 0)
    #expect(try run("printf 'no newline'").standardOutput == "no newline")
    // Quotes, backslashes and newlines arrive intact (the RemoteShell.portable path).
    #expect(try run("printf '%s\\n' \"it's\" 'a\\b'\necho second").standardOutput == "it's\na\\b\nsecond\n")
    // The command cannot read the next request from the session's stdin.
    #expect(try run("cat").standardOutput == "")
    #expect(try run("echo still alive").standardOutput == "still alive\n")
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: gitShell)))
func sessionThatEndsAtStartupReportsTheExitStatus() throws {
    let session = PersistentSSHSession(executable: gitShell, arguments: ["-c", "echo 'Permission denied' >&2; exit 255"], environment: [:])
    guard case .connectionLost(let wasUsed, let output) = try session.execute("echo hi", timeout: .seconds(20)) else {
        Issue.record("expected the connection to be lost")
        return
    }
    #expect(!wasUsed)
    #expect(output.exitStatus == 255)
    #expect(output.standardError == "Permission denied")
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: gitShell)))
func sessionTimesOutAndCanBeReplaced() throws {
    let session = PersistentSSHSession(executable: gitShell, arguments: ["-s"], environment: [:])
    guard case .completed = try session.execute("true", timeout: .seconds(20)) else {
        Issue.record("first command failed")
        return
    }
    guard case .timedOut = try session.execute("sleep 5", timeout: .seconds(1)) else {
        Issue.record("expected a timeout")
        return
    }
    #expect(!session.isUsable)
}

// MARK: Passwords

@Test func askPassAnswersOnlyPasswordPrompts() {
    #expect(AskPass.isPasswordPrompt("alice@gpu-a's password: "))
    #expect(AskPass.isPasswordPrompt("Password:"))
    #expect(AskPass.isPasswordPrompt("(alice@gpu-a) Password: "))
    #expect(!AskPass.isPasswordPrompt("Enter passphrase for key 'C:\\Users\\me\\.ssh\\id_ed25519': "))
    #expect(!AskPass.isPasswordPrompt("Are you sure you want to continue connecting (yes/no/[fingerprint])?"))
    #expect(!AskPass.isPasswordPrompt("(alice@gpu-a) Verification code: "))
    #expect(!AskPass.isPasswordPrompt("(alice@gpu-a) New password: "))
    #expect(!AskPass.isPasswordPrompt("Enter your old password:"))
}

@Test func passwordStoreRoundTripsThroughCredentialManager() {
    let store = SSHPasswordStore(prefix: "NVBeacon-test/\(UUID().uuidString)/")
    defer { for id in store.savedServerIDs() { store.delete(for: id) } }
    #expect(store.password(for: "A") == nil)
    #expect(store.save("s3cret 비밀", for: "A"))
    #expect(store.password(for: "A") == "s3cret 비밀")
    #expect(store.savedServerIDs() == ["A"])
    #expect(store.save("", for: "A"), "an empty password removes it")
    #expect(store.password(for: "A") == nil)
    #expect(store.delete(for: "missing"))
}

@Test func monitorTreatsSSHPermissionDeniedAsAnAuthenticationFailure() {
    let denied = MetricsCollectionError.commandFailed(255, "alice@gpu-a: Permission denied (publickey,password).")
    #expect(ServerMonitor.isAuthenticationFailure(denied))
    #expect(!ServerMonitor.isAuthenticationFailure(MetricsCollectionError.commandFailed(255, "Connection timed out")))
    #expect(!ServerMonitor.isAuthenticationFailure(MetricsCollectionError.commandFailed(1, "Permission denied")))
}

// MARK: Settings

@Test func serversSavedBeforeReuseModeExistedDefaultToReuse() throws {
    let json = #"{"id":"A","name":"Lab","sshTarget":"lab","sshPort":"","sshIdentityFilePath":"","sshAuthenticationMode":"passwordBased","remoteCommand":"nvidia-smi","hostCommand":"host","isEnabled":true}"#
    let server = try JSONDecoder().decode(ServerSettings.self, from: Data(json.utf8))
    #expect(server.sshConnectionReuseMode == .reuseWhenPossible)
    #expect(server.sshAuthenticationMode == .passwordBased)
    #expect(server.isPollable, "password servers are polled once a password is saved")
}

@Test func backupKeepsEachServersReuseMode() {
    var settings = WindowsSettings()
    settings.servers = [ServerSettings(sshTarget: "lab", sshConnectionReuseMode: .newConnectionEachRefresh)]
    #expect(settings.backup().servers.first?.sshConnectionReuseMode == .newConnectionEachRefresh)
    var imported = WindowsSettings()
    imported.importServers(from: settings.backup())
    #expect(imported.servers.first?.sshConnectionReuseMode == .newConnectionEachRefresh)
}
