import Foundation
import NVBeaconCore
import Testing
@testable import NVBeaconWindowsKit

private var argvEcho: String {
    URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("ArgvEcho.exe").path
}

private func echoedArguments(_ arguments: [String]) async throws -> [String] {
    let output = try await WindowsProcessRunner.run(executable: argvEcho, arguments: arguments)
    #expect(output.exitCode == 0)
    return try JSONSerialization.jsonObject(with: Data(output.standardOutput)) as? [String] ?? []
}

@Test func quotingRoundTripsAwkwardArguments() async throws {
    let arguments = ["plain", "", "two words", #"quote"inside"#, #"trailing\"#, #"dir\ with\ spaces\"#,
                     #"\\server\share"#, #"a\\"b"#, "tab\tand\nnewline", "%PATH% ^&|<>", "한글 GPU"]
    #expect(try await echoedArguments(arguments) == arguments)
}

@Test func sshArgumentsReachTheChildByteForByte() async throws {
    let command = RemoteMetricCommands.summary(summaryCommand: RemoteMetricCommands.defaultGPUCommand)
    let arguments = SSHTransport.arguments(target: "gpu-box", remoteCommand: command)
    #expect(try await echoedArguments(arguments) == arguments)
}

@Test func remoteCommandMatchesTheMacOSEncoding() {
    let arguments = SSHTransport.arguments(target: "alice@gpu", remoteCommand: "echo 'hi'\nexit 0")
    #expect(arguments.contains("BatchMode=yes"))
    #expect(!arguments.contains { $0.hasPrefix("ControlMaster") })
    #expect(Array(arguments.suffix(4)) == [
        "alice@gpu", "/bin/sh", "-lc",
        #"'exec /bin/sh -c "$(printf '\''%b'\'' '\''echo \0047hi\0047\0012exit 0'\'')"'"#,
    ])
    #expect(SSHTransport.loginShellPortable("nvidia-smi -L") == "nvidia-smi -L")
}

@Test func targetsThatLookLikeOptionsAreRejected() {
    #expect(SSHTransport.isValidTarget("gpu-box"))
    #expect(SSHTransport.isValidTarget("alice@10.0.0.5"))
    #expect(!SSHTransport.isValidTarget("-oProxyCommand=calc"))
    #expect(!SSHTransport.isValidTarget("two words"))
    #expect(!SSHTransport.isValidTarget(""))
}

@Test func launchOptionsAndServerFile() throws {
    let options = try LaunchOptions.parse(["--interval", "5", "gpu-a", "--once", "bob@gpu-b"])
    #expect(options == LaunchOptions(targets: ["gpu-a", "bob@gpu-b"], interval: .seconds(5), once: true))
    #expect(throws: LaunchOptions.ParseError.invalidInterval("0")) { try LaunchOptions.parse(["--interval", "0"]) }
    #expect(throws: LaunchOptions.ParseError.invalidTarget("-v")) { try LaunchOptions.parse(["-v"]) }
    let file = "# comment\n  gpu-a  \n\nbob@gpu-b # trailing\n-bad\r\n"
    #expect(LaunchOptions.targets(fromServerFile: file) == ["gpu-a", "bob@gpu-b"])
}

@Test func runnerReportsExitCodesAndLaunchFailures() async throws {
    let cmd = (ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#) + #"\System32\cmd.exe"#
    let output = try await WindowsProcessRunner.run(executable: cmd, arguments: ["/c", "echo out& echo err 1>&2& exit 3"])
    #expect(output.exitCode == 3)
    #expect(String(decoding: output.standardOutput, as: UTF8.self).contains("out"))
    #expect(String(decoding: output.standardError, as: UTF8.self).contains("err"))
    await #expect(throws: ProcessRunError.self) {
        try await WindowsProcessRunner.run(executable: #"C:\does-not-exist\nope.exe"#, arguments: [])
    }
}

@Test func runnerEnforcesTimeoutAndOutputLimit() async throws {
    let powershell = (ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#)
        + #"\System32\WindowsPowerShell\v1.0\powershell.exe"#
    let started = ContinuousClock.now
    await #expect(throws: ProcessRunError.timedOut(seconds: 1)) {
        try await WindowsProcessRunner.run(executable: powershell, arguments: ["-NoProfile", "-Command", "Start-Sleep 30"],
                                           timeout: .seconds(1))
    }
    #expect(ContinuousClock.now - started < .seconds(10))
    await #expect(throws: ProcessRunError.outputLimitExceeded(bytes: 1000)) {
        try await WindowsProcessRunner.run(executable: powershell,
                                           arguments: ["-NoProfile", "-Command", "'x' * 100000"],
                                           outputLimit: 1000)
    }
}

@Test func cancellationTerminatesTheProcess() async throws {
    let powershell = (ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#)
        + #"\System32\WindowsPowerShell\v1.0\powershell.exe"#
    let started = ContinuousClock.now
    let task = Task {
        try await WindowsProcessRunner.run(executable: powershell, arguments: ["-NoProfile", "-Command", "Start-Sleep 30"])
    }
    try await Task.sleep(for: .milliseconds(500))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ContinuousClock.now - started < .seconds(10))
}

@Test func unreachableServerFailsWithSSHsMessage() async throws {
    // Port 1 on loopback refuses immediately, so this exercises ssh.exe without a server.
    let output = try await WindowsProcessRunner.run(
        executable: SSHTransport.defaultSSHExecutable,
        arguments: ["-p", "1"] + SSHTransport.arguments(target: "nobody@127.0.0.1", remoteCommand: "true")
    )
    #expect(output.exitCode == 255)
    #expect(String(decoding: output.standardError, as: UTF8.self).localizedCaseInsensitiveContains("refused"))
}

@Test func sshOctalEscapesAreDecoded() {
    #expect(SSHTransport.decodeStandardError(Array("plain C:\\Users\\x".utf8)) == "plain C:\\Users\\x")
    // "한" in UTF-8 is ED 95 9C.
    #expect(SSHTransport.decodeStandardError(Array("a \\355\\225\\234 b".utf8)) == "a 한 b")
    #expect(SSHTransport.decodeStandardError(Array("tail \\12".utf8)) == "tail \\12")
}

@Test func formatterSummaries() {
    let gpu = GPUReading(index: 0, name: "A100", uuid: "GPU-1", utilization: 45, memoryUsedMB: 12_288,
                         memoryTotalMB: 81_920, temperatureCelsius: 52, processes: [])
    var state = ServerState(target: "gpu-a")
    state.snapshot = GPUSnapshot(takenAt: Date(), gpus: [gpu])
    #expect(SummaryFormatter.gpuLine(gpu) == "GPU 0  45%  ·  12.0/80.0 GB  ·  52°C  ·  idle  —  A100")
    #expect(SummaryFormatter.compactLine(state) == "gpu-a: 45% · 12.0/80.0 GB")
    #expect(SummaryFormatter.tooltip(Array(repeating: state, count: 10)).count <= 127)
}
