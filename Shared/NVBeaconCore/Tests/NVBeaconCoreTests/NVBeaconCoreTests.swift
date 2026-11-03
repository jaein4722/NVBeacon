import Foundation
import Testing
@testable import NVBeaconCore

private let gpuCSV = "0, NVIDIA Fixture, GPU-fixture, 50, 100, 1000, 45"

@Test func parsesCurrentAndLegacyGPUFormats() throws {
    let current = try MetricsParser.parse(gpuCSV)
    #expect(current[0].uuid == "GPU-fixture")
    #expect(current[0].memoryUsagePercent == 10)
    #expect(current[0].utilization == 50)
    let legacy = try MetricsParser.parse("0, NVIDIA Fixture, 20, 10, 1000, N/A")
    #expect(legacy[0].uuid == nil)
    #expect(legacy[0].temperatureCelsius == nil)
    let unavailable = try MetricsParser.parse("0, NVIDIA Fixture, GPU-fixture, N/A, N/A, N/A, N/A")
    #expect(unavailable[0].memoryTotalMB == 0)
}

@Test func memoryParserKeepsInvalidDataOptional() throws {
    let output = RemoteMetricCommands.memorySectionSeparator + "\nMemTotal: 1000 kB\nMemAvailable: 250 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB"
    let memory = try #require(MetricsParser.parseHostMemory(output))
    #expect(memory.usedKiB == 750)
    #expect(memory.usagePercent == 75)
    #expect(memory.swapUsedKiB == 0)
    #expect(MetricsParser.parseHostMemory(output.replacingOccurrences(of: "250", with: "1001")) == nil)
    #expect(MetricsParser.parseHostMemory("") == nil)
}

@Test func duplicateProcessStatusRowsUseTheLastReadingWithoutTrapping() throws {
    let output = gpuCSV + "\n" + RemoteMetricCommands.processSectionSeparator
        + "\nGPU-fixture, 101, python, 100\n"
        + RemoteMetricCommands.psSectionSeparator + "\n101 first old-command\n101 last new-command"
    let gpu = try #require(MetricsParser.parseSnapshot(output).first)
    #expect(gpu.processes[0].user == "last")
    #expect(gpu.processes[0].commandLine == "new-command")
}

@Test func metadataMergingPreservesTheNewMemoryReadingAndSampleTime() {
    let process = GPUProcessReading(gpuUUID: "GPU-fixture", pid: 101, processName: "python",
                                    usedGPUMemoryMB: 100, user: "fixture", commandLine: "python fixture.py")
    let gpu = GPUReading(index: 0, name: "Fixture", uuid: "GPU-fixture", utilization: 50,
                         memoryUsedMB: 100, memoryTotalMB: 1000, temperatureCelsius: 40,
                         processes: [process, process])
    let memory = HostMemoryReading(totalKiB: 1000, availableKiB: 250, swapTotalKiB: 0, swapFreeKiB: 0)
    let old = GPUSnapshot(takenAt: Date(timeIntervalSince1970: 10), gpus: [gpu])
    let cpu = HostCPUSample(takenAt: Date(timeIntervalSince1970: 20), total: 1000, idle: 800, bootTime: 100)
    let network = NetworkSample(takenAt: cpu.takenAt, interfaces: [.init(name: "eth0", receivedBytes: 1000, transmittedBytes: 2000)])
    let current = GPUSnapshot(takenAt: cpu.takenAt, gpus: [gpu], hostMemory: memory,
                              hostCPU: 20, networkSample: network, hostCPUSample: cpu)
    let merged = current.mergingResolvedProcessMetadata(from: old)
    #expect(merged.hostMemory == memory)
    #expect(merged.takenAt == current.takenAt)
    #expect(merged.applyingResolvedProcessMetadata([process, process]).hostMemory == memory)
    #expect(merged.hostCPUSample == cpu)
    #expect(merged.networkSample == network)
    let resolved = merged.applyingResolvedProcessMetadata([process, process])
    #expect(resolved.hostCPU == 20)
    #expect(resolved.hostCPUSample == cpu)
    #expect(resolved.networkSample == network)
}

