import Foundation
import NVBeaconCore

typealias BusyDetectionMode = NVBeaconCore.BusyDetectionMode
typealias GPUReading = NVBeaconCore.GPUReading
typealias HostMemoryReading = NVBeaconCore.HostMemoryReading
typealias HostMetricsOptions = NVBeaconCore.HostMetricsOptions
typealias HostCPUSample = NVBeaconCore.HostCPUSample
typealias CPUUsageEvaluator = NVBeaconCore.CPUUsageEvaluator
typealias NetworkInterfaceReading = NVBeaconCore.NetworkInterfaceReading
typealias NetworkSample = NVBeaconCore.NetworkSample
typealias NetworkUsage = NVBeaconCore.NetworkUsage
typealias NetworkUsageEvaluator = NVBeaconCore.NetworkUsageEvaluator
typealias NetworkUsageFormatter = NVBeaconCore.NetworkUsageFormatter
typealias GPUSnapshot = NVBeaconCore.GPUSnapshot
typealias GPUProcessReading = NVBeaconCore.GPUProcessReading
typealias RemoteProcessStatus = NVBeaconCore.RemoteProcessStatus
typealias SSHAuthenticationMode = NVBeaconCore.SSHAuthenticationMode
typealias SSHConnectionReuseMode = NVBeaconCore.SSHConnectionReuseMode
typealias ServerSettingsBackup = NVBeaconCore.ServerSettingsBackup
typealias MetricsParser = NVBeaconCore.MetricsParser
typealias MetricsParseError = NVBeaconCore.MetricsParseError
typealias MetricsCollectionError = NVBeaconCore.MetricsCollectionError
typealias RemoteMetricCommands = NVBeaconCore.RemoteMetricCommands
typealias RemoteCommandOutput = NVBeaconCore.RemoteCommandOutput
typealias RemoteCommandExecuting = NVBeaconCore.RemoteCommandExecuting
typealias MetricsCollector<Transport: RemoteCommandExecuting> = NVBeaconCore.MetricsCollector<Transport>

extension GPUReading {
    func isBusy(using settings: AppSettings) -> Bool {
        isBusy(mode: settings.busyDetectionMode, memoryThresholdMB: settings.busyMemoryThresholdMB,
               utilizationThreshold: settings.busyUtilizationThresholdPercent)
    }
}

extension GPUSnapshot {
    func busyCount(using settings: AppSettings) -> Int {
        gpus.filter { $0.isBusy(using: settings) }.count
    }
}
