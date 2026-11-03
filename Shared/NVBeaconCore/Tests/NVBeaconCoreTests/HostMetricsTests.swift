import Foundation
import Testing
@testable import NVBeaconCore

private let hostGPUCSV = "0, Fixture GPU, GPU-fixture, 20, 100, 1000, 40"

@Test func aggregateCPUUsageUsesOrdinaryPollsAndExcludesGuestDoubleCounting() throws {
    let start = Date(timeIntervalSince1970: 1000)
    let first = try #require(MetricsParser.parseHostCPUSample(
        "__NVBEACON_CPU_SECTION__\ncpu 100 0 100 800 0 0 0 0 100 0\nbtime 100", takenAt: start))
    let second = try #require(MetricsParser.parseHostCPUSample(
        "__NVBEACON_CPU_SECTION__\ncpu 150 0 110 840 0 0 0 0 150 0\nbtime 100", takenAt: start.addingTimeInterval(10)))
    #expect(first.total == 1000)
    #expect(second.total == 1100)
    #expect(CPUUsageEvaluator.usage(previous: first, current: second, maximumInterval: 60) == 60)
    #expect(CPUUsageEvaluator.usage(previous: nil, current: first, maximumInterval: 60) == nil)
}

@Test func CPUUsageResetsForRebootsCounterResetsAndUnusableIntervals() {
    let start = Date(timeIntervalSince1970: 1000)
    let previous = HostCPUSample(takenAt: start, total: 1000, idle: 800, bootTime: 100)
    let invalid = [
        HostCPUSample(takenAt: start.addingTimeInterval(10), total: 1100, idle: 840, bootTime: 200),
        HostCPUSample(takenAt: start.addingTimeInterval(10), total: 100, idle: 80, bootTime: 100),
        HostCPUSample(takenAt: start.addingTimeInterval(10), total: 1100, idle: 700, bootTime: 100),
        HostCPUSample(takenAt: start.addingTimeInterval(10), total: 1000, idle: 800, bootTime: 100),
        HostCPUSample(takenAt: start.addingTimeInterval(0.01), total: 1100, idle: 840, bootTime: 100),
        HostCPUSample(takenAt: start.addingTimeInterval(-10), total: 1100, idle: 840, bootTime: 100),
        HostCPUSample(takenAt: start.addingTimeInterval(3600), total: 1100, idle: 840, bootTime: 100),
    ]
    for current in invalid {
        #expect(CPUUsageEvaluator.usage(previous: previous, current: current, maximumInterval: 60) == nil)
    }
}

@Test(arguments: [
    "", "cpu 1 2 3", "cpu 1 broken 3 4", "cpu -1 2 3 4",
    "cpu 18446744073709551615 1 1 1", "cpu 1 2 3 4\ncpu 1 2 3 4",
    "cpu 1 2 3 4\nbtime invalid", "cpu 1 2 3 4\nbtime 100\nbtime 200"
]) func malformedCPUSamplesRemainOptional(_ text: String) {
    #expect(MetricsParser.parseHostCPUSample("__NVBEACON_CPU_SECTION__\n" + text, takenAt: Date()) == nil)
}

private actor HostFixtureTransport: RemoteCommandExecuting {
    let text: String
    var commands: [String] = []
    init(_ text: String) { self.text = text }
    func execute(_ command: String) -> RemoteCommandOutput {
        commands.append(command)
        return .init(standardOutput: text, standardError: "", exitStatus: 0)
    }
}

@Test func disabledHostCollectionIgnoresUnrequestedHostDataAndStillCollectsGPU() async throws {
    let output = hostGPUCSV + """

    __GPUUSAGE_PROCESS_SECTION__
    __NVBEACON_CPU_SECTION__
    cpu 100 0 100 800 0 0 0 0
    btime 100
    __NVBEACON_MEMORY_SECTION__
    MemTotal: 1000 kB
    MemAvailable: 250 kB
    __GPUUSAGE_NETWORK_SECTION__
    eth0 1000 2000
    """
    let transport = HostFixtureTransport(output)
    let snapshot = try await MetricsCollector(transport: transport).fetchSummary(hostMetrics: .none)
    #expect(snapshot.gpus.first?.utilization == 20)
    #expect(snapshot.hostMemory == nil)
    #expect(snapshot.hostCPU == nil)
    #expect(snapshot.hostCPUSample == nil)
    #expect(snapshot.networkSample == nil)
    let commands = await transport.commands
    #expect(commands.count == 1)
    #expect(!commands[0].contains("/proc/stat"))
    #expect(!commands[0].contains("/proc/meminfo"))
    #expect(!commands[0].contains("/sys/class/net"))
    #expect(!commands[0].contains("/proc/net/dev"))
}

@Test func selectedHostMetricsAreCollectedThroughOneTransportCommand() async throws {
    let output = hostGPUCSV + "\n__NVBEACON_CPU_SECTION__\ncpu 100 0 100 800 0 0 0 0\nbtime 100"
    let transport = HostFixtureTransport(output)
    let snapshot = try await MetricsCollector(transport: transport).fetchSummary(
        hostMetrics: HostMetricsOptions(cpu: true, memory: false, network: false))
    #expect(snapshot.hostCPUSample?.total == 1000)
    #expect(snapshot.hostCPUSample?.bootTime == 100)
    #expect(snapshot.hostCPU == nil)
    let commands = await transport.commands
    #expect(commands.count == 1)
    #expect(!commands[0].contains("sleep"))
}

@Test func hostCommandsRespectAllSelectionsWhenExecuted() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-host-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stub = root.appendingPathComponent("nvidia-smi")
    try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
    let stat = root.appendingPathComponent("cpu-stat")
    try "cpu 100 0 100 800 0 0 0 0\ncpu0 100 0 100 800\nbtime 100\n".write(to: stat, atomically: true, encoding: .utf8)
    let network = root.appendingPathComponent("sys/class/net/eth0/statistics")
    try FileManager.default.createDirectory(at: network, withIntermediateDirectories: true)
    try "1000\n".write(to: network.appendingPathComponent("rx_bytes"), atomically: true, encoding: .utf8)
    try "2000\n".write(to: network.appendingPathComponent("tx_bytes"), atomically: true, encoding: .utf8)
    let memoryMarker = root.appendingPathComponent("memory-was-read")
    let memoryCommand = "touch '\(memoryMarker.path)'; printf 'MemTotal: 1000 kB\\nMemAvailable: 250 kB\\n'"

    for mask in 0..<8 {
        try? FileManager.default.removeItem(at: memoryMarker)
        let options = HostMetricsOptions(cpu: mask & 1 != 0, memory: mask & 2 != 0, network: mask & 4 != 0)
        let command = RemoteMetricCommands.summary(summaryCommand: "printf '\(hostGPUCSV)\\n'",
                                                  memoryCommand: memoryCommand, hostMetrics: options)
            .replacingOccurrences(of: "/proc/stat", with: stat.path)
            .replacingOccurrences(of: "/sys/class/net/", with: root.appendingPathComponent("sys/class/net").path + "/")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": root.path + ":/usr/bin:/bin"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try MetricsParser.parseSnapshot(output).first?.utilization == 20)
        #expect((MetricsParser.parseHostCPUSample(output, takenAt: Date()) != nil) == options.cpu)
        #expect((MetricsParser.parseHostMemory(output) != nil) == options.memory)
        #expect(FileManager.default.fileExists(atPath: memoryMarker.path) == options.memory)
        #expect(!MetricsParser.parseNetworkSection(MetricsParser.networkSection(output)).isEmpty == options.network)
    }
}
