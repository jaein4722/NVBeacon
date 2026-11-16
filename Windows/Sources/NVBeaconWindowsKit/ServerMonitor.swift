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
    /// The remote login user, from the target, the ssh config, or the local user name.
    public var detectedSSHUsername: String?
    /// Resolved with `id -u` once per monitor when highlighting is on.
    public var detectedSSHUserID: Int?
    /// GPU indexes whose process details are being fetched.
    public var loadingDetailGPUs: Set<Int> = []
    public var detailError: String?

    public init(server: ServerSettings, detectedSSHUsername: String? = nil) {
        self.server = server
        self.detectedSSHUsername = detectedSSHUsername
    }

    public var id: String { server.id }
    public var target: String { server.trimmedTarget }
    public var displayName: String { server.displayName }

    /// Matches the macOS rule: compare uids when both are known, otherwise user names.
    public func isCurrentUserProcess(_ process: GPUProcessReading) -> Bool {
        if let uid = detectedSSHUserID, let processUID = process.userID { return uid == processUID }
        guard let name = detectedSSHUsername else { return false }
        return process.user?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == name
    }
}

/// Polls every enabled server on a fixed interval and reports each change.
public final class ServerMonitor: @unchecked Sendable {
    public let interval: Duration
    public let hostMetrics: HostMetricsOptions
    public let highlightsMyProcesses: Bool
    private let lock = NSLock()
    private var states: [ServerState]
    private var refreshRequested = false
    private var loop: Task<Void, Never>?
    private let onChange: @Sendable () -> Void
    /// What a successful poll hands to `afterPoll` (alerts and GPU history).
    public struct PollResult: Sendable {
        public let server: ServerSettings
        public let snapshot: GPUSnapshot
        public let transport: AnyRemoteCommandExecutor
        /// Per-user SM % from `nvidia-smi pmon`, when it was sampled this poll.
        public let userUtilization: [Int: [String: Double]]?
    }

    /// Runs after each successful poll with the merged snapshot.
    public var afterPoll: (@Sendable (PollResult) async -> Void)?
    /// GPU History: sample per-user utilization at most once a minute per server.
    public let samplesUserUtilization: Bool
    private var lastUserSample: [String: Date] = [:]

    public init(servers: [ServerSettings], interval: Duration, hostMetrics: HostMetricsOptions = .init(),
                highlightsMyProcesses: Bool = false, samplesUserUtilization: Bool = false,
                sshConfigHosts: [SSHConfigHost] = [],
                localUsername: String? = ProcessInfo.processInfo.environment["USERNAME"],
                onChange: @escaping @Sendable () -> Void) {
        self.interval = interval
        self.hostMetrics = hostMetrics
        self.highlightsMyProcesses = highlightsMyProcesses
        self.samplesUserUtilization = samplesUserUtilization
        self.states = servers.map { server in
            ServerState(server: server, detectedSSHUsername: highlightsMyProcesses
                ? Self.detectedSSHUsername(for: server, sshConfigHosts: sshConfigHosts, localUsername: localUsername) : nil)
        }
        self.onChange = onChange
    }

