import Foundation
import Testing
@testable import NVBeacon

@Test func memoryCommandUpgradePreservesExistingServerSettings() throws {
    let original = AppSettings(servers: [ServerConfig(
        id: "fixture", name: "Fixture server", sshTarget: "gpu.example.invalid",
        remoteCommand: "/opt/nvidia/bin/nvidia-smi --query-gpu=custom"
    )])
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    json.removeValue(forKey: "memoryCommand")
    var servers = try #require(json["servers"] as? [[String: Any]])
    servers[0].removeValue(forKey: "memoryCommand")
    json["servers"] = servers

    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json)).normalized()
    #expect(decoded.servers.count == 1)
    #expect(decoded.servers[0].id == original.servers[0].id)
    #expect(decoded.servers[0].remoteCommand == original.servers[0].remoteCommand)
    #expect(decoded.servers[0].memoryCommand == AppSettings.defaultMemoryCommand)
}

@Test func memoryCommandsPersistAndFollowTheSelectedServer() throws {
    let first = ServerConfig(id: "first", sshTarget: "first.example.invalid", memoryCommand: "cat /host/proc/meminfo")
    let second = ServerConfig(id: "second", sshTarget: "second.example.invalid", memoryCommand: " /opt/bin/memory-report ")
    let original = AppSettings(servers: [first, second]).normalized()
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
    #expect(decoded == original)
    #expect(decoded.memoryCommand == first.memoryCommand)
    let selected = decoded.servers[1].connectionSettings(from: decoded).normalized()
    #expect(selected.sshTarget == second.sshTarget)
    #expect(selected.memoryCommand == "/opt/bin/memory-report")
    #expect(selected.remoteCommand == second.remoteCommand)
    #expect(ServerConfig(memoryCommand: " \n ").normalized().memoryCommand == AppSettings.defaultMemoryCommand)
    let legacy = AppSettings(sshTarget: "legacy.example.invalid", memoryCommand: "cat /host/proc/meminfo").normalized()
    #expect(legacy.servers.first?.memoryCommand == "cat /host/proc/meminfo")
}

@Test func customMemoryCommandIsParsedAndFailureDoesNotFailGPUQuery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-command-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stub = directory.appendingPathComponent("nvidia-smi")
    try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)

    for memoryCommand in ["printf 'MemTotal: 1000 kB\\nMemAvailable: 250 kB\\n'", "exit 13"] {
        let command = SSHMetricsFetcher.buildSummaryRemoteCommand(
            summaryCommand: "printf '0, Fixture GPU, GPU-fixture, 42, 100, 1000, 45\\n'",
            memoryCommand: memoryCommand
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": directory.path + ":/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(try SSHMetricsFetcher.parseSnapshot(text).first?.utilization == 42)
        if memoryCommand == "exit 13" {
            #expect(SSHMetricsFetcher.parseHostMemory(text) == nil)
        } else {
            #expect(SSHMetricsFetcher.parseHostMemory(text)?.usagePercent == 75)
        }
    }
}

@Test func memorySectionDoesNotContaminateGPUOrProcessParsing() throws {
    let output = """
    0, NVIDIA Test GPU, GPU-111, 50, 24576, 32768, 60
    __GPUUSAGE_PROCESS_SECTION__
    GPU-111, 1001, 501, python, 24576
    __NVBEACON_MEMORY_SECTION__
    MemTotal:       67108864 kB
    MemFree:          524288 kB
    MemAvailable:   16777216 kB
    Cached:         12582912 kB
    SwapTotal:       8388608 kB
    SwapFree:        6291456 kB
    __GPUUSAGE_PS_SECTION__
    1001 alice python train.py
    """

    let gpus = try SSHMetricsFetcher.parseSnapshot(output)
    let memory = try #require(SSHMetricsFetcher.parseHostMemory(output))
    #expect(gpus.count == 1)
    #expect(gpus[0].processes.first?.user == "alice")
    #expect(memory.usedKiB == 50331648)
    #expect(memory.availableKiB == 16777216)
    #expect(memory.usagePercent == 75)
    #expect(memory.usageRatio == 0.75)
    #expect(memory.swapUsedKiB == 2097152)
    #expect(memory.swapUsageRatio == 0.25)
    #expect(HostMemoryReading.capacityText(kibibytes: memory.totalKiB) == "64.0 GiB")
}

@Test(arguments: [
    "",
    "MemTotal: 100 kB\nMemFree: 20 kB",
    "MemTotal: 0 kB\nMemAvailable: 0 kB",
    "MemTotal: 100 kB\nMemAvailable: 101 kB",
    "MemTotal: 100 kB\nMemAvailable: -1 kB",
    "MemTotal: 100 kB\nMemAvailable: unknown kB",
    "MemTotal: 100 MB\nMemAvailable: 50 MB",
    "MemTotal: 100 kB\nMemAvailable: 50 kB\nMemAvailable: 30 kB"
]) func unavailableMemoryDoesNotInterruptGPUMonitoring(_ meminfo: String) throws {
    let output = """
    0, NVIDIA Test GPU, GPU-111, 50, 24576, 32768, 60
    __GPUUSAGE_PROCESS_SECTION__
    __NVBEACON_MEMORY_SECTION__
    \(meminfo)
    """
    #expect(SSHMetricsFetcher.parseHostMemory(output) == nil)
    #expect(try SSHMetricsFetcher.parseSnapshot(output).count == 1)
}

@Test func oldSnapshotWithoutMemorySectionStillParses() throws {
    let output = "0, NVIDIA Test GPU, GPU-111, 50, 24576, 32768, 60"
    #expect(SSHMetricsFetcher.parseHostMemory(output) == nil)
    #expect(try SSHMetricsFetcher.parseSnapshot(output).count == 1)
}

@Test(arguments: [
    ("SwapTotal: 0 kB\nSwapFree: 0 kB", Optional(0)),
    ("SwapTotal: 100 kB\nSwapFree: 0 kB", Optional(100)),
    ("SwapTotal: 100 kB\nSwapFree: 101 kB", nil),
    ("SwapTotal: 100 kB\nSwapFree: -1 kB", nil),
    ("SwapTotal: 100 kB\nSwapFree: unknown kB", nil),
    ("SwapTotal: 100 kB", nil),
    ("", nil)
]) func swapHandlesDisabledFullAndUnavailableData(_ swap: String, _ expectedUsed: Int?) throws {
    let output = """
    __NVBEACON_MEMORY_SECTION__
    MemTotal: 1000 kB
    MemAvailable: 200 kB
    \(swap)
    """
    let memory = try #require(SSHMetricsFetcher.parseHostMemory(output))
    #expect(memory.swapUsedKiB == expectedUsed)
    #expect(memory.usagePercent == 80)
    if expectedUsed == 0 {
        #expect(memory.swapUsageRatio == 0)
    }
}
