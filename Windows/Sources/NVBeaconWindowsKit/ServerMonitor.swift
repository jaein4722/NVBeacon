import Foundation
import NVBeaconCore

public struct ServerState: Sendable {
    public let server: ServerSettings
    public var snapshot: GPUSnapshot?
    public var cpuPercent: Int?
    public var networkUsage: NetworkUsage?
    public var lastError: String?
    public var lastAttempt: Date?
    public var isRefreshing = false

    public init(server: ServerSettings) { self.server = server }

    public var id: String { server.id }
    public var target: String { server.trimmedTarget }
    public var displayName: String { server.displayName }
}

/// Polls every enabled server on a fixed interval and reports each change.
public final class ServerMonitor: @unchecked Sendable {
    public let interval: Duration
    public let hostMetrics: HostMetricsOptions
    private let lock = NSLock()
    private var states: [ServerState]
    private var refreshRequested = false
    private var loop: Task<Void, Never>?
    private let onChange: @Sendable () -> Void

    public init(servers: [ServerSettings], interval: Duration, hostMetrics: HostMetricsOptions = .init(),
                onChange: @escaping @Sendable () -> Void) {
        self.interval = interval
        self.hostMetrics = hostMetrics
        self.states = servers.map(ServerState.init)
        self.onChange = onChange
    }

    /// Command-line and demo targets: plain SSH targets with default commands.
    public convenience init(targets: [String], interval: Duration, onChange: @escaping @Sendable () -> Void) {
        self.init(servers: targets.map { ServerSettings(sshTarget: $0) }, interval: interval, onChange: onChange)
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

    /// Polls one server right away unless it is already being polled.
    public func refresh(serverID: String) {
        guard let index = lock.withLock({ states.firstIndex { $0.id == serverID } }) else { return }
        Task.detached { [self] in await poll(index: index) }
    }

    private func takeRefreshRequest() -> Bool {
        lock.withLock {
            defer { refreshRequested = false }
            return refreshRequested
        }
    }

    public func pollAll() async {
        let count = lock.withLock { states.count }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask { [self] in await poll(index: index) }
            }
        }
    }

    /// Samples further apart than this restart CPU and network rate measurement,
    /// matching the macOS app (`max(60, interval × 4)`).
    private var maximumSampleInterval: TimeInterval {
        max(60, Double(interval.components.seconds) * 4)
    }

    static func transport(for server: ServerSettings) -> AnyRemoteCommandExecutor {
        let target = server.trimmedTarget
        if target.hasPrefix(DemoTransport.targetPrefix) {
            return AnyRemoteCommandExecutor(DemoTransport(target: target))
        }
        return AnyRemoteCommandExecutor(SSHTransport(target: target, port: server.resolvedPort,
                                                     identityFile: server.sshIdentityFilePath))
    }

    private func poll(index: Int) async {
        let server: ServerSettings? = lock.withLock {
            guard !states[index].isRefreshing, states[index].server.isPollable else { return nil }
            states[index].isRefreshing = true
            return states[index].server
        }
        guard let server else { return }
        onChange()

        let collector = MetricsCollector(transport: Self.transport(for: server))
        let result: Result<GPUSnapshot, Error>
        do {
            result = .success(try await collector.fetchSummary(
                gpuCommand: server.resolvedRemoteCommand,
                includesNetworkUsage: hostMetrics.network,
                hostMetrics: hostMetrics,
                hostCommand: server.resolvedHostCommand))
        } catch {
            result = .failure(error)
        }
        let maximum = maximumSampleInterval
        lock.withLock {
            var state = states[index]
            state.isRefreshing = false
            state.lastAttempt = Date()
            switch result {
            case .success(let snapshot):
                state.cpuPercent = snapshot.hostCPUSample.flatMap { current in
                    CPUUsageEvaluator.usage(previous: state.snapshot?.hostCPUSample, current: current,
                                            maximumInterval: maximum)
                } ?? snapshot.hostCPU
                state.networkUsage = snapshot.networkSample.flatMap { current in
                    NetworkUsageEvaluator.usage(previous: state.snapshot?.networkSample, current: current,
                                                maximumInterval: maximum)
                }
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
