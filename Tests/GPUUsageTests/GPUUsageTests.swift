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
    """

    let gpus = try SSHMetricsFetcher.parseSnapshot(output)

    #expect(gpus[0].processes.count == 2)
    #expect(gpus[0].processes[0].pid == 1001)
    #expect(gpus[0].processes[1].processName == "tensorboard")
    #expect(gpus[1].processes.isEmpty)
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
