import Foundation
import NVBeaconCore

/// Type-erases a transport so the monitor can mix real and demo servers.
public struct AnyRemoteCommandExecutor: RemoteCommandExecuting {
    private let run: @Sendable (String) async throws -> RemoteCommandOutput

    public init(_ transport: some RemoteCommandExecuting) {
        run = { try await transport.execute($0) }
    }

    public func execute(_ command: String) async throws -> RemoteCommandOutput {
        try await run(command)
    }
}

/// Answers Core's summary command with made-up but well-formed output, so the
/// UI can be tried without a GPU server. The text goes through Core's real parser.
public struct DemoTransport: RemoteCommandExecuting {
    /// A colon keeps demo names apart from real SSH host aliases.
    public static let targetPrefix = "demo:"
    public static let demoTargets = ["demo:a100", "demo:h100"]

    public let target: String

    public init(target: String) { self.target = target }

    /// The demo servers' login user, so "Mine" highlighting can be tried too.
    public static let loginUser = "alice"

    // Demo jobs: GPU i runs pid 41000 + 17·i; even GPUs belong to alice. Every third GPU
    // is idle, and GPU 3's job stops and restarts every 90 s so exit alerts can be tried.
    private static func user(_ index: Int) -> String { index.isMultiple(of: 2) ? "alice" : "bob" }
    private static func uid(_ index: Int) -> Int { index.isMultiple(of: 2) ? 1001 : 1002 }
    private static func commandLine(_ index: Int) -> String { "python train.py --config configs/run\(index).yaml --seed \(index)" }
    private static func isRunning(_ index: Int, at time: Double) -> Bool {
        guard index % 3 != 2 else { return false }
        return index != 3 || Int(time / 90).isMultiple(of: 2)
    }

    public func execute(_ command: String) async throws -> RemoteCommandOutput {
        try await Task.sleep(for: .milliseconds(300))
        let now = Date().timeIntervalSince1970
        if command.hasPrefix("id -u") {
            return RemoteCommandOutput(standardOutput: "1001\n", standardError: "", exitStatus: 0)
        }
        if command.hasPrefix("ps -o pid=") {
            // Both ps lookups the app uses: "pid uid user args" and "pid user args".
            let withUID = command.hasPrefix("ps -o pid= -o uid=")
            let pids = command.split(separator: "\"").dropFirst().first?.split(separator: ",").compactMap { Int($0) } ?? []
            let lines = pids.compactMap { pid -> String? in
                let index = (pid - 41_000) / 17
                guard (pid - 41_000) % 17 == 0, Self.isRunning(index, at: now) else { return nil }
                return withUID ? "\(pid) \(Self.uid(index)) \(Self.user(index)) \(Self.commandLine(index))"
                    : "\(pid) \(Self.user(index)) \(Self.commandLine(index))"
            }
            return RemoteCommandOutput(standardOutput: lines.joined(separator: "\n"), standardError: "", exitStatus: 0)
        }
        let t = now
        let wave = { (phase: Double, low: Double, high: Double) -> Int in
            Int(low + (high - low) * (0.5 + 0.5 * sin(t / 7 + phase)))
        }
        let isH100 = target.contains("h100")
        let name = isH100 ? "NVIDIA H100 80GB HBM3" : "NVIDIA A100-SXM4-80GB"
        let count = isH100 ? 8 : 4
        var gpuLines: [String] = []
        var processLines: [String] = []
        var psLines: [String] = []
        for index in 0..<count {
            let busy = Self.isRunning(index, at: t)
            let utilization = busy ? wave(Double(index), 35, 99) : 0
            let memory = busy ? wave(Double(index) + 1, 20_000, 76_000) : 3
            let temperature = busy ? wave(Double(index) + 2, 48, 78) : 31
            gpuLines.append("\(index), \(name), GPU-\(target)-\(index), \(utilization), \(memory), 81559, \(temperature)")
            if busy {
                let pid = 41_000 + index * 17
                processLines.append("GPU-\(target)-\(index),\(pid),\(Self.uid(index)),python,\(memory - 500)")
                psLines.append("\(pid) \(Self.user(index)) \(Self.commandLine(index))")
            }
        }
        let cpuBase = UInt64(t * 100)
        let uptime = t.truncatingRemainder(dividingBy: 3 * 86_400)  // counters as if booted within 3 days
        let output = """
        \(gpuLines.joined(separator: "\n"))

        \(RemoteMetricCommands.processSectionSeparator)
        \(processLines.joined(separator: "\n"))
        \(RemoteMetricCommands.psSectionSeparator)
        \(psLines.joined(separator: "\n"))

        \(RemoteMetricCommands.hostSectionSeparator)
        \(RemoteMetricCommands.cpuSectionSeparator)
        cpu \(cpuBase * 6) 0 \(cpuBase) \(cpuBase * 3) 0 0 0 0
        btime 1700000000
        \(RemoteMetricCommands.memorySectionSeparator)
        MemTotal: 1056768000 kB
        MemAvailable: \(UInt64(wave(4, 300_000_000, 800_000_000))) kB
        SwapTotal: 8388604 kB
        SwapFree: \(UInt64(wave(5, 7_800_000, 8_388_604))) kB
        \(RemoteMetricCommands.networkSectionSeparator)
        eth0 \(UInt64(uptime * 48_000_000)) \(UInt64(uptime * 9_500_000))
        ib0 \(UInt64(uptime * 210_000_000)) \(UInt64(uptime * 205_000_000))
        """
        return RemoteCommandOutput(standardOutput: output, standardError: "", exitStatus: 0)
    }
}
