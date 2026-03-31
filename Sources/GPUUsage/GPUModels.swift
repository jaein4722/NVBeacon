import Foundation

struct AppSettings: Codable, Equatable, Sendable {
    static let legacyDefaultRemoteCommand = "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    static let defaultRemoteCommand = "nvidia-smi --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"

    var sshTarget: String = ""
    var sshPort: String = ""
    var sshIdentityFilePath: String = ""
    var pollIntervalSeconds: Int = 10
    var remoteCommand: String = Self.defaultRemoteCommand

    var isConfigured: Bool {
        !sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func normalized() -> Self {
        var copy = self
        copy.sshTarget = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sshPort = sshPort.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sshIdentityFilePath = NSString(string: sshIdentityFilePath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        copy.pollIntervalSeconds = min(max(pollIntervalSeconds, 3), 300)

        let trimmedCommand = remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCommand.isEmpty || trimmedCommand == Self.legacyDefaultRemoteCommand {
            copy.remoteCommand = Self.defaultRemoteCommand
        } else {
            copy.remoteCommand = trimmedCommand
        }

        return copy
    }

    var resolvedPort: Int? {
        guard let port = Int(sshPort), (1...65535).contains(port) else {
            return nil
        }

        return port
    }
}

struct GPUReading: Identifiable, Equatable, Sendable {
    let index: Int
    let name: String
    let uuid: String?
    let utilization: Int
    let memoryUsedMB: Int
    let memoryTotalMB: Int
    let temperatureCelsius: Int?
    let processes: [GPUProcessReading]

    var id: Int { index }

    var utilizationRatio: Double {
        Double(utilization) / 100.0
    }

    var memoryUsagePercent: Int {
        guard memoryTotalMB > 0 else { return 0 }
        return Int((Double(memoryUsedMB) / Double(memoryTotalMB) * 100.0).rounded())
    }

    var memoryUsageRatio: Double {
        Double(memoryUsagePercent) / 100.0
    }

    var memorySummary: String {
        "\(memoryUsedMB) / \(memoryTotalMB) MB"
    }

    var temperatureSummary: String {
        if let temperatureCelsius {
            return "\(temperatureCelsius) C"
        }

        return "--"
    }

    var processSummary: String {
        processes.isEmpty ? "No active processes" : "\(processes.count) active process\(processes.count == 1 ? "" : "es")"
    }
}

struct GPUSnapshot: Equatable, Sendable {
    let takenAt: Date
    let gpus: [GPUReading]

    var averageUtilization: Int {
        guard !gpus.isEmpty else { return 0 }
        return gpus.map(\.utilization).reduce(0, +) / gpus.count
    }

    var busyCount: Int {
        gpus.filter { $0.utilization >= 10 }.count
    }

    var totalProcessCount: Int {
        gpus.reduce(0) { $0 + $1.processes.count }
    }
}

struct GPUProcessReading: Identifiable, Equatable, Sendable {
    let gpuUUID: String
    let pid: Int
    let processName: String
    let usedGPUMemoryMB: Int

    var id: String {
        "\(gpuUUID):\(pid):\(processName)"
    }

    var memorySummary: String {
        "\(usedGPUMemoryMB) MB"
    }
}
