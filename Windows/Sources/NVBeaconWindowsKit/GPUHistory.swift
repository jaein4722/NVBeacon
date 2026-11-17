import Foundation
import NVBeaconCore

// GPU History, ported from the macOS GPUHistory.swift and GPUHistoryView.swift.
// Sampling, storage format, retention and plotting rules are the same.

/// One GPU's utilization over one wall-clock minute.
public struct GPUHistorySample: Codable, Equatable, Sendable, Identifiable {
    public let timestamp: Date
    public let gpuIndex: Int
    public let gpuUUID: String?
    public var totalSum: Double = 0
    public var sampleCount: Int = 0
    /// Summed process SM utilization per remote user from one `nvidia-smi pmon` sample.
    /// `nil` means per-user sampling did not run or failed this minute; `[:]` means no processes.
    public var users: [String: Double]?

    public init(timestamp: Date, gpuIndex: Int, gpuUUID: String?, totalSum: Double = 0, sampleCount: Int = 0,
                users: [String: Double]? = nil) {
        self.timestamp = timestamp
        self.gpuIndex = gpuIndex
        self.gpuUUID = gpuUUID
        self.totalSum = totalSum
        self.sampleCount = sampleCount
        self.users = users
    }

    public var id: String { "\(timestamp.timeIntervalSince1970):\(gpuUUID ?? String(gpuIndex))" }
    public var totalUtilization: Double { totalSum / Double(max(1, sampleCount)) }

    public static func minute(of date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    /// Adds one refresh to the current minute's samples.
    public static func accumulating(_ snapshot: GPUSnapshot, users: [Int: [String: Double]]?, into pending: [Self]) -> [Self] {
        let minute = minute(of: snapshot.takenAt)
        var result = pending
        for gpu in snapshot.gpus {
            let index = result.firstIndex { $0.gpuIndex == gpu.index && $0.gpuUUID == gpu.uuid }
            var sample = index.map { result[$0] } ?? Self(timestamp: minute, gpuIndex: gpu.index, gpuUUID: gpu.uuid)
            sample.totalSum += Double(gpu.utilization)
            sample.sampleCount += 1
            if let users { sample.users = users[gpu.index] ?? [:] }
            if let index { result[index] = sample } else { result.append(sample) }
        }
        return result
    }

    /// Combines samples of the same GPU and minute, keeping first-seen order.
    public static func merged(_ samples: [Self]) -> [Self] {
        var order: [String] = []
        var byID: [String: Self] = [:]
        for sample in samples {
            guard var existing = byID[sample.id] else {
                order.append(sample.id)
                byID[sample.id] = sample
                continue
            }
            existing.totalSum += sample.totalSum
            existing.sampleCount += sample.sampleCount
            if let users = sample.users { existing.users = users }
            byID[sample.id] = existing
        }
        return order.compactMap { byID[$0] }
    }
}

/// Per-user utilization via `nvidia-smi pmon`. Sampled at most once a minute because
/// pmon blocks for about a second per call.
public enum UserUtilizationSampler {
    public static let minimumInterval: TimeInterval = 60
    private static let ownersSeparator = "__NVBEACON_PMON_OWNERS__"

    /// Copied unchanged from the macOS app.
    public static let command = """
    pmon_output="$(nvidia-smi pmon -s u -c 1 2>/dev/null || true)"
    printf '%s\\n' "$pmon_output"
    printf '\\n\(ownersSeparator)\\n'
    pmon_pids="$(printf '%s\\n' "$pmon_output" | awk '$1 !~ /^#/ && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $2 }' | sort -u | paste -sd, -)"
    if [ -n "$pmon_pids" ]; then
      ps -o pid= -o user:256= -p "$pmon_pids" 2>/dev/null || true
    fi
    true
    """

