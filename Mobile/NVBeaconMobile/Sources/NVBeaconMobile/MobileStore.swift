import Foundation
import Observation
import NVBeaconCore

public struct GPULoadSample: Identifiable, Sendable {
    public let time: Date
    public let load: Int
    public let memory: Int
    public var id: Date { time }

    public init(_ snapshot: GPUSnapshot) {
        time = snapshot.takenAt
        load = snapshot.averageUtilization
        let capacity = snapshot.gpus.reduce(0.0) { $0 + Double($1.memoryTotalMB) }
        let used = snapshot.gpus.reduce(0.0) { $0 + Double($1.memoryUsedMB) }
        memory = capacity > 0 ? Int((100 * used / capacity).rounded()) : 0
    }
}

public struct ServerReading: Sendable {
    public var snapshot: GPUSnapshot?
    public var error: String?
    /// The error text includes output from the remote server; show it verbatim, never as Markdown.
    public fileprivate(set) var errorIncludesRemoteOutput = false
    fileprivate var errorCategory: String?
    public var hostKey: String?
    public var fingerprint: String?
    public var networkUsage: NetworkUsage?
    public fileprivate(set) var history: [GPULoadSample] = []
    public init() {}
}

public typealias SnapshotLoader = @Sendable (MobileServer, MobileCredential) async throws -> GPUSnapshot

@MainActor @Observable public final class MobileStore {
    public private(set) var servers: [MobileServer] = []
    public private(set) var readings: [UUID: ServerReading] = [:]
    public private(set) var refreshingServerIDs: Set<UUID> = []
    public var isRefreshing: Bool { !refreshingServerIDs.isEmpty }
    public private(set) var generation = UUID()
    public var message: String?
    public var refreshInterval: Int {
        didSet {
            defaults.set(min(300, max(5, refreshInterval)), forKey: "refreshInterval")
            generation = UUID()
        }
    }
    public var collectsCPU: Bool { didSet { changeCollection("collectsCPU", collectsCPU) } }
    public var collectsMemory: Bool { didSet { changeCollection("collectsMemory", collectsMemory) } }
    public var collectsNetwork: Bool { didSet { changeCollection("collectsNetwork", collectsNetwork) } }
    public var highlightMine: Bool { didSet { defaults.set(highlightMine, forKey: "highlightMine") } }
    public var busyMode: BusyDetectionMode { didSet { defaults.set(busyMode.rawValue, forKey: "busyMode") } }
    public var memoryThreshold: Int { didSet { defaults.set(memoryThreshold, forKey: "busyMB") } }
    public var utilizationThreshold: Int { didSet { defaults.set(utilizationThreshold, forKey: "busyPercent") } }

    public func isBusy(_ gpu: GPUReading) -> Bool {
        gpu.isBusy(mode: busyMode, memoryThresholdMB: memoryThreshold, utilizationThreshold: utilizationThreshold)
    }

    public func isMine(_ process: GPUProcessReading, on server: MobileServer) -> Bool {
        guard highlightMine else { return false }
        if let uid = readings[server.id]?.snapshot?.sshUserID, let owner = process.userID { return uid == owner }
        let login = server.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !login.isEmpty else { return false }
        return process.user?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == login
    }

    private func changeCollection(_ name: String, _ value: Bool) {
        defaults.set(value, forKey: name)
        resetBaselines()
        revision = UUID()
        generation = UUID()
    }

    private func resetBaselines() {
        cpuSamples.removeAll()
        networkSamples.removeAll()
    }

    @ObservationIgnored private var cpuSamples: [UUID: HostCPUSample] = [:]
    @ObservationIgnored private var networkSamples: [UUID: NetworkSample] = [:]
    @ObservationIgnored private var sessions: [UUID: SSHTransport] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let vault: any CredentialStorage
    @ObservationIgnored private let loader: SnapshotLoader?
    @ObservationIgnored private var transferState = MobileTransferState()
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var refreshBatch: (task: Task<Void, Never>, ids: Set<UUID>, revision: UUID)?

