import Foundation
import NVBeaconCore

// Process-exit and GPU-idle alerts, ported from the macOS app (GPUModels.swift and
// NVBeaconStore.swift). Field names, ids and matching rules are the same.

extension ServerSettings {
    /// Same as macOS `ServerConfig.connectionFingerprint`: watches survive renames
    /// but not a change of where or how the app connects.
    public var connectionFingerprint: String {
        [sshTarget, sshPort, sshIdentityFilePath, sshAuthenticationMode.rawValue].joined(separator: "|")
    }
}

public struct ProcessExitWatch: Codable, Identifiable, Equatable, Sendable {
    public let connectionFingerprint: String
    public let connectionLabel: String
    public let gpuUUID: String
    public let gpuIndex: Int
    public let gpuName: String
    public let pid: Int
    public let processName: String
    public let usedGPUMemoryMB: Int
    public let user: String?
    public let commandLine: String?
    public let createdAt: Date

    public init(server: ServerSettings, gpu: GPUReading, process: GPUProcessReading, createdAt: Date = Date()) {
        connectionFingerprint = server.connectionFingerprint
        connectionLabel = server.displayName
        gpuUUID = process.gpuUUID
        gpuIndex = gpu.index
        gpuName = gpu.name
        pid = process.pid
        processName = process.processName
        usedGPUMemoryMB = process.usedGPUMemoryMB
        user = process.user
        commandLine = process.commandLine
        self.createdAt = createdAt
    }

    public var id: String { "\(connectionFingerprint):\(gpuUUID):\(pid):\(processName)" }

    public var displayProcessName: String {
        let name = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let command = commandLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return command.isEmpty ? "PID \(pid)" : command
    }

    /// "Server · GPU 0 · PID 123 · user", the notification body on macOS.
    public var subtitle: String {
        var parts = [connectionLabel, "GPU \(gpuIndex)", "PID \(pid)"]
        if let user, !user.isEmpty { parts.append(user) }
        return parts.joined(separator: " · ")
    }

    public func matches(_ process: GPUProcessReading) -> Bool {
        process.gpuUUID == gpuUUID && process.pid == pid && process.processName == processName
    }

    public func matches(_ status: RemoteProcessStatus) -> Bool {
        guard status.pid == pid else { return false }
        if let user, !user.isEmpty, user != status.user { return false }
        let command = commandLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !command.isEmpty { return command == (status.commandLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") }
        return true
    }
}

public struct GPUIdleWatch: Codable, Identifiable, Equatable, Sendable {
    public let connectionFingerprint: String
    public let connectionLabel: String
    public let gpuUUID: String?
    public let gpuIndex: Int
    public let gpuName: String
    public let createdAt: Date

    public init(server: ServerSettings, gpu: GPUReading, createdAt: Date = Date()) {
        connectionFingerprint = server.connectionFingerprint
        connectionLabel = server.displayName
        gpuUUID = gpu.uuid
        gpuIndex = gpu.index
        gpuName = gpu.name
        self.createdAt = createdAt
    }

    public var id: String { "\(connectionFingerprint):\(gpuUUID ?? "gpu-\(gpuIndex)")" }
    public var title: String { "GPU \(gpuIndex)" }
    public var subtitle: String { [gpuName, connectionLabel].filter { !$0.isEmpty }.joined(separator: " · ") }

    public func matches(_ gpu: GPUReading) -> Bool {
        if let gpuUUID, let current = gpu.uuid { return gpuUUID == current }
        return gpu.index == gpuIndex
    }
}

public enum NotificationHistoryKind: String, Codable, Equatable, Sendable {
    case permissionEnabled, permissionDenied
    case watchAdded, watchRemoved, idleWatchAdded, idleWatchRemoved
    case testNotificationScheduled, exitNotificationScheduled, idleNotificationScheduled
}

public struct NotificationHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let kind: NotificationHistoryKind
    public let connectionLabel: String?
    public let gpuIndex: Int?
    public let pid: Int?
    public let user: String?
    public let processName: String?
    public let detail: String?

    public init(id: UUID = UUID(), timestamp: Date = Date(), kind: NotificationHistoryKind, connectionLabel: String? = nil,
                gpuIndex: Int? = nil, pid: Int? = nil, user: String? = nil, processName: String? = nil, detail: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.connectionLabel = connectionLabel
        self.gpuIndex = gpuIndex
        self.pid = pid
        self.user = user
        self.processName = processName
        self.detail = detail
    }

    public init(kind: NotificationHistoryKind, watch: ProcessExitWatch, detail: String? = nil) {
        self.init(kind: kind, connectionLabel: watch.connectionLabel, gpuIndex: watch.gpuIndex, pid: watch.pid,
                  user: watch.user, processName: watch.displayProcessName, detail: detail)
    }

    public init(kind: NotificationHistoryKind, idleWatch: GPUIdleWatch, detail: String? = nil) {
        self.init(kind: kind, connectionLabel: idleWatch.connectionLabel, gpuIndex: idleWatch.gpuIndex,
                  processName: idleWatch.title, detail: detail ?? idleWatch.gpuName)
    }

    public var subtitle: String {
        var parts: [String] = []
        if let processName, !processName.isEmpty { parts.append(processName) }
        if let user, !user.isEmpty { parts.append(user) }
        if let pid { parts.append("PID \(pid)") }
        if let gpuIndex { parts.append("GPU \(gpuIndex)") }
        if let connectionLabel, !connectionLabel.isEmpty { parts.append(connectionLabel) }
        if let detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: " · ")
    }
}

