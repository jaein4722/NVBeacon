import Foundation
import Testing
@testable import GPUUsage

@Test func parsesMultipleGPUsFromNvidiaSMIOutput() throws {
    let output = """
    0, NVIDIA RTX 6000 Ada Generation, GPU-111, 73, 12048, 49140, 65
    1, NVIDIA RTX 6000 Ada Generation, GPU-222, 11, 4096, 49140, 47
    """

    let gpus = try SSHMetricsFetcher.parse(output)

    #expect(gpus.count == 2)
    #expect(gpus[0].index == 0)
    #expect(gpus[0].uuid == "GPU-111")
    #expect(gpus[0].utilization == 73)
    #expect(gpus[0].memoryUsedMB == 12048)
    #expect(gpus[1].temperatureCelsius == 47)
}

@Test func combinesProcessesIntoMatchingGPU() throws {
    let output = """
    0, NVIDIA RTX 6000 Ada Generation, GPU-111, 73, 12048, 49140, 65
    1, NVIDIA RTX 6000 Ada Generation, GPU-222, 11, 4096, 49140, 47
    __GPUUSAGE_PROCESS_SECTION__
    GPU-111, 1001, python, 8192
    GPU-111, 1002, tensorboard, 512
    __GPUUSAGE_PS_SECTION__
    1001 alice python train.py --epochs 100
    1002 alice tensorboard --logdir runs/demo
    """

    let gpus = try SSHMetricsFetcher.parseSnapshot(output)

    #expect(gpus[0].processes.count == 2)
    #expect(gpus[0].processes[0].pid == 1001)
    #expect(gpus[0].processes[1].processName == "tensorboard")
    #expect(gpus[0].processes[0].user == "alice")
    #expect(gpus[0].processes[0].commandLine == "python train.py --epochs 100")
    #expect(gpus[1].processes.isEmpty)
}

@Test func summaryPollingKeepsProcessMetadataLazy() throws {
    let output = """
    0, NVIDIA RTX 6000 Ada Generation, GPU-111, 73, 12048, 49140, 65
    __GPUUSAGE_PROCESS_SECTION__
    GPU-111, 1001, python, 8192
    """

    let gpus = try SSHMetricsFetcher.parseSnapshot(output)

    #expect(gpus.count == 1)
    #expect(gpus[0].processes.count == 1)
    #expect(gpus[0].processes[0].processName == "python")
    #expect(gpus[0].processes[0].user == nil)
    #expect(gpus[0].processes[0].commandLine == nil)
}

@Test func malformedOutputThrows() {
    #expect(throws: SSHMetricsFetcher.FetchError.self) {
        try SSHMetricsFetcher.parse("unexpected output")
    }
}

@Test func migratesLegacyDefaultCommandToUUIDAwareQuery() {
    let settings = AppSettings(remoteCommand: AppSettings.legacyDefaultRemoteCommand).normalized()
    #expect(settings.remoteCommand == AppSettings.defaultRemoteCommand)
}

@Test func parsesSSHConfigHosts() {
    let config = """
    Host gpu-prod
      HostName 10.0.0.10
      User lee
      Port 2222
      IdentityFile ~/.ssh/id_gpu

    Host *
      ServerAliveInterval 30

    Host train-box backup-box
      HostName 10.0.0.20
      User ubuntu
    """

    let hosts = SSHConfigLoader.parse(config)

    #expect(hosts.map(\.alias) == ["backup-box", "gpu-prod", "train-box"])
    #expect(hosts.first(where: { $0.alias == "gpu-prod" })?.hostName == "10.0.0.10")
    #expect(hosts.first(where: { $0.alias == "gpu-prod" })?.identityFilePath?.hasSuffix(".ssh/id_gpu") == true)
    #expect(hosts.first(where: { $0.alias == "train-box" })?.user == "ubuntu")
}

