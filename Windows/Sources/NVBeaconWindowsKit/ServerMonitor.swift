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
    /// Password authentication with no saved password: not polled until one is saved.
    public var passwordMissing = false
    /// The server rejected the saved password. Polling stops until the password is
    /// saved again, so repeated failures cannot lock the account or get the address banned.
    public var passwordRejected = false

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

/// Logins whose saved password the server refused. The app keeps one for its whole
/// run, so a refusal outlives the monitor that is rebuilt on every settings edit: the
/// same wrong password is never tried again until it is saved again, or the server's
/// target, port, key file or authentication method changes.
public final class PasswordRejections: @unchecked Sendable {
    private let lock = NSLock()
    private var logins: Set<String> = []

    public init() {}

    private static func login(_ server: ServerSettings) -> String { server.id + "\n" + server.connectionFingerprint }

    public func contains(_ server: ServerSettings) -> Bool { lock.withLock { logins.contains(Self.login(server)) } }
    public func insert(_ server: ServerSettings) { _ = lock.withLock { logins.insert(Self.login(server)) } }
    /// The password was saved again or removed.
    public func remove(serverID: String) {
        lock.withLock { logins = logins.filter { !$0.hasPrefix(serverID + "\n") } }
    }
}

/// Polls every enabled server on a fixed interval and reports each change.
public final class ServerMonitor: @unchecked Sendable {
    public let interval: Duration
    public let hostMetrics: HostMetricsOptions
    public let highlightsMyProcesses: Bool
    /// Long-lived connections for servers set to "Reuse connection".
    public let connectionPool: SSHConnectionPool
    /// NVBeacon.exe, which answers ssh's password prompt (nil: no password authentication).
    public let askPassExecutable: String?
    public let passwordStore: SSHPasswordStore
    public let rejections: PasswordRejections
    private let lock = NSLock()
    private var states: [ServerState]
    private var refreshGeneration = 0
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
                askPassExecutable: String? = nil, passwordStore: SSHPasswordStore = SSHPasswordStore(),
                connectionPool: SSHConnectionPool = SSHConnectionPool(),
                rejections: PasswordRejections = PasswordRejections(),
                previous: [ServerState] = [],
                onChange: @escaping @Sendable () -> Void) {
        self.interval = interval
        self.askPassExecutable = askPassExecutable
        self.passwordStore = passwordStore
        self.connectionPool = connectionPool
        self.rejections = rejections
        self.hostMetrics = hostMetrics
        self.highlightsMyProcesses = highlightsMyProcesses
        self.samplesUserUtilization = samplesUserUtilization
        self.states = servers.map { server in
            var state = ServerState(server: server, detectedSSHUsername: highlightsMyProcesses
                ? Self.detectedSSHUsername(for: server, sshConfigHosts: sshConfigHosts, localUsername: localUsername) : nil)
            // A server that still connects the same way keeps what it showed until its next poll.
            if let old = previous.first(where: { $0.id == server.id && $0.server.connectionFingerprint == server.connectionFingerprint }) {
                state.snapshot = old.snapshot
                state.cpuPercent = old.cpuPercent
                state.networkUsage = old.networkUsage
                state.lastError = old.lastError
                state.lastAttempt = old.lastAttempt
                state.passwordMissing = old.passwordMissing
                if state.detectedSSHUsername == old.detectedSSHUsername { state.detectedSSHUserID = old.detectedSSHUserID }
            }
            state.passwordRejected = rejections.contains(server)
            return state
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

    /// Each server polls in its own loop (as on macOS 0.9), so a slow or unreachable
    /// server only delays itself.
    public func start() {
        let count = lock.withLock { states.count }
        loop = Task.detached { [self] in
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<count {
                    group.addTask { [self] in await serverLoop(index: index) }
                }
            }
        }
    }

    private func serverLoop(index: Int) async {
        var seenRefresh = lock.withLock { refreshGeneration }
        while !Task.isCancelled {
            await poll(index: index)
            let deadline = ContinuousClock.now + interval
            while !Task.isCancelled, ContinuousClock.now < deadline {
                let generation = lock.withLock { refreshGeneration }
                if generation != seenRefresh {
                    seenRefresh = generation
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Stops polling and closes every kept connection. A monitor replaced after a
    /// settings change passes false, so the next monitor reuses the connections.
    public func stop(closingConnections: Bool = true) {
        loop?.cancel()
        if closingConnections { connectionPool.closeAll() }
    }

    /// Every server's loop polls again right away.
    public func refreshNow() { lock.withLock { refreshGeneration += 1 } }

    /// Polls one server right away unless it is already being polled.
    public func refresh(serverID: String) {
        guard let index = lock.withLock({ states.firstIndex { $0.id == serverID } }) else { return }
        Task.detached { [self] in await poll(index: index) }
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

    /// A fresh connection per command, or a lane of the kept connections.
    func transport(for server: ServerSettings, lane: SSHConnectionPool.Lane) -> AnyRemoteCommandExecutor {
        let target = server.trimmedTarget
        if target.hasPrefix(DemoTransport.targetPrefix) {
            return AnyRemoteCommandExecutor(DemoTransport(target: target))
        }
        let authentication = self.authentication(for: server) ?? .key
        let identity = server.sshIdentityFilePath.trimmingCharacters(in: .whitespaces)
        if server.sshConnectionReuseMode == .newConnectionEachRefresh {
            return AnyRemoteCommandExecutor(SSHTransport(target: target, port: server.resolvedPort,
                                                         identityFile: identity, authentication: authentication))
        }
        return AnyRemoteCommandExecutor(connectionPool.transport(
            target: target, port: server.resolvedPort, identityFile: identity.isEmpty ? nil : identity,
            authentication: authentication, serverID: server.id, lane: lane))
    }

    /// nil when password authentication is selected but cannot be used.
    private func authentication(for server: ServerSettings) -> SSHAuthentication? {
        guard server.sshAuthenticationMode == .passwordBased else { return .key }
        guard let askPassExecutable else { return nil }
        return .password(account: server.id, askPassExecutable: askPassExecutable)
    }

    private func usesPassword(_ server: ServerSettings) -> Bool {
        server.sshAuthenticationMode == .passwordBased && !server.trimmedTarget.hasPrefix(DemoTransport.targetPrefix)
    }

    /// The password was saved or removed in Settings: forget the rejection, drop the
    /// connections that used the old password, and poll again.
    public func passwordChanged(serverID: String) {
        rejections.remove(serverID: serverID)
        connectionPool.close(serverID: serverID)
        lock.withLock {
            guard let index = states.firstIndex(where: { $0.id == serverID }) else { return }
            states[index].passwordRejected = false
            states[index].passwordMissing = false
            states[index].lastError = nil
        }
        onChange()
        refresh(serverID: serverID)
    }

    public enum ConnectionTestResult: Sendable {
        case success(gpuCount: Int, seconds: Double)
        case passwordMissing
        case failure(String)
    }

    /// Settings › Servers › Test Connection: runs the GPU query once over a new
    /// connection with the server's current settings. Nothing is stored.
    public static func testConnection(_ server: ServerSettings, askPassExecutable: String?,
                                      passwordStore: SSHPasswordStore = SSHPasswordStore()) async -> ConnectionTestResult {
        let target = server.trimmedTarget
        guard SSHTransport.isValidTarget(target) else { return .failure(SSHTransportError.invalidTarget(target).description) }
        let transport: AnyRemoteCommandExecutor
        if target.hasPrefix(DemoTransport.targetPrefix) {
            transport = AnyRemoteCommandExecutor(DemoTransport(target: target))
        } else {
            var authentication = SSHAuthentication.key
            if server.sshAuthenticationMode == .passwordBased {
                guard let askPassExecutable, passwordStore.hasPassword(for: server.id) else { return .passwordMissing }
                authentication = .password(account: server.id, askPassExecutable: askPassExecutable)
            }
            transport = AnyRemoteCommandExecutor(SSHTransport(target: target, port: server.resolvedPort,
                                                              identityFile: server.sshIdentityFilePath, authentication: authentication))
        }
        let started = ContinuousClock.now
        do {
            let snapshot = try await MetricsCollector(transport: transport).fetchSummary(
                gpuCommand: server.resolvedRemoteCommand, includesNetworkUsage: false,
                hostMetrics: HostMetricsOptions(cpu: false, memory: false, network: false),
                hostCommand: server.resolvedHostCommand)
            let elapsed = ContinuousClock.now - started
            return .success(gpuCount: snapshot.gpus.count,
                            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        } catch {
            return .failure(message(for: error))
        }
    }

    /// ssh's message when the server refuses the credentials.
    static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let error = error as? MetricsCollectionError, case .commandFailed(let status, let output) = error,
              status == 255 else { return false }
        return output.contains("Permission denied") || output.contains("Too many authentication failures")
    }

    private func poll(index: Int) async {
        let claimed: (ServerSettings, String?, Int?)? = lock.withLock {
            // The rejection may come from the monitor this one replaced, after it was built.
            if rejections.contains(states[index].server) { states[index].passwordRejected = true }
            guard !states[index].isRefreshing, states[index].server.isPollable,
                  !states[index].passwordRejected else { return nil }
            states[index].isRefreshing = true
            return (states[index].server, states[index].detectedSSHUsername, states[index].detectedSSHUserID)
        }
        guard let (server, username, knownUserID) = claimed else { return }
        onChange()

        if usesPassword(server), askPassExecutable == nil || !passwordStore.hasPassword(for: server.id) {
            lock.withLock {
                states[index].isRefreshing = false
                states[index].passwordMissing = true
                states[index].lastAttempt = Date()
            }
            onChange()
            return
        }

        let transport = self.transport(for: server, lane: .polling)
        let detailsTransport = self.transport(for: server, lane: .details)
        let collector = MetricsCollector(transport: transport)
        // Concurrent with the summary, so pmon's one-second sample adds no latency (as on macOS).
        // Only after a successful poll, so a new connection with a wrong password is not
        // opened twice at once.
        let samplesUsers: Bool = samplesUserUtilization && lock.withLock {
            guard states[index].snapshot != nil, states[index].lastError == nil else { return false }
            let now = Date()
            if let last = lastUserSample[server.id], now.timeIntervalSince(last) < UserUtilizationSampler.minimumInterval { return false }
            lastUserSample[server.id] = now
            return true
        }
        async let userUtilization: [Int: [String: Double]]? = samplesUsers ? UserUtilizationSampler.fetch(transport: detailsTransport) : nil
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
            state.passwordMissing = false
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
                if usesPassword(server), Self.isAuthenticationFailure(error) {
                    state.passwordRejected = true
                    rejections.insert(server)
                }
            }
            states[index] = state
        }
        if lock.withLock({ states[index].passwordRejected }) { connectionPool.close(serverID: server.id) }
        onChange()
        let users = await userUtilization
        if let afterPoll, let merged = lock.withLock({ states[index].snapshot }), case .success = result {
            await afterPoll(PollResult(server: server, snapshot: merged, transport: detailsTransport, userUtilization: users))
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
                  states[index].server.isPollable, !states[index].passwordRejected,
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
                result = .success(try await Self.fetchProcessStatuses(pids: processes.map(\.pid), transport: self.transport(for: server, lane: .details)))
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
            return detail
        }
        return String(describing: error)
    }
}
