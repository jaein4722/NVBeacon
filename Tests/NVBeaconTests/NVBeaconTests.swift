import Foundation
import Testing
@testable import NVBeacon

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
    GPU-111, 1001, 501, python, 8192
    """

    let gpus = try SSHMetricsFetcher.parseSnapshot(output)

    #expect(gpus.count == 1)
    #expect(gpus[0].processes.count == 1)
    #expect(gpus[0].processes[0].processName == "python")
    #expect(gpus[0].processes[0].userID == 501)
    #expect(gpus[0].processes[0].user == nil)
    #expect(gpus[0].processes[0].commandLine == nil)
}

@Test func mergingResolvedProcessMetadataKeepsFreshVRAM() throws {
    let previous = GPUSnapshot(
        takenAt: .distantPast,
        gpus: [
            GPUReading(
                index: 0,
                name: "NVIDIA RTX 6000 Ada Generation",
                uuid: "GPU-111",
                utilization: 12,
                memoryUsedMB: 8192,
                memoryTotalMB: 49140,
                temperatureCelsius: 50,
                processes: [
                    GPUProcessReading(
                        gpuUUID: "GPU-111",
                        pid: 1001,
                        processName: "python",
                        usedGPUMemoryMB: 8192,
                        user: "alice",
                        commandLine: "python train.py"
                    )
                ]
            )
        ]
    )

    let latest = GPUSnapshot(
        takenAt: .now,
        gpus: [
            GPUReading(
                index: 0,
                name: "NVIDIA RTX 6000 Ada Generation",
                uuid: "GPU-111",
                utilization: 0,
                memoryUsedMB: 4096,
                memoryTotalMB: 49140,
                temperatureCelsius: 42,
                processes: [
                    GPUProcessReading(
                        gpuUUID: "GPU-111",
                        pid: 1001,
                        processName: "python",
                        usedGPUMemoryMB: 4096,
                        user: nil,
                        commandLine: nil
                    )
                ]
            )
        ]
    )

    let merged = latest.mergingResolvedProcessMetadata(from: previous)
    let process = try #require(merged.gpus.first?.processes.first)

    #expect(process.usedGPUMemoryMB == 4096)
    #expect(process.user == "alice")
    #expect(process.commandLine == "python train.py")
}

@Test func applyingResolvedProcessMetadataUpdatesOwnershipWithoutChangingSnapshotTime() throws {
    let takenAt = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = GPUSnapshot(
        takenAt: takenAt,
        gpus: [
            GPUReading(
                index: 0,
                name: "NVIDIA RTX 6000 Ada Generation",
                uuid: "GPU-111",
                utilization: 12,
                memoryUsedMB: 8192,
                memoryTotalMB: 49140,
                temperatureCelsius: 50,
                processes: [
                    GPUProcessReading(
                        gpuUUID: "GPU-111",
                        pid: 1001,
                        processName: "python",
                        usedGPUMemoryMB: 8192,
                        user: nil,
                        commandLine: nil
                    )
                ]
            )
        ]
    )

    let refreshedProcesses = [
        GPUProcessReading(
            gpuUUID: "GPU-111",
            pid: 1001,
            processName: "python",
            usedGPUMemoryMB: 8192,
            userID: 501,
            user: nil,
            commandLine: nil
        )
    ]

    let updated = snapshot.applyingResolvedProcessMetadata(refreshedProcesses)
    let process = try #require(updated.gpus.first?.processes.first)

    #expect(updated.takenAt == takenAt)
    #expect(process.userID == 501)
    #expect(process.user == nil)
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

@Test func detectsSSHUsernameFromExplicitTarget() {
    let settings = AppSettings(sshTarget: "alice@10.0.0.10")

    #expect(settings.detectedSSHUsername(using: [], fallbackLocalUsername: "local") == "alice")
}

@Test func detectsSSHUsernameFromSSHConfigAlias() {
    let settings = AppSettings(sshTarget: "gpu-prod")
    let hosts = [
        SSHConfigHost(
            alias: "gpu-prod",
            hostName: "10.0.0.10",
            user: "ubuntu",
            port: "2222",
            identityFilePath: "/Users/test/.ssh/id_gpu"
        )
    ]

    #expect(settings.detectedSSHUsername(using: hosts, fallbackLocalUsername: "local") == "ubuntu")
}

@Test func detectsSSHUsernameFallsBackToLocalUser() {
    let settings = AppSettings(sshTarget: "gpu-prod")

    #expect(settings.detectedSSHUsername(using: [], fallbackLocalUsername: "lee") == "lee")
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
    #expect(settings.languagePreference == .system)
    #expect(settings.appearanceMode == .system)
    #expect(settings.showsDockIcon == false)
    #expect(settings.closesPopoverOnOutsideClick == true)
    #expect(settings.highlightsMyProcesses == true)
    #expect(settings.showsNetworkUsage == true)
    #expect(settings.sshConnectionReuseMode == .reuseWhenPossible)
    #expect(settings.busyDetectionMode == .activeProcess)
    #expect(settings.busyMemoryThresholdMB == 50)
    #expect(settings.busyUtilizationThresholdPercent == 10)
    #expect(settings.idleNotificationSeconds == 300)
    #expect(settings.idleMemoryThresholdMB == 50)
}

@Test func normalizesLegacySettingsIntoSingleServerConfig() {
    let settings = AppSettings(
        sshTarget: "gpu-prod",
        sshPort: "2222",
        sshIdentityFilePath: "/Users/test/.ssh/id_gpu",
        sshAuthenticationMode: .passwordBased,
        sshConnectionReuseMode: .newConnectionEachRefresh,
        remoteCommand: AppSettings.legacyDefaultRemoteCommand
    ).normalized()

    let server = settings.configuredServers.first

    #expect(settings.configuredServers.count == 1)
    #expect(server?.id == "legacy-primary")
    #expect(server?.sshTarget == "gpu-prod")
    #expect(server?.sshPort == "2222")
    #expect(server?.sshAuthenticationMode == .passwordBased)
    #expect(server?.sshConnectionReuseMode == .newConnectionEachRefresh)
    #expect(server?.remoteCommand == AppSettings.defaultRemoteCommand)
    #expect(settings.sshTarget == "gpu-prod")
    #expect(settings.pollableServers.count == 1)
}

@Test func keepsMultipleServerConfigsAndEnabledSubset() {
    let enabledServer = ServerConfig(
        id: "server-a",
        name: "Box A",
        sshTarget: "alice@gpu-a",
        sshPort: "22",
        sshIdentityFilePath: "/Users/test/.ssh/a",
        sshAuthenticationMode: .keyBased,
        sshConnectionReuseMode: .reuseWhenPossible,
        isEnabled: true
    )
    let disabledServer = ServerConfig(
        id: "server-b",
        name: "Box B",
        sshTarget: "bob@gpu-b",
        sshPort: "2222",
        sshIdentityFilePath: "/Users/test/.ssh/b",
        sshAuthenticationMode: .passwordBased,
        sshConnectionReuseMode: .newConnectionEachRefresh,
        isEnabled: false
    )

    let settings = AppSettings(servers: [enabledServer, disabledServer]).normalized()

    #expect(settings.configuredServers.map(\.id) == ["server-a", "server-b"])
    #expect(settings.pollableServers.map(\.id) == ["server-a"])
    #expect(settings.sshTarget == "alice@gpu-a")
    #expect(settings.sshPort == "22")

    let connectionSettings = disabledServer.connectionSettings(from: settings)
    #expect(connectionSettings.sshTarget == "bob@gpu-b")
    #expect(connectionSettings.sshPort == "2222")
    #expect(connectionSettings.sshAuthenticationMode == .passwordBased)
    #expect(connectionSettings.sshConnectionReuseMode == .newConnectionEachRefresh)
}

@Test func menuBarDisplayModesBuildExpectedSummary() {
    let settings = AppSettings(
        busyDetectionMode: .activeProcess
    )
    let snapshot = GPUSnapshot(
        takenAt: Date(),
        gpus: [
            GPUReading(
                index: 0,
                name: "A",
                uuid: "GPU-1",
                utilization: 10,
                memoryUsedMB: 1,
                memoryTotalMB: 10,
                temperatureCelsius: 40,
                processes: [GPUProcessReading(gpuUUID: "GPU-1", pid: 1, processName: "python", usedGPUMemoryMB: 1, user: nil, commandLine: nil)]
            ),
            GPUReading(
                index: 1,
                name: "B",
                uuid: "GPU-2",
                utilization: 90,
                memoryUsedMB: 2,
                memoryTotalMB: 10,
                temperatureCelsius: 50,
                processes: [GPUProcessReading(gpuUUID: "GPU-2", pid: 2, processName: "python", usedGPUMemoryMB: 1, user: nil, commandLine: nil)]
            ),
        ]
    )

    #expect(MenuBarDisplayMode.averageAndBusy.titleText(for: snapshot, settings: settings, language: .english) == "GPU 50% · 2/2")
    #expect(MenuBarDisplayMode.averageOnly.titleText(for: snapshot, settings: settings, language: .english) == "GPU 50%")
    #expect(MenuBarDisplayMode.busyOnly.titleText(for: snapshot, settings: settings, language: .english) == "GPU 2/2")
    #expect(MenuBarDisplayMode.iconOnly.titleText(for: snapshot, settings: settings, language: .english).isEmpty)
}

@Test func serverScopedWatchesUseServerIdentity() {
    let server = ServerConfig(
        id: "server-a",
        name: "A100 Lab",
        sshTarget: "alice@gpu-a"
    )
    let gpu = GPUReading(
        index: 0,
        name: "A100",
        uuid: "GPU-A",
        utilization: 90,
        memoryUsedMB: 10,
        memoryTotalMB: 20,
        temperatureCelsius: 60,
        processes: []
    )
    let process = GPUProcessReading(
        gpuUUID: "GPU-A",
        pid: 1234,
        processName: "python",
        usedGPUMemoryMB: 8192,
        user: "alice",
        commandLine: "python train.py"
    )

    let processWatch = ProcessExitWatch(server: server, gpu: gpu, process: process)
    let idleWatch = GPUIdleWatch(server: server, gpu: gpu)

    #expect(processWatch.connectionFingerprint == server.connectionFingerprint)
    #expect(processWatch.connectionLabel == "A100 Lab")
    #expect(idleWatch.connectionFingerprint == server.connectionFingerprint)
    #expect(idleWatch.connectionLabel == "A100 Lab")
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
        busyMemoryThresholdMB: -1,
        busyUtilizationThresholdPercent: -1,
        idleNotificationSeconds: 0,
        idleMemoryThresholdMB: 50_000
    ).normalized()
    let upperBoundSettings = AppSettings(
        pollIntervalSeconds: 500,
        busyMemoryThresholdMB: 12_000,
        busyUtilizationThresholdPercent: 500,
        idleNotificationSeconds: 5_000,
        idleMemoryThresholdMB: 12_000
    ).normalized()

    #expect(lowerBoundSettings.pollIntervalSeconds == 1)
    #expect(lowerBoundSettings.busyMemoryThresholdMB == 0)
    #expect(lowerBoundSettings.busyUtilizationThresholdPercent == 0)
    #expect(lowerBoundSettings.idleNotificationSeconds == 1)
    #expect(lowerBoundSettings.idleMemoryThresholdMB == 10_240)
    #expect(upperBoundSettings.pollIntervalSeconds == 300)
    #expect(upperBoundSettings.busyMemoryThresholdMB == 10_240)
    #expect(upperBoundSettings.busyUtilizationThresholdPercent == 100)
    #expect(upperBoundSettings.idleNotificationSeconds == 3_600)
    #expect(upperBoundSettings.idleMemoryThresholdMB == 10_240)
}

@Test func busyDetectionModesUseConfiguredRule() {
    let process = GPUProcessReading(
        gpuUUID: "GPU-1",
        pid: 1001,
        processName: "python",
        usedGPUMemoryMB: 4_096,
        user: nil,
        commandLine: nil
    )
    let gpu = GPUReading(
        index: 0,
        name: "A6000",
        uuid: "GPU-1",
        utilization: 0,
        memoryUsedMB: 4_096,
        memoryTotalMB: 48_068,
        temperatureCelsius: 31,
        processes: [process]
    )

    #expect(gpu.isBusy(using: AppSettings(busyDetectionMode: .activeProcess)))
    #expect(gpu.isBusy(using: AppSettings(busyDetectionMode: .memoryThreshold, busyMemoryThresholdMB: 2_000)))
    #expect(!gpu.isBusy(using: AppSettings(busyDetectionMode: .memoryThreshold, busyMemoryThresholdMB: 8_000)))
    #expect(gpu.isBusy(using: AppSettings(busyDetectionMode: .activeProcessOrMemoryThreshold, busyMemoryThresholdMB: 8_000)))
    #expect(!gpu.isBusy(using: AppSettings(busyDetectionMode: .utilizationThreshold, busyUtilizationThresholdPercent: 10)))
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

@Test func parsesNetworkSectionFromSummaryOutput() throws {
    let output = """
    0, NVIDIA RTX 6000 Ada Generation, GPU-111, 73, 12048, 49140, 65
    __GPUUSAGE_PROCESS_SECTION__
    GPU-111, 1001, 501, python, 8192
    __GPUUSAGE_NETWORK_SECTION__
    eth0 1024 2048
    ib0 4096 8192
    """

    let reading = try SSHMetricsFetcher.parseReading(output)

    #expect(reading.snapshot.gpus.count == 1)
    #expect(reading.snapshot.gpus[0].processes.count == 1)

    let sample = try #require(reading.networkSample)
    #expect(sample.interfaces.map(\.name) == ["eth0", "ib0"])
    #expect(sample.receivedBytes == 5_120)
    #expect(sample.transmittedBytes == 10_240)
}

@Test func summaryOutputWithoutNetworkSectionHasNoNetworkSample() throws {
    let output = """
    0, NVIDIA RTX 6000 Ada Generation, GPU-111, 73, 12048, 49140, 65
    __GPUUSAGE_PROCESS_SECTION__
    GPU-111, 1001, 501, python, 8192
    """

    let reading = try SSHMetricsFetcher.parseReading(output)

    #expect(reading.snapshot.gpus.count == 1)
    #expect(reading.networkSample == nil)
}

@Test func networkUsageComputesRateBetweenSamples() throws {
    let start = Date()
    let previous = NetworkSample(
        takenAt: start,
        interfaces: [NetworkInterfaceReading(name: "eth0", receivedBytes: 1_000, transmittedBytes: 2_000)]
    )
    let current = NetworkSample(
        takenAt: start.addingTimeInterval(10),
        interfaces: [NetworkInterfaceReading(name: "eth0", receivedBytes: 21_000, transmittedBytes: 12_000)]
    )

    let usage = try #require(
        NetworkUsageEvaluator.usage(previous: previous, current: current, maximumInterval: 60)
    )

    #expect(usage.receivedBytesPerSecond == 2_000)
    #expect(usage.transmittedBytesPerSecond == 1_000)
    #expect(usage.totalReceivedBytes == 21_000)
    #expect(usage.interfaceNames == ["eth0"])
    #expect(usage.hasRates)
}

@Test func networkUsageWithoutPreviousSampleHasTotalsOnly() throws {
    let current = NetworkSample(
        takenAt: Date(),
        interfaces: [NetworkInterfaceReading(name: "eth0", receivedBytes: 21_000, transmittedBytes: 12_000)]
    )

    let usage = try #require(
        NetworkUsageEvaluator.usage(previous: nil, current: current, maximumInterval: 60)
    )

    #expect(usage.receivedBytesPerSecond == nil)
    #expect(!usage.hasRates)
    #expect(usage.totalReceivedBytes == 21_000)
    #expect(usage.totalTransmittedBytes == 12_000)
}

@Test func networkUsageSkipsRateWhenCountersReset() throws {
    let start = Date()
    let previous = NetworkSample(
        takenAt: start,
        interfaces: [NetworkInterfaceReading(name: "eth0", receivedBytes: 5_000_000, transmittedBytes: 5_000_000)]
    )
    let current = NetworkSample(
        takenAt: start.addingTimeInterval(10),
        interfaces: [NetworkInterfaceReading(name: "eth0", receivedBytes: 500, transmittedBytes: 600)]
    )

    let usage = try #require(
        NetworkUsageEvaluator.usage(previous: previous, current: current, maximumInterval: 60)
    )

    #expect(usage.receivedBytesPerSecond == nil)
    #expect(usage.totalReceivedBytes == 500)
}

@Test func networkUsageSkipsRateForLongIntervals() throws {
    let start = Date()
    let previous = NetworkSample(
        takenAt: start,
        interfaces: [NetworkInterfaceReading(name: "eth0", receivedBytes: 1_000, transmittedBytes: 2_000)]
    )
    let current = NetworkSample(
        takenAt: start.addingTimeInterval(3_600),
        interfaces: [NetworkInterfaceReading(name: "eth0", receivedBytes: 3_601_000, transmittedBytes: 3_602_000)]
    )

    let usage = try #require(
        NetworkUsageEvaluator.usage(previous: previous, current: current, maximumInterval: 60)
    )

    #expect(usage.receivedBytesPerSecond == nil)
}

@Test func networkUsageIgnoresInterfacesWithoutBaseline() throws {
    let start = Date()
    let previous = NetworkSample(
        takenAt: start,
        interfaces: [NetworkInterfaceReading(name: "eth0", receivedBytes: 1_000, transmittedBytes: 1_000)]
    )
    let current = NetworkSample(
        takenAt: start.addingTimeInterval(10),
        interfaces: [
            NetworkInterfaceReading(name: "eth0", receivedBytes: 3_000, transmittedBytes: 2_000),
            NetworkInterfaceReading(name: "ib0", receivedBytes: 9_000_000, transmittedBytes: 9_000_000),
        ]
    )

    let usage = try #require(
        NetworkUsageEvaluator.usage(previous: previous, current: current, maximumInterval: 60)
    )

    #expect(usage.receivedBytesPerSecond == 200)
    #expect(usage.transmittedBytesPerSecond == 100)
    #expect(usage.totalReceivedBytes == 9_003_000)
    #expect(usage.interfaceNames == ["eth0", "ib0"])
}

@Test func networkUsageWithoutInterfacesIsUnavailable() {
    let current = NetworkSample(takenAt: Date(), interfaces: [])

    #expect(NetworkUsageEvaluator.usage(previous: nil, current: current, maximumInterval: 60) == nil)
}

@Test func formatsNetworkRatesAndSizes() {
    #expect(NetworkUsageFormatter.rateText(nil) == "--")
    #expect(NetworkUsageFormatter.rateText(-5) == "--")
    #expect(NetworkUsageFormatter.rateText(0) == "0 B/s")
    #expect(NetworkUsageFormatter.rateText(1_500) == "1.5 KB/s")
    #expect(NetworkUsageFormatter.rateText(12_345_678) == "12.3 MB/s")
    #expect(NetworkUsageFormatter.rateText(1_250_000_000) == "1.2 GB/s")
    #expect(NetworkUsageFormatter.byteCountText(2_500_000_000_000) == "2.5 TB")
}

@Test func networkSampleCommandReportsPhysicalInterfacesOnly() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sysNet = root.appendingPathComponent("sys/class/net", isDirectory: true)
    let interfaces: [(name: String, receivedBytes: UInt64, transmittedBytes: UInt64)] = [
        ("eth0", 1_000, 2_000),
        ("ib0", 500, 600),
        ("bond0", 7_000, 8_000),
        ("eth1", 7_000, 8_000),
        ("lo", 10, 20),
        ("veth1234", 30, 40),
        ("docker0", 50, 60),
    ]
    for interface in interfaces {
        try writeInterfaceCounters(interface, in: sysNet)
    }

    // eth1 is enslaved to bond0, so only the aggregate bond device must be reported.
    try FileManager.default.createSymbolicLink(
        atPath: sysNet.appendingPathComponent("eth1/master").path,
        withDestinationPath: "../bond0"
    )

    let output = try runNetworkSampleCommand(
        sysNetPath: sysNet,
        procNetDevPath: root.appendingPathComponent("missing-proc-net-dev").path
    )

    #expect(output.split(whereSeparator: \.isNewline).map(String.init).sorted() == ["bond0 7000 8000", "eth0 1000 2000", "ib0 500 600"])
}

@Test func networkSampleCommandFallsBackToProcNetDev() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let procNetDev = root.appendingPathComponent("proc-net-dev")
    let contents = """
    Inter-|   Receive                                                |  Transmit
     face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        lo: 1000  10 0 0 0 0 0 0 1000 10 0 0 0 0 0 0
      eth0: 5000  50 0 0 0 0 0 0 7000 70 0 0 0 0 0 0
    docker0: 111  1 0 0 0 0 0 0 222  2 0 0 0 0 0 0
    """
    try contents.write(to: procNetDev, atomically: true, encoding: .utf8)

    let output = try runNetworkSampleCommand(
        sysNetPath: root.appendingPathComponent("missing-sys-class-net"),
        procNetDevPath: procNetDev.path
    )

    #expect(output.split(whereSeparator: \.isNewline).map(String.init).sorted() == ["eth0 5000 7000"])
}

private func makeTemporaryDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nvbeacon-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeInterfaceCounters(
    _ interface: (name: String, receivedBytes: UInt64, transmittedBytes: UInt64),
    in sysNet: URL
) throws {
    let directory = sysNet.appendingPathComponent(interface.name, isDirectory: true)
    let statistics = directory.appendingPathComponent("statistics", isDirectory: true)
    try FileManager.default.createDirectory(at: statistics, withIntermediateDirectories: true)
    try "\(interface.receivedBytes)\n".write(
        to: statistics.appendingPathComponent("rx_bytes"),
        atomically: true,
        encoding: .utf8
    )
    try "\(interface.transmittedBytes)\n".write(
        to: statistics.appendingPathComponent("tx_bytes"),
        atomically: true,
        encoding: .utf8
    )
}

private func runNetworkSampleCommand(sysNetPath: URL, procNetDevPath: String) throws -> String {
    let command = SSHMetricsFetcher.networkSampleCommand
        .replacingOccurrences(of: "/sys/class/net/", with: sysNetPath.path + "/")
        .replacingOccurrences(of: "/proc/net/dev", with: procNetDevPath)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]

    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = Pipe()

    try process.run()
    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return String(decoding: data, as: UTF8.self)
}

@Test func hostMetricsCoexistWithNetworkAndGPU() throws {
    let output = """
    0, Test GPU, GPU-123, 20, 100, 1000, 40
    __GPUUSAGE_PROCESS_SECTION__
    __NVBEACON_CPU_SECTION__
    cpu 100 0 100 800 0 0 0 0
    cpu 150 0 110 840 0 0 0 0
    __NVBEACON_MEMORY_SECTION__
    MemTotal: 1000 kB
    MemAvailable: 250 kB
    SwapTotal: 100 kB
    SwapFree: 50 kB
    __GPUUSAGE_NETWORK_SECTION__
    eth0 1000 2000
    """
    let reading = try SSHMetricsFetcher.parseReading(output)
    #expect(reading.snapshot.hostCPU == 60)
    #expect(reading.snapshot.hostMemory?.usedKiB == 750)
    #expect(reading.snapshot.hostMemory?.swapFreeKiB == 50)
    #expect(reading.networkSample?.interfaces.count == 1)
    #expect(reading.snapshot.gpus.count == 1)
    #expect(SSHMetricsFetcher.parseHostCPU("__NVBEACON_CPU_SECTION__\ncpu 1 2 3 4\ncpu 1 2 3 4") == nil)
}
