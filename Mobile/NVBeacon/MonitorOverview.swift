import Charts
import SwiftUI
import NVBeaconCore
import NVBeaconMobile

/// Only fresh successful readings participate in the fleet summary. A server
/// with a failed poll keeps its timestamped snapshot in its own row.
struct FleetOverview: View {
    let store: MobileStore

    var body: some View {
        let enabled = store.servers.filter(\.isEnabled)
        let snapshots = enabled.compactMap { server -> GPUSnapshot? in
            guard let reading = store.readings[server.id], reading.error == nil else { return nil }
            return reading.snapshot
        }
        let gpus = snapshots.flatMap(\.gpus)
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Fleet overview").font(.headline)
                    Spacer()
                    Text("\(snapshots.count)/\(enabled.count) servers reporting").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("Fleet overview").font(.headline)
                    Text("\(snapshots.count)/\(enabled.count) servers reporting").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !gpus.isEmpty {
                GPUFigures(store: store, gpus: gpus)
            }
        }
        .padding(.vertical, 3)
    }
}

struct GPUFigures: View {
    let store: MobileStore
    let gpus: [GPUReading]

    var body: some View {
        let busy = gpus.filter { store.isBusy($0) }.count
        let average = gpus.isEmpty ? 0 : Int((Double(gpus.reduce(0) { $0 + $1.utilization }) / Double(gpus.count)).rounded())
        let processes = gpus.reduce(0) { $0 + $1.processes.count }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: typeSize.isAccessibilitySize ? 1 : 3), alignment: .leading, spacing: 5) {
            MonitorSummaryTile("Available GPUs", Text(verbatim: "\(gpus.count - busy)/\(gpus.count)"))
            MonitorSummaryTile("Average GPU", Text("\(average)%"))
            MonitorSummaryTile("GPU processes", Text("\(processes)"))
        }
    }

    @Environment(\.dynamicTypeSize) private var typeSize
}

struct MonitorSummaryTile: View {
    let title: LocalizedStringKey
    let value: Text

