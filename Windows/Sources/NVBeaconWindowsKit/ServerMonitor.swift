import Foundation
import NVBeaconCore

public struct ServerState: Sendable {
    public let target: String
    public var snapshot: GPUSnapshot?
    public var cpuPercent: Int?
    public var lastError: String?
    public var lastAttempt: Date?

    public init(target: String) { self.target = target }
}

/// Polls every server on a fixed interval and reports each finished poll.
public final class ServerMonitor: @unchecked Sendable {
    public let interval: Duration
    private let lock = NSLock()
    private var states: [ServerState]
    private var refreshRequested = false
    private var loop: Task<Void, Never>?
    private let onChange: @Sendable () -> Void

    public init(targets: [String], interval: Duration, onChange: @escaping @Sendable () -> Void) {
        self.interval = interval
        self.states = targets.map(ServerState.init)
        self.onChange = onChange
    }

    public var snapshot: [ServerState] { lock.withLock { states } }

    public func start() {
        loop = Task.detached { [self] in
            while !Task.isCancelled {
                await pollAll()
                let deadline = ContinuousClock.now + interval
                while !Task.isCancelled, ContinuousClock.now < deadline, !takeRefreshRequest() {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }

    public func stop() { loop?.cancel() }

    public func refreshNow() { lock.withLock { refreshRequested = true } }

    private func takeRefreshRequest() -> Bool {
        lock.withLock {
            defer { refreshRequested = false }
            return refreshRequested
        }
    }

    public func pollAll() async {
        let targets = lock.withLock { states.map(\.target) }
        await withTaskGroup(of: Void.self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask { [self] in await poll(index: index, target: target) }
            }
        }
    }

    private func poll(index: Int, target: String) async {
        let collector = MetricsCollector(transport: SSHTransport(target: target))
        let result: Result<GPUSnapshot, Error>
        do { result = .success(try await collector.fetchSummary()) } catch { result = .failure(error) }
        if Task.isCancelled { return }
        lock.withLock {
            var state = states[index]
            state.lastAttempt = Date()
            switch result {
            case .success(let snapshot):
                let maximum = Double(interval.components.seconds) * 3 + 5
                state.cpuPercent = snapshot.hostCPUSample.flatMap { current in
                    CPUUsageEvaluator.usage(previous: state.snapshot?.hostCPUSample, current: current,
                                            maximumInterval: maximum)
                } ?? snapshot.hostCPU
                state.snapshot = snapshot
                state.lastError = nil
            case .failure(let error):
                state.lastError = Self.message(for: error)
            }
            states[index] = state
        }
        onChange()
    }

    static func message(for error: Error) -> String {
        if let error = error as? MetricsCollectionError, case .commandFailed(let status, let output) = error {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            if detail.isEmpty { return "ssh exited with status \(status)" }
            if detail.contains("Host key verification failed") {
                return detail + " Connect once with ssh from a terminal to accept the host key."
            }
            if detail.contains("Permission denied") {
                return detail + " Only key or ssh-agent authentication is supported for now."
            }
            return detail
        }
        return String(describing: error)
    }
}