@Test func portableDataFormatDoesNotResolveLocalSSHPathsOrAliases() throws {
    let entry = ServerSettingsBackup.Entry(
        name: "Fixture", sshTarget: "fixture-alias", sshPort: "2222",
        sshIdentityFilePath: "~/.ssh/fixture",
        sshAuthenticationMode: .keyBased, sshConnectionReuseMode: .reuseWhenPossible,
        remoteCommand: RemoteMetricCommands.defaultGPUCommand, memoryCommand: RemoteMetricCommands.defaultMemoryCommand
    )
    let original = ServerSettingsBackup(servers: [entry])
    let loaded = try ServerSettingsBackup.decode(original.encoded())
    #expect(loaded == original)
    #expect(loaded.servers[0].sshIdentityFilePath == "~/.ssh/fixture")
    #expect(loaded.servers[0].sshTarget == "fixture-alias")
}

@Test func malformedOutputAndUnknownBackupVersionsRemainTypedErrors() throws {
    #expect(throws: MetricsParseError.emptyResponse) { try MetricsParser.parse("") }
    #expect(throws: MetricsParseError.invalidOutput("not GPU CSV")) { try MetricsParser.parse("not GPU CSV") }
    #expect(throws: ServerSettingsBackup.BackupError.unsupportedFormat) {
        try ServerSettingsBackup.decode(Data("{\"format\":\"NVBeacon.servers\",\"version\":999,\"servers\":[]}".utf8))
    }
}

private actor FixtureTransport: RemoteCommandExecuting {
    let output: RemoteCommandOutput
    var commands: [String] = []
    init(_ output: RemoteCommandOutput) { self.output = output }
    func execute(_ command: String) async throws -> RemoteCommandOutput {
        commands.append(command)
        return output
    }
}

@Test func sharedCollectorUsesTheInjectedTransportAndCustomCommands() async throws {
    let text = gpuCSV + "\n" + RemoteMetricCommands.memorySectionSeparator + "\nMemTotal: 1000 kB\nMemAvailable: 250 kB"
    let transport = FixtureTransport(.init(standardOutput: text, standardError: "", exitStatus: 0))
    let collector = MetricsCollector(transport: transport)
    let snapshot = try await collector.fetchSummary(gpuCommand: "/opt/bin/gpu-query", memoryCommand: "cat /host/proc/meminfo")
    #expect(snapshot.gpus.count == 1)
    #expect(snapshot.hostMemory?.usedKiB == 750)
    let commands = await transport.commands
    #expect(commands.count == 1)
    #expect(commands[0].contains("/opt/bin/gpu-query"))
    #expect(commands[0].contains("cat /host/proc/meminfo"))
}

@Test func collectorPreservesRemoteFailures() async {
    let transport = FixtureTransport(.init(standardOutput: "", standardError: "fixture failure", exitStatus: 7))
    await #expect(throws: MetricsCollectionError.commandFailed(7, "fixture failure")) {
        try await MetricsCollector(transport: transport).fetchSummary()
    }
}

@Test func alreadyCancelledCollectionDoesNotSendACommand() async {
    let transport = FixtureTransport(.init(standardOutput: gpuCSV, standardError: "", exitStatus: 0))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await MetricsCollector(transport: transport).fetchSummary()
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await transport.commands.isEmpty)
}

private struct CancellingTransport: RemoteCommandExecuting {
    func execute(_ command: String) async throws -> RemoteCommandOutput {
        withUnsafeCurrentTask { $0?.cancel() }
        return .init(standardOutput: gpuCSV, standardError: "", exitStatus: 0)
    }
}

@Test func collectorDoesNotPublishDataAfterCancellationDuringTransport() async {
    let task = Task { try await MetricsCollector(transport: CancellingTransport()).fetchSummary() }
    await #expect(throws: CancellationError.self) { try await task.value }
}
