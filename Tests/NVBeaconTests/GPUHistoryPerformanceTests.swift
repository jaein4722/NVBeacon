import Foundation
import Testing
@testable import NVBeacon

private let performanceUsers = ["alice", "bob", "carol", "dana", "erin", "frank"]

private func performanceHistory(now: Date) -> [GPUHistorySample] {
    (0..<1440).map { offset in
        let timestamp = now.addingTimeInterval(-Double(offset * 60))
        let metrics = Dictionary(uniqueKeysWithValues: performanceUsers.enumerated().map { index, user in
            (user, GPUHistoryUserMetric(sum: Double((offset + index * 13) % 101), count: 1))
        })
        return GPUHistorySample(timestamp: timestamp, gpuIndex: 0, gpuUUID: "fixture-gpu",
                               totalSum: 75, sampleCount: 1, attributedSampleCount: 1,
                               users: metrics, unavailableUsers: offset.isMultiple(of: 37) ? ["unavailable-owner"] : [])
    }
}

@Test func preparedHistoryRenderDataBoundsWindowsAndSortsSamples() throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let history = performanceHistory(now: now)
    // Deliberately reverse the input so the render model owns the visible sort order.
    let reversed = Array(history.reversed())

    for hours in [5, 12, 24] {
        let model = GPUHistoryRenderData(samples: reversed, hours: hours, now: now, pollInterval: 30)
        #expect(model.samples.count <= history.prefix(hours * 60 + 1).count)
        #expect(model.samples.map(\.timestamp) == model.totalPoints.map(\.timestamp))
        #expect(model.samples.allSatisfy { $0.timestamp >= now.addingTimeInterval(-Double(hours * 3600)) && $0.timestamp <= now })
        #expect(model.samples.map(\.timestamp) == model.samples.map(\.timestamp).sorted())
        #expect(model.users == performanceUsers + ["unavailable-owner"])
        #expect(!model.points.isEmpty)
        #expect(!model.areas.isEmpty)
        // The unavailable user's repeated gaps intentionally retain minute-resolution bins.
        #expect(model.totalPoints.count <= model.samples.count)
        let continuousHistory = history.map { sample in
            var sample = sample
            sample.unavailableUsers = []
            return sample
        }
        let continuousModel = GPUHistoryRenderData(samples: continuousHistory, hours: hours, now: now, pollInterval: 30)
        #expect(continuousModel.totalPoints.count <= 121)
        #expect(model.maximumY.isFinite && model.maximumY > 0)
        #expect(model.range.lowerBound == now.addingTimeInterval(-Double(hours * 3600)) && model.range.upperBound == now)
    }
}

@Test func preparedHistoryNearestLookupHandlesBoundariesAndEarlierTies() throws {
    let now = Date(timeIntervalSince1970: 3_000_000)
    let samples = [0, 60, 120].map {
        GPUHistorySample(timestamp: now.addingTimeInterval(Double($0)), gpuIndex: 0, gpuUUID: "fixture-gpu",
                         totalSum: 1, sampleCount: 1)
    }
    let model = GPUHistoryRenderData(samples: samples, hours: 1, now: now.addingTimeInterval(120), pollInterval: 30)

    #expect(model.nearestSampleIndex(to: now.addingTimeInterval(-100)) == 0)
    #expect(model.nearestSampleIndex(to: now.addingTimeInterval(200)) == 2)
    #expect(model.nearestSampleIndex(to: now.addingTimeInterval(30)) == 0)
    #expect(model.nearestSampleIndex(to: now.addingTimeInterval(90)) == 1)
    #expect(model.nearestSampleIndex(to: now.addingTimeInterval(60)) == 1)
}

@Test func preparedHistoryLookupKeepsEmptyAndPreparedSnapshotsStable() throws {
    let now = Date(timeIntervalSince1970: 4_000_000)
    let empty = GPUHistoryRenderData(samples: [], hours: 5, now: now, pollInterval: 30)
    #expect(empty.nearestSampleIndex(to: now) == nil)
    #expect(empty.samples.isEmpty && empty.points.isEmpty && empty.areas.isEmpty && empty.totalPoints.isEmpty)

    let samples = performanceHistory(now: now)
    let model = GPUHistoryRenderData(samples: samples, hours: 12, now: now, pollInterval: 30)
    let sampleSnapshot = model.samples
    let pointsSnapshot = model.points
    let areasSnapshot = model.areas
    let totalSnapshot = model.totalPoints
    for query in 0..<300 {
        #expect(model.nearestSampleIndex(to: now.addingTimeInterval(-Double(query * 17))) != nil)
    }
    #expect(model.samples == sampleSnapshot)
    #expect(model.points == pointsSnapshot)
    #expect(model.areas == areasSnapshot)
    #expect(model.totalPoints == totalSnapshot)
}

