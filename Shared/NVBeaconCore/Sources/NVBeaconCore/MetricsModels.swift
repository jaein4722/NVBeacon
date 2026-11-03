import Foundation

public struct GPUReading: Identifiable, Equatable, Sendable {
    public let index: Int
    public let name: String
    public let uuid: String?
    public let utilization: Int
    public let memoryUsedMB: Int
    public let memoryTotalMB: Int
    public let temperatureCelsius: Int?
    public let processes: [GPUProcessReading]

    public init(index: Int, name: String, uuid: String?, utilization: Int,
                memoryUsedMB: Int, memoryTotalMB: Int, temperatureCelsius: Int?,
                processes: [GPUProcessReading]) {
        self.index = index
        self.name = name
        self.uuid = uuid
        self.utilization = utilization
        self.memoryUsedMB = memoryUsedMB
        self.memoryTotalMB = memoryTotalMB
        self.temperatureCelsius = temperatureCelsius
        self.processes = processes
    }

    public var id: Int { index }

    public var utilizationRatio: Double {
        Double(utilization) / 100.0
    }

    public var memoryUsagePercent: Int {
        guard memoryTotalMB > 0 else { return 0 }
        return Int((Double(memoryUsedMB) / Double(memoryTotalMB) * 100.0).rounded())
    }

    public var memoryUsageRatio: Double {
        Double(memoryUsagePercent) / 100.0
    }

    public var memorySummary: String {
        "\(memoryUsedMB) / \(memoryTotalMB) MB"
    }

    public var temperatureSummary: String {
        if let temperatureCelsius {
            return "\(temperatureCelsius) C"
        }

        return "--"
    }

    public var processSummary: String {
        processes.isEmpty ? "No active processes" : "\(processes.count) active process\(processes.count == 1 ? "" : "es")"
    }

    public func isIdle(memoryThresholdMB: Int) -> Bool {
        utilization == 0 && memoryUsedMB <= memoryThresholdMB
    }
}

public struct HostMemoryReading: Equatable, Sendable {
    public let totalKiB: Int
    public let availableKiB: Int
    public let swapTotalKiB: Int?
    public let swapFreeKiB: Int?

    public init(totalKiB: Int, availableKiB: Int, swapTotalKiB: Int?, swapFreeKiB: Int?) {
        self.totalKiB = totalKiB
        self.availableKiB = availableKiB
        self.swapTotalKiB = swapTotalKiB
        self.swapFreeKiB = swapFreeKiB
    }

    public var usedKiB: Int { totalKiB - availableKiB }
    public var usageRatio: Double { Double(usedKiB) / Double(totalKiB) }
    public var usagePercent: Int { Int((usageRatio * 100).rounded()) }

    public var swapUsedKiB: Int? {
        guard let swapTotalKiB, let swapFreeKiB else { return nil }
        return swapTotalKiB - swapFreeKiB
    }

    public var swapUsageRatio: Double? {
        guard let swapTotalKiB, let swapUsedKiB else { return nil }
        return swapTotalKiB > 0 ? Double(swapUsedKiB) / Double(swapTotalKiB) : 0
    }

    public static func capacityText(kibibytes: Int) -> String {
        String(format: "%.1f GiB", locale: Locale(identifier: "en_US_POSIX"), Double(kibibytes) / 1_048_576)
    }
}

public struct GPUSnapshot: Equatable, Sendable {
    public let takenAt: Date
    public let gpus: [GPUReading]
    public init(takenAt: Date, gpus: [GPUReading], hostMemory: HostMemoryReading? = nil, hostCPU: Int? = nil, networkSample: NetworkSample? = nil) {
        self.takenAt = takenAt
        self.gpus = gpus
        self.hostMemory = hostMemory
        self.hostCPU = hostCPU
        self.networkSample = networkSample
    }

    public var hostMemory: HostMemoryReading? = nil
    public var hostCPU: Int? = nil
    public var networkSample: NetworkSample? = nil

    public var averageUtilization: Int {
        guard !gpus.isEmpty else { return 0 }
        return gpus.map(\.utilization).reduce(0, +) / gpus.count
    }

    public var totalProcessCount: Int {
        gpus.reduce(0) { $0 + $1.processes.count }
    }

    public func mergingResolvedProcessMetadata(from previous: GPUSnapshot?) -> GPUSnapshot {
        guard let previous else { return self }

        let previousProcessesByID = Dictionary(
            previous.gpus
                .flatMap(\.processes)
                .filter(\.hasResolvedMetadata)
                .map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }
        )

