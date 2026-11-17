import Foundation
import Testing
@testable import NVBeaconCore

private let hasSh = FileManager.default.isExecutableFile(atPath: "/bin/sh")

/// Runs the summary like sshd would: a login shell whose rc file prints a banner.
private actor BannerTransport: RemoteCommandExecuting {
    let path: String
    let shell: String
    init(path: String, shell: String) { self.path = path; self.shell = shell }

    func execute(_ command: String) throws -> RemoteCommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", "echo 'Welcome to the cluster, 4 GPUs free'; " + RemoteShell.shCommand(command)]
        process.standardInput = FileHandle.nullDevice
        process.environment = ["PATH": path + ":/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return .init(standardOutput: text, standardError: "", exitStatus: process.terminationStatus)
    }
}

@Test(.enabled(if: hasSh)) func summaryKeepsProcessesWithHiddenProcEntriesAndSkipsProfileText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-summary-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stub = root.appendingPathComponent("nvidia-smi")
    // PID 2147483646 has no /proc entry anywhere, like a process hidden by hidepid
    // or one from another PID namespace. "[N/A]" is what some drivers print.
    try """
    #!/bin/sh
    case "$*" in
      *--query-compute-apps*) printf 'GPU-a, 2147483646, python, 512\\nGPU-a, [N/A], [N/A], [N/A]\\n' ;;
      *) printf '0, Fixture GPU, GPU-a, 30, 600, 1000, 40\\n' ;;
    esac
    """.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)

    let shells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/tcsh", "/opt/homebrew/bin/fish", "/usr/bin/fish"]
        .filter { FileManager.default.isExecutableFile(atPath: $0) }
    for shell in shells {
        let snapshot = try await MetricsCollector(transport: BannerTransport(path: root.path, shell: shell))
            .fetchSummary(hostMetrics: .init(cpu: false, memory: false, network: false))
        let gpu = try #require(snapshot.gpus.first, "\(shell)")
        #expect(gpu.utilization == 30)
        #expect(gpu.processes.map(\.pid) == [2147483646], "\(shell)")
        #expect(gpu.processes.first?.userID == nil)
        #expect(gpu.processes.first?.usedGPUMemoryMB == 512)
    }
}

@Test func psSectionsIgnoreLoginProfileText() throws {
    let output = """
    Welcome to Ubuntu 22.04 LTS
      * Documentation: https://help.ubuntu.com
      123  1000 alice  python train.py
    """
    let detailed = try MetricsParser.parseDetailedPSSection(output)
    #expect(detailed.map(\.pid) == [123])
    #expect(detailed.first?.userID == 1000)
    let plain = try MetricsParser.parsePSSection("Last login: Mon\n  123 alice python\n")
    #expect(plain.map(\.user) == ["alice"])
}