public enum ProcessExitWatchEvaluator {
    /// Watches whose process is gone: not visible on its GPU and not running
    /// as the same user and command according to `ps`.
    public static func exitedWatches(watches: [ProcessExitWatch], visibleProcesses: [GPUProcessReading],
                                     remoteStatuses: [RemoteProcessStatus]) -> [ProcessExitWatch] {
        let visible = Set(watches.compactMap { watch in visibleProcesses.contains(where: watch.matches(_:)) ? watch.id : nil })
        let statuses = Dictionary(remoteStatuses.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
        return watches.filter { watch in
            guard !visible.contains(watch.id) else { return false }
            guard let status = statuses[watch.pid] else { return true }
            return !watch.matches(status)
        }
    }
}

/// A notification to show, in the user's language.
public struct PendingNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// Owns the watches and the notification history, persists them, and decides
/// when a poll should notify. Thread-safe; evaluation runs off the UI thread.
public final class WatchStore: @unchecked Sendable {
    public struct Saved: Codable, Equatable, Sendable {
        public var processWatches: [ProcessExitWatch] = []
        public var idleWatches: [GPUIdleWatch] = []
        public var history: [NotificationHistoryEntry] = []
        public init() {}
    }

    private struct IdleTracking { var idleSince: Date?; var handled = false }

    private let lock = NSLock()
    private var saved: Saved
    private var tracking: [String: IdleTracking] = [:]
    private let fileURL: URL?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.iso.decode(Saved.self, from: data) {
            saved = decoded
        } else {
            saved = Saved()
        }
    }

    public static var defaultFileURL: URL { SettingsStore.folder.appendingPathComponent("watches.json") }

    public var processWatches: [ProcessExitWatch] { lock.withLock { saved.processWatches } }
    public var idleWatches: [GPUIdleWatch] { lock.withLock { saved.idleWatches } }