        let mergedGPUs = gpus.map { gpu in
            let mergedProcesses = gpu.processes.map { process in
                let previousProcess = previousProcessesByID[process.id]
                return GPUProcessReading(
                    gpuUUID: process.gpuUUID,
                    pid: process.pid,
                    processName: process.processName,
                    usedGPUMemoryMB: process.usedGPUMemoryMB,
                    userID: process.userID,
                    user: process.user ?? previousProcess?.user,
                    commandLine: process.commandLine ?? previousProcess?.commandLine
                )
            }

            return GPUReading(
                index: gpu.index,
                name: gpu.name,
                uuid: gpu.uuid,
                utilization: gpu.utilization,
                memoryUsedMB: gpu.memoryUsedMB,
                memoryTotalMB: gpu.memoryTotalMB,
                temperatureCelsius: gpu.temperatureCelsius,
                processes: mergedProcesses
            )
        }

        return GPUSnapshot(takenAt: takenAt, gpus: mergedGPUs, hostMemory: hostMemory, hostCPU: hostCPU, networkSample: networkSample)
    }

    public func applyingResolvedProcessMetadata(_ processes: [GPUProcessReading]) -> GPUSnapshot {
        guard !processes.isEmpty else { return self }

        let processesByID = Dictionary(processes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let updatedGPUs = gpus.map { gpu in
            let updatedProcesses = gpu.processes.map { process in
                guard let refreshedProcess = processesByID[process.id] else {
                    return process
                }

                return refreshedProcess.mergingResolvedMetadata(from: process)
            }

            return GPUReading(
                index: gpu.index,
                name: gpu.name,
                uuid: gpu.uuid,
                utilization: gpu.utilization,
                memoryUsedMB: gpu.memoryUsedMB,
                memoryTotalMB: gpu.memoryTotalMB,
                temperatureCelsius: gpu.temperatureCelsius,
                processes: updatedProcesses
            )
        }

        return GPUSnapshot(takenAt: takenAt, gpus: updatedGPUs, hostMemory: hostMemory, hostCPU: hostCPU, networkSample: networkSample)
    }
}

public struct GPUProcessReading: Identifiable, Equatable, Sendable {
    public let gpuUUID: String
    public let pid: Int
    public let processName: String
    public let usedGPUMemoryMB: Int
    public let userID: Int?
    public let user: String?
    public let commandLine: String?

    public init(
        gpuUUID: String,
        pid: Int,
        processName: String,
        usedGPUMemoryMB: Int,
        userID: Int? = nil,
        user: String?,
        commandLine: String?
    ) {
        self.gpuUUID = gpuUUID
        self.pid = pid
        self.processName = processName
        self.usedGPUMemoryMB = usedGPUMemoryMB
        self.userID = userID
        self.user = user
        self.commandLine = commandLine
    }

    public var id: String {
        "\(gpuUUID):\(pid):\(processName)"
    }

    public var hasResolvedMetadata: Bool {
        userID != nil || user != nil || commandLine != nil
    }

    public var memorySummary: String {
        "\(usedGPUMemoryMB) MB"
    }

    public var userSummary: String {
        user ?? "--"
    }

    public var commandSummary: String {
        guard let commandLine, !commandLine.isEmpty else {
            return processName
        }

        return commandLine
    }

    public var displayProcessName: String {
        if !processName.isEmpty {
            return processName
        }

        return commandSummary
    }

    public var showsSeparateCommandSummary: Bool {
        let normalizedProcessName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommand = commandSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedCommand.isEmpty && normalizedProcessName != normalizedCommand
    }

    public func mergingResolvedMetadata(from previous: GPUProcessReading?) -> GPUProcessReading {
        GPUProcessReading(
            gpuUUID: gpuUUID,
            pid: pid,
            processName: processName,
            usedGPUMemoryMB: usedGPUMemoryMB,
            userID: userID ?? previous?.userID,
            user: user ?? previous?.user,
            commandLine: commandLine ?? previous?.commandLine
        )
    }
}

public struct RemoteProcessStatus: Equatable, Sendable {
    public let pid: Int
    public let userID: Int?
    public let user: String
    public let commandLine: String?

    public init(pid: Int, userID: Int? = nil, user: String, commandLine: String?) {
        self.pid = pid
        self.userID = userID
        self.user = user
        self.commandLine = commandLine
    }
}
