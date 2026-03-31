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
