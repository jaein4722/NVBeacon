import Foundation
import Testing
@testable import NVBeacon

private func historySnapshot(at seconds: Double, total: Int = 60,
                             users: [GPUUserUtilizationReading] = []) -> GPUSnapshot {
    GPUSnapshot(takenAt: Date(timeIntervalSince1970: seconds), gpus: [
        GPUReading(index: 0, name: "Test GPU", uuid: "GPU-test", utilization: total,
                   memoryUsedMB: 100, memoryTotalMB: 1000, temperatureCelsius: 40, processes: [])
    ], userUtilization: users)
}

private func reading(_ user: String, _ value: Double?) -> GPUUserUtilizationReading {
    GPUUserUtilizationReading(gpuIndex: 0, user: user, utilization: value)
}

@Test func historyAveragesMinuteSamplesAndAccountsForUserDeparture() throws {
    let first = historySnapshot(at: 120, total: 80, users: [reading("alice", 60)])
    var samples = GPUHistorySample.recording(first, into: [], now: first.takenAt)
    let second = historySnapshot(at: 150, total: 20, users: [reading("bob", 20)])
    samples = GPUHistorySample.recording(second, into: samples, now: second.takenAt)
    let sample = try #require(samples.first)
    #expect(samples.count == 1)
    #expect(sample.sampleCount == 2)
    #expect(sample.totalUtilization == 50)
    #expect(sample.users["alice"]?.average == 30)
    #expect(sample.users["bob"]?.average == 10)
}

@Test func historyUnavailableDoesNotBecomeZeroAndIdleDoes() throws {
    let active = historySnapshot(at: 120, users: [reading("alice", 60)])
    var samples = GPUHistorySample.recording(active, into: [], now: active.takenAt)
    let unavailable = historySnapshot(at: 150)
    samples = GPUHistorySample.recording(unavailable, into: samples, now: unavailable.takenAt)
    #expect(samples.first?.users["alice"]?.average == 60)
    let idle = historySnapshot(at: 160, users: [reading("(idle)", 0)])
    samples = GPUHistorySample.recording(idle, into: samples, now: idle.takenAt)
    #expect(samples.first?.users["alice"]?.average == 30)
    #expect(samples.first?.users["(idle)"] == nil)
    let missing = historySnapshot(at: 180, users: [reading("alice", nil)])
    samples = GPUHistorySample.recording(missing, into: samples, now: missing.takenAt)
    #expect(samples.last?.unavailableUsers.contains("alice") == true)
    #expect(samples.last?.users["alice"]?.average == nil)
}

@Test func historyPrunesOldAndFutureBucketsAndSeparatesGPUIdentity() {
    let old = GPUHistorySample(timestamp: Date(timeIntervalSince1970: 0), gpuIndex: 0, gpuUUID: "old")
    let future = GPUHistorySample(timestamp: Date(timeIntervalSince1970: 200_000), gpuIndex: 0, gpuUUID: "future")
    let now = historySnapshot(at: 100_000)
    let samples = GPUHistorySample.recording(now, into: [old, future], now: now.takenAt)
    #expect(samples.count == 1)
    #expect(samples.first?.gpuUUID == "GPU-test")
}

@Test func historyArchivePersistsAndKeepsServersAndConnectionsSeparate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-history-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let snapshot = historySnapshot(at: Date().timeIntervalSince1970, users: [reading("alice", 40)])
    let writer = GPUHistoryArchive(directory: directory)
    let saved = try await writer.record(snapshot, serverID: "server/../one", fingerprint: "fixture-a")
    let reader = GPUHistoryArchive(directory: directory)
    let loaded = try await reader.load(serverID: "server/../one", fingerprint: "fixture-a")
    #expect(loaded == saved)
    #expect(try await reader.load(serverID: "server/../one", fingerprint: "fixture-b").isEmpty)
    #expect(try await reader.load(serverID: "another", fingerprint: "fixture-a").isEmpty)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    #expect(files[0].deletingLastPathComponent().resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
    let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test func historyArchiveReportsCorruptDataInsteadOfSilentlyErasingIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-corrupt-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(Data("one".utf8).base64EncodedString() + ".json")
    try Data("not json".utf8).write(to: file)
    await #expect(throws: (any Error).self) {
        try await GPUHistoryArchive(directory: directory).record(historySnapshot(at: Date().timeIntervalSince1970),
                                                               serverID: "one", fingerprint: "fixture")
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
}

@Test func historyPlotConnectsShortMetricDropoutsButNotOfflineIntervals() {
    var samples: [GPUHistorySample] = []
    for (time, users) in [(120.0, [reading("alice", 60)]), (180.0, []),
                          (240.0, [reading("alice", 30)]), (600.0, [reading("alice", 20)])] {
        let snapshot = historySnapshot(at: time, users: users)
        samples = GPUHistorySample.recording(snapshot, into: samples, now: snapshot.takenAt)
    }
    let points = GPUHistoryPlot.points(samples: samples, hours: 1, now: Date(timeIntervalSince1970: 600), pollInterval: 30)
    let alice = points.filter { $0.user == "alice" }
    #expect(alice.count == 3)
    #expect(Set(alice.map(\.segment)).count == 2)
    #expect(points.filter { $0.user == GPUHistoryPlot.totalLabel }.count == 4)
}