    public init(defaults: UserDefaults = .standard, vault: any CredentialStorage = CredentialVault(),
                loader: SnapshotLoader? = nil) {
        self.defaults = defaults
        self.vault = vault
        self.loader = loader
        collectsCPU = defaults.object(forKey: "collectsCPU") as? Bool ?? true
        collectsMemory = defaults.object(forKey: "collectsMemory") as? Bool ?? true
        collectsNetwork = defaults.object(forKey: "collectsNetwork") as? Bool ?? true
        highlightMine = defaults.object(forKey: "highlightMine") as? Bool ?? true
        busyMode = defaults.string(forKey: "busyMode").flatMap(BusyDetectionMode.init(rawValue:)) ?? .activeProcess
        memoryThreshold = defaults.object(forKey: "busyMB") as? Int ?? 50
        utilizationThreshold = defaults.object(forKey: "busyPercent") as? Int ?? 10
        refreshInterval = min(300, max(5, defaults.object(forKey: "refreshInterval") as? Int ?? 10))
        if let data = defaults.data(forKey: "mobileServers") {
            do {
                let decoder = JSONDecoder()
                if let saved = try? decoder.decode(MobileTransferState.self, from: data) {
                    transferState = saved
                    servers = saved.servers
                } else {
                    servers = try decoder.decode([MobileServer].self, from: data)
                    transferState.servers = servers
                }
            }
            catch {
                // Keep the unreadable record under its own key before the next save replaces it.
                defaults.set(data, forKey: "mobileServers.unreadable.\(Int(Date().timeIntervalSince1970))")
                message = "Saved server settings could not be read. They have not been overwritten."
            }
        }
        if !transferState.journal.isEmpty {
            do { try recoverInterruptedTransfer() }
            catch { message = MacTransferImportError.recovery.localizedDescription }
        }
    }

    public func credential(for server: MobileServer) throws -> MobileCredential {
        try recoverInterruptedTransfer()
        return try vault.read(server.id) ?? MobileCredential()
    }

    /// Pass `keyAlreadyValidated` after running `SSHTransport.validatePrivateKey` off the main actor;
    /// unlocking an encrypted key runs bcrypt and can take seconds.
    public func save(_ server: MobileServer, credential: MobileCredential, keyAlreadyValidated: Bool = false) throws {
        try recoverInterruptedTransfer()
        var normalized = try server.validated()
        if normalized.isEnabled { normalized.transferSetupIssue = nil }
        guard !normalized.isEnabled || !credential.secret.isEmpty else { throw MobileError.missingCredential }
        if normalized.authentication == .keyBased, !credential.secret.isEmpty, !keyAlreadyValidated {
            try SSHTransport.validatePrivateKey(credential)
        }
        var next = servers
        if let index = next.firstIndex(where: { $0.id == server.id }) { next[index] = normalized }
        else {
            guard next.count < ServerSettingsBackup.maximumServers else { throw ServerSettingsBackup.BackupError.invalidServerCount }
            next.append(normalized)
        }
        discardSession(server.id)
        try vault.write(credential, for: server.id)
        try persist(next)
        readings[server.id] = nil
    }

    public func delete(_ server: MobileServer) throws {
        try deleteServers([server.id])
    }

    public func deleteServers(_ ids: Set<UUID>) throws {
        try recoverInterruptedTransfer()
        // Persist each successful removal before moving on to the next Keychain item.
        // On failure the remaining rows are still selectable for retry.
        for server in servers where ids.contains(server.id) {
            try vault.delete(server.id)
            try persist(servers.filter { $0.id != server.id })
            readings[server.id] = nil
        }
    }

    public func reorderServers(_ ids: [UUID]) throws {
        let current = servers.map(\.id)
        guard ids != current, ids.count == current.count, Set(ids) == Set(current) else { return }
        let byID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        try persist(ids.compactMap { byID[$0] }, affectsMonitoring: false)
    }

    public func trustHost(for server: MobileServer, key: String) throws {
        // A prompt from an old endpoint must never authorize the edited endpoint.
        guard let current = servers.first(where: { $0.id == server.id }),
              current.endpoint == server.endpoint, readings[server.id]?.hostKey == key else { return }
        var trusted = current
        trusted.trustedHostKey = key
        trusted.trustedEndpoint = current.endpoint
        try persist(servers.map { $0.id == server.id ? trusted : $0 })
        readings[server.id] = nil
    }

    public func importServers(_ backup: ServerSettingsBackup) throws {
        try backup.validate()
        guard servers.count + backup.servers.count <= ServerSettingsBackup.maximumServers else {
            throw ServerSettingsBackup.BackupError.invalidServerCount
        }
        try persist(servers + backup.servers.map(MobileServer.importing))
    }

