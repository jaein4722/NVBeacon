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

/// Quitting saves the partial minute; a relaunch in that same minute starts it again.
/// Before 0.8.1 both lines were kept, and the chart trapped on the duplicate user key.
@Test func relaunchWithinOneMinuteKeepsOneSamplePerMinute() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = floor(Date().timeIntervalSince1970 / 60) * 60 - 600

    let beforeQuit = GPUHistoryArchive(directory: directory)
    _ = try await beforeQuit.record(snapshot(at: start, utilization: 20), users: [0: ["alice": 20]], serverID: "s", fingerprint: "f")
    await beforeQuit.flush(now: Date(timeIntervalSince1970: start + 10))

    let relaunched = GPUHistoryArchive(directory: directory)
    _ = try await relaunched.record(snapshot(at: start + 30, utilization: 40), users: [0: ["alice": 40]], serverID: "s", fingerprint: "f")
    let committed = try await relaunched.record(snapshot(at: start + 60, utilization: 0), users: nil, serverID: "s", fingerprint: "f")
    #expect(committed?.count == 1)

    let reloaded = try await GPUHistoryArchive(directory: directory).load(serverID: "s", fingerprint: "f")
    #expect(reloaded.count == 1)
    #expect(reloaded.first?.sampleCount == 2)
    #expect(reloaded.first?.totalUtilization == 30)
    #expect(reloaded.first?.users == ["alice": 40])
    _ = GPUHistoryRenderData(samples: reloaded, hours: 1, now: Date(), pollInterval: 10)
}

/// Files written by 0.8.0 may already hold the same minute twice.
@Test func chartToleratesDuplicateMinutesFromOlderFiles() {
    let minute = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60 - 300)
    let sample = GPUHistorySample(timestamp: minute, gpuIndex: 0, gpuUUID: "GPU-0", totalSum: 50, sampleCount: 1, users: ["alice": 50])
    let render = GPUHistoryRenderData(samples: [sample, sample], hours: 1, now: Date(), pollInterval: 10)
    #expect(render.samples.count == 1)
    #expect(GPUHistorySample.merged([sample, sample]).first?.sampleCount == 2)
}
