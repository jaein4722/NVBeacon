import Foundation
import Testing
@testable import NVBeaconCore

private let hasSh = FileManager.default.isExecutableFile(atPath: "/bin/sh")

/// Runs a command the way sshd does: `<login shell> -c <command>`.
private func run(_ shell: String, _ command: String) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-c", command]
    process.standardInput = FileHandle.nullDevice
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
                           "/usr/bin/fish", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
    .filter { FileManager.default.isExecutableFile(atPath: $0) }

@Test(.enabled(if: hasSh)) func shCommandRunsTheScriptInShFromEveryLoginShell() throws {
    // `set -- $line` is how the summary reads a UID; zsh does not split it.
    let script = """
    uid_line='Uid: 1000 1000 1000 1000'
    set -- $uid_line
    printf '%s\\n' "$2"
    quoted='it'"'"'s'; printf '%s\\n' "$quoted"
    printf '%s\\n' 'back\\slash' "bang!" "tab\there" "$(echo sub)"
    echo "$((2 + 3))"
    """
    let expected = try run("/bin/sh", script)
    #expect(expected.status == 0)
    #expect(expected.output.hasPrefix("1000\n"))
    for shell in loginShells {
        let result = try run(shell, RemoteShell.shCommand(script))
        #expect(result.status == 0, "\(shell): \(result.output)")
        #expect(result.output == expected.output, "\(shell) changed the script")
    }
}

@Test(.enabled(if: hasSh)) func shCommandKeepsOneLineScriptsReadable() throws {
    let ps = "printf 'uid=%s\\n' \"$(id -u)\"; ps -p 1 -o pid= 2>/dev/null || true"
    let command = RemoteShell.shCommand("ps -o pid= -p \"1,2\"")
    #expect(command == "/bin/sh -c 'ps -o pid= -p \"1,2\"'")
    for shell in loginShells {
        let result = try run(shell, RemoteShell.shCommand(ps))
        #expect(result.output.hasPrefix("uid="), "\(shell): \(result.output)")
    }
}

@Test func summaryReachesShByteForByte() throws {
    let summary = RemoteMetricCommands.summary(summaryCommand: RemoteMetricCommands.defaultGPUCommand)
    let command = RemoteShell.shCommand("cat <<'NVBEACON_EOF'\n\(summary)\nNVBEACON_EOF")
    #expect(!command.contains("\n") && !command.contains("\\\\") && !command.contains("\\'"))
    for shell in loginShells where hasSh {
        let result = try run(shell, command)
        #expect(result.output == summary + "\n", "\(shell)")
    }
}