    init(_ title: LocalizedStringKey, _ value: Text) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            value.font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct ServerMonitorRow: View {
    let store: MobileStore
    let server: MobileServer
    let expanded: Bool
    let showsInlineDetails: Bool
    let toggle: () -> Void
    let open: () -> Void

#if NVBEACON_DESIGN_LAB && targetEnvironment(simulator)
    @AppStorage("monitorLayoutChoice") private var experiment = MonitorExperiment.approved
#endif
    private var reading: ServerReading? { store.readings[server.id] }
    private var canExpand: Bool { showsInlineDetails && server.isEnabled && reading?.snapshot != nil }

    var body: some View {
#if NVBEACON_DESIGN_LAB && targetEnvironment(simulator)
        if experiment == .approved { approvedRow }
        else if experiment != .original {
            DesignLabServerRow(store: store, server: server, experiment: experiment, expanded: canExpand && expanded,
                               toggle: canExpand ? toggle : open, open: open)
        } else { standardRow }
#else
        approvedRow
#endif
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    private var metricLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 10))
    }

    private var approvedRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 2) {
                Button(action: canExpand ? toggle : open) {
                    HStack(spacing: 5) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                        Text(server.displayName).font(.headline).foregroundStyle(Color.primary)
                        Spacer(minLength: 2)
                        if !server.isEnabled { Text("Disabled").font(.caption) }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if canExpand {
                    Button(action: open) {
                        Image(systemName: "info.circle").frame(width: 44, height: 44)
                    }.buttonStyle(.borderless).accessibilityLabel("Server details")
                }
                if server.isEnabled { RefreshServerButton(store: store, id: server.id) }
            }
            if server.isEnabled {
                if reading?.error != nil {
                    Label("Connection needs attention", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                if let snapshot = reading?.snapshot {
                    let current = reading?.history.last ?? GPULoadSample(snapshot)
                    if store.collectsCPU || store.collectsMemory || store.collectsNetwork {
                        compactHostInfo(snapshot)
                    }
                    Button(action: canExpand ? toggle : open) {
                        metricLayout {
                            MonitorGauge(title: "Average GPU", value: current.load, color: MonitorInk.load)
                            MonitorGauge(title: "VRAM", value: current.memory, color: MonitorInk.memory)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { statusLine(snapshot) }
                        VStack(alignment: .leading, spacing: 2) { statusLine(snapshot) }
                    }.font(.caption2).foregroundStyle(.secondary)
                    if canExpand && expanded {
                        Divider()
                        ForEach(snapshot.gpus) { gpu in
                            CompactGPUReading(gpu: gpu,
                                              mine: gpu.processes.contains { store.isMine($0, on: server) })
                        }
                    }
                } else if reading?.error == nil { Text("Waiting for first update…").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(.bottom, 4)
    }

    private func compactHostInfo(_ snapshot: GPUSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if store.collectsCPU || store.collectsMemory {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { hostValues(snapshot) }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 4) { hostValues(snapshot) }
                }
            }
            if store.collectsNetwork { NetworkRateSummary(usage: reading?.networkUsage) }
        }
        .font(.caption).monospacedDigit()
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func hostValues(_ snapshot: GPUSnapshot) -> some View {
        if store.collectsCPU {
            hostValue("CPU", percent: snapshot.hostCPU, color: .orange)
        }
        if store.collectsMemory {
            let memory = snapshot.hostMemory
            hostValue("RAM", percent: memory?.usagePercent, color: MonitorInk.memoryTint(memory?.usageRatio ?? 0))
            if let total = memory?.swapTotalKiB, total > 0, let ratio = memory?.swapUsageRatio {
                hostValue("Swap", percent: Int((ratio * 100).rounded()), color: MonitorInk.memoryTint(ratio))
            }
        }
    }

    private func hostValue(_ name: LocalizedStringKey, percent: Int?, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(.secondary)
            Text(verbatim: percent.map { "\($0)%" } ?? "—")
                .fontWeight(.semibold).foregroundStyle(percent == nil ? .secondary : color)
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private func statusLine(_ s: GPUSnapshot) -> some View {
        Text("\(s.gpus.filter { !store.isBusy($0) }.count)/\(s.gpus.count) available")
        Text("\(s.totalProcessCount) processes")
        if s.gpus.contains(where: { $0.processes.contains { store.isMine($0, on: server) } }) {
            Image(systemName: "person.fill").foregroundStyle(.green).accessibilityLabel("My jobs")
        }
        if reading?.error != nil { Text("Last successful update") }
        Text(s.takenAt, style: .time)
    }

#if NVBEACON_DESIGN_LAB && targetEnvironment(simulator)
    private var standardRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button(action: canExpand ? toggle : open) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: server.isEnabled ? "server.rack" : "pause.circle")
                            Text(server.displayName).font(.headline).foregroundStyle(Color.primary)
                            if showsInlineDetails {
                                Image(systemName: canExpand && expanded ? "chevron.down" : "chevron.right").font(.caption2)
                            }
                        }
                        if server.isEnabled, let snapshot = reading?.snapshot {
                            ViewThatFits(in: .horizontal) {
                                HStack { summary(snapshot) }
                                VStack(alignment: .leading) { summary(snapshot) }
                            }.font(.caption).monospacedDigit()
                        }
                        if !server.isEnabled { Text("Disabled").font(.caption) }
                        else if reading?.error != nil {
                            Label("Connection needs attention", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        } else if reading?.snapshot == nil {
                            Text("Waiting for first update…").font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if server.isEnabled {
                    RefreshServerButton(store: store, id: server.id)
                }
            }
            if canExpand && expanded {
                Divider()
                if server.isEnabled, let snapshot = reading?.snapshot {
                    if store.collectsCPU || store.collectsMemory || store.collectsNetwork {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { hostSummary(snapshot) }
                            VStack(alignment: .leading) { hostSummary(snapshot) }
                        }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    ForEach(snapshot.gpus) { gpu in
                        CompactGPUReading(gpu: gpu,
                                          mine: gpu.processes.contains { store.isMine($0, on: server) })
                    }
                    HStack {
                        Text(reading?.error == nil ? "Updated" : "Last successful update")
                        Text(snapshot.takenAt, style: .time)
                    }.font(.caption2).foregroundStyle(.secondary)
                }
                Button(action: open) {
                    Label("Server details", systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.borderless)
            }
        }.padding(.vertical, 3)
    }

    @ViewBuilder private func hostSummary(_ snapshot: GPUSnapshot) -> some View {
        if store.collectsCPU, let cpu = snapshot.hostCPU { Text("CPU \(cpu)%") }
        if store.collectsMemory, let memory = snapshot.hostMemory { Text("RAM \(memory.usagePercent)%") }
        if store.collectsNetwork, let network = reading?.networkUsage, network.hasRates {
            Text(verbatim: network.rateSummary).accessibilityLabel(Text("Network") + Text(verbatim: " " + network.rateSummary))
        }
    }

    @ViewBuilder private func summary(_ snapshot: GPUSnapshot) -> some View {
        Text("\(snapshot.gpus.filter { store.isBusy($0) }.count)/\(snapshot.gpus.count) busy")
        Text("\(snapshot.averageUtilization)% utilization")
        if snapshot.gpus.contains(where: { $0.processes.contains { store.isMine($0, on: server) } }) {
            Label("My jobs", systemImage: "person.fill").foregroundStyle(.tint)
        }
    }
#endif
}

struct ServerLoadTrends: View {
    let current: GPULoadSample
    let samples: [GPULoadSample]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            trend(title: "Average GPU", value: current.load, key: \.load, color: MonitorInk.load)
            trend(title: "VRAM", value: current.memory, key: \.memory, color: MonitorInk.memory)
        }
    }

    private func trend(title: LocalizedStringKey, value: Int, key: KeyPath<GPULoadSample, Int>, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text("\(value)%").monospacedDigit() }.font(.caption2).foregroundStyle(color)
            Chart(samples) { point in
                AreaMark(x: .value("Time", point.time), y: .value("Percent", point[keyPath: key])).foregroundStyle(color.opacity(0.18))
                LineMark(x: .value("Time", point.time), y: .value("Percent", point[keyPath: key])).foregroundStyle(color)
                if samples.count == 1 {
                    PointMark(x: .value("Time", point.time), y: .value("Percent", value)).foregroundStyle(color)
                }
            }
            .chartYScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 24)
        }
    }
}

