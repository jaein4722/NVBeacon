import AppKit
import SwiftUI

private struct StatusMenuContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct StatusMenuView: View {
    @ObservedObject var store: NVBeaconStore
    let onContentHeightChange: (CGFloat) -> Void
    @State private var expandedGPUIds: Set<Int> = []

    private var snapshotGPUIds: [Int] {
        store.snapshot?.gpus.map(\.id) ?? []
    }

    private var language: AppInterfaceLanguage {
        store.settings.resolvedLanguage
    }

    private func t(_ english: String, _ korean: String) -> String {
        language.text(english, korean)
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

                if let noticeMessage = store.noticeMessage, store.settings.isConfigured {
                    Label(noticeMessage, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                if let lastErrorMessage = store.lastErrorMessage, store.settings.isConfigured {
                    Text(lastErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
            .padding(12)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: StatusMenuContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .scrollIndicators(.visible)
        .frame(width: 480, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: expandedGPUIds)
        .onChange(of: snapshotGPUIds) { _, newValue in
            expandedGPUIds.formIntersection(Set(newValue))
        }
        .onPreferenceChange(StatusMenuContentHeightKey.self) { height in
            guard height > 0 else { return }
            onContentHeightChange(height)
        }
    }

    private var headerStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(
                    store.settings.isConfigured ? store.settings.sshTarget : t("No server configured", "서버 미설정"),
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
                    .foregroundStyle(.primary)
                    .help(t("Refresh now and restart polling if needed", "필요하면 polling을 다시 시작하면서 새로고침"))
                }

                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let snapshot = store.snapshot {
                let busyCount = snapshot.busyCount(using: store.settings)
                HStack(spacing: 6) {
                    SummaryPill(title: t("Avg", "평균"), value: "\(snapshot.averageUtilization)%")
                    SummaryPill(title: t("Busy", "사용중"), value: "\(busyCount)/\(snapshot.gpus.count)")
                    SummaryPill(title: t("Proc", "프로세스"), value: "\(snapshot.totalProcessCount)")
                    UpdatedPill(date: snapshot.takenAt, language: language)
                }
            } else {
                Text(store.settings.isConfigured ? t("Waiting for the first polling result.", "첫 polling 결과를 기다리는 중입니다.") : t("Right-click the menu bar item and open Settings to configure a server.", "우클릭 메뉴에서 Settings를 열어 서버를 설정하세요."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(t("Right-click the menu bar item for settings and quit.", "설정과 종료는 메뉴바 아이콘 우클릭으로 열 수 있습니다."))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if store.shouldHighlightMyProcesses, let detectedSSHUsername = store.detectedSSHUsername {
                Label(
                    t("My processes: \(detectedSSHUsername)", "내 프로세스: \(detectedSSHUsername)"),
                    systemImage: "person.crop.circle.badge.checkmark"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
            }

            if store.watchedNotificationCount > 0 {
                Label(
                    watchSummaryText,
                    systemImage: "bell.badge.fill"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
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
                GPUListRow(
                    gpu: gpu,
                    isExpanded: isExpanded,
                    isLoadingDetails: isLoadingDetails,
                    hasCurrentUserProcess: store.hasCurrentUserProcess(on: gpu),
                    isWatchingIdle: store.isWatchingIdle(for: gpu),
                    isWatchingProcessExit: { process in
                        store.isWatchingExit(for: process)
                    },
                    isCurrentUserProcess: { process in
                        store.isCurrentUserProcess(process)
                    },
                    toggleIdleWatch: {
                        store.toggleIdleWatch(for: gpu)
                    },
                    toggleProcessExitWatch: { process in
                        store.toggleExitWatch(for: process, on: gpu)
                    },
                    toggleExpansion: {
                        let willExpand = !expandedGPUIds.contains(gpu.id)
                        toggleExpansion(for: gpu.id)

                        if willExpand {
                            store.loadProcessDetails(for: gpu.id)
                        }
                    }
                )
            }
        }
    }

    private var emptyState: some View {
        Text(t("No GPU data is available yet.", "표시할 GPU 데이터가 아직 없습니다."))
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

    private var watchSummaryText: String {
        let processCount = store.watchedProcessCount
        let idleCount = store.watchedIdleGPUCount
        var parts = [String]()

        if processCount > 0 {
            parts.append(t("\(processCount) process exit", "\(processCount)개 프로세스 종료"))
        }

        if idleCount > 0 {
            parts.append(t("\(idleCount) GPU idle", "\(idleCount)개 GPU idle"))
        }

        return t("Watching ", "감시 중: ") + parts.joined(separator: " · ")
    }
}

private struct GPUListRow: View {
    let gpu: GPUReading
    let isExpanded: Bool
    let isLoadingDetails: Bool
    let hasCurrentUserProcess: Bool
    let isWatchingIdle: Bool
    let isWatchingProcessExit: (GPUProcessReading) -> Bool
    let isCurrentUserProcess: (GPUProcessReading) -> Bool
    let toggleIdleWatch: () -> Void
    let toggleProcessExitWatch: (GPUProcessReading) -> Void
    let toggleExpansion: () -> Void

    private let language = AppLocalizer.currentLanguage()

    private func t(_ english: String, _ korean: String) -> String {
        language.text(english, korean)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Button(action: toggleIdleWatch) {
                    Image(systemName: isWatchingIdle ? "star.fill" : "star")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isWatchingIdle ? Color.yellow : Color.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help(isWatchingIdle ? t("Disable GPU idle alert", "GPU idle 알림 해제") : t("Enable GPU idle alert", "GPU idle 알림 받기"))

                Button(action: toggleExpansion) {
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

                            if hasCurrentUserProcess {
                                Text(t("Mine", "내 프로세스"))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.green.opacity(0.12))
                                    )
                            }

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
                                title: "Memory",
                                valueText: "\(gpu.memoryUsagePercent)% · \(gpu.memoryUsedMB)/\(gpu.memoryTotalMB)MB",
                                ratio: gpu.memoryUsageRatio,
                                tint: Color(red: 0.12, green: 0.54, blue: 0.94)
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isWatchingIdle {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 26, height: 1)

                    Label(t("Idle notification armed", "Idle 알림 설정됨"), systemImage: "star.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.yellow.opacity(0.12))
                        )
                }
            }

            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    if isLoadingDetails {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)

                            Text(t("Loading process details...", "프로세스 상세를 불러오는 중..."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if gpu.processes.isEmpty {
                        Text(t("There are no active compute processes reported on this GPU.", "이 GPU에서 보고된 active compute process가 없습니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(gpu.processes) { process in
                            ProcessRow(
                                process: process,
                                isCurrentUserProcess: isCurrentUserProcess(process),
                                isWatched: isWatchingProcessExit(process),
                                toggleWatch: {
                                    toggleProcessExitWatch(process)
                                }
                            )
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
                .fill((hasCurrentUserProcess ? Color.green : Color(nsColor: .controlBackgroundColor)).opacity(hasCurrentUserProcess ? 0.08 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isExpanded ? Color.orange.opacity(0.42) : (hasCurrentUserProcess ? Color.green.opacity(0.26) : Color.primary.opacity(0.05)),
                    lineWidth: 1
                )
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
    let language: AppInterfaceLanguage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            SummaryPill(title: language.text("Updated", "업데이트"), value: relativeText(referenceDate: context.date))
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
    let isCurrentUserProcess: Bool
    let isWatched: Bool
    let toggleWatch: () -> Void
    private let userColumnWidth: CGFloat = 52
    private let language = AppLocalizer.currentLanguage()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 10) {
                Text(process.userSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isCurrentUserProcess ? .green : .secondary)
                    .lineLimit(1)
                    .frame(width: userColumnWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(process.displayProcessName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if isCurrentUserProcess {
                            Text(language.text("Mine", "내 프로세스"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.green.opacity(0.12))
                                )
                        }
                    }

                    Text("PID \(process.pid)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(process.memorySummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button(action: toggleWatch) {
                    HStack(spacing: 4) {
                        Image(systemName: isWatched ? "bell.fill" : "bell")
                            .font(.system(size: 11, weight: .semibold))

                        Text(isWatched ? language.text("Watching", "감시 중") : language.text("Notify", "알림"))
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(isWatched ? Color.orange : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill((isWatched ? Color.orange : Color.primary).opacity(isWatched ? 0.18 : 0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke((isWatched ? Color.orange : Color.primary).opacity(isWatched ? 0.35 : 0.12), lineWidth: 1)
                    )
                }
                .contentShape(Capsule(style: .continuous))
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.16), value: isWatched)
                .help(isWatched ? language.text("Disable process exit alert", "프로세스 종료 알림 해제") : language.text("Enable process exit alert", "프로세스 종료 알림 받기"))
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
                .fill((isCurrentUserProcess ? Color.green : Color(nsColor: .windowBackgroundColor)).opacity(isCurrentUserProcess ? 0.08 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isCurrentUserProcess ? Color.green.opacity(0.22) : .clear, lineWidth: 1)
        )
    }
}
