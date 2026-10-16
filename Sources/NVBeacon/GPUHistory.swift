import Foundation

struct GPUHistoryUserMetric: Codable, Equatable, Sendable {
    var sum: Double = 0
    var count: Int = 0
    var average: Double? { count > 0 ? sum / Double(count) : nil }
}

struct GPUHistorySample: Codable, Equatable, Sendable, Identifiable {
    let timestamp: Date
    let gpuIndex: Int
    let gpuUUID: String?
    var totalSum: Double = 0
    var sampleCount: Int = 0
    var attributedSampleCount: Int = 0
    var users: [String: GPUHistoryUserMetric] = [:]
    var unavailableUsers: Set<String> = []

    var id: String { "\(timestamp.timeIntervalSince1970):\(gpuUUID ?? String(gpuIndex))" }
    var totalUtilization: Double { totalSum / Double(max(1, sampleCount)) }

    static func recording(_ snapshot: GPUSnapshot, into history: [Self], now: Date) -> [Self] {
        let cutoff = now.addingTimeInterval(-24 * 3600 - 60)
        var result = history.filter { $0.timestamp >= cutoff && $0.timestamp <= now }
        // Minute averages bound storage to 1,441 entries per GPU, regardless of polling frequency.
        let minute = Date(timeIntervalSince1970: floor(snapshot.takenAt.timeIntervalSince1970 / 60) * 60)
        for gpu in snapshot.gpus {
            let index = result.lastIndex {
                $0.timestamp == minute && $0.gpuIndex == gpu.index && $0.gpuUUID == gpu.uuid
            }
            var sample = index.map { result[$0] } ?? Self(timestamp: minute, gpuIndex: gpu.index, gpuUUID: gpu.uuid)
            sample.totalSum += Double(gpu.utilization)
            sample.sampleCount += 1
            let readings = snapshot.userUtilization.filter { $0.gpuIndex == gpu.index }
            let activeUsers = readings.filter { $0.user != "(idle)" }
            sample.unavailableUsers.formUnion(activeUsers.filter { $0.utilization == nil }.map(\.user))
            if !readings.isEmpty {
                let byUser = Dictionary(grouping: activeUsers, by: \.user)
                for user in Set(sample.users.keys).union(byUser.keys) {
                    var metric = sample.users[user] ?? GPUHistoryUserMetric(count: sample.attributedSampleCount)
                    if let userReadings = byUser[user] {
                        // A missing metric is a gap, not zero or a memory-weighted guess.
                        if userReadings.allSatisfy({ $0.utilization != nil }) {
                            metric.sum += userReadings.compactMap(\.utilization).reduce(0, +)
                            metric.count += 1
                        }
                    } else {
                        metric.count += 1
                    }
                    sample.users[user] = metric
                }
                sample.attributedSampleCount += 1
            }
            if let index { result[index] = sample } else { result.append(sample) }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }
}

actor GPUHistoryArchive {
    private struct Archive: Codable {
        let connectionFingerprint: String
        let samples: [GPUHistorySample]
    }
    private let directory: URL
    private var archives: [String: Archive] = [:]

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.leejaein.NVBeacon/GPUHistory", isDirectory: true)) {
        self.directory = directory
    }

    private func file(for serverID: String) -> URL {
        // IDs come from persisted settings; do not let an imported ID escape the archive directory.
        let safeID = Data(serverID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safeID + ".json")
    }

    func load(serverID: String, fingerprint: String, now: Date = Date()) throws -> [GPUHistorySample] {
        if archives[serverID] == nil, FileManager.default.fileExists(atPath: file(for: serverID).path) {
            let data = try Data(contentsOf: file(for: serverID))
            archives[serverID] = try JSONDecoder().decode(Archive.self, from: data)
        }
        guard let archive = archives[serverID], archive.connectionFingerprint == fingerprint else { return [] }
        return archive.samples.filter { $0.timestamp >= now.addingTimeInterval(-24 * 3600 - 60) && $0.timestamp <= now }
    }

    func record(_ snapshot: GPUSnapshot, serverID: String, fingerprint: String) throws -> [GPUHistorySample] {
        let history = try load(serverID: serverID, fingerprint: fingerprint, now: snapshot.takenAt)
        let samples = GPUHistorySample.recording(snapshot, into: history, now: snapshot.takenAt)
        let archive = Archive(connectionFingerprint: fingerprint, samples: samples)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(archive)
        try data.write(to: file(for: serverID), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(for: serverID).path)
        archives[serverID] = archive
        return samples
    }
}