    public func exportServers() throws -> Data {
        try ServerSettingsBackup(servers: servers.map(\.backupEntry)).encoded()
    }

    private func persist(_ next: [MobileServer], affectsMonitoring: Bool = true) throws {
        var state = transferState
        state.servers = next
        try writeState(state)
        for old in servers where !next.contains(old) {
            discardSession(old.id)
            cpuSamples[old.id] = nil
            networkSamples[old.id] = nil
        }
        servers = next
        if affectsMonitoring {
            revision = UUID()
            generation = UUID()
        }
    }

    private func writeState(_ state: MobileTransferState) throws {
        let data = try JSONEncoder().encode(state)
        defaults.set(data, forKey: "mobileServers")
        transferState = state
    }

    /// Only absent or entirely empty Keychain slots can be import destinations.
    /// This journal contains UUIDs and presence bits, never credential contents.
    private func recoverInterruptedTransfer() throws {
        guard !transferState.journal.isEmpty else { return }
        // A failed final preference flush leaves the durable outcome uncertain.
        // First ensure the old profiles and rollback journal are on disk.
        guard defaults.synchronize() else { throw MacTransferImportError.recovery }
        for entry in transferState.journal {
            if entry.wasEmptyItem {
                try vault.write(MobileCredential(), for: entry.id)
            } else {
                try vault.delete(entry.id)
            }
        }
        var state = transferState
        state.journal.removeAll()
        try writeState(state)
        guard defaults.synchronize() else { throw MacTransferImportError.recovery }
    }

    public func reviewTransfer(_ incoming: IncomingMacTransfer) throws -> MacTransferReview {
        try recoverInterruptedTransfer()
        if transferState.receipts.contains(incoming.id) {
            return MacTransferReview(rows: [], alreadyImported: true)
        }
        // Names can distinguish intentional profiles that share an endpoint.
        // Multiple possible destinations always require manual setup.
        func sameEndpoint(_ host: String, _ user: String, _ port: Int, as server: MobileServer) -> Bool {
            host.caseInsensitiveCompare(server.host) == .orderedSame && user == server.username && port == server.port
        }
        var claimed = Set<UUID>()
        let rows = try incoming.servers.map { remote -> MacTransferReview.Row in
            let key = remote.credentialID.flatMap { incoming.credentials[$0] }
            var action = MacTransferReview.Action.add
            var note = [remote.setupIssue, key?.issue].compactMap { $0 }.joined(separator: " ")
            if key?.value == nil && note.isEmpty { note = "Add a credential in Edit Server." }
            let matches = servers.filter { sameEndpoint(remote.host, remote.username, remote.port, as: $0) }
            if !matches.isEmpty {
                let named = matches.filter { $0.name == remote.name }
                let candidates = matches.count == 1 ? matches : named
                action = .skip
                let distinctSource = incoming.servers.filter {
                    $0.host.caseInsensitiveCompare(remote.host) == .orderedSame &&
                    $0.username == remote.username && $0.port == remote.port &&
                    (named.isEmpty || $0.name == remote.name)
                }.count == 1
                if candidates.count == 1, let match = candidates.first, distinctSource, !claimed.contains(match.id) {
                    if match.authentication.rawValue == remote.authentication, !match.isEnabled,
                       match.trustedHostKey == nil, key?.value != nil {
                        let existing = try vault.read(match.id)
                        if existing == nil || existing == MobileCredential() {
                            action = .fill(match.id)
                            claimed.insert(match.id)
                        }
                    }
                    if action == .skip { note = "Existing profile and credentials will be kept." }
                } else { note = "Multiple profiles may use this address. Existing settings will be kept." }
            }
            let savesCredential = action != .skip && key?.value != nil
            let label = remote.authentication == "keyBased" ? "SSH private key" : "SSH password"
            return .init(id: remote.id, name: remote.name.isEmpty ? remote.host : remote.name,
                         address: "\(remote.username)@\(remote.host):\(remote.port)", action: action,
                         credentialLabel: savesCredential ? label : nil, note: note.isEmpty ? nil : note)
        }
        let review = MacTransferReview(rows: rows, alreadyImported: false)
        guard servers.count + review.added <= ServerSettingsBackup.maximumServers else {
            throw ServerSettingsBackup.BackupError.invalidServerCount
        }
        return review
    }

