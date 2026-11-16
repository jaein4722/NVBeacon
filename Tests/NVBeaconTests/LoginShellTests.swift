import Foundation
import NVBeaconCore
import Testing
@testable import NVBeacon

/// Runs the command line ssh would hand to a remote login shell, locally.
private func run(_ shell: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-c", arguments.joined(separator: " ")]
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private let loginShells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/tcsh", "/bin/csh",
                           "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
    .filter { FileManager.default.isExecutableFile(atPath: $0) }

@Test func remoteScriptsReachShUnchangedFromEveryLoginShell() throws {
    let script = """
    printf 'line one\\n'
    quoted='it'"'"'s'; printf '%s\\n' "$quoted"
    printf '%s\\n' 'back\\slash' "bang!" "tab\there"
    echo "$((2 + 3))"
    """
    let expected = try run("/bin/sh", [script])
    #expect(expected.status == 0)
    #expect(loginShells.contains("/bin/tcsh"))
    for shell in loginShells {
        let result = try run(shell, SSHMetricsFetcher.loginShellArguments(script))
        #expect(result.status == 0, "\(shell): \(result.output)")
        #expect(result.output == expected.output, "\(shell) changed the script")
    }
}

@Test func summaryScriptSurvivesTcshByteForByte() throws {
    let summary = RemoteMetricCommands.summary(summaryCommand: RemoteMetricCommands.defaultGPUCommand)
    let echo = "cat <<'NVBEACON_EOF'\n\(summary)\nNVBEACON_EOF"
    let result = try run("/bin/tcsh", SSHMetricsFetcher.loginShellArguments(echo))
    #expect(result.status == 0)
    #expect(result.output == summary + "\n")
}

@Test func singleLineCommandsAreSentAsBefore() {
    #expect(SSHMetricsFetcher.loginShellPortable("ps -o pid= -p \"1,2\"") == "ps -o pid= -p \"1,2\"")
    let wrapped = SSHMetricsFetcher.loginShellPortable("a\nb\\c'd!e")
    #expect(!wrapped.contains("\n") && !wrapped.contains("\\\\") && !wrapped.contains("\\'"))
}
