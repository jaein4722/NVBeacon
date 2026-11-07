import Foundation
import Testing
@testable import NVBeacon

private func snapshot(at seconds: TimeInterval, utilization: Int) -> GPUSnapshot {
    GPUSnapshot(takenAt: Date(timeIntervalSince1970: seconds), gpus: [
        GPUReading(index: 0, name: "GPU", uuid: "GPU-0", utilization: utilization,
                   memoryUsedMB: 0, memoryTotalMB: 1000, temperatureCelsius: nil, processes: []),
    ])
}

@Test func pmonSumsByOwnerAndSkipsMissingSM() {
    let output = """
    # gpu         pid  type    sm   mem   enc   dec   command
    # Idx           #   C/G     %     %     %     %   name
        0         101     C    40    10     0     0   python
        0         102     C    20     5     0     0   python
        0         103     C     -     -     -     -   python
        1           -     -     -     -     -     -   -
    __NVBEACON_PMON_OWNERS__
      101 alice
      102 alice
      103 root
    """
    #expect(UserUtilizationSampler.parse(output) == [0: ["alice": 60]])
    #expect(UserUtilizationSampler.parse("nvidia-smi: command not found\n__NVBEACON_PMON_OWNERS__\n") == nil)
}

@Test func refreshesAccumulateIntoOneSamplePerMinute() {
    var pending = GPUHistorySample.accumulating(snapshot(at: 60, utilization: 20), users: nil, into: [])
    pending = GPUHistorySample.accumulating(snapshot(at: 90, utilization: 40), users: [0: ["alice": 30]], into: pending)
    #expect(pending.count == 1)
    #expect(pending[0].timestamp == Date(timeIntervalSince1970: 60))
    #expect(pending[0].totalUtilization == 30)
    #expect(pending[0].users == ["alice": 30])
}

@Test func archiveAppendsCompletedMinutesAndReloads() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let start = floor(now / 60) * 60 - 600

    let archive = GPUHistoryArchive(directory: directory)
    #expect(try await archive.record(snapshot(at: start, utilization: 10), users: nil, serverID: "s", fingerprint: "f") == nil)
    let afterFirstMinute = try await archive.record(snapshot(at: start + 60, utilization: 50), users: nil, serverID: "s", fingerprint: "f")
    #expect(afterFirstMinute?.map(\.totalUtilization) == [10])
    _ = try await archive.record(snapshot(at: start + 120, utilization: 70), users: nil, serverID: "s", fingerprint: "f")
    await archive.flush()

    let reloaded = try await GPUHistoryArchive(directory: directory).load(serverID: "s", fingerprint: "f")
    #expect(reloaded.map(\.totalUtilization) == [10, 50, 70])
    #expect(try await GPUHistoryArchive(directory: directory).load(serverID: "s", fingerprint: "other").isEmpty)
}