@Test func applyingSSHConfigHostPopulatesPortAndIdentity() {
    let host = SSHConfigHost(
        alias: "gpu-prod",
        hostName: "10.0.0.10",
        user: "lee",
        port: "2222",
        identityFilePath: "/Users/test/.ssh/id_gpu"
    )

    let applied = host.apply(to: AppSettings())
    let backfilled = host.backfillingMissingFields(in: AppSettings(sshTarget: "gpu-prod"))

    #expect(applied.sshTarget == "gpu-prod")
    #expect(applied.sshPort == "2222")
    #expect(applied.sshIdentityFilePath == "/Users/test/.ssh/id_gpu")
    #expect(backfilled.sshPort == "2222")
    #expect(backfilled.sshIdentityFilePath == "/Users/test/.ssh/id_gpu")
}

@Test func decodesLegacySettingsWithoutMenuBarMode() throws {
    let json = """
    {
      "sshTarget": "gpu-prod",
      "sshPort": "2222",
      "sshIdentityFilePath": "",
      "pollIntervalSeconds": 15,
      "remoteCommand": "nvidia-smi --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    }
    """

    let settings = try JSONDecoder().decode(AppSettings.self, from: #require(json.data(using: .utf8)))

    #expect(settings.sshTarget == "gpu-prod")
    #expect(settings.sshAuthenticationMode == .keyBased)
    #expect(settings.menuBarDisplayMode == .averageAndBusy)
    #expect(settings.appearanceMode == .system)
    #expect(settings.showsDockIcon == false)
    #expect(settings.closesPopoverOnOutsideClick == true)
    #expect(settings.idleNotificationSeconds == 300)
    #expect(settings.idleMemoryThresholdMB == 50)
}

@Test func menuBarDisplayModesBuildExpectedSummary() {
    let snapshot = GPUSnapshot(
        takenAt: Date(),
        gpus: [
            GPUReading(index: 0, name: "A", uuid: "GPU-1", utilization: 10, memoryUsedMB: 1, memoryTotalMB: 10, temperatureCelsius: 40, processes: []),
            GPUReading(index: 1, name: "B", uuid: "GPU-2", utilization: 90, memoryUsedMB: 2, memoryTotalMB: 10, temperatureCelsius: 50, processes: []),
        ]
    )

    #expect(MenuBarDisplayMode.averageAndBusy.titleText(for: snapshot) == "GPU 50% · 2/2")
    #expect(MenuBarDisplayMode.averageOnly.titleText(for: snapshot) == "GPU 50%")
    #expect(MenuBarDisplayMode.busyOnly.titleText(for: snapshot) == "GPU 2/2")
    #expect(MenuBarDisplayMode.iconOnly.titleText(for: snapshot).isEmpty)
}

@Test func exitWatchDoesNotFireWhileProcessIsStillVisible() {
    let settings = AppSettings(sshTarget: "gpu-prod")
    let gpu = GPUReading(index: 0, name: "A6000", uuid: "GPU-1", utilization: 90, memoryUsedMB: 10, memoryTotalMB: 20, temperatureCelsius: 60, processes: [])
    let process = GPUProcessReading(gpuUUID: "GPU-1", pid: 1234, processName: "python", usedGPUMemoryMB: 8192, user: "alice", commandLine: "python train.py")
    let watch = ProcessExitWatch(settings: settings, gpu: gpu, process: process)

    let exited = ProcessExitWatchEvaluator.exitedWatches(
        watches: [watch],
        visibleProcesses: [process],
        remoteStatuses: []
    )

    #expect(exited.isEmpty)
}

@Test func exitWatchFiresWhenProcessDisappearsFromGPUAndPS() {
    let settings = AppSettings(sshTarget: "gpu-prod")
    let gpu = GPUReading(index: 0, name: "A6000", uuid: "GPU-1", utilization: 90, memoryUsedMB: 10, memoryTotalMB: 20, temperatureCelsius: 60, processes: [])
    let process = GPUProcessReading(gpuUUID: "GPU-1", pid: 1234, processName: "python", usedGPUMemoryMB: 8192, user: "alice", commandLine: "python train.py")
    let watch = ProcessExitWatch(settings: settings, gpu: gpu, process: process)

    let exited = ProcessExitWatchEvaluator.exitedWatches(
        watches: [watch],
        visibleProcesses: [],
        remoteStatuses: []
    )

    #expect(exited == [watch])
}

@Test func exitWatchFiresWhenPIDIsReusedByDifferentCommand() {
    let settings = AppSettings(sshTarget: "gpu-prod")
    let gpu = GPUReading(index: 0, name: "A6000", uuid: "GPU-1", utilization: 90, memoryUsedMB: 10, memoryTotalMB: 20, temperatureCelsius: 60, processes: [])
    let process = GPUProcessReading(gpuUUID: "GPU-1", pid: 1234, processName: "python", usedGPUMemoryMB: 8192, user: "alice", commandLine: "python train.py")
    let watch = ProcessExitWatch(settings: settings, gpu: gpu, process: process)
    let reusedPID = RemoteProcessStatus(pid: 1234, user: "alice", commandLine: "python serve.py")

    let exited = ProcessExitWatchEvaluator.exitedWatches(
        watches: [watch],
        visibleProcesses: [],
        remoteStatuses: [reusedPID]
    )

    #expect(exited == [watch])
}

@Test func notificationHistoryFiltersToRecent24Hours() {
    let now = Date()
    let recent = NotificationHistoryEntry(
        timestamp: now.addingTimeInterval(-(2 * 3600)),
        kind: .watchAdded,
        connectionLabel: "gpu-prod",
        gpuIndex: 0,
        pid: 1234,
        user: "alice",
        processName: "python"
    )
    let old = NotificationHistoryEntry(
        timestamp: now.addingTimeInterval(-(30 * 3600)),
        kind: .watchRemoved,
        connectionLabel: "gpu-prod",
        gpuIndex: 0,
        pid: 1234,
        user: "alice",
        processName: "python"
    )

    let filtered = NotificationHistoryEntry.recentEntries(from: [old, recent], now: now)

    #expect(filtered == [recent])
}

@Test func normalizesIdleAlertThresholds() {
    let lowerBoundSettings = AppSettings(
        pollIntervalSeconds: 0,
        idleNotificationSeconds: 0,
        idleMemoryThresholdMB: 50_000
    ).normalized()
    let upperBoundSettings = AppSettings(
        pollIntervalSeconds: 500,
        idleNotificationSeconds: 5_000,
        idleMemoryThresholdMB: 12_000
    ).normalized()

    #expect(lowerBoundSettings.pollIntervalSeconds == 1)
    #expect(lowerBoundSettings.idleNotificationSeconds == 1)
    #expect(lowerBoundSettings.idleMemoryThresholdMB == 10_240)
    #expect(upperBoundSettings.pollIntervalSeconds == 300)
    #expect(upperBoundSettings.idleNotificationSeconds == 3_600)
    #expect(upperBoundSettings.idleMemoryThresholdMB == 10_240)
}

@Test func gpuIdleWatchMatchesByUUIDOrIndex() {
    let settings = AppSettings(sshTarget: "gpu-prod")
    let gpuWithUUID = GPUReading(
        index: 7,
        name: "A6000",
        uuid: "GPU-777",
        utilization: 0,
        memoryUsedMB: 12,
        memoryTotalMB: 48_068,
        temperatureCelsius: 31,
        processes: []
    )
    let gpuWithoutUUID = GPUReading(
        index: 7,
        name: "A6000",
        uuid: nil,
        utilization: 0,
        memoryUsedMB: 12,
        memoryTotalMB: 48_068,
        temperatureCelsius: 31,
        processes: []
    )
    let watch = GPUIdleWatch(settings: settings, gpu: gpuWithUUID)

    #expect(watch.matches(gpuWithUUID))
    #expect(watch.matches(gpuWithoutUUID))
}

@Test func gpuReadingIdleCheckUsesUtilAndMemoryThreshold() {
    let idleGPU = GPUReading(
        index: 0,
        name: "A6000",
        uuid: "GPU-1",
        utilization: 0,
        memoryUsedMB: 49,
        memoryTotalMB: 48_068,
        temperatureCelsius: 31,
        processes: []
    )
    let busyGPU = GPUReading(
        index: 0,
        name: "A6000",
        uuid: "GPU-1",
        utilization: 2,
        memoryUsedMB: 49,
        memoryTotalMB: 48_068,
        temperatureCelsius: 31,
        processes: []
    )

    #expect(idleGPU.isIdle(memoryThresholdMB: 50))
    #expect(!idleGPU.isIdle(memoryThresholdMB: 10))
    #expect(!busyGPU.isIdle(memoryThresholdMB: 50))
}
