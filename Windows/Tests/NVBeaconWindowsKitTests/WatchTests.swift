import Foundation
import NVBeaconCore
import Testing
@testable import NVBeaconWindowsKit

private func gpu(_ index: Int, util: Int, memory: Int, processes: [GPUProcessReading] = []) -> GPUReading {
    GPUReading(index: index, name: "Fixture", uuid: "GPU-\(index)", utilization: util, memoryUsedMB: memory,
               memoryTotalMB: 1000, temperatureCelsius: 40, processes: processes)
}

private func process(_ pid: Int, gpu index: Int = 0) -> GPUProcessReading {
    GPUProcessReading(gpuUUID: "GPU-\(index)", pid: pid, processName: "python", usedGPUMemoryMB: 100,
                      user: "alice", commandLine: "python train.py")
}

/// Answers the ps lookup with the given running pids.
private struct PSFixture: RemoteCommandExecuting {
    let running: [Int]
    func execute(_ command: String) async throws -> RemoteCommandOutput {
        #expect(command.hasPrefix(#"ps -o pid= -o user= -o args= -p ""#))
        let lines = running.map { "\($0) alice python train.py" }
        return RemoteCommandOutput(standardOutput: lines.joined(separator: "\n"), standardError: "", exitStatus: 0)
    }
}

@Test func idleWatchNotifiesOncePerIdleStretch() async {
    let store = WatchStore(fileURL: nil)
    let server = ServerSettings(name: "Lab", sshTarget: "lab")
    var settings = WindowsSettings()
    settings.idleNotificationSeconds = 60
    let transport = AnyRemoteCommandExecutor(PSFixture(running: []))
    let start = Date(timeIntervalSince1970: 1_000)

    #expect(store.toggleIdleWatch(gpu: gpu(0, util: 50, memory: 500), server: server, snapshotTakenAt: start,
                                  idleSeconds: 60, memoryThresholdMB: 50))
    func poll(_ offset: TimeInterval, util: Int, memory: Int) async -> [PendingNotification] {
        await store.evaluate(snapshot: GPUSnapshot(takenAt: start.addingTimeInterval(offset), gpus: [gpu(0, util: util, memory: memory)]),
                             server: server, settings: settings, korean: false, transport: transport)
    }
    #expect(await poll(10, util: 0, memory: 10).isEmpty)        // idle starts
    #expect(await poll(40, util: 0, memory: 10).isEmpty)        // 30 s idle
    let alert = await poll(75, util: 0, memory: 10)              // 65 s idle
    #expect(alert == [PendingNotification(title: "GPU 0 is idle", body: "Lab · Fixture · Idle 65s · Mem 10 MB")])
    #expect(await poll(200, util: 0, memory: 10).isEmpty)       // same stretch: once
    #expect(await poll(210, util: 30, memory: 10).isEmpty)      // busy again resets
    #expect(await poll(220, util: 0, memory: 10).isEmpty)
    #expect(await poll(290, util: 0, memory: 10).count == 1)    // new stretch alerts again
    #expect(store.recentHistory(now: start.addingTimeInterval(300)).filter { $0.kind == .idleNotificationScheduled }.count == 2)
}

@Test func exitWatchConfirmsWithPSAndRemovesItself() async {
    let store = WatchStore(fileURL: nil)
    let server = ServerSettings(name: "Lab", sshTarget: "lab")
    let settings = WindowsSettings()
    let watched = process(42)
    #expect(store.toggleExitWatch(process: watched, gpu: gpu(0, util: 90, memory: 500, processes: [watched]), server: server))
    #expect(store.isWatching(watched, on: server))

    // Gone from nvidia-smi but ps still shows it (e.g. between samples): no alert.
    let stillRunning = await store.evaluate(snapshot: GPUSnapshot(takenAt: Date(), gpus: [gpu(0, util: 0, memory: 0)]), server: server,
                                            settings: settings, korean: true, transport: AnyRemoteCommandExecutor(PSFixture(running: [42])))
    #expect(stillRunning.isEmpty)
    #expect(store.processWatches.count == 1)

    let exited = await store.evaluate(snapshot: GPUSnapshot(takenAt: Date(), gpus: [gpu(0, util: 0, memory: 0)]), server: server,
                                      settings: settings, korean: true, transport: AnyRemoteCommandExecutor(PSFixture(running: [])))
    #expect(exited == [PendingNotification(title: "python 종료", body: "Lab · GPU 0 · PID 42 · alice")])
    #expect(store.processWatches.isEmpty)
}

@Test func watchesBelongToTheConnectionAndPersist() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-watches-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let server = ServerSettings(sshTarget: "lab", sshPort: "22")
    let store = WatchStore(fileURL: file)
    store.toggleIdleWatch(gpu: gpu(1, util: 0, memory: 0), server: server, snapshotTakenAt: nil, idleSeconds: 300, memoryThresholdMB: 50)
    #expect(!store.isWatchingIdle(gpu(1, util: 0, memory: 0), on: ServerSettings(sshTarget: "lab", sshPort: "2222")))

    let reloaded = WatchStore(fileURL: file)
    #expect(reloaded.isWatchingIdle(gpu(1, util: 0, memory: 0), on: server))
    #expect(reloaded.recentHistory().first?.kind == .idleWatchAdded)
    reloaded.removeWatch(id: reloaded.idleWatches[0].id)
    #expect(reloaded.idleWatches.isEmpty)
}
