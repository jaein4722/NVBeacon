import CryptoKit
import Foundation

/// One GPU's utilization over one wall-clock minute.
struct GPUHistorySample: Codable, Equatable, Sendable, Identifiable {
    let timestamp: Date
    let gpuIndex: Int
    let gpuUUID: String?
    var totalSum: Double = 0
    var sampleCount: Int = 0
    /// Summed process SM utilization per remote user from one `nvidia-smi pmon` sample.
    /// `nil` means per-user sampling did not run or failed this minute; `[:]` means no processes.
    var users: [String: Double]?

    var id: String { "\(timestamp.timeIntervalSince1970):\(gpuUUID ?? String(gpuIndex))" }
    var totalUtilization: Double { totalSum / Double(max(1, sampleCount)) }

    static func minute(of date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    /// Adds one refresh to the current minute's samples.
    static func accumulating(_ snapshot: GPUSnapshot, users: [Int: [String: Double]]?, into pending: [Self]) -> [Self] {
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
}

/// Per-user utilization via `nvidia-smi pmon`. Sampled at most once a minute because
/// pmon blocks for about a second per call.
enum UserUtilizationSampler {
    static let minimumInterval: TimeInterval = 60
    private static let ownersSeparator = "__NVBEACON_PMON_OWNERS__"

    static let command = """
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
    /// Processes without an SM reading are skipped rather than stored as unavailable.
    static func parse(_ output: String) -> [Int: [String: Double]]? {
        let parts = output.components(separatedBy: ownersSeparator)
        let pmonLines = parts[0].split(whereSeparator: \.isNewline)
        // pmon prints a "# gpu pid type sm ..." header on every successful sample.
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
}

/// 24 hours of minute samples per server, stored as append-only JSON Lines.
///
/// A completed minute is appended (a few hundred bytes per GPU). The file is rewritten
/// only every `compactionInterval` to drop expired lines, so it never holds much more
/// than `retention + compactionInterval` of data.
actor GPUHistoryArchive {
    static let retention: TimeInterval = 24 * 3600
    static let compactionInterval: TimeInterval = 6 * 3600

    private struct Server {
        var samples: [GPUHistorySample]
        var pending: [GPUHistorySample] = []
        var compactedAt: Date = .distantPast
    }

    private let directory: URL
    private var servers: [String: Server] = [:]
    private var prunedStaleFiles = false

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.leejaein.NVBeacon/GPUHistory", isDirectory: true)) {
        self.directory = directory
    }

    /// A changed connection gets a new file, so history never mixes two machines.
    private func key(serverID: String, fingerprint: String) -> String {
        SHA256.hash(data: Data("\(serverID)\n\(fingerprint)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(key + ".jsonl")
    }

    func load(serverID: String, fingerprint: String, now: Date = Date()) throws -> [GPUHistorySample] {
        let key = key(serverID: serverID, fingerprint: fingerprint)
        if let server = servers[key] { return server.samples }
        pruneStaleFilesOnce(now: now)

        var samples: [GPUHistorySample] = []
        if let data = try? Data(contentsOf: file(key)) {
            let decoder = JSONDecoder()
            let cutoff = now.addingTimeInterval(-Self.retention)
            // A line cut short by a crash is skipped; the next compaction drops it.
            samples = data.split(separator: UInt8(ascii: "\n"))
                .compactMap { try? decoder.decode(GPUHistorySample.self, from: Data($0)) }
                .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
                .sorted { $0.timestamp < $1.timestamp }
        }
        servers[key] = Server(samples: samples)
        return samples
    }

    /// Returns the updated history only when a minute was completed and saved.
    func record(_ snapshot: GPUSnapshot, users: [Int: [String: Double]]?,
                serverID: String, fingerprint: String) throws -> [GPUHistorySample]? {
        _ = try load(serverID: serverID, fingerprint: fingerprint, now: snapshot.takenAt)
        let key = key(serverID: serverID, fingerprint: fingerprint)
        guard var server = servers[key] else { return nil }

        var completed: [GPUHistorySample] = []
        if let current = server.pending.first?.timestamp, current != GPUHistorySample.minute(of: snapshot.takenAt) {
            completed = server.pending
            server.pending = []
        }
        server.pending = GPUHistorySample.accumulating(snapshot, users: users, into: server.pending)
        servers[key] = server
        guard !completed.isEmpty else { return nil }
        return try commit(completed, key: key, now: snapshot.takenAt)
    }

    /// Saves the partial minute, e.g. before the app quits.
    func flush(now: Date = Date()) {
        for (key, server) in servers where !server.pending.isEmpty {
            servers[key]?.pending = []
            _ = try? commit(server.pending, key: key, now: now)
        }
    }

    private func commit(_ completed: [GPUHistorySample], key: String, now: Date) throws -> [GPUHistorySample] {
        guard var server = servers[key] else { return [] }
        let cutoff = now.addingTimeInterval(-Self.retention)
        server.samples.append(contentsOf: completed)
        if let firstKept = server.samples.firstIndex(where: { $0.timestamp >= cutoff }) {
            server.samples.removeFirst(firstKept)
        } else {
            server.samples.removeAll()
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = file(key)
        if now.timeIntervalSince(server.compactedAt) >= Self.compactionInterval {
            try jsonLines(server.samples).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            server.compactedAt = now
        } else {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: jsonLines(completed))
        }
        servers[key] = server
        return server.samples
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
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if url.pathExtension != "jsonl" || (modified ?? .distantPast) < now.addingTimeInterval(-Self.retention) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