    @discardableResult
    public func importTransfer(_ incoming: IncomingMacTransfer, reviewed: MacTransferReview) throws -> [MobileServer] {
        let review = try reviewTransfer(incoming)
        guard !review.alreadyImported else {
            guard defaults.synchronize() else { throw MacTransferImportError.recovery }
            return []
        }
        guard review == reviewed else { throw MacTransferImportError.changed }

        var next = servers
        var imported = Set<UUID>()
        var writes: [(UUID, MobileCredential)] = []
        var journal: [MobileTransferState.JournalEntry] = []
        for (remote, row) in zip(incoming.servers, review.rows) {
            let id: UUID
            switch row.action {
            case .skip: continue
            case .fill(let existing):
                guard let index = next.firstIndex(where: { $0.id == existing }) else { throw MacTransferImportError.changed }
                id = existing
                next[index].transferSetupIssue = row.note
            case .add:
                var server = MobileServer()
                server.name = remote.name
                server.host = remote.host
                server.username = remote.username
                server.port = remote.port
                guard let auth = SSHAuthenticationMode(rawValue: remote.authentication) else { throw MobileError.invalidServer }
                server.authentication = auth
                server.connectionReuseMode = remote.connectionReuseMode.flatMap(SSHConnectionReuseMode.init(rawValue:))
                server.gpuCommand = remote.gpuCommand
                server.memoryCommand = remote.memoryCommand
                server.hostCommand = remote.hostCommand == RemoteMetricCommands.hostInfo(memoryCommand: remote.memoryCommand)
                    ? nil : remote.hostCommand
                server.isEnabled = false
                server.transferSetupIssue = row.note
                id = server.id
                next.append(server)
            }
            imported.insert(id)
            if let ref = remote.credentialID, let value = incoming.credentials[ref]?.value {
                let previous = try vault.read(id)
                guard previous == nil || previous == MobileCredential() else { throw MacTransferImportError.changed }
                writes.append((id, value))
                journal.append(.init(id: id, wasEmptyItem: previous != nil))
            }
        }
        // One durable metadata record governs both rollback and replay. It is
        // established before any Keychain write and replaced in full on commit.
        var pending = transferState
        pending.journal = journal
        try writeState(pending)
        guard defaults.synchronize() else { throw MacTransferImportError.recovery }
        do {
            for (id, value) in writes { try vault.write(value, for: id) }
            var completed = transferState
            completed.servers = next
            completed.journal = []
            completed.receipts.insert(incoming.id)
            try writeState(completed)
            guard defaults.synchronize() else { throw MacTransferImportError.recovery }
            servers = next
            revision = UUID()
            generation = UUID()
            return next.filter { imported.contains($0.id) }
        } catch {
            do {
                try writeState(pending)
                guard defaults.synchronize() else { throw MacTransferImportError.recovery }
                try recoverInterruptedTransfer()
            } catch { throw MacTransferImportError.recovery }
            throw error
        }
    }

    public func trustAndConnectTransferred(_ keys: [TransferHostKey]) throws {
        guard !keys.isEmpty else { return }
        var next = servers
        for observed in keys {
            guard let index = next.firstIndex(where: { $0.id == observed.server.id }),
                  next[index] == observed.server, !next[index].isEnabled,
                  next[index].trustedHostKey == nil, next[index].transferSetupIssue == nil
            else { throw MacTransferImportError.changed }
            next[index].trustedHostKey = observed.key
            next[index].trustedEndpoint = next[index].endpoint
            next[index].isEnabled = true
        }
        try persist(next)
    }