    /// GPU index → user → summed SM %. `nil` when pmon is missing or unsupported.
    public static func parse(_ output: String) -> [Int: [String: Double]]? {
        let parts = output.components(separatedBy: ownersSeparator)
        let pmonLines = parts[0].split(whereSeparator: \.isNewline)
        guard pmonLines.contains(where: { line in
            let lower = line.lowercased()
            return lower.hasPrefix("#") && lower.contains("pid") && lower.contains("sm")
        }) else { return nil }

        var owners: [Int: String] = [:]
        for line in (parts.count > 1 ? parts[1] : "").split(whereSeparator: \.isNewline) {
            let columns = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if columns.count == 2, let pid = Int(columns[0]) {
                owners[pid] = columns[1].trimmingCharacters(in: .whitespaces)
            }
        }

        var result: [Int: [String: Double]] = [:]
        for line in pmonLines where !line.hasPrefix("#") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 4, let gpu = Int(columns[0]), let pid = Int(columns[1]),
                  let sm = Double(columns[3]), (0...100).contains(sm) else { continue }
            result[gpu, default: [:]][owners[pid] ?? "(unknown user)", default: 0] += sm
        }
        return result
    }

    public static func fetch(transport: AnyRemoteCommandExecutor) async -> [Int: [String: Double]]? {
        guard let output = try? await transport.execute(command), output.exitStatus == 0 else { return nil }
        return parse(output.standardOutput)
    }
}

