import Foundation
import NVBeaconCore
import NVBeaconWindowsKit
import WinSDK

/// What the flyout page receives. Swift sends domain values and decisions (busy
/// counts, thresholds); the page owns presentation-only state such as collapsed
/// sections and expanded GPUs, and formats text in the chosen language.
struct FlyoutState: Encodable {
    struct Fleet: Encodable {
        let averageUtilization: Int
        let busyCount: Int
        let gpuCount: Int
        let processCount: Int
        let latestUpdate: Double?
        let isRefreshing: Bool
        let watchedProcessCount: Int
        let watchedIdleCount: Int
    }

    struct Server: Encodable {
        let id: String
        let name: String
        let isEnabled: Bool
        /// Why an enabled server shows no readings: "target" (no usable SSH target), "password"
        /// (no saved password), "passwordRejected" (the server refused it; polling paused) or
        /// "sshTooOld" (ssh.exe cannot log in with a password; `error` says why).
        let inactiveReason: String?
        let updatedAt: Double?
        let error: String?
        let isRefreshing: Bool
        let averageUtilization: Int?
        let busyCount: Int?
        let processCount: Int?
        let host: Host?
        let gpus: [GPU]
        /// The login user when "Highlight my processes" is on.
        let myUser: String?
        let loadingDetailGPUs: [Int]
        let detailError: String?
    }

    struct Host: Encodable {
        let cpuPercent: Int?
        let cpuMeasuring: Bool
        let memory: Memory?
        let network: Network?
    }

    struct Memory: Encodable {
        let usedPercent: Int
        let usedText: String
        let totalText: String
        let availableText: String
        let ratio: Double
        let swapUsedText: String?
        let swapTotalText: String?
        let swapRatio: Double?
        let swapTotalKiB: Int?
    }

    struct Network: Encodable {
        let downText: String
        let upText: String
        let totalText: String
        let interfaces: [String]
        let hasRates: Bool
    }

    struct GPU: Encodable {
        let index: Int
        let name: String
        let utilization: Int
        let memoryPercent: Int
        let memoryUsedMB: Int
        let memoryTotalMB: Int
        let temperature: String
        let processes: [Process]
        let hasMine: Bool
        let isWatchingIdle: Bool
    }

    struct Process: Encodable {
        let pid: Int
        let user: String
        let name: String
        let memoryText: String
        let command: String?
        let isMine: Bool
        let isWatched: Bool
    }

    let type = "state"
    /// Milliseconds since 1970, echoed back by the page to measure delivery time.
    let sentAt: Double
    let language: String
    let theme: String
    /// "popover" or "window"; the page shows the matching header buttons.
    let displayMode: String
    let alwaysOnTop: Bool
    /// Shows the history (chart) button in the header, as on macOS.
    let recordsGPUHistory: Bool
    let pollableServerCount: Int
    /// Data older than 2 × refresh interval + 15 s reads "Last update … ago".
    let staleAfterMs: Double
    let fleet: Fleet
    let servers: [Server]
    /// The latest status line (alert set, alert sent), shown for a short while.
    let notice: String?

    init(states: [ServerState], settings: WindowsSettings, watches: WatchStore, notice: (text: String, at: Date)?) {
        self.notice = notice.flatMap { Date().timeIntervalSince($0.at) < 20 ? $0.text : nil }
        sentAt = Date().timeIntervalSince1970 * 1000
        language = Theme.language
        theme = Theme.resolvedName
        displayMode = settings.displayMode.rawValue
        alwaysOnTop = settings.windowAlwaysOnTop
        recordsGPUHistory = settings.recordsGPUHistory
        let active = states.filter { $0.server.isPollable }
        pollableServerCount = active.count
        staleAfterMs = Double(settings.pollIntervalSeconds * 2 + 15) * 1000
        let allGPUs = active.flatMap { $0.snapshot?.gpus ?? [] }
        fleet = Fleet(
            averageUtilization: allGPUs.isEmpty ? 0 : Int((Double(allGPUs.reduce(0) { $0 + $1.utilization }) / Double(allGPUs.count)).rounded()),
            busyCount: allGPUs.filter(settings.isBusy).count,
            gpuCount: allGPUs.count,
            processCount: allGPUs.reduce(0) { $0 + $1.processes.count },
            // The oldest data feeding the totals, as on every platform (macOS 0.9).
            latestUpdate: active.compactMap { $0.snapshot?.takenAt }.min().map { $0.timeIntervalSince1970 * 1000 },
            isRefreshing: states.contains { $0.isRefreshing },
            watchedProcessCount: watches.processWatches.count,
            watchedIdleCount: watches.idleWatches.count
        )
        servers = states.map { Self.server($0, settings: settings, watches: watches) }
    }