    /// Ported from macOS `ServerConfig.detectedSSHUsername`: `user@` in the target,
    /// then the alias's `User` in the ssh config, then the local account name
    /// (which OpenSSH also uses when nothing else is set).
    public static func detectedSSHUsername(for server: ServerSettings, sshConfigHosts: [SSHConfigHost],
                                           localUsername: String?) -> String? {
        let target = server.trimmedTarget
        func normalized(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed.lowercased()
        }
        if target.contains("@") { return normalized(target.components(separatedBy: "@").first) }
        if let user = normalized(sshConfigHosts.first { $0.alias == target }?.user) { return user }
        if target.hasPrefix(DemoTransport.targetPrefix) { return DemoTransport.loginUser }
        guard !target.isEmpty else { return nil }
        return normalized(localUsername)
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
        let claimed: (ServerSettings, String?, Int?)? = lock.withLock {
            guard !states[index].isRefreshing, states[index].server.isPollable else { return nil }
            states[index].isRefreshing = true
            return (states[index].server, states[index].detectedSSHUsername, states[index].detectedSSHUserID)
        }
        guard let (server, username, knownUserID) = claimed else { return }
        onChange()

        let transport = Self.transport(for: server)
        let collector = MetricsCollector(transport: transport)
        // Concurrent with the summary, so pmon's one-second sample adds no latency (as on macOS).
        let samplesUsers: Bool = samplesUserUtilization && lock.withLock {
            let now = Date()
            if let last = lastUserSample[server.id], now.timeIntervalSince(last) < UserUtilizationSampler.minimumInterval { return false }
            lastUserSample[server.id] = now
            return true
        }
        async let userUtilization: [Int: [String: Double]]? = samplesUsers ? UserUtilizationSampler.fetch(transport: transport) : nil
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
        // Like macOS: look the login user's uid up once, after a successful poll.
        var userID = knownUserID
        if highlightsMyProcesses, userID == nil, let username, case .success = result {
            userID = try? await Self.fetchRemoteUserID(username: username, transport: transport)
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
                // Keep user names and command lines already resolved for processes that are still running.
                state.snapshot = snapshot.mergingResolvedProcessMetadata(from: state.snapshot)
                state.detectedSSHUserID = userID
                state.lastError = nil
            case .failure(let error):
                state.lastError = Self.message(for: error)
            }
            states[index] = state
        }
        onChange()
        let users = await userUtilization
        if let afterPoll, let merged = lock.withLock({ states[index].snapshot }), case .success = result {
            await afterPoll(PollResult(server: server, snapshot: merged, transport: transport, userUtilization: users))
        }
    }

    // MARK: Process details (macOS `loadProcessDetails`)

    /// Looks up user names and full command lines for one GPU's processes with `ps`.
    ///
    /// Unlike the macOS app, the reply is merged into the snapshot that is current
    /// when it arrives, and only into processes that are still listed, so a slow
    /// reply can never bring back an older process list.
    public func loadProcessDetails(serverID: String, gpuIndex: Int) {
        let claimed: (ServerSettings, [GPUProcessReading])? = lock.withLock {
            guard let index = states.firstIndex(where: { $0.id == serverID }),
                  states[index].server.isPollable,
                  !states[index].loadingDetailGPUs.contains(gpuIndex),
                  let gpu = states[index].snapshot?.gpus.first(where: { $0.index == gpuIndex }),
                  !gpu.processes.isEmpty else { return nil }
            states[index].loadingDetailGPUs.insert(gpuIndex)
            return (states[index].server, gpu.processes)
        }
        guard let (server, processes) = claimed else { return }
        onChange()
        Task.detached { [self] in
            let result: Result<[RemoteProcessStatus], Error>
            do {
                result = .success(try await Self.fetchProcessStatuses(pids: processes.map(\.pid), transport: Self.transport(for: server)))
            } catch {
                result = .failure(error)
            }
            lock.withLock {
                guard let index = states.firstIndex(where: { $0.id == serverID }) else { return }
                states[index].loadingDetailGPUs.remove(gpuIndex)
                switch result {
                case .success(let statuses):
                    let byPID = Dictionary(statuses.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
                    let enriched = processes.compactMap { process -> GPUProcessReading? in
                        guard let details = byPID[process.pid] else { return nil }
                        return GPUProcessReading(gpuUUID: process.gpuUUID, pid: process.pid, processName: process.processName,
                                                 usedGPUMemoryMB: process.usedGPUMemoryMB, userID: details.userID ?? process.userID,
                                                 user: details.user, commandLine: details.commandLine)
                    }
                    states[index].snapshot = states[index].snapshot?.applyingResolvedProcessMetadata(enriched)
                    states[index].detailError = nil
                case .failure(let error):
                    states[index].detailError = Self.message(for: error)
                }
            }
            onChange()
        }
    }

    // The two commands below are copied unchanged from the macOS SSHMetricsFetcher.

    static func detailedPSLookupCommand(pids: [Int]) -> String {
        let pidList = pids.map(String.init).joined(separator: ",")
        return """
        ps -o pid= -o uid= -o user= -o args= -p "\(pidList)" 2>/dev/null || true
        """
    }

    static func remoteUIDLookupCommand(username: String) -> String {
        "id -u -- \(SSHTransport.shellQuoted(username))"
    }

    static func fetchProcessStatuses(pids: [Int], transport: AnyRemoteCommandExecutor) async throws -> [RemoteProcessStatus] {
        let unique = Array(Set(pids)).sorted()
        guard !unique.isEmpty else { return [] }
        let output = try await transport.execute(detailedPSLookupCommand(pids: unique))
        guard output.exitStatus == 0 else {
            throw MetricsCollectionError.commandFailed(output.exitStatus, output.standardError.isEmpty ? output.standardOutput : output.standardError)
        }
        return try MetricsParser.parseDetailedPSSection(output.standardOutput)
    }

    static func fetchRemoteUserID(username: String, transport: AnyRemoteCommandExecutor) async throws -> Int? {
        let output = try await transport.execute(remoteUIDLookupCommand(username: username))
        guard output.exitStatus == 0 else { return nil }
        return Int(output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
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