@Test func historyPlotSupportsAllRequestedWindowsAndBoundsRendering() {
    let now = Date(timeIntervalSince1970: 100_020)
    let samples = (0..<1440).map { offset in
        GPUHistorySample(timestamp: now.addingTimeInterval(-Double(offset * 60)), gpuIndex: 0,
                         gpuUUID: "GPU-test", totalSum: 20, sampleCount: 1, attributedSampleCount: 1,
                         users: ["alice": GPUHistoryUserMetric(sum: 20, count: 1)])
    }
    for hours in [1, 5, 12, 24] {
        let points = GPUHistoryPlot.points(samples: samples, hours: hours, now: now, pollInterval: 30)
        #expect(!points.isEmpty)
        #expect(points.allSatisfy { $0.timestamp >= now.addingTimeInterval(-Double(hours * 3600)) })
        #expect(points.filter { $0.user == "alice" }.count <= 361)
    }
}

@Test func historyPlotDoesNotBridgeExactlyOneMissingMinute() {
    var samples: [GPUHistorySample] = []
    for time in [120.0, 240.0] {
        let snapshot = historySnapshot(at: time, users: [reading("alice", 20)])
        samples = GPUHistorySample.recording(snapshot, into: samples, now: snapshot.takenAt)
    }
    let points = GPUHistoryPlot.points(samples: samples, hours: 1, now: Date(timeIntervalSince1970: 240), pollInterval: 30)
    #expect(Set(points.filter { $0.user == "alice" }.map(\.segment)).count == 2)
}

@Test func stackedAreasKeepMeasuredUserValuesAndExcludeGPUTotal() {
    let time = Date(timeIntervalSince1970: 120)
    let points = [
        GPUHistoryPoint(timestamp: time, user: "bob", value: 55, segment: 0),
        GPUHistoryPoint(timestamp: time, user: "alice", value: 70, segment: 0),
        GPUHistoryPoint(timestamp: time, user: GPUHistoryPlot.totalLabel, value: 95, segment: 0),
    ]
    let areas = GPUHistoryPlot.areas(from: points)
    #expect(areas.count == 2)
    #expect(areas[0].point.user == "alice")
    #expect(areas[0].lower == 0)
    #expect(areas[0].upper == 70)
    #expect(areas[1].point.user == "bob")
    #expect(areas[1].lower == 70)
    #expect(areas[1].upper == 125)
    #expect(areas[1].upper - areas[1].lower == 55)
}

@Test func stackedAreasKeepMissingReadingsAndOfflineSegments() {
    var samples: [GPUHistorySample] = []
    for (time, users) in [(120.0, [reading("alice", 60), reading("bob", 20)]),
                          (180.0, [reading("alice", nil), reading("bob", 30)]),
                          (240.0, [reading("alice", 40), reading("bob", 10)]),
                          (600.0, [reading("alice", 50), reading("bob", 20)])] {
        let snapshot = historySnapshot(at: time, users: users)
        samples = GPUHistorySample.recording(snapshot, into: samples, now: snapshot.takenAt)
    }
    let points = GPUHistoryPlot.points(samples: samples, hours: 1, now: Date(timeIntervalSince1970: 600), pollInterval: 30)
    let areas = GPUHistoryPlot.areas(from: points)
    let alice = areas.filter { $0.point.user == "alice" }
    #expect(alice.count == 3)
    #expect(Set(alice.map { $0.point.segment }).count == 2)
    #expect(!areas.contains { $0.point.user == "alice" && $0.point.timestamp == Date(timeIntervalSince1970: 180) })
}

@Test func stackedAreasDoNotSmoothMissingUserMetricsIntoLongWindowBuckets() {
    var samples: [GPUHistorySample] = []
    for (time, users) in [(120.0, [reading("alice", nil), reading("bob", 20)]),
                          (180.0, [reading("alice", 40), reading("bob", 30)]),
                          (240.0, [reading("alice", 50), reading("bob", 10)])] {
        let snapshot = historySnapshot(at: time, users: users)
        samples = GPUHistorySample.recording(snapshot, into: samples, now: snapshot.takenAt)
    }
    let points = GPUHistoryPlot.points(samples: samples, hours: 24, now: Date(timeIntervalSince1970: 240), pollInterval: 30)
    let areas = GPUHistoryPlot.areas(from: points)
    #expect(!areas.contains { $0.point.user == "alice" && $0.point.timestamp == Date(timeIntervalSince1970: 120) })
    #expect(areas.filter { $0.point.timestamp == Date(timeIntervalSince1970: 180) }.last?.upper == 70)
    #expect(areas.filter { $0.point.timestamp == Date(timeIntervalSince1970: 240) }.last?.upper == 60)
}