    public func monitor() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(min(300, max(5, refreshInterval)))) }
            catch { return }
        }
    }

    public func refresh(serverID: UUID? = nil) async {
        let requestedRevision = revision
        var requested = Set(servers.filter { $0.isEnabled && (serverID == nil || $0.id == serverID) }.map(\.id))
        // Join overlapping requests. If a full poll follows a single-server
        // refresh, only the remaining servers need another SSH operation.
        while !requested.isEmpty, !Task.isCancelled, revision == requestedRevision {
            if let batch = refreshBatch {
                await batch.task.value
                if !batch.task.isCancelled, batch.revision == requestedRevision {
                    requested.subtract(batch.ids)
                }
                continue
            }
            let ids = requested
            refreshingServerIDs = ids
            let work = Task {
                defer { refreshingServerIDs.removeAll(); refreshBatch = nil }
                await collect(ids: ids)
            }
            refreshBatch = (work, ids, requestedRevision)
            await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            return
        }
    }

    private func discardSession(_ id: UUID) {
        if let session = sessions.removeValue(forKey: id) { Task { await session.invalidate() } }
    }

    public func suspend() {
        revision = UUID()
        refreshBatch?.task.cancel()
        resetBaselines()
        for id in Array(sessions.keys) { discardSession(id) }
    }

    private func collect(ids: Set<UUID>) async {
        guard !Task.isCancelled else { return }
        let revision = revision
        let loader = loader
        let options = HostMetricsOptions(cpu: collectsCPU, memory: collectsMemory, network: collectsNetwork)
        // Resolve device-only credentials on the main actor; workers receive values.
        var jobs: [(MobileServer, MobileCredential, SSHTransport)] = []
        for server in servers where server.isEnabled && ids.contains(server.id) {
            do {
                let value = try credential(for: server)
                let reusable = server.reusesConnection && server.pinnedHostKey != nil && loader == nil
                let transport = sessions[server.id] ?? SSHTransport(server: server, credential: value, reusable: reusable)
                if reusable { sessions[server.id] = transport }
                jobs.append((server, value, transport))
            }
            catch { record(error, for: server.id); refreshingServerIDs.remove(server.id) }
        }
        await withTaskGroup(of: (UUID, Result<GPUSnapshot, any Error>).self) { group in
            var iterator = jobs.makeIterator()
            func enqueue(_ job: (MobileServer, MobileCredential, SSHTransport)) {
                let server = job.0
                group.addTask {
                    do {
                        let snapshot: GPUSnapshot
                        if let loader { snapshot = try await loader(server, job.1) }
                        else { snapshot = try await Self.loadSnapshot(server: server, transport: job.2, options: options) }
                        return (server.id, .success(snapshot))
                    }
                    catch { return (job.0.id, .failure(error)) }
                }
            }
            for _ in 0..<4 { if let job = iterator.next() { enqueue(job) } }
            while let (id, result) = await group.next() {
                guard !Task.isCancelled, self.revision == revision else { group.cancelAll(); continue }
                refreshingServerIDs.remove(id)
                switch result {
                case .success(var snapshot):
                    var reading = ServerReading()
                    let maximum = max(60, Double(refreshInterval) * 4)
                    if let cpu = snapshot.hostCPUSample {
                        let old = cpuSamples[id]
                        snapshot.hostCPU = CPUUsageEvaluator.usage(previous: old, current: cpu, maximumInterval: maximum) ?? snapshot.hostCPU
                        if old.map({ $0.bootTime != cpu.bootTime || !(0..<1).contains(cpu.takenAt.timeIntervalSince($0.takenAt)) }) ?? true {
                            cpuSamples[id] = cpu
                        }
                    } else { cpuSamples[id] = nil }
                    if let network = snapshot.networkSample {
                        let old = networkSamples[id]
                        reading.networkUsage = NetworkUsageEvaluator.usage(previous: old, current: network, maximumInterval: maximum)
                        if old.map({ !(0..<1).contains(network.takenAt.timeIntervalSince($0.takenAt)) }) ?? true {
                            networkSamples[id] = network
                        }
                    } else { networkSamples[id] = nil }
                    let previous = readings[id]
                    if let previous, previous.error == nil, let last = previous.history.last {
                        let elapsed = snapshot.takenAt.timeIntervalSince(last.time)
                        if elapsed > 0 && elapsed <= maximum { reading.history = Array(previous.history.suffix(19)) }
                    }
                    reading.history.append(GPULoadSample(snapshot))
                    reading.snapshot = snapshot
                    readings[id] = reading
                case .failure(let error):
                    if !(error is CancellationError) { record(error, for: id) }
                }
                if let job = iterator.next() { enqueue(job) }
            }
        }
    }

    private func record(_ error: any Error, for id: UUID) {
        var reading = readings[id] ?? ServerReading()
        reading.hostKey = nil
        reading.fingerprint = nil
        if case MobileError.hostKeyRequired(let key, let fingerprint) = error {
            reading.hostKey = key
            reading.fingerprint = fingerprint
        } else if case MobileError.hostKeyChanged(let fingerprint) = error {
            reading.fingerprint = fingerprint
        }
        switch error as? MobileError {
        case .hostKeyRequired: reading.errorCategory = "unverified host key"
        case .hostKeyChanged: reading.errorCategory = "host key changed"
        case .authenticationFailed, .missingCredential, .cannotUnlockKey, .keyPassphraseRequired: reading.errorCategory = "authentication"
        case .timedOut: reading.errorCategory = "timeout"
        case .invalidMetrics, .commandFailed, .outputTooLarge: reading.errorCategory = "remote metrics"
        case .keychain: reading.errorCategory = "keychain"
        default: reading.errorCategory = "connection or configuration"
        }
        reading.error = error.localizedDescription
        if case MobileError.commandFailed = error { reading.errorIncludesRemoteOutput = true }
        else { reading.errorIncludesRemoteOutput = false }
        readings[id] = reading
    }

    public func diagnostics() -> String {
        var lines = ["NVBeacon for iOS " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
                     "OS: " + ProcessInfo.processInfo.operatingSystemVersionString,
                     "Refresh interval: \(refreshInterval)s. CPU: \(collectsCPU), memory: \(collectsMemory), network: \(collectsNetwork)."]
        for (index, server) in servers.enumerated() {
            let reading = readings[server.id]
            let status = server.isEnabled ? reading?.errorCategory ?? (reading?.snapshot == nil ? "waiting" : "ok") : "disabled"
            let count = reading?.snapshot.map { String($0.gpus.count) } ?? "unknown"
            lines.append("Server \(index + 1): \(status); GPUs: \(count); SSH reuse: \(server.reusesConnection)")
        }
        return lines.joined(separator: "\n")
    }

    nonisolated public static func loadSnapshot(server: MobileServer, credential: MobileCredential) async throws -> GPUSnapshot {
        let transport = SSHTransport(server: server, credential: credential)
        return try await loadSnapshot(server: server, transport: transport, options: .init())
    }

    nonisolated private static func loadSnapshot(server: MobileServer, transport: SSHTransport, options: HostMetricsOptions) async throws -> GPUSnapshot {
        let snapshot: GPUSnapshot
        do {
            snapshot = try await MetricsCollector(transport: transport)
                .fetchSummary(gpuCommand: server.gpuCommand, memoryCommand: server.memoryCommand, hostMetrics: options, hostCommand: server.hostCommand)
        } catch MetricsCollectionError.commandFailed(let status, let message) {
            throw MobileError.commandFailed(status, message)
        } catch is MetricsParseError { throw MobileError.invalidMetrics }
        let pids = Array(Set(snapshot.gpus.flatMap(\.processes).map(\.pid))).sorted()
        guard !pids.isEmpty else { return snapshot }
        // Process ownership is optional; a failed metadata lookup preserves GPU data.
        do {
            let pidList = pids.map(String.init).joined(separator: ",")
            let output = try await transport.execute("printf 'uid=%s\\n' \"$(id -u 2>/dev/null)\"; ps -ww -p \(pidList) -o pid=,uid=,user:64=,args= 2>/dev/null || ps -p \(pidList) -o pid= -o uid= -o user= -o args= 2>/dev/null || true")
            guard output.exitStatus == 0 else { return snapshot }
            let parts = output.standardOutput.split(separator: "\n", maxSplits: 1)
            let hasUIDLine = parts.first?.hasPrefix("uid=") == true
            let uid = hasUIDLine ? parts.first.flatMap { Int($0.dropFirst(4)) } : nil
            let psOutput = hasUIDLine ? String(parts.dropFirst().first ?? "") : output.standardOutput
            let details = try MetricsParser.parseDetailedPSSection(psOutput)
            let byPID = Dictionary(details.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
            let processes = snapshot.gpus.flatMap(\.processes).map { process in
                GPUProcessReading(gpuUUID: process.gpuUUID, pid: process.pid, processName: process.processName,
                    usedGPUMemoryMB: process.usedGPUMemoryMB, userID: byPID[process.pid]?.userID,
                    user: byPID[process.pid]?.user, commandLine: byPID[process.pid]?.commandLine)
            }
            var resolved = snapshot.applyingResolvedProcessMetadata(processes)
            resolved.sshUserID = uid
            return resolved
        } catch is CancellationError { throw CancellationError() }
        catch { return snapshot }
    }
}