    /// macOS shows the last 24 hours and keeps up to 200 entries for 7 days.
    public func recentHistory(now: Date = Date(), hours: Double = 24) -> [NotificationHistoryEntry] {
        let cutoff = now.addingTimeInterval(-hours * 3600)
        return lock.withLock { saved.history }.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp > $1.timestamp }
    }

    public func isWatching(_ process: GPUProcessReading, on server: ServerSettings) -> Bool {
        let fingerprint = server.connectionFingerprint
        return lock.withLock { saved.processWatches.contains { $0.connectionFingerprint == fingerprint && $0.matches(process) } }
    }

    public func isWatchingIdle(_ gpu: GPUReading, on server: ServerSettings) -> Bool {
        let fingerprint = server.connectionFingerprint
        return lock.withLock { saved.idleWatches.contains { $0.connectionFingerprint == fingerprint && $0.matches(gpu) } }
    }

    /// Returns true when the watch is now on.
    @discardableResult
    public func toggleExitWatch(process: GPUProcessReading, gpu: GPUReading, server: ServerSettings) -> Bool {
        let fingerprint = server.connectionFingerprint
        let enabled: Bool = lock.withLock {
            if let index = saved.processWatches.firstIndex(where: { $0.connectionFingerprint == fingerprint && $0.matches(process) }) {
                let removed = saved.processWatches.remove(at: index)
                appendHistory(NotificationHistoryEntry(kind: .watchRemoved, watch: removed))
                return false
            }
            let watch = ProcessExitWatch(server: server, gpu: gpu, process: process)
            saved.processWatches.append(watch)
            saved.processWatches.sort {
                if $0.connectionLabel == $1.connectionLabel {
                    return $0.gpuIndex == $1.gpuIndex ? $0.pid < $1.pid : $0.gpuIndex < $1.gpuIndex
                }
                return $0.connectionLabel.localizedCaseInsensitiveCompare($1.connectionLabel) == .orderedAscending
            }
            appendHistory(NotificationHistoryEntry(kind: .watchAdded, watch: watch))
            return true
        }
        persist()
        return enabled
    }

    @discardableResult
    public func toggleIdleWatch(gpu: GPUReading, server: ServerSettings, snapshotTakenAt: Date?,
                                idleSeconds: Int, memoryThresholdMB: Int) -> Bool {
        let fingerprint = server.connectionFingerprint
        let enabled: Bool = lock.withLock {
            if let index = saved.idleWatches.firstIndex(where: { $0.connectionFingerprint == fingerprint && $0.matches(gpu) }) {
                let removed = saved.idleWatches.remove(at: index)
                tracking.removeValue(forKey: removed.id)
                appendHistory(NotificationHistoryEntry(kind: .idleWatchRemoved, idleWatch: removed))
                return false
            }
            let watch = GPUIdleWatch(server: server, gpu: gpu)
            saved.idleWatches.append(watch)
            saved.idleWatches.sort {
                $0.connectionLabel == $1.connectionLabel ? $0.gpuIndex < $1.gpuIndex
                    : $0.connectionLabel.localizedCaseInsensitiveCompare($1.connectionLabel) == .orderedAscending
            }
            if gpu.isIdle(memoryThresholdMB: memoryThresholdMB) {
                tracking[watch.id] = IdleTracking(idleSince: snapshotTakenAt ?? Date())
            }
            appendHistory(NotificationHistoryEntry(kind: .idleWatchAdded, idleWatch: watch,
                                                   detail: "Idle \(idleSeconds)s · <=\(memoryThresholdMB)MB"))
            return true
        }
        persist()
        return enabled
    }

    public func removeWatch(id: String) {
        lock.withLock {
            if let index = saved.processWatches.firstIndex(where: { $0.id == id }) {
                appendHistory(NotificationHistoryEntry(kind: .watchRemoved, watch: saved.processWatches.remove(at: index)))
            } else if let index = saved.idleWatches.firstIndex(where: { $0.id == id }) {
                let removed = saved.idleWatches.remove(at: index)
                tracking.removeValue(forKey: removed.id)
                appendHistory(NotificationHistoryEntry(kind: .idleWatchRemoved, idleWatch: removed))
            }
        }
        persist()
    }

    public func record(_ entry: NotificationHistoryEntry) {
        lock.withLock { appendHistory(entry) }
        persist()
    }

    public func clear() {
        lock.withLock {
            saved = Saved()
            tracking = [:]
        }
        persist()
    }

    /// After a successful poll: returns the notifications to show. Exited
    /// processes are confirmed with `ps` (the macOS command) before notifying,
    /// and their watches are removed; an idle GPU notifies once per idle stretch.
    public func evaluate(snapshot: GPUSnapshot, server: ServerSettings, settings: WindowsSettings, korean: Bool,
                         transport: AnyRemoteCommandExecutor) async -> [PendingNotification] {
        var notifications: [PendingNotification] = []
        let fingerprint = server.connectionFingerprint
        let visible = snapshot.gpus.flatMap(\.processes)

        let hidden = lock.withLock {
            saved.processWatches.filter { $0.connectionFingerprint == fingerprint && !visible.contains(where: $0.matches(_:)) }
        }
        if !hidden.isEmpty, let statuses = try? await Self.fetchProcessStatuses(pids: hidden.map(\.pid), transport: transport) {
            let exited = ProcessExitWatchEvaluator.exitedWatches(watches: hidden, visibleProcesses: visible, remoteStatuses: statuses)
            if !exited.isEmpty {
                let ids = Set(exited.map(\.id))
                lock.withLock {
                    saved.processWatches.removeAll { ids.contains($0.id) }
                    for watch in exited { appendHistory(NotificationHistoryEntry(kind: .exitNotificationScheduled, watch: watch)) }
                }
                notifications += exited.map {
                    PendingNotification(title: korean ? "\($0.displayProcessName) 종료" : "\($0.displayProcessName) finished", body: $0.subtitle)
                }
            }
        }

        lock.withLock {
            let watchedIDs = Set(saved.idleWatches.map(\.id))
            tracking = tracking.filter { watchedIDs.contains($0.key) }
            for watch in saved.idleWatches where watch.connectionFingerprint == fingerprint {
                guard let gpu = snapshot.gpus.first(where: watch.matches(_:)) else {
                    tracking.removeValue(forKey: watch.id)
                    continue
                }
                var state = tracking[watch.id] ?? IdleTracking()
                guard gpu.isIdle(memoryThresholdMB: settings.idleMemoryThresholdMB) else {
                    tracking[watch.id] = IdleTracking()
                    continue
                }
                let since = state.idleSince ?? snapshot.takenAt
                state.idleSince = since
                let duration = snapshot.takenAt.timeIntervalSince(since)
                if duration >= TimeInterval(settings.idleNotificationSeconds), !state.handled {
                    state.handled = true
                    let seconds = Int(duration.rounded())
                    appendHistory(NotificationHistoryEntry(kind: .idleNotificationScheduled, idleWatch: watch,
                                                           detail: "Idle \(seconds)s · \(gpu.memoryUsedMB)MB"))
                    let body = [watch.connectionLabel, watch.gpuName,
                                korean ? "Idle \(seconds)초" : "Idle \(seconds)s",
                                korean ? "메모리 \(gpu.memoryUsedMB) MB" : "Mem \(gpu.memoryUsedMB) MB"]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    notifications.append(PendingNotification(title: korean ? "\(watch.title) idle 상태" : "\(watch.title) is idle", body: body))
                }
                tracking[watch.id] = state
            }
        }
        persist()
        return notifications
    }

    /// Copied unchanged from the macOS SSHMetricsFetcher.
    static func psLookupCommand(pids: [Int]) -> String {
        let pidList = pids.map(String.init).joined(separator: ",")
        return """
        ps -o pid= -o user= -o args= -p "\(pidList)" 2>/dev/null || true
        """
    }

    static func fetchProcessStatuses(pids: [Int], transport: AnyRemoteCommandExecutor) async throws -> [RemoteProcessStatus] {
        let unique = Array(Set(pids)).sorted()
        guard !unique.isEmpty else { return [] }
        let output = try await transport.execute(psLookupCommand(pids: unique))
        guard output.exitStatus == 0 else {
            throw MetricsCollectionError.commandFailed(output.exitStatus, output.standardError)
        }
        return try MetricsParser.parsePSSection(output.standardOutput)
    }

    /// Caller holds the lock. Keeps 7 days and at most 200 entries, as on macOS.
    private func appendHistory(_ entry: NotificationHistoryEntry) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        saved.history.append(entry)
        saved.history.removeAll { $0.timestamp < cutoff }
        if saved.history.count > 200 { saved.history = Array(saved.history.suffix(200)) }
    }

    private func persist() {
        guard let fileURL else { return }
        let snapshot = lock.withLock { saved }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso.encode(snapshot) { try? data.write(to: fileURL, options: .atomic) }
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