// Explicitly opt-in because this is a comparative CPU benchmark, not a CI timing gate.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NVBEACON_PERF_CHECK"] == "1"))
func preparedHistoryRenderDataHoverCostBenchmark() throws {
    let now = Date(timeIntervalSince1970: 5_000_000)
    let history = performanceHistory(now: now)
    let queryDates = (0..<40).map { now.addingTimeInterval(-Double($0 * 173)) }
    var checksum = 0.0

    for hours in [5, 12, 24] {
        let prepareStart = ProcessInfo.processInfo.systemUptime
        let model = GPUHistoryRenderData(samples: history, hours: hours, now: now, pollInterval: 30)
        let preparationSeconds = ProcessInfo.processInfo.systemUptime - prepareStart

        let legacyStart = ProcessInfo.processInfo.systemUptime
        for date in queryDates {
            // Legacy hover path: rebuild chart points, stacked areas, and color inputs for every event.
            let points = GPUHistoryPlot.points(samples: history, hours: hours, now: now, pollInterval: 30)
            let areas = GPUHistoryPlot.areas(from: points)
            let visibleUsers = Set(history.filter { $0.timestamp >= now.addingTimeInterval(-Double(hours * 3600)) }
                .flatMap { Array($0.users.keys) + Array($0.unavailableUsers) }).sorted()
            let colorInputs = visibleUsers.enumerated().map { index, user in
                (user, index < 10 ? Double(index) : Double(index - 10) / Double(max(visibleUsers.count - 10, 1)))
            }
            let legacyIndex = history.min {
                abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
            }
            checksum += Double(points.count + areas.count + colorInputs.count) + (legacyIndex?.totalUtilization ?? 0)
        }
        let legacySeconds = ProcessInfo.processInfo.systemUptime - legacyStart

        let lookupStart = ProcessInfo.processInfo.systemUptime
        for iteration in 0..<10_000 {
            let date = queryDates[iteration % queryDates.count]
            if let index = model.nearestSampleIndex(to: date) { checksum += Double(index + 1) }
        }
        let lookupSeconds = ProcessInfo.processInfo.systemUptime - lookupStart
        let normalizedLookupPerHover = lookupSeconds / 10_000 * 40
        print("GPU history CPU benchmark \(hours)h: prepare=\(preparationSeconds)s, legacy 40 hovers=\(legacySeconds)s, prepared 10,000 lookups=\(lookupSeconds)s (\(normalizedLookupPerHover)s per 40-hover equivalent)")
    }

    #expect(checksum.isFinite && checksum > 0)
}

@Test func preparedTimeScaleTicksStayAlignedToWindowEdges() {
    let now = Date(timeIntervalSince1970: 5_000_000)
    for hours in [1, 5, 12, 24] {
        let model = GPUHistoryRenderData(samples: [], hours: hours, now: now, pollInterval: 30)
        #expect(model.hours == hours)
        #expect(model.ticks.count == 5)
        #expect(model.ticks.first == model.range.lowerBound)
        #expect(model.ticks.last == model.range.upperBound)
        #expect(model.ticks[2] == model.range.lowerBound.addingTimeInterval(Double(hours * 3600) / 2))
    }
}

@Test func userColorsDoNotChangeWhenSwitchingTimeWindows() {
    let now = Date(timeIntervalSince1970: 5_000_000)
    let samples = [
        GPUHistorySample(timestamp: now.addingTimeInterval(-10 * 3600), gpuIndex: 0, gpuUUID: "fixture",
                         totalSum: 40, sampleCount: 1, attributedSampleCount: 1,
                         users: ["alice": GPUHistoryUserMetric(sum: 40, count: 1)]),
        GPUHistorySample(timestamp: now, gpuIndex: 0, gpuUUID: "fixture",
                         totalSum: 50, sampleCount: 1, attributedSampleCount: 1,
                         users: ["bob": GPUHistoryUserMetric(sum: 50, count: 1)]),
    ]
    let short = GPUHistoryRenderData(samples: samples, hours: 5, now: now, pollInterval: 30)
    let long = GPUHistoryRenderData(samples: samples, hours: 24, now: now, pollInterval: 30)
    #expect(short.users == ["bob"])
    #expect(long.users == ["alice", "bob"])
    #expect(short.colors["bob"] == long.colors["bob"])
}

