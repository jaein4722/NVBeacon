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
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, vault: any CredentialStorage = CredentialVault(),
                loader: @escaping SnapshotLoader = MobileStore.loadSnapshot) {
        self.defaults = defaults
        self.vault = vault
        self.loader = loader
        refreshInterval = min(300, max(5, defaults.object(forKey: "refreshInterval") as? Int ?? 10))
        if let data = defaults.data(forKey: "mobileServers") {
            do { servers = try JSONDecoder().decode([MobileServer].self, from: data) }
            catch { message = "Saved server settings could not be read. They have not been overwritten." }
        }
    }

    public func credential(for server: MobileServer) throws -> MobileCredential {
        try vault.read(server.id) ?? MobileCredential()
    }

    public func save(_ server: MobileServer, credential: MobileCredential) throws {
        let normalized = try server.validated()
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
        try vault.delete(server.id)
        try persist(servers.filter { $0.id != server.id })
        readings[server.id] = nil
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

    private func persist(_ next: [MobileServer]) throws {
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: "mobileServers")
        servers = next
        revision = UUID()
        generation = UUID()
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
                .fetchSummary(gpuCommand: server.gpuCommand, memoryCommand: server.memoryCommand)
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
