import Foundation
import NVBeaconCore

/// Plain-text descriptions shared by the tray menu, its tooltip and the CLI.
public enum SummaryFormatter {
    public static func gigabytes(fromMB megabytes: Int) -> String {
        String(format: "%.1f", Double(megabytes) / 1024)
    }

    public static func gpuLine(_ gpu: GPUReading) -> String {
        var parts = ["GPU \(gpu.index)  \(gpu.utilization)%",
                     "\(gigabytes(fromMB: gpu.memoryUsedMB))/\(gigabytes(fromMB: gpu.memoryTotalMB)) GB"]
        if let temperature = gpu.temperatureCelsius { parts.append("\(temperature)°C") }
        parts.append(gpu.processes.isEmpty ? "idle" : "\(gpu.processes.count) proc")
        return parts.joined(separator: "  ·  ") + "  —  \(gpu.name)"
    }

    public static func processLine(_ process: GPUProcessReading) -> String {
        let owner = process.userID.map { "uid \($0)" } ?? "uid ?"
        return "PID \(process.pid)  ·  \(owner)  ·  \(process.usedGPUMemoryMB) MB  ·  \(process.displayProcessName)"
    }

    public static func hostLine(_ state: ServerState) -> String? {
        var parts: [String] = []
        if let cpu = state.cpuPercent { parts.append("CPU \(cpu)%") }
        if let memory = state.snapshot?.hostMemory {
            parts.append("RAM \(memory.usagePercent)% (\(HostMemoryReading.capacityText(kibibytes: memory.usedKiB)) / \(HostMemoryReading.capacityText(kibibytes: memory.totalKiB)))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// One short line per server, for the 127-character tray tooltip.
    public static func compactLine(_ state: ServerState) -> String {
        if state.lastError != nil, state.snapshot == nil { return "\(state.target): error" }
        guard let snapshot = state.snapshot else { return "\(state.target): connecting…" }
        let used = snapshot.gpus.reduce(0) { $0 + $1.memoryUsedMB }
        let total = snapshot.gpus.reduce(0) { $0 + $1.memoryTotalMB }
        let stale = state.lastError == nil ? "" : " (stale)"
        return "\(state.target): \(snapshot.averageUtilization)% · \(gigabytes(fromMB: used))/\(gigabytes(fromMB: total)) GB\(stale)"
    }

    public static func tooltip(_ states: [ServerState]) -> String {
        let text = (["NVBeacon"] + states.map(compactLine)).joined(separator: "\n")
        return text.count <= 127 ? text : String(text.prefix(126)) + "…"
    }

    public static func report(_ state: ServerState) -> String {
        var lines = ["== \(state.target)"]
        if let error = state.lastError { lines.append("error: \(error)") }
        if let snapshot = state.snapshot {
            for gpu in snapshot.gpus {
                lines.append(gpuLine(gpu))
                lines += gpu.processes.map { "    " + processLine($0) }
            }
            if let host = hostLine(state) { lines.append(host) }
        }
        return lines.joined(separator: "\n")
    }
}