@Test func longWindowsAverageRealZerosAndCursorMatchesRenderedValues() throws {
    let samples = (0..<6).map { minute in
        let value = minute.isMultiple(of: 2) ? 100.0 : 0.0
        return GPUHistorySample(timestamp: Date(timeIntervalSince1970: Double(minute * 60)),
                                gpuIndex: 0, gpuUUID: "fixture", totalSum: value, sampleCount: 1,
                                attributedSampleCount: 1, users: ["alice": GPUHistoryUserMetric(sum: value, count: 1)])
    }
    let now = Date(timeIntervalSince1970: 300)
    let detail = GPUHistoryRenderData(samples: samples, hours: 1, now: now, pollInterval: 30)
    #expect(detail.samples.map(\.totalUtilization) == [100, 0, 100, 0, 100, 0])
    let trend = GPUHistoryRenderData(samples: samples, hours: 5, now: now, pollInterval: 30)
    #expect(trend.rollupMinutes == 3)
    #expect(trend.samples.count == 2)
    #expect(abs(trend.samples[0].totalUtilization - 200.0 / 3) < 0.001)
    #expect(abs(trend.samples[1].totalUtilization - 100.0 / 3) < 0.001)
    for sample in trend.samples {
        let total = try #require(trend.totalPoints.first { $0.timestamp == sample.timestamp })
        let area = try #require(trend.areas.first { $0.point.timestamp == sample.timestamp })
        #expect(sample.totalUtilization == total.value)
        #expect(sample.users["alice"]?.average == area.upper - area.lower)
    }
    #expect(samples.map(\.totalUtilization) == [100, 0, 100, 0, 100, 0])
}

@Test func trendReadoutsKeepMissingMetricsAndOfflineSegments() {
    let samples = [0, 1, 2, 10, 11].map { minute in
        GPUHistorySample(timestamp: Date(timeIntervalSince1970: Double(minute * 60)),
                         gpuIndex: 0, gpuUUID: "fixture", totalSum: 100, sampleCount: 1,
                         attributedSampleCount: 1,
                         users: minute == 1 ? [:] : ["alice": GPUHistoryUserMetric(sum: 100, count: 1)],
                         unavailableUsers: minute == 1 ? ["alice"] : [])
    }
    let model = GPUHistoryRenderData(samples: samples, hours: 24,
                                    now: Date(timeIntervalSince1970: 660), pollInterval: 30)
    #expect(model.samples.first { $0.timestamp == Date(timeIntervalSince1970: 60) }?.unavailableUsers.contains("alice") == true)
    #expect(Set(model.points.filter { $0.user == "alice" }.map(\.segment)).count == 2)
    #expect(model.samples.allSatisfy { $0.totalUtilization == 100 })
}

@Test func trendRollupScalesWithWindowWithoutChangingOneHourDetail() {
    #expect([1, 5, 12, 24].map { GPUHistoryPlot.rollupMinutes(hours: $0) } == [1, 3, 6, 12])
}

@Test func shortDropoutsConnectOnlyDuringContinuousRefreshesAndLongDropoutsBreak() {
    let samples = (0...8).map { minute in
        GPUHistorySample(timestamp: Date(timeIntervalSince1970: Double(minute * 60)),
                         gpuIndex: 0, gpuUUID: "fixture", totalSum: 100, sampleCount: 1,
                         attributedSampleCount: 1,
                         users: [0, 3, 8].contains(minute) ? ["alice": GPUHistoryUserMetric(sum: 100, count: 1)] : [:],
                         unavailableUsers: [0, 3, 8].contains(minute) ? [] : ["alice"])
    }
    let model = GPUHistoryRenderData(samples: samples, hours: 1,
                                    now: Date(timeIntervalSince1970: 480), pollInterval: 30)
    let alice = model.points.filter { $0.user == "alice" }
    #expect(alice.count == 3)
    #expect(alice[0].segment == alice[1].segment)
    #expect(alice[1].segment != alice[2].segment)
    #expect(model.samples[1].unavailableUsers.contains("alice"))
    #expect(!model.areas.contains { $0.point.timestamp == Date(timeIntervalSince1970: 60) })
}