struct NetworkRateSummary: View {
    let usage: NetworkUsage?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { Text("Network").foregroundStyle(.secondary); Spacer(minLength: 6); rates.fixedSize() }
            VStack(alignment: .leading, spacing: 3) { Text("Network").foregroundStyle(.secondary); rates }
        }
    }

    @ViewBuilder private var rates: some View {
        if let usage, usage.hasRates {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { directions(usage) }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 2) { directions(usage) }
            }
        } else if usage != nil { Text("Measuring…") }
        else { Text("Unavailable") }
    }

    @ViewBuilder private func directions(_ usage: NetworkUsage) -> some View {
        rate("Download", symbol: "arrow.down", value: usage.receivedBytesPerSecond, color: MonitorInk.memory)
        rate("Upload", symbol: "arrow.up", value: usage.transmittedBytesPerSecond, color: MonitorInk.load)
    }

    private func rate(_ label: LocalizedStringKey, symbol: String, value: Double?, color: Color) -> some View {
        let text = NetworkUsageFormatter.rateText(value)
        return HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(verbatim: text)
        }.accessibilityElement(children: .ignore).accessibilityLabel(Text(label)).accessibilityValue(text)
    }
}

struct RefreshServerButton: View {
    let store: MobileStore
    let id: UUID

    var body: some View {
        let refreshing = store.refreshingServerIDs.contains(id)
        Button {
            Task { await store.refresh(serverID: id) }
        } label: {
            Group {
                if refreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }.frame(width: 44, height: 44)
        }.buttonStyle(.borderless).disabled(refreshing)
            .accessibilityLabel("Refresh this server")
    }
}

struct CompactGPUReading: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let gpu: GPUReading
    let mine: Bool
    var body: some View {
        contents
            .padding(6)
            .background(.green.opacity(mine ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(mine ? .green.opacity(0.26) : .primary.opacity(0.05)) }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("GPU \(gpu.index)").font(.caption.bold())
                Text(gpu.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                if let temperature = gpu.temperatureCelsius { Text("\(temperature)°C").font(.caption2).monospacedDigit() }
                Text("\(gpu.processes.count)p").font(.caption.monospacedDigit())
                    .accessibilityLabel(Text("\(gpu.processes.count) processes"))
                if mine {
                    Text("My processes").font(.caption2.bold()).foregroundStyle(.green)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.green.opacity(0.12), in: Capsule())
                }

            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                MonitorGauge(title: "GPU", value: gpu.utilization, color: MonitorInk.load)
                MonitorGauge(title: "VRAM", value: gpu.memoryUsagePercent, color: MonitorInk.memory)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum MonitorInk {
    static let load = Color(red: 0.93, green: 0.45, blue: 0.15)
    static let memory = Color(red: 0.12, green: 0.54, blue: 0.94)
    static func memoryTint(_ ratio: Double) -> Color { ratio >= 0.95 ? .red : ratio >= 0.85 ? .orange : memory }
}

struct MonitorGauge: View {
    let title: LocalizedStringKey
    let value: Int
    let color: Color
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(minLength: 2); Text(verbatim: detail ?? "\(value)%").monospacedDigit() }.font(.caption2)
            ProgressView(value: Double(min(100, max(0, value))), total: 100)
                .tint(color).accessibilityHidden(true)
        }.accessibilityElement(children: .combine)
    }
}
