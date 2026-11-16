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

    public func execute(_ command: String) async throws -> RemoteCommandOutput {
        try await Task.sleep(for: .milliseconds(300))
        let t = Date().timeIntervalSince1970
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
            let busy = index % 3 != 2
            let utilization = busy ? wave(Double(index), 35, 99) : 0
            let memory = busy ? wave(Double(index) + 1, 20_000, 76_000) : 3
            let temperature = busy ? wave(Double(index) + 2, 48, 78) : 31
            gpuLines.append("\(index), \(name), GPU-\(target)-\(index), \(utilization), \(memory), 81559, \(temperature)")
            if busy {
                let pid = 41_000 + index * 17
                let user = index.isMultiple(of: 2) ? "alice" : "bob"
                let uid = user == "alice" ? 1001 : 1002
                processLines.append("GPU-\(target)-\(index),\(pid),\(uid),python,\(memory - 500)")
                psLines.append("\(pid) \(user) python train.py --config configs/run\(index).yaml")
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
