import AppKit
import SwiftUI
import Charts

struct GPUHistoryPoint: Identifiable, Equatable, Sendable {
    let timestamp: Date
    let user: String
    let value: Double
    let segment: Int
    var series: String { "\(user):\(segment)" }
    var id: String { "\(series):\(timestamp.timeIntervalSince1970)" }
}

struct GPUHistoryAreaPoint: Identifiable, Equatable, Sendable {
    let point: GPUHistoryPoint
    let lower: Double
    let upper: Double
    var id: String { point.id }
}

enum GPUHistoryPlot {
    static let totalLabel = "GPU total"

    static func rollupMinutes(hours: Int) -> Int {
        max(1, Int(ceil(Double(hours * 60) / 120)))
    }

    static func areas(from points: [GPUHistoryPoint]) -> [GPUHistoryAreaPoint] {
        let byTime = Dictionary(grouping: points.filter { $0.user != totalLabel }, by: \.timestamp)
        return byTime.keys.sorted().flatMap { time in
            var baseline = 0.0
            return (byTime[time] ?? []).sorted { $0.user < $1.user }.map { point in
                let area = GPUHistoryAreaPoint(point: point, lower: baseline, upper: baseline + point.value)
                baseline = area.upper
                return area
            }
        }
    }

    static func points(samples: [GPUHistorySample], hours: Int, now: Date, pollInterval: Int) -> [GPUHistoryPoint] {
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        let visible = samples.filter { $0.timestamp >= start && $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }
        let users = Set(visible.flatMap { Array($0.users.keys) + Array($0.unavailableUsers) }).sorted()
        var result: [GPUHistoryPoint] = []
        for user in [totalLabel] + users {
            var previous: Date?
            var previousSample: Date?
            var segment = 0
            for sample in visible {
                // Missing refreshes are offline gaps, never interpolated. A short
                // per-user metric dropout during otherwise live refreshes may be
                // connected visually, but never becomes a zero or a stored reading.
                if let previousSample, sample.timestamp.timeIntervalSince(previousSample) >= Double(max(120, pollInterval * 2)) {
                    segment += 1
                    previous = nil
                }
                defer { previousSample = sample.timestamp }
                let value: Double?
                if user == totalLabel {
                    value = sample.totalUtilization
                } else if sample.unavailableUsers.contains(user) || sample.attributedSampleCount == 0 {
                    value = nil
                } else {
                    value = sample.users[user]?.average ?? 0
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
        // Gapped buckets below retain their minute detail rather than inventing continuity.
        let step = Double(rollupMinutes(hours: hours) * 60)
        let buckets = Dictionary(grouping: result) { floor($0.timestamp.timeIntervalSince1970 / step) }
        return buckets.values.flatMap { bucket -> [GPUHistoryPoint] in
            let byUser = Dictionary(grouping: bucket, by: \.user)
            let times = Set(bucket.map(\.timestamp))
            // Keep partial/gapped buckets at minute resolution. Stable buckets share
            // one timestamp across users so area layers stack the same time sample.
            if byUser.values.contains(where: { points in
                points.count != times.count || Set(points.map(\.segment)).count > 1
            }) { return bucket }
            guard let timestamp = times.min() else { return [] }
            return byUser.values.compactMap { points in
                guard let first = points.first else { return nil }
                return GPUHistoryPoint(timestamp: timestamp, user: first.user,
                                       value: points.map(\.value).reduce(0, +) / Double(points.count), segment: first.segment)
            }
        }.sorted { $0.timestamp < $1.timestamp }

    }
}

// Immutable geometry is prepared only when data, GPU, or the time window changes.
struct GPUHistoryRenderData: Sendable {
    let id = UUID()
    let samples: [GPUHistorySample]
    let users: [String]
    let points: [GPUHistoryPoint]
    let areas: [GPUHistoryAreaPoint]
    let totalPoints: [GPUHistoryPoint]
    let maximumY: Double
    let range: ClosedRange<Date>
    let hours: Int
    let ticks: [Date]
    let colors: [String: Color]
    var rollupMinutes: Int { GPUHistoryPlot.rollupMinutes(hours: hours) }

    init(samples: [GPUHistorySample], hours: Int, now: Date, pollInterval: Int) {
        let start = now.addingTimeInterval(-Double(hours * 3600))
        let window = start...now
        range = window
        self.hours = hours
        ticks = (0...4).map { start.addingTimeInterval(Double(hours * 3600) * Double($0) / 4) }
        let visible = samples.filter { window.contains($0.timestamp) }.sorted { $0.timestamp < $1.timestamp }
        let sortedUsers = Set(visible.flatMap { Array($0.users.keys) + Array($0.unavailableUsers) }).sorted()
        users = sortedUsers
        let plotted = GPUHistoryPlot.points(samples: visible, hours: hours, now: now, pollInterval: pollInterval)
        points = plotted
        // Cursor and legend read the very same means as the marks, not raw minute spikes.
        let originals = Dictionary(visible.map { ($0.timestamp, $0) }, uniquingKeysWith: { _, last in last })
        self.samples = Dictionary(grouping: plotted, by: \.timestamp).compactMap { time, values in
            guard var sample = originals[time], let total = values.first(where: { $0.user == GPUHistoryPlot.totalLabel }) else { return nil }
            sample.totalSum = total.value
            sample.sampleCount = 1
            let measured = values.filter { $0.user != GPUHistoryPlot.totalLabel }
            sample.users = Dictionary(uniqueKeysWithValues: measured.map { ($0.user, GPUHistoryUserMetric(sum: $0.value, count: 1)) })
            sample.unavailableUsers = Set(sortedUsers).subtracting(sample.users.keys)
            return sample
        }.sorted { $0.timestamp < $1.timestamp }
        areas = GPUHistoryPlot.areas(from: points)
        totalPoints = points.filter { $0.user == GPUHistoryPlot.totalLabel }
        maximumY = max(100, max(areas.map(\.upper).max() ?? 0, totalPoints.map(\.value).max() ?? 0).rounded(.up))
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .cyan, .indigo, .mint, .teal, .brown]
        let colorDomain = Set(samples.flatMap { Array($0.users.keys) + Array($0.unavailableUsers) }).sorted()
        colors = Dictionary(uniqueKeysWithValues: colorDomain.enumerated().map { index, user in
            let color = index < palette.count ? palette[index]
                : Color(hue: Double(index - palette.count) / Double(max(colorDomain.count - palette.count, 1)), saturation: 0.68, brightness: 0.82)
            return (user, color)
        })
    }

    func nearestSampleIndex(to date: Date) -> Int? {
        guard !samples.isEmpty else { return nil }
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].timestamp < date { lower = middle + 1 } else { upper = middle }
        }
        if lower == 0 { return 0 }
        if lower == samples.count { return samples.count - 1 }
        return date.timeIntervalSince(samples[lower - 1].timestamp) <= samples[lower].timestamp.timeIntervalSince(date)
            ? lower - 1 : lower
    }
}

