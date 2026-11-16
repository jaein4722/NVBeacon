import Foundation
import NVBeaconCore
import NVBeaconWindowsKit

/// What the flyout page receives. Swift sends domain values; the page owns
/// presentation-only state (collapsed sections, scrolling, hover).
struct FlyoutState: Encodable {
    struct Server: Encodable {
        let id: String
        let target: String
        let updatedAt: Double?
        let error: String?
        let stale: Bool
        let averageUtilization: Int?
        let memoryUsedMB: Int?
        let memoryTotalMB: Int?
        let cpuPercent: Int?
        let ramPercent: Int?
        let ramText: String?
        let gpus: [GPU]
    }

    struct GPU: Encodable {
        let index: Int
        let name: String
        let utilization: Int
        let memoryUsedMB: Int
        let memoryTotalMB: Int
        let temperature: Int?
        let processes: [Process]
    }

    struct Process: Encodable {
        let pid: Int
        let user: String
        let memoryMB: Int
        let command: String
    }

    let type = "state"
    /// Milliseconds since 1970, echoed back by the page to measure delivery time.
    let sentAt: Double
    let servers: [Server]

    init(states: [ServerState]) {
        sentAt = Date().timeIntervalSince1970 * 1000
        servers = states.map { state in
            let gpus = state.snapshot?.gpus ?? []
            let memory = state.snapshot?.hostMemory
            return Server(
                id: state.target,
                target: state.target,
                updatedAt: state.lastAttempt.map { $0.timeIntervalSince1970 * 1000 },
                error: state.lastError,
                stale: state.lastError != nil && state.snapshot != nil,
                averageUtilization: state.snapshot?.averageUtilization,
                memoryUsedMB: state.snapshot.map { _ in gpus.reduce(0) { $0 + $1.memoryUsedMB } },
                memoryTotalMB: state.snapshot.map { _ in gpus.reduce(0) { $0 + $1.memoryTotalMB } },
                cpuPercent: state.cpuPercent,
                ramPercent: memory?.usagePercent,
                ramText: memory.map {
                    "\(HostMemoryReading.capacityText(kibibytes: $0.usedKiB)) / \(HostMemoryReading.capacityText(kibibytes: $0.totalKiB))"
                },
                gpus: gpus.map { gpu in
                    GPU(index: gpu.index, name: gpu.name, utilization: gpu.utilization,
                        memoryUsedMB: gpu.memoryUsedMB, memoryTotalMB: gpu.memoryTotalMB,
                        temperature: gpu.temperatureCelsius,
                        processes: gpu.processes.map {
                            Process(pid: $0.pid, user: $0.user ?? $0.userID.map { "uid \($0)" } ?? "?",
                                    memoryMB: $0.usedGPUMemoryMB, command: $0.commandSummary)
                        })
                }
            )
        }
    }

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// Optional timing log for the prototype checks: `NVBeacon.exe --diag` writes
/// %LOCALAPPDATA%\NVBeacon\diag.log.
enum Diagnostics {
    nonisolated(unsafe) static var enabled = false
    private static let lock = NSLock()
    private static let start = ContinuousClock.now

    static var logURL: URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: base).appendingPathComponent("NVBeacon").appendingPathComponent("diag.log")
    }

    static func log(_ text: @autoclosure () -> String) {
        guard enabled else { return }
        let elapsed = ContinuousClock.now - start
        let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        let line = "\(milliseconds) ms  \(text())\n"
        lock.withLock {
            let url = logURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
