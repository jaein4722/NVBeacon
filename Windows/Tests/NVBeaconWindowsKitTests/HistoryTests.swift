import Foundation
import NVBeaconCore
import Testing
@testable import NVBeaconWindowsKit

private func snapshot(at seconds: TimeInterval, utilization: Int) -> GPUSnapshot {
    GPUSnapshot(takenAt: Date(timeIntervalSince1970: seconds),
                gpus: [GPUReading(index: 0, name: "Fixture", uuid: "GPU-0", utilization: utilization, memoryUsedMB: 0,
                                  memoryTotalMB: 1000, temperatureCelsius: nil, processes: [])])
}

@Test func pmonOutputParsesPerUserSM() {
    let output = """
    # gpu         pid   type     sm    mem    enc    dec    command
    # Idx           #    C/G      %      %      %      %    name
        0      1234     C     40     10      -      -    python
        0      5678     C     15      3      -      -    python
        1      9999     C      -      -      -      -    python
        1      4321     C     70     30      -      -    torchrun

    __NVBEACON_PMON_OWNERS__
    1234 alice
    5678 alice
    4321 bob
    """
    let users = UserUtilizationSampler.parse(output)
    #expect(users == [0: ["alice": 55], 1: ["bob": 70]])
    #expect(UserUtilizationSampler.parse("nvidia-smi: command not found") == nil)
}

@Test func minutesAccumulateAndArchiveRoundTrips() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-history-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let archive = GPUHistoryArchive(directory: folder)
    // A whole minute shortly before now: the archive prunes files older than 24 hours.
    let base = floor(Date().timeIntervalSince1970 / 60) * 60 - 600
    #expect(try await archive.record(snapshot(at: base + 1, utilization: 20), users: [0: ["alice": 10]], serverID: "s", fingerprint: "f") == false)
    #expect(try await archive.record(snapshot(at: base + 31, utilization: 40), users: nil, serverID: "s", fingerprint: "f") == false)
    // The next minute completes the first one.
    #expect(try await archive.record(snapshot(at: base + 61, utilization: 80), users: nil, serverID: "s", fingerprint: "f") == true)
    let saved = await archive.samples(serverID: "s", fingerprint: "f", now: Date(timeIntervalSince1970: base + 70))
    #expect(saved.count == 1)
    #expect(saved[0].totalUtilization == 30)
    #expect(saved[0].users == ["alice": 10])

    await archive.flush(now: Date(timeIntervalSince1970: base + 70))
    let reloaded = GPUHistoryArchive(directory: folder)
    let loaded = await reloaded.samples(serverID: "s", fingerprint: "f", now: Date(timeIntervalSince1970: base + 120))
    #expect(loaded.map(\.totalUtilization) == [30, 80])
    #expect(await reloaded.samples(serverID: "s", fingerprint: "other", now: Date(timeIntervalSince1970: base + 120)).isEmpty)
}

@Test func plotSplitsOfflineGapsAndStacksUsers() {
    let base: TimeInterval = 1_800_000_000
    var samples: [GPUHistorySample] = []
    for minute in 0..<5 {
        samples.append(GPUHistorySample(timestamp: Date(timeIntervalSince1970: base + Double(minute) * 60), gpuIndex: 0, gpuUUID: "GPU-0",
                                        totalSum: 50, sampleCount: 1, users: ["alice": 20, "bob": 30]))
    }
    // Ten minutes offline, then one more sample.
    samples.append(GPUHistorySample(timestamp: Date(timeIntervalSince1970: base + 900), gpuIndex: 0, gpuUUID: "GPU-0",
                                    totalSum: 10, sampleCount: 1, users: nil))
    let data = GPUHistoryRenderData(samples: samples, hours: 1, now: Date(timeIntervalSince1970: base + 960), pollInterval: 10)
    #expect(data.users == ["alice", "bob"])
    #expect(Set(data.total.map(\.segment)) == [0, 1])
    let first = data.areas.filter { $0.time == base * 1000 }
    #expect(first.map(\.user) == ["alice", "bob"])
    #expect(first.map(\.upper) == [20, 50])
    #expect(data.readings.last?.users == nil)
    #expect(data.maximumY == 100)
    #expect(GPUHistoryPlot.rollupMinutes(hours: 24) == 12)
}
