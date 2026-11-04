import Foundation
import Observation
import NVBeaconCore

public struct ServerReading: Sendable {
    public var snapshot: GPUSnapshot?
    public var error: String?
    public var hostKey: String?
    public var fingerprint: String?
    public init() {}
}

public typealias SnapshotLoader = @Sendable (MobileServer, MobileCredential) async throws -> GPUSnapshot

@MainActor @Observable public final class MobileStore {
    public private(set) var servers: [MobileServer] = []
    public private(set) var readings: [UUID: ServerReading] = [:]
    public private(set) var isRefreshing = false
    public private(set) var generation = UUID()
    public var message: String?
    public var refreshInterval: Int {
        didSet {
            defaults.set(min(300, max(5, refreshInterval)), forKey: "refreshInterval")
            generation = UUID()
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let vault: any CredentialStorage
    @ObservationIgnored private let loader: SnapshotLoader
    @ObservationIgnored private var transferState = MobileTransferState()
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, vault: any CredentialStorage = CredentialVault(),
                loader: @escaping SnapshotLoader = MobileStore.loadSnapshot) {
        self.defaults = defaults
        self.vault = vault
        self.loader = loader
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
            catch { message = "Saved server settings could not be read. They have not been overwritten." }
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

    public func save(_ server: MobileServer, credential: MobileCredential) throws {
        try recoverInterruptedTransfer()
        var normalized = try server.validated()
        if normalized.isEnabled { normalized.transferSetupIssue = nil }
        guard !normalized.isEnabled || !credential.secret.isEmpty else { throw MobileError.missingCredential }
        if normalized.authentication == .keyBased, !credential.secret.isEmpty {
            try SSHTransport.validatePrivateKey(credential)
        }
        var next = servers
        if let index = next.firstIndex(where: { $0.id == server.id }) { next[index] = normalized }
        else {
            guard next.count < ServerSettingsBackup.maximumServers else { throw ServerSettingsBackup.BackupError.invalidServerCount }
            next.append(normalized)
        }
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

    public func refresh() async {
        guard !isRefreshing, !Task.isCancelled else { return }
        isRefreshing = true
        let work = Task { await collect() }
        refreshTask = work
        defer { isRefreshing = false; refreshTask = nil }
        await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
    }

    public func suspend() { refreshTask?.cancel() }

    private func collect() async {
        guard !Task.isCancelled else { return }
        let revision = revision
        let loader = loader
        // Resolve device-only credentials on the main actor; workers receive values.
        var jobs: [(MobileServer, MobileCredential)] = []
        for server in servers where server.isEnabled {
            do { jobs.append((server, try credential(for: server))) }
            catch { record(error, for: server.id) }
        }
        await withTaskGroup(of: (UUID, Result<GPUSnapshot, any Error>).self) { group in
            var iterator = jobs.makeIterator()
            func enqueue(_ job: (MobileServer, MobileCredential)) {
                group.addTask {
                    do { return (job.0.id, .success(try await loader(job.0, job.1))) }
                    catch { return (job.0.id, .failure(error)) }
                }
            }
            for _ in 0..<4 { if let job = iterator.next() { enqueue(job) } }
            while let (id, result) = await group.next() {
                guard !Task.isCancelled, self.revision == revision else { group.cancelAll(); continue }
                switch result {
                case .success(let snapshot):
                    var reading = ServerReading()
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
        reading.error = error.localizedDescription
        readings[id] = reading
    }

    nonisolated public static func loadSnapshot(server: MobileServer, credential: MobileCredential) async throws -> GPUSnapshot {
        let transport = SSHTransport(server: server, credential: credential)
        let snapshot: GPUSnapshot
        do {
            snapshot = try await MetricsCollector(transport: transport)
                .fetchSummary(gpuCommand: server.gpuCommand, memoryCommand: server.memoryCommand, hostCommand: server.hostCommand)
        } catch MetricsCollectionError.commandFailed(let status, let message) {
            throw MobileError.commandFailed(status, message)
        } catch is MetricsParseError { throw MobileError.invalidMetrics }
        let pids = Array(Set(snapshot.gpus.flatMap(\.processes).map(\.pid))).sorted()
        guard !pids.isEmpty else { return snapshot }
        // Process ownership is optional; a failed metadata lookup preserves GPU data.
        do {
            let pidList = pids.map(String.init).joined(separator: ",")
            let output = try await transport.execute("ps -ww -p \(pidList) -o pid=,uid=,user=,args= 2>/dev/null || true")
            guard output.exitStatus == 0 else { return snapshot }
            let details = try MetricsParser.parseDetailedPSSection(output.standardOutput)
            let byPID = Dictionary(details.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
            let processes = snapshot.gpus.flatMap(\.processes).map { process in
                GPUProcessReading(gpuUUID: process.gpuUUID, pid: process.pid, processName: process.processName,
                    usedGPUMemoryMB: process.usedGPUMemoryMB, userID: byPID[process.pid]?.userID,
                    user: byPID[process.pid]?.user, commandLine: byPID[process.pid]?.commandLine)
            }
            return snapshot.applyingResolvedProcessMetadata(processes)
        } catch is CancellationError { throw CancellationError() }
        catch { return snapshot }
    }
}
