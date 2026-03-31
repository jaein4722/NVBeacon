import AppKit
import SwiftUI

struct StatusMenuView: View {
    @ObservedObject var store: GPUUsageStore
    @State private var expandedGPUIds: Set<Int> = []

    private var snapshotGPUIds: [Int] {
        store.snapshot?.gpus.map(\.id) ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                headerStrip

                if let snapshot = store.snapshot {
                    gpuList(snapshot)
                } else {
                    emptyState
                }

                if let lastErrorMessage = store.lastErrorMessage, store.settings.isConfigured {
                    Text(lastErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.visible)
        .frame(width: 480, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: expandedGPUIds)
        .onChange(of: snapshotGPUIds) { _, newValue in
            expandedGPUIds.formIntersection(Set(newValue))
        }
    }

    private var headerStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    store.settings.isConfigured ? store.settings.sshTarget : "No server configured",
                    systemImage: "server.rack"
                )
                .font(.headline)

                Spacer()

                if store.settings.isConfigured {
                    Button {
                        store.refreshNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isRefreshing)
                    .foregroundStyle(store.isRefreshing ? .secondary : .primary)
                    .help("Refresh now")
                }

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let snapshot = store.snapshot {
                HStack(spacing: 6) {
                    SummaryPill(title: "Avg", value: "\(snapshot.averageUtilization)%")
                    SummaryPill(title: "Busy", value: "\(snapshot.busyCount)/\(snapshot.gpus.count)")
                    SummaryPill(title: "Proc", value: "\(snapshot.totalProcessCount)")
                    UpdatedPill(date: snapshot.takenAt)
                }
            } else {
                Text(store.settings.isConfigured ? "첫 polling 결과를 기다리는 중입니다." : "우클릭 메뉴에서 Settings를 열어 서버를 설정하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Right-click the menu bar item for settings and quit.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func gpuList(_ snapshot: GPUSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.gpus) { gpu in
                let isExpanded = expandedGPUIds.contains(gpu.id)
                let isLoadingDetails = store.isLoadingProcessDetails(for: gpu.id)

                Button {
                    let willExpand = !expandedGPUIds.contains(gpu.id)
                    toggleExpansion(for: gpu.id)

                    if willExpand {
                        store.loadProcessDetails(for: gpu.id)
                    }
                } label: {
                    GPUListRow(gpu: gpu, isExpanded: isExpanded, isLoadingDetails: isLoadingDetails)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        Text("표시할 GPU 데이터가 아직 없습니다.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    private func toggleExpansion(for gpuId: Int) {
        if expandedGPUIds.contains(gpuId) {
            expandedGPUIds.remove(gpuId)
        } else {
            expandedGPUIds.insert(gpuId)
        }
    }
}

private struct GPUListRow: View {
    let gpu: GPUReading
    let isExpanded: Bool
    let isLoadingDetails: Bool

    private var cardBackgroundColor: Color {
        if gpu.isIdle {
            return Color(nsColor: .controlBackgroundColor).opacity(0.76)
        }

        return Color(nsColor: .controlBackgroundColor)
    }

    private var cardBorderColor: Color {
        if isExpanded {
            return .orange.opacity(0.42)
        }

        return gpu.isIdle ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("GPU \(gpu.index)")
                    .font(.headline)

                Text(gpu.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(gpu.temperatureSummary) · \(gpu.processes.count)p · \(gpu.utilization)%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()

                Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isExpanded ? .orange : .secondary)
            }

            HStack(spacing: 10) {
                ThinMetricBar(
                    title: "Util",
                    valueText: "\(gpu.utilization)%",
                    ratio: gpu.utilizationRatio,
                    tint: Color(red: 0.93, green: 0.45, blue: 0.15)
                )

                ThinMetricBar(
                    title: "Mem",
                    valueText: "\(gpu.memoryUsagePercent)% · \(gpu.memoryUsedMB)/\(gpu.memoryTotalMB)MB",
                    ratio: gpu.memoryUsageRatio,
                    tint: Color(red: 0.12, green: 0.54, blue: 0.94)
                )
            }

            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    if isLoadingDetails {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)

                            Text("Loading process details...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if gpu.processes.isEmpty {
                        Text("이 GPU에서 보고된 active compute process가 없습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(gpu.processes) { process in
                            ProcessRow(process: process)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(cardBorderColor, lineWidth: 1)
        )
    }
}

private struct SummaryPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private struct UpdatedPill: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            SummaryPill(title: "Updated", value: relativeText(referenceDate: context.date))
                .help(date.formatted(date: .omitted, time: .standard))
        }
    }

    private func relativeText(referenceDate: Date) -> String {
        let seconds = max(Int(referenceDate.timeIntervalSince(date)), 0)

        if seconds < 60 {
            return "\(seconds)s"
        }

        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return "\(minutes)m \(remainingSeconds)s"
    }
}

private struct ThinMetricBar: View {
    let title: String
    let valueText: String
    let ratio: Double
    let tint: Color

    private var clampedRatio: Double {
        min(max(ratio, .zero), 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Text(valueText)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.08))

                    if clampedRatio > 0 {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [tint.opacity(0.72), tint],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(8, proxy.size.width * clampedRatio))
                    }
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProcessRow: View {
    let process: GPUProcessReading
    private let userColumnWidth: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                Text(process.userSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: userColumnWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(process.displayProcessName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("PID \(process.pid)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(process.memorySummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if process.showsSeparateCommandSummary {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: userColumnWidth + 10, height: 1)

                    Text(process.commandSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }
}
