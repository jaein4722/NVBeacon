import Foundation
import Testing
@testable import NVBeacon

@Test func pmonIdleSampleProducesIdleRows() {
    let output = """
    0, NVIDIA GPU, GPU-0, 0, 0, 1000, 30
    1, NVIDIA GPU, GPU-1, 0, 0, 1000, 31
    __GPUUSAGE_PMON_SECTION__
    # gpu         pid  type    sm   mem   enc   dec   command
    0             -    -       -    -     -     -     -
    1             -    -       -    -     -     -     -
    __GPUUSAGE_PMON_PS_SECTION__
    """

    let readings = SSHMetricsFetcher.parseUserUtilizationSnapshot(output, gpuIndices: [0, 1])
    #expect(readings == [
        GPUUserUtilizationReading(gpuIndex: 0, user: "(idle)", utilization: 0),
        GPUUserUtilizationReading(gpuIndex: 1, user: "(idle)", utilization: 0),
    ])
}

@Test func malformedOrUnsupportedPmonIsIgnored() throws {
    let unsupported = """
    0, NVIDIA GPU, GPU-0, 8, 10, 1000, 30
    __GPUUSAGE_PROCESS_SECTION__
    GPU-0, 10, python, 10
    """
    #expect(try SSHMetricsFetcher.parseSnapshot(unsupported).count == 1)
    #expect(SSHMetricsFetcher.parseUserUtilizationSnapshot(unsupported, gpuIndices: [0]).isEmpty)

    let malformed = """
    0, NVIDIA GPU, GPU-0, 8, 10, 1000, 30
    __GPUUSAGE_PMON_SECTION__
    # gpu pid type sm mem enc dec command
    not-a-valid-row
    __GPUUSAGE_PMON_PS_SECTION__
    """
    #expect(try SSHMetricsFetcher.parseSnapshot(malformed).count == 1)
    #expect(SSHMetricsFetcher.parseUserUtilizationSnapshot(malformed, gpuIndices: [0]).isEmpty)
}

@Test func absentPmonGPUIsUnavailableRatherThanInferredIdle() {
    let output = """
    __GPUUSAGE_PMON_SECTION__
    # gpu pid type sm mem enc dec command
    0 101 C 12 20 0 0 python
    __GPUUSAGE_PMON_PS_SECTION__
    """

    #expect(SSHMetricsFetcher.parseUserUtilizationSnapshot(output, gpuIndices: [0, 1]) == [
        GPUUserUtilizationReading(gpuIndex: 0, user: "(unknown user)", utilization: 12),
    ])
}

@Test func pmonUnavailableSMIsNilAndUnknownOwnersRemainUnknown() {
    let output = """
    0, NVIDIA GPU, GPU-0, 75, 400, 1000, 60
    __GPUUSAGE_PMON_SECTION__
    # gpu pid type sm mem enc dec command
    0 101 C - - - - python
    0 102 C 25 - - - python
    __GPUUSAGE_PMON_PS_SECTION__
    102 researcher-with-a-long-name
    """

    let readings = SSHMetricsFetcher.parseUserUtilizationSnapshot(output, gpuIndices: [0])
    #expect(readings == [
        GPUUserUtilizationReading(gpuIndex: 0, user: "(unknown user)", utilization: nil),
        GPUUserUtilizationReading(gpuIndex: 0, user: "researcher-with-a-long-name", utilization: 25),
    ])
}

@Test func mixedAvailableAndUnavailableProcessesYieldNilForTheirUser() {
    let output = """
    __GPUUSAGE_PMON_SECTION__
    # gpu pid type sm mem enc dec command
    0 101 C 12 20 0 0 python
    0 102 C - 20 0 0 python
    __GPUUSAGE_PMON_PS_SECTION__
    101 alice
    102 alice
    """

    #expect(SSHMetricsFetcher.parseUserUtilizationSnapshot(output, gpuIndices: [0]) == [
        GPUUserUtilizationReading(gpuIndex: 0, user: "alice", utilization: nil),
    ])
}

@Test func pmonRejectsNonFiniteAndOutOfRangeSMValues() {
    let output = """
    __GPUUSAGE_PMON_SECTION__
    # gpu pid type sm mem enc dec command
    0 101 C NaN 20 0 0 python
    0 102 C 101 20 0 0 python
    __GPUUSAGE_PMON_PS_SECTION__
    """

    #expect(SSHMetricsFetcher.parseUserUtilizationSnapshot(output, gpuIndices: [0]) == [
        GPUUserUtilizationReading(gpuIndex: 0, user: "(unknown user)", utilization: nil),
    ])
}

@Test func pmonAggregatesPerProcessSMByGPUAndUser() {
    let output = """
    0, NVIDIA GPU, GPU-0, 90, 700, 1000, 60
    1, NVIDIA GPU, GPU-1, 0, 0, 1000, 35
    __GPUUSAGE_PMON_SECTION__
    # gpu pid type sm mem enc dec command
    0 101 C 12 20 0 0 python
    0 102 C 18 30 0 0 python
    0 103 C 7 40 0 0 python
    1 - - - - - - -
    __GPUUSAGE_PMON_PS_SECTION__
    101 alice
    102 alice
    103 bob
    """

    let readings = SSHMetricsFetcher.parseUserUtilizationSnapshot(output, gpuIndices: [0, 1])
    #expect(readings == [
        GPUUserUtilizationReading(gpuIndex: 0, user: "alice", utilization: 30),
        GPUUserUtilizationReading(gpuIndex: 0, user: "bob", utilization: 7),
        GPUUserUtilizationReading(gpuIndex: 1, user: "(idle)", utilization: 0),
    ])
}

@Test func summaryCommandCollectsPmonAndWideUserNamesInSameRoundTrip() {
    let command = SSHMetricsFetcher.buildSummaryRemoteCommand(summaryCommand: "nvidia-smi --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits", includesUserUtilization: true)
    #expect(command.contains("nvidia-smi pmon -s u -c 1"))
    #expect(command.contains("__GPUUSAGE_PMON_SECTION__"))
    #expect(command.contains("__GPUUSAGE_PMON_PS_SECTION__"))
    #expect(command.contains("user:256="))
}

@Test func disabledHistoryDoesNotCollectPmon() {
    let command = SSHMetricsFetcher.buildSummaryRemoteCommand(summaryCommand: AppSettings.defaultRemoteCommand)
    #expect(!command.contains("nvidia-smi pmon"))
    #expect(!command.contains("__GPUUSAGE_PMON_SECTION__"))
    #expect(command.contains(AppSettings.defaultRemoteCommand))
}

@Test func historySettingDefaultsToOptInAndRoundTrips() throws {
    #expect(AppSettings().recordsGPUHistory == false)
    #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).recordsGPUHistory == false)
    let enabled = AppSettings(recordsGPUHistory: true)
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(enabled)).recordsGPUHistory == true)
    #expect(enabled.normalized().recordsGPUHistory == true)
}