    private static func server(_ state: ServerState, settings: WindowsSettings, watches: WatchStore) -> Server {
        let config = state.server
        // A disabled server keeps no readings in the popover, as on macOS.
        let inactiveReason: String? = !config.isEnabled ? nil
            : !config.isPollable ? "target"
            : state.sshTooOldForPassword != nil ? "sshTooOld"
            : state.passwordRejected ? "passwordRejected"
            : state.passwordMissing ? "password" : nil
        let snapshot = config.isPollable && inactiveReason == nil ? state.snapshot : nil
        let gpus = snapshot?.gpus ?? []
        return Server(
            id: state.id,
            name: state.displayName,
            isEnabled: config.isEnabled,
            inactiveReason: inactiveReason,
            updatedAt: snapshot.map { $0.takenAt.timeIntervalSince1970 * 1000 },
            error: state.sshTooOldForPassword.map { TrayApp.sshTooOldText($0, korean: Theme.language == "ko") } ?? state.lastError,
            isRefreshing: state.isRefreshing,
            averageUtilization: snapshot?.averageUtilization,
            busyCount: snapshot.map { _ in gpus.filter(settings.isBusy).count },
            processCount: snapshot?.totalProcessCount,
            host: snapshot.map { host(snapshot: $0, state: state) },
            gpus: gpus.map { gpu in
                let mine = { (process: GPUProcessReading) in settings.highlightsMyProcesses && state.isCurrentUserProcess(process) }
                return GPU(index: gpu.index, name: gpu.name, utilization: gpu.utilization,
                    memoryPercent: gpu.memoryUsagePercent, memoryUsedMB: gpu.memoryUsedMB,
                    memoryTotalMB: gpu.memoryTotalMB, temperature: gpu.temperatureSummary,
                    processes: gpu.processes.map { process in
                        Process(pid: process.pid, user: process.userSummary == "--" ? (process.userID.map { "uid \($0)" } ?? "--") : process.userSummary,
                                name: process.displayProcessName, memoryText: process.memorySummary,
                                command: process.showsSeparateCommandSummary ? process.commandSummary : nil,
                                isMine: mine(process),
                                isWatched: watches.isWatching(process, on: config))
                    },
                    hasMine: gpu.processes.contains(where: mine),
                    isWatchingIdle: watches.isWatchingIdle(gpu, on: config))
            },
            myUser: settings.highlightsMyProcesses && config.isPollable ? state.detectedSSHUsername : nil,
            loadingDetailGPUs: Array(state.loadingDetailGPUs).sorted(),
            detailError: state.detailError
        )
    }

    private static func host(snapshot: GPUSnapshot, state: ServerState) -> Host {
        let memory = snapshot.hostMemory.map { reading in
            Memory(usedPercent: reading.usagePercent,
                   usedText: HostMemoryReading.capacityText(kibibytes: reading.usedKiB),
                   totalText: HostMemoryReading.capacityText(kibibytes: reading.totalKiB),
                   availableText: HostMemoryReading.capacityText(kibibytes: reading.availableKiB),
                   ratio: reading.usageRatio,
                   swapUsedText: reading.swapUsedKiB.map { HostMemoryReading.capacityText(kibibytes: $0) },
                   swapTotalText: reading.swapTotalKiB.map { HostMemoryReading.capacityText(kibibytes: $0) },
                   swapRatio: reading.swapUsageRatio,
                   swapTotalKiB: reading.swapTotalKiB)
        }
        let network = state.networkUsage.map { usage in
            Network(downText: NetworkUsageFormatter.rateText(usage.receivedBytesPerSecond),
                    upText: NetworkUsageFormatter.rateText(usage.transmittedBytesPerSecond),
                    totalText: usage.totalSummary, interfaces: usage.interfaceNames, hasRates: usage.hasRates)
        }
        return Host(cpuPercent: state.cpuPercent, cpuMeasuring: snapshot.hostCPUSample != nil,
                    memory: memory, network: network)
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
