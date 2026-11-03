import Foundation
import Testing
@testable import NVBeaconCore

private let hostCommandFixture = """
if [ "$NVBEACON_COLLECT_CPU" = "1" ]; then
  printf '__NVBEACON_CPU_SECTION__\\ncpu 100 0 100 800 0 0 0 0\\nbtime 100\\n'
fi
if [ "$NVBEACON_COLLECT_MEMORY" = "1" ]; then
  printf '__NVBEACON_MEMORY_SECTION__\\nMemTotal: 1000 kB\\nMemAvailable: 250 kB\\nSwapTotal: 0 kB\\nSwapFree: 0 kB\\n'
fi
if [ "$NVBEACON_COLLECT_NETWORK" = "1" ]; then
  printf '__GPUUSAGE_NETWORK_SECTION__\\nfixture0 1000 2000\\n'
fi
"""

private actor HostCommandTransport: RemoteCommandExecuting {
    let path: String
    var commands: [String] = []
    init(path: String) { self.path = path }

    func execute(_ command: String) throws -> RemoteCommandOutput {
        commands.append(command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": path + ":/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return .init(standardOutput: text, standardError: "", exitStatus: process.terminationStatus)
    }
}

@Test func customHostCommandControlsAllMetricsAndHonorsEveryCollectionChoice() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-host-command-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stub = root.appendingPathComponent("nvidia-smi")
    try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
    let gpu = "printf '0, Fixture GPU, GPU-fixture, 20, 100, 1000, 40\\n'"
    for mask in 0..<8 {
        let options = HostMetricsOptions(cpu: mask & 1 != 0, memory: mask & 2 != 0, network: mask & 4 != 0)
        let transport = HostCommandTransport(path: root.path)
        let snapshot = try await MetricsCollector(transport: transport).fetchSummary(
            gpuCommand: gpu, hostMetrics: options, hostCommand: hostCommandFixture)
        #expect(snapshot.gpus.first?.utilization == 20)
        #expect((snapshot.hostCPUSample?.total == 1000) == options.cpu)
        #expect((snapshot.hostMemory?.usedKiB == 750) == options.memory)
        #expect((snapshot.networkSample?.interfaces.first?.name == "fixture0") == options.network)
        #expect(await transport.commands.count == 1)
        let command = try #require(await transport.commands.first)
        #expect(!command.contains("/proc/stat"))
        #expect(!command.contains("/proc/meminfo"))
        #expect(!command.contains("/sys/class/net"))
    }
}

@Test func failedOrMalformedHostCommandCannotContaminateGPUProcessParsing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-host-failure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stub = root.appendingPathComponent("nvidia-smi")
    try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
    for hostCommand in ["exit 13", "printf 'unrecognized host output\\n'", "printf 'unrecognized host output\\n'; exit 13", "if", "printf '"] {
        let transport = HostCommandTransport(path: root.path)
        let snapshot = try await MetricsCollector(transport: transport).fetchSummary(
            gpuCommand: "printf '0, Fixture GPU, GPU-fixture, 20, 100, 1000, 40\\n'", hostCommand: hostCommand)
        #expect(snapshot.gpus.count == 1)
        #expect(snapshot.gpus[0].processes.isEmpty)
        #expect(snapshot.hostMemory == nil)
        #expect(snapshot.hostCPUSample == nil)
        #expect(snapshot.networkSample == nil)
    }
}

@Test func disabledHostCollectionNeverRunsEvenACustomCommandWithoutGuards() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-host-off-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let marker = root.appendingPathComponent("host-command-ran")
    let command = RemoteMetricCommands.summary(summaryCommand: ":", hostMetrics: .none,
                                               hostCommand: "touch '\(marker.path)'")
    let transport = HostCommandTransport(path: root.path)
    let output = try await transport.execute(command)
    #expect(output.exitStatus == 0)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}