struct GPUHistoryView: View {
    @ObservedObject var store: NVBeaconStore
    let state: ServerRuntimeState
    @State private var isExpanded = false
    @State private var hours = 1
    @State private var gpuIndex = 0
    @State private var prepared: GPUHistoryRenderData?

    private var language: AppInterfaceLanguage { store.settings.resolvedLanguage }
    private func t(_ english: String, _ korean: String) -> String { language.text(english, korean) }
    private var history: [GPUHistorySample] { store.gpuHistory[state.id] ?? [] }
    private var indices: [Int] {
        let current = state.snapshot?.gpus.map(\.index) ?? []
        return current.isEmpty ? Set(history.map(\.gpuIndex)).sorted() : current.sorted()
    }
    private var selectedGPU: Int { indices.contains(gpuIndex) ? gpuIndex : (indices.first ?? 0) }
    private var selectedUUID: String? { state.snapshot?.gpus.first { $0.index == selectedGPU }?.uuid }

    private func prepare() {
        guard isExpanded else { return }
        let samples = history.filter { $0.gpuIndex == selectedGPU && (selectedUUID == nil || $0.gpuUUID == selectedUUID) }
        prepared = GPUHistoryRenderData(samples: samples, hours: hours, now: Date(), pollInterval: store.settings.pollIntervalSeconds)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !store.settings.recordsGPUHistory {
                            Label(t("Recording paused", "기록 일시 중지"), systemImage: "pause.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Picker(t("GPU", "GPU"), selection: $gpuIndex) {
                                ForEach(indices, id: \.self) { index in Text("GPU \(index)").tag(index) }
                            }
                            .labelsHidden()
                            .frame(width: 112)
                            Picker(t("Time range", "시간 범위"), selection: $hours) {
                                ForEach([1, 5, 12, 24], id: \.self) { value in Text("\(value)h").tag(value) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                        .frame(height: 28)
                        if let prepared {
                            if prepared.points.isEmpty && !store.settings.recordsGPUHistory {
                                Text(t("Enable Record GPU history in General settings.", "일반 설정에서 GPU 기록 저장을 켜세요."))
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 230, alignment: .center)
                            } else {
                                GPUHistoryContent(data: prepared, language: language)
                                    .id("\(selectedGPU):\(selectedUUID ?? "")")
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    if let error = store.gpuHistoryErrors[state.id] {
                        Text(t("History could not be saved: \(error)", "기록 저장 실패: \(error)"))
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 7)
            }
        } label: {
            Label(t("GPU history by user", "사용자별 GPU 기록"), systemImage: "chart.xyaxis.line")
                .font(.system(size: 15, weight: .semibold))
        }
        .accessibilityIdentifier("gpu-history-\(state.id)")
        .onChange(of: isExpanded) { _, _ in prepare() }
        .onChange(of: history) { _, _ in prepare() }
        .onChange(of: hours) { _, _ in prepare() }
        .onChange(of: selectedGPU) { _, _ in prepare() }
        .onChange(of: selectedUUID) { _, _ in prepare() }
        .onChange(of: Int(Date().timeIntervalSince1970 / 60)) { _, _ in prepare() }
    }
}

private struct GPUHistoryContent: View {
    let data: GPUHistoryRenderData
    let language: AppInterfaceLanguage
    @State private var selectedIndex: Int?
    private func t(_ english: String, _ korean: String) -> String { language.text(english, korean) }
    private var sample: GPUHistorySample? {
        if let selectedIndex, data.samples.indices.contains(selectedIndex) { return data.samples[selectedIndex] }
        return data.samples.last
    }

    var body: some View {
        if data.points.isEmpty {
            Text(t("Waiting for the first history sample.", "첫 GPU 기록을 기다리는 중입니다."))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 230, alignment: .center)
        } else {
            if let sample {
                HStack {
                    Text(sample.timestamp, format: .dateTime.month().day().hour().minute())
                    Spacer()
                    Text(t("\(data.rollupMinutes)m avg", "\(data.rollupMinutes)분 평균"))
                        .help(t("Interval averages. Short per-user sampling gaps are connected visually, but read as unavailable. Offline and longer gaps stay open.", "구간 평균입니다. 짧은 사용자별 측정 누락은 시각적으로 연결하지만 측정 불가로 표시합니다. 오프라인 및 긴 누락 구간은 연결하지 않습니다."))
                }
                .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    metricRow(user: GPUHistoryPlot.totalLabel, value: sample.totalUtilization)
                    ForEach(data.users, id: \.self) { user in
                        metricRow(user: user, value: sample.unavailableUsers.contains(user) || sample.attributedSampleCount == 0
                                  ? nil : sample.users[user]?.average ?? 0)
                    }
                }
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            // Selection lives outside the equatable marks view: moving the pointer
            // updates only the legend and overlay, never the area/line geometry.
            GPUHistoryStaticChart(data: data, selectedIndex: $selectedIndex)
                .equatable()
                .frame(height: 230)
                .accessibilityLabel(t("GPU utilization history by user", "사용자별 GPU 사용률 기록"))
            if data.users.isEmpty || data.samples.last?.attributedSampleCount == 0 {
                Text(t("Per-user SM sampling unavailable or GPU idle. The gray line is measured GPU utilization.", "사용자별 SM 측정 불가 또는 GPU 유휴 상태입니다. 회색 선은 GPU 사용률입니다."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func metricRow(user: String, value: Double?) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(user == GPUHistoryPlot.totalLabel ? Color.secondary : data.colors[user] ?? .blue)
                .frame(width: 18, height: 12)
            Text(user == GPUHistoryPlot.totalLabel ? t("GPU total", "GPU 전체") : user)
                .font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .help(user)
            Spacer()
            Text(value.map { String(format: "%.1f%%", $0) } ?? t("Unavailable", "측정 불가"))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                .frame(width: 108, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

private struct GPUHistoryStaticChart: View, Equatable {
    let data: GPUHistoryRenderData
    @Binding var selectedIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.data.id == rhs.data.id }

    var body: some View {
        Chart {
            ForEach(data.areas) { area in
                AreaMark(x: .value("Time", area.point.timestamp),
                         yStart: .value("SM %", area.lower), yEnd: .value("SM %", area.upper),
                         series: .value("Segment", area.point.series))
                    .foregroundStyle((data.colors[area.point.user] ?? .blue).opacity(0.28))
                    .interpolationMethod(.linear)
                LineMark(x: .value("Time", area.point.timestamp), y: .value("SM %", area.upper),
                         series: .value("Segment", area.point.series))
                    .foregroundStyle(data.colors[area.point.user] ?? .blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            ForEach(data.totalPoints) { point in
                LineMark(x: .value("Time", point.timestamp), y: .value("SM %", point.value),
                         series: .value("Segment", point.series))
                    .foregroundStyle(Color.secondary.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: data.range, range: .plotDimension(startPadding: 0, endPadding: 0))
        .chartYScale(domain: 0...data.maximumY)
        .chartYAxis { AxisMarks(position: .leading) { value in
            AxisGridLine().foregroundStyle(Color.secondary.opacity(0.10))
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text("\(Int(number))%")
                        .font(.system(size: 12).monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
            }
        } }
        .chartXAxis { AxisMarks(values: data.ticks) { value in
            AxisValueLabel(anchor: value.index == 0 ? .topLeading : value.index == value.count - 1 ? .topTrailing : .top) {
                if let date = value.as(Date.self) {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 12).monospacedDigit())
                }
            }
        } }
        .chartPlotStyle { plot in plot.clipped() }
        // Only changing time scale animates; pointer reads and background polling stay instant.
        .animation(reduceMotion ? nil : .timingCurve(0.77, 0, 0.175, 1, duration: 0.28), value: data.hours)
        .chartOverlay { proxy in
            GPUHistoryCursorOverlay(data: data, proxy: proxy, selectedIndex: $selectedIndex)
        }
    }
}

private struct GPUHistoryCursorOverlay: View {
    let data: GPUHistoryRenderData
    let proxy: ChartProxy
    @Binding var selectedIndex: Int?

    private func select(at location: CGPoint, in plot: CGRect) {
        let index: Int?
        if plot.contains(location), let date: Date = proxy.value(atX: location.x - plot.minX) {
            index = data.nearestSampleIndex(to: date)
        } else { index = nil }
        guard index != selectedIndex else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { selectedIndex = index }
    }

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point): select(at: point, in: plot)
                            case .ended: selectedIndex = nil
                            }
                        }
                        .gesture(DragGesture(minimumDistance: 0).onChanged { select(at: $0.location, in: plot) })
                    if let selectedIndex, data.samples.indices.contains(selectedIndex),
                       let x = proxy.position(forX: data.samples[selectedIndex].timestamp) {
                        Rectangle().fill(Color.secondary.opacity(0.5))
                            .frame(width: 1, height: plot.height)
                            .position(x: plot.minX + x, y: plot.midY)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .onChange(of: data.id) { _, _ in selectedIndex = nil }
    }
}
