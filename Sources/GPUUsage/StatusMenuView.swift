import AppKit
import SwiftUI

struct StatusMenuView: View {
    @ObservedObject var store: GPUUsageStore
    @State private var showsSettings = false
    @State private var expandedGPUIds: Set<Int> = []

    private var snapshotGPUIds: [Int] {
        store.snapshot?.gpus.map(\.id) ?? []
    }

    private var preferredWindowHeight: CGFloat {
        let gpuCount = CGFloat(store.snapshot?.gpus.count ?? 1)
        let collapsedCardsHeight = gpuCount * 88
        let expandedCardsHeight = CGFloat(expandedGPUIds.count) * 130
        let settingsHeight = showsSettings ? CGFloat(280) : .zero
        let baseHeight = CGFloat(220)

        return min(900, max(360, baseHeight + collapsedCardsHeight + expandedCardsHeight + settingsHeight))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard

                if let snapshot = store.snapshot {
                    gpuList(snapshot)
                } else {
                    emptyState
                }

                if let lastErrorMessage = store.lastErrorMessage, store.settings.isConfigured {
                    Text(lastErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Divider()

                DisclosureGroup("Connection Settings", isExpanded: $showsSettings) {
                    ConnectionSettingsView(store: store)
                        .padding(.top, 8)
                }

                Divider()

                HStack {
                    Button("Refresh Now") {
                        store.refreshNow()
                    }
                    .disabled(!store.settings.isConfigured || store.isRefreshing)

                    Spacer()

                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .padding(18)
        }
        .scrollIndicators(.visible)
        .frame(width: 500, height: preferredWindowHeight, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: expandedGPUIds)
        .animation(.easeInOut(duration: 0.2), value: showsSettings)
        .onAppear {
            if !store.settings.isConfigured {
                showsSettings = true
            }
        }
        .onChange(of: snapshotGPUIds) { _, newValue in
            expandedGPUIds.formIntersection(Set(newValue))
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(
                        store.settings.isConfigured ? store.settings.sshTarget : "No server configured",
                        systemImage: "server.rack"
                    )
                    .font(.headline)

                    Text("Click any GPU card to inspect active processes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let snapshot = store.snapshot {
                HStack(spacing: 12) {
                    summaryMetric(title: "Average", value: "\(snapshot.averageUtilization)%")
                    summaryMetric(title: "Busy", value: "\(snapshot.busyCount)/\(snapshot.gpus.count)")
                    summaryMetric(title: "Processes", value: "\(snapshot.totalProcessCount)")
                    summaryMetric(title: "Updated", value: store.lastUpdatedRelativeText ?? "now")
                }
            } else {
                Text(store.settings.isConfigured ? "첫 polling 결과를 기다리는 중입니다." : "SSH target를 설정하면 polling을 시작합니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func gpuList(_ snapshot: GPUSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(snapshot.gpus) { gpu in
                let isExpanded = expandedGPUIds.contains(gpu.id)

                Button {
                    toggleExpansion(for: gpu.id)
                } label: {
                    gpuCard(gpu, isExpanded: isExpanded)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func gpuCard(_ gpu: GPUReading, isExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GPU \(gpu.index)")
                        .font(.headline)
                    Text(gpu.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(gpu.utilization)%")
                        .font(.title3.weight(.semibold))
                    Text(gpu.processSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isExpanded ? .orange : .secondary)
                    .padding(.top, 2)
            }

            MetricBar(
                title: "Util",
                valueText: "\(gpu.utilization)%",
                ratio: gpu.utilizationRatio,
                tint: Color(red: 0.93, green: 0.45, blue: 0.15)
            )

            MetricBar(
                title: "Memory",
                valueText: "\(gpu.memoryUsagePercent)%  ·  \(gpu.memorySummary)",
                ratio: gpu.memoryUsageRatio,
                tint: Color(red: 0.12, green: 0.54, blue: 0.94)
            )

            HStack {
                footerPill(label: "Temp", value: gpu.temperatureSummary)
                footerPill(label: "Proc", value: "\(gpu.processes.count)")
            }

            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Active Processes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isExpanded ? Color.orange.opacity(0.45) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        )
    }

    private func footerPill(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var emptyState: some View {
        Text("표시할 GPU 데이터가 아직 없습니다.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func toggleExpansion(for gpuId: Int) {
        if expandedGPUIds.contains(gpuId) {
            expandedGPUIds.remove(gpuId)
        } else {
            expandedGPUIds.insert(gpuId)
        }
    }
}

private struct MetricBar: View {
    let title: String
    let valueText: String
    let ratio: Double
    let tint: Color

    private var clampedRatio: Double {
        min(max(ratio, .zero), 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
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
                            .frame(width: max(10, proxy.size.width * clampedRatio))
                    }
                }
            }
            .frame(height: 8)
        }
    }
}

private struct ProcessRow: View {
    let process: GPUProcessReading

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(process.processName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text("PID \(process.pid)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(process.memorySummary)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }
}

private struct ConnectionSettingsView: View {
    @ObservedObject var store: GPUUsageStore
    @State private var draft = AppSettings()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SSH Target")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("gpu-prod or user@host", text: $draft.sshTarget)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Identity File (Optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("~/.ssh/id_ed25519", text: $draft.sshIdentityFilePath)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("SSH Port (Optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Leave blank to use ~/.ssh/config or port 22", text: $draft.sshPort)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Refresh Interval")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Stepper(value: $draft.pollIntervalSeconds, in: 3...300) {
                    Text("\(draft.pollIntervalSeconds) seconds")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Remote Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(AppSettings.defaultRemoteCommand, text: $draft.remoteCommand)
                    .textFieldStyle(.roundedBorder)
            }

            Text("로컬 Mac의 SSH 키와 ~/.ssh/config를 그대로 사용합니다. `SSH Target`에 alias를 넣으면 config의 포트/유저가 적용되고, 직접 host를 넣을 때만 `SSH Port`를 채우면 됩니다. PATH 문제가 있으면 `nvidia-smi` 대신 전체 경로를 넣으면 됩니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Reset") {
                    draft = store.settings
                }
                .disabled(draft == store.settings)

                Spacer()

                Button("Apply") {
                    store.applySettings(draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == store.settings)
            }
        }
        .onAppear {
            draft = store.settings
        }
    }
}
