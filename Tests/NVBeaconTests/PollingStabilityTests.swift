import Foundation
import Testing
@testable import NVBeacon

private actor RefreshLog {
    private(set) var counts: [String: Int] = [:]
    func record(_ serverID: String) { counts[serverID, default: 0] += 1 }
    func count(_ serverID: String) -> Int { counts[serverID, default: 0] }
}

@Test func aSlowServerDoesNotDelayOtherServers() async throws {
    let log = RefreshLog()
    let polling = Task {
        await PerServerPolling.run(
            serverIDs: ["slow", "fast"],
            interval: { .milliseconds(10) },
            refresh: { serverID in
                await log.record(serverID)
                // Like a server that hangs until the 15 s SSH timeout.
                if serverID == "slow" { try? await Task.sleep(for: .seconds(30)) }
            }
        )
    }
    try await Task.sleep(for: .milliseconds(400))
    polling.cancel()
    await polling.value

    #expect(await log.count("slow") == 1)
    #expect(await log.count("fast") >= 5)
}

@Test func cancellingPollingStopsEveryServerLoop() async throws {
    let log = RefreshLog()
    let polling = Task {
        await PerServerPolling.run(
            serverIDs: ["a", "b"],
            interval: { .milliseconds(10) },
            refresh: { await log.record($0) }
        )
    }
    try await Task.sleep(for: .milliseconds(100))
    polling.cancel()
    await polling.value
    let afterCancel = (await log.count("a"), await log.count("b"))

    try await Task.sleep(for: .milliseconds(100))
    #expect(await log.count("a") == afterCancel.0)
    #expect(await log.count("b") == afterCancel.1)
    #expect(afterCancel.0 > 0 && afterCancel.1 > 0)
}

@Test func idleStretchRestartsAfterAGapInSamples() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let gap = GPUIdleWatchTrackingState.maximumSampleGap(pollIntervalSeconds: 10)
    #expect(gap == 120)
    var state = GPUIdleWatchTrackingState()

    #expect(state.record(isIdle: true, at: start, maximumGap: gap) == 0)
    #expect(state.record(isIdle: true, at: start.addingTimeInterval(10), maximumGap: gap) == 10)
    #expect(state.record(isIdle: true, at: start.addingTimeInterval(20), maximumGap: gap) == 20)

    // An hour asleep: the GPU was not observed, so the stretch starts again.
    #expect(state.record(isIdle: true, at: start.addingTimeInterval(3_620), maximumGap: gap) == 0)
    #expect(state.record(isIdle: true, at: start.addingTimeInterval(3_630), maximumGap: gap) == 10)

    // Busy resets the stretch and the alert state.
    state.hasHandledCurrentIdleStretch = true
    #expect(state.record(isIdle: false, at: start.addingTimeInterval(3_640), maximumGap: gap) == nil)
    #expect(state.idleSince == nil)
    #expect(state.hasHandledCurrentIdleStretch == false)
}

@Test func anAlertAlreadySentIsNotRepeatedAfterAGap() {
    let start = Date(timeIntervalSince1970: 2_000_000)
    var state = GPUIdleWatchTrackingState()
    _ = state.record(isIdle: true, at: start, maximumGap: 120)
    state.hasHandledCurrentIdleStretch = true
    _ = state.record(isIdle: true, at: start.addingTimeInterval(3_600), maximumGap: 120)
    #expect(state.hasHandledCurrentIdleStretch)
}

@Test func lateProcessDetailsDoNotReplaceANewerProcessList() {
    func process(_ pid: Int, user: String? = nil, command: String? = nil) -> GPUProcessReading {
        GPUProcessReading(gpuUUID: "GPU-1", pid: pid, processName: "python", usedGPUMemoryMB: 1_000,
                          user: user, commandLine: command)
    }
    func snapshot(_ processes: [GPUProcessReading]) -> GPUSnapshot {
        GPUSnapshot(takenAt: Date(), gpus: [
            GPUReading(index: 0, name: "GPU", uuid: "GPU-1", utilization: 50, memoryUsedMB: 2_000,
                       memoryTotalMB: 80_000, temperatureCelsius: 50, processes: processes),
        ])
    }

    // Details were requested for 100 and 200; meanwhile a poll saw 200 exit and 300 start.
    let newer = snapshot([process(100), process(300)])
    let lateDetails = [process(100, user: "alice", command: "train.py"), process(200, user: "bob", command: "old.py")]
    let merged = newer.applyingResolvedProcessMetadata(lateDetails)

    #expect(merged.gpus[0].processes.map(\.pid) == [100, 300])
    #expect(merged.gpus[0].processes[0].user == "alice")
    #expect(merged.gpus[0].processes[1].user == nil)
}

@Test func staleDataIsOlderThanTwoIntervalsPlusTheTimeout() {
    let now = Date(timeIntervalSince1970: 3_000_000)
    // 10 s interval: 2 × 10 + 15 = 35 s.
    #expect(!NVBeaconStore.isSnapshotStale(takenAt: now.addingTimeInterval(-35), now: now, pollIntervalSeconds: 10))
    #expect(NVBeaconStore.isSnapshotStale(takenAt: now.addingTimeInterval(-36), now: now, pollIntervalSeconds: 10))
    #expect(!NVBeaconStore.isSnapshotStale(takenAt: now.addingTimeInterval(-600), now: now, pollIntervalSeconds: 300))
}

@Test func staleAgeTextIsShort() {
    #expect(StatusMenuView.ageText(42, language: .english) == "42s")
    #expect(StatusMenuView.ageText(185, language: .english) == "3m")
    #expect(StatusMenuView.ageText(185, language: .korean) == "3분")
    #expect(StatusMenuView.ageText(3_900, language: .korean) == "1시간 5분")
}