/// 24 hours of minute samples per server, stored as append-only JSON Lines
/// (%LOCALAPPDATA%\NVBeacon\GPUHistory). Rewritten every `compactionInterval`.
public actor GPUHistoryArchive {
    public static let retention: TimeInterval = 24 * 3600
    public static let compactionInterval: TimeInterval = 6 * 3600

    private struct Server {
        var samples: [GPUHistorySample]
        var pending: [GPUHistorySample] = []
        var compactedAt: Date = .distantPast
    }

    private let directory: URL
    private var servers: [String: Server] = [:]
    private var prunedStaleFiles = false

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: base).appendingPathComponent("NVBeacon").appendingPathComponent("GPUHistory")
    }

    /// A changed connection gets a new file, so history never mixes two machines.
    /// (macOS hashes with SHA-256; CryptoKit is not available on Windows, and the
    /// name only needs to be stable and distinct, so FNV-1a 64 is used here.)
    static func key(serverID: String, fingerprint: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array("\(serverID)\n\(fingerprint)".utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".jsonl") }

    /// Settings › Monitoring › Delete History…: forgets every server's samples, on disk too.
    public func deleteAll() {
        servers = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "jsonl" { try? FileManager.default.removeItem(at: url) }
    }

    public func samples(serverID: String, fingerprint: String, now: Date = Date()) -> [GPUHistorySample] {
        load(serverID: serverID, fingerprint: fingerprint, now: now)
    }

    private func load(serverID: String, fingerprint: String, now: Date) -> [GPUHistorySample] {
        let key = Self.key(serverID: serverID, fingerprint: fingerprint)
        if let server = servers[key] { return server.samples }
        pruneStaleFilesOnce(now: now)
        var samples: [GPUHistorySample] = []
        if let data = try? Data(contentsOf: file(key)) {
            let decoder = JSONDecoder()
            let cutoff = now.addingTimeInterval(-Self.retention)
            // A line cut short by a crash is skipped; the next compaction drops it.
            samples = GPUHistorySample.merged(data.split(separator: UInt8(ascii: "\n"))
                .compactMap { try? decoder.decode(GPUHistorySample.self, from: Data($0)) }
                .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
                .sorted { $0.timestamp < $1.timestamp })
        }
        servers[key] = Server(samples: samples)
        return samples
    }

    /// Returns true when a minute was completed and saved (the history changed).
    @discardableResult
    public func record(_ snapshot: GPUSnapshot, users: [Int: [String: Double]]?, serverID: String, fingerprint: String) throws -> Bool {
        _ = load(serverID: serverID, fingerprint: fingerprint, now: snapshot.takenAt)
        let key = Self.key(serverID: serverID, fingerprint: fingerprint)
        guard var server = servers[key] else { return false }
        var completed: [GPUHistorySample] = []
        if let current = server.pending.first?.timestamp, current != GPUHistorySample.minute(of: snapshot.takenAt) {
            completed = server.pending
            server.pending = []
        }
        server.pending = GPUHistorySample.accumulating(snapshot, users: users, into: server.pending)
        servers[key] = server
        guard !completed.isEmpty else { return false }
        try commit(completed, key: key, now: snapshot.takenAt)
        return true
    }

    /// Saves the partial minute, e.g. before the app quits.
    public func flush(now: Date = Date()) {
        for (key, server) in servers where !server.pending.isEmpty {
            servers[key]?.pending = []
            try? commit(server.pending, key: key, now: now)
        }
    }

    private func commit(_ completed: [GPUHistorySample], key: String, now: Date) throws {
        guard var server = servers[key] else { return }
        let cutoff = now.addingTimeInterval(-Self.retention)
        server.samples = GPUHistorySample.merged(server.samples + completed)
        if let firstKept = server.samples.firstIndex(where: { $0.timestamp >= cutoff }) {
            server.samples.removeFirst(firstKept)
        } else {
            server.samples.removeAll()
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = file(key)
        if now.timeIntervalSince(server.compactedAt) >= Self.compactionInterval {
            try jsonLines(server.samples).writeReliably(to: url)
            server.compactedAt = now
        } else {
            if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: jsonLines(completed))
        }
        servers[key] = server
    }

    private func jsonLines(_ samples: [GPUHistorySample]) throws -> Data {
        let encoder = JSONEncoder()
        var data = Data()
        for sample in samples {
            data.append(try encoder.encode(sample))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    /// Files of removed servers or old connections expire with their data.
    private func pruneStaleFilesOnce(now: Date) {
        guard !prunedStaleFiles else { return }
        prunedStaleFiles = true
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if url.pathExtension != "jsonl" || (modified ?? .distantPast) < now.addingTimeInterval(-Self.retention) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

// MARK: Plotting (macOS GPUHistoryPlot / GPUHistoryRenderData)

public struct GPUHistoryPoint: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let user: String
    public let value: Double
    public let segment: Int
}

public enum GPUHistoryPlot {
    public static let totalLabel = "GPU total"

    public static func rollupMinutes(hours: Int) -> Int { max(1, Int(ceil(Double(hours * 60) / 120))) }

    public static func points(samples: [GPUHistorySample], hours: Int, now: Date, pollInterval: Int) -> [GPUHistoryPoint] {
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        let visible = samples.filter { $0.timestamp >= start && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }
        let users = Set(visible.flatMap { $0.users.map { Array($0.keys) } ?? [] }).sorted()
        var result: [GPUHistoryPoint] = []
        for user in [totalLabel] + users {
            var previous: Date?
            var previousSample: Date?
            var segment = 0
            for sample in visible {
                // Missing refreshes are offline gaps, never interpolated.
                if let previousSample, sample.timestamp.timeIntervalSince(previousSample) >= Double(max(120, pollInterval * 2)) {
                    segment += 1
                    previous = nil
                }
                defer { previousSample = sample.timestamp }
                let value: Double?
                if user == totalLabel {
                    value = sample.totalUtilization
                } else if sample.users == nil {
                    value = nil
                } else {
                    value = sample.users?[user] ?? 0
                }
                guard let value else { continue }
                if let previous, sample.timestamp.timeIntervalSince(previous) > Double(max(180, pollInterval * 2)) {
                    segment += 1
                }
                result.append(GPUHistoryPoint(timestamp: sample.timestamp, user: user, value: value, segment: segment))
                previous = sample.timestamp
            }
        }
        // Long windows show interval means, not hundreds of minute-to-minute spikes.
        let step = Double(rollupMinutes(hours: hours) * 60)
        let buckets = Dictionary(grouping: result) { floor($0.timestamp.timeIntervalSince1970 / step) }
        return buckets.values.flatMap { bucket -> [GPUHistoryPoint] in
            let byUser = Dictionary(grouping: bucket, by: \.user)
            let times = Set(bucket.map(\.timestamp))
            if byUser.values.contains(where: { points in points.count != times.count || Set(points.map(\.segment)).count > 1 }) {
                return bucket
            }
            guard let timestamp = times.min() else { return [] }
            return byUser.values.compactMap { points in
                guard let first = points.first else { return nil }
                return GPUHistoryPoint(timestamp: timestamp, user: first.user,
                                       value: points.map(\.value).reduce(0, +) / Double(points.count), segment: first.segment)
            }
        }.sorted { $0.timestamp < $1.timestamp }
    }
}

/// Everything the history page draws, prepared in Swift (like macOS's GPUHistoryRenderData).
public struct GPUHistoryRenderData: Encodable, Sendable {
    public struct Area: Encodable, Sendable {
        public let user: String
        public let segment: Int
        public let time: Double
        public let lower: Double
        public let upper: Double
    }
    public struct Reading: Encodable, Sendable {
        public let time: Double
        public let total: Double
        /// nil when per-user sampling did not run for that minute.
        public let users: [String: Double]?
    }

    public struct TotalPoint: Encodable, Sendable {
        public let segment: Int
        public let time: Double
        public let value: Double
    }

    public let users: [String]
    /// Every user in this GPU's stored history, so colors stay put across time ranges.
    public let colorUsers: [String]
    public let areas: [Area]
    public let total: [TotalPoint]
    public let readings: [Reading]
    public let maximumY: Double
    public let start: Double
    public let end: Double
    public let ticks: [Double]
    public let rollupMinutes: Int
    public let lastReadingHasUsers: Bool

    public init(samples: [GPUHistorySample], hours: Int, now: Date, pollInterval: Int) {
        let start = now.addingTimeInterval(-Double(hours * 3600))
        self.start = start.timeIntervalSince1970 * 1000
        end = now.timeIntervalSince1970 * 1000
        ticks = (0...4).map { start.addingTimeInterval(Double(hours * 3600) * Double($0) / 4).timeIntervalSince1970 * 1000 }
        rollupMinutes = GPUHistoryPlot.rollupMinutes(hours: hours)
        let visible = samples.filter { $0.timestamp >= start && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }
        users = Set(visible.flatMap { $0.users.map { Array($0.keys) } ?? [] }).sorted()
        colorUsers = Set(samples.flatMap { $0.users.map { Array($0.keys) } ?? [] }).sorted()
        let plotted = GPUHistoryPlot.points(samples: visible, hours: hours, now: now, pollInterval: pollInterval)

        // Stack per-user areas at each timestamp, ordered by user name.
        let perUser = Dictionary(grouping: plotted.filter { $0.user != GPUHistoryPlot.totalLabel }, by: \.timestamp)
        areas = perUser.keys.sorted().flatMap { time -> [Area] in
            var baseline = 0.0
            return (perUser[time] ?? []).sorted { $0.user < $1.user }.map { point in
                let area = Area(user: point.user, segment: point.segment, time: time.timeIntervalSince1970 * 1000,
                                lower: baseline, upper: baseline + point.value)
                baseline = area.upper
                return area
            }
        }
        total = plotted.filter { $0.user == GPUHistoryPlot.totalLabel }
            .map { TotalPoint(segment: $0.segment, time: $0.timestamp.timeIntervalSince1970 * 1000, value: $0.value) }

        // Cursor and legend read the same means as the marks.
        let originals = Dictionary(visible.map { ($0.timestamp, $0) }, uniquingKeysWith: { _, last in last })
        readings = Dictionary(grouping: plotted, by: \.timestamp).compactMap { time, values -> Reading? in
            guard let original = originals[time], let total = values.first(where: { $0.user == GPUHistoryPlot.totalLabel }) else { return nil }
            let measured = values.filter { $0.user != GPUHistoryPlot.totalLabel }
            return Reading(time: time.timeIntervalSince1970 * 1000, total: total.value,
                           users: original.users == nil ? nil : Dictionary(measured.map { ($0.user, $0.value) }, uniquingKeysWith: { _, last in last }))
        }.sorted { $0.time < $1.time }
        maximumY = max(100, max(areas.map(\.upper).max() ?? 0, self.total.map(\.value).max() ?? 0).rounded(.up))
        lastReadingHasUsers = visible.last?.users != nil
    }
}
