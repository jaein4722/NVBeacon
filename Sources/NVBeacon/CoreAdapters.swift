import Foundation
import NVBeaconCore

typealias GPUReading = NVBeaconCore.GPUReading
typealias HostMemoryReading = NVBeaconCore.HostMemoryReading
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
        switch settings.busyDetectionMode {
        case .activeProcess:
            return !processes.isEmpty
        case .memoryThreshold:
            return memoryUsedMB > settings.busyMemoryThresholdMB
        case .activeProcessOrMemoryThreshold:
            return !processes.isEmpty || memoryUsedMB > settings.busyMemoryThresholdMB
        case .utilizationThreshold:
            return utilization >= settings.busyUtilizationThresholdPercent
        }
    }
}

extension GPUSnapshot {
    func busyCount(using settings: AppSettings) -> Int {
        gpus.filter { $0.isBusy(using: settings) }.count
    }
}
