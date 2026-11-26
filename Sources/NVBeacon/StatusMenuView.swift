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
    var onOpenHistory: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// The same view fills the popover and the monitor window.
    var presentation: MonitorDisplayMode = .popover
    @State private var expandedGPUIds: Set<String> = []

    private var snapshotGPUIds: [String] {
        store.serverStates.flatMap { state in
            state.snapshot?.gpus.map { scopedGPUKey(serverID: state.id, gpuID: $0.id) } ?? []
        }
    }

    private var language: AppInterfaceLanguage {
        store.settings.resolvedLanguage
    }

    private func t(_ english: String, _ korean: String, _ simplifiedChinese: String) -> String {
        language.text(english, korean, simplifiedChinese)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                headerStrip

                if store.serverStates.isEmpty {
                    emptyState
                } else {
                    serverList
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
        .scrollIndicators(.automatic)
        .frame(
            minWidth: presentation == .window ? CGFloat(AppSettings.popoverWidthRange.lowerBound) : nil,
            idealWidth: CGFloat(store.settings.resolvedPopoverWidth),
            maxWidth: presentation == .window ? .infinity : CGFloat(store.settings.resolvedPopoverWidth),
            maxHeight: presentation == .window ? .infinity : nil,
            alignment: .top
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: expandedGPUIds)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: store.collapsedHostServerIDs)
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: store.collapsedServerIDs)
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
                    headerTitle,
                    systemImage: "server.rack"
                )
                .font(.headline)

                Spacer()

                // Left of the buttons, so showing it takes space from the spacer
                // instead of pushing the buttons sideways.
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }

                if store.settings.recordsGPUHistory {
                    Button(action: onOpenHistory) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .help(t("Open GPU history", "GPU 기록 열기", "打开 GPU 使用记录"))
                }

                if store.settings.isConfigured {
                    Button {
                        store.refreshNow()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .help(t("Refresh now and restart polling if needed", "필요하면 polling을 다시 시작하면서 새로고침", "立即刷新，必要时重新开始监控"))
                }

                displayModeButtons

                headerIconButton("gearshape", help: t("Settings", "설정", "设置"), action: onOpenSettings)
            }

            if store.totalGPUCount > 0 {
                HStack(spacing: 6) {
                    SummaryPill(title: t("Avg", "평균", "平均"), value: "\(store.fleetAverageUtilization)%")
                    SummaryPill(title: t("Busy", "사용중", "使用中"), value: "\(store.fleetBusyCount)/\(store.totalGPUCount)")
                    SummaryPill(title: t("Proc", "프로세스", "进程"), value: "\(store.totalProcessCount)")
                    if let oldestSnapshotDate = store.oldestSnapshotDate {
                        UpdatedPill(date: oldestSnapshotDate, language: language)
                    }
                }
            } else {
                Text(headerEmptyStateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.shouldHighlightMyProcesses, store.configuredServerCount == 1, let detectedSSHUsername = store.detectedSSHUsername {
                Label(
                    t("My processes: \(detectedSSHUsername)", "내 프로세스: \(detectedSSHUsername)", "我的进程：\(detectedSSHUsername)"),
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

    @ViewBuilder
    private var displayModeButtons: some View {
        switch presentation {
        case .popover:
            headerIconButton("macwindow", help: t("Show as Window", "창으로 보기", "显示为窗口")) {
                store.setDisplayMode(.window)
            }
        case .window:
            let pinned = store.settings.keepsWindowOnTop
            headerIconButton(pinned ? "pin.fill" : "pin", help: pinned
                ? t("Stop keeping the window on top", "항상 위에 표시 끄기", "取消窗口置顶")
                : t("Keep Window on Top", "항상 위에 표시", "窗口置顶"), tint: pinned ? .accentColor : .primary) {
                store.setKeepsWindowOnTop(!pinned)
            }
            .accessibilityAddTraits(pinned ? .isSelected : [])

            headerIconButton("menubar.arrow.up.rectangle", help: t("Show as Popover", "팝오버로 보기", "显示为弹出面板")) {
                store.setDisplayMode(.popover)
            }
        }
    }

    private func headerIconButton(_ systemImage: String, help: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .help(help)
        .accessibilityLabel(help)
    }

    private var headerTitle: String {
        guard store.settings.isConfigured else {
            return t("No server configured", "서버 미설정", "尚未配置服务器")
        }

        if store.configuredServerCount == 1, let server = store.serverStates.first?.server {
            return server.displayName
        }

        return t("\(store.pollableServerCount)/\(store.configuredServerCount) servers", "\(store.pollableServerCount)/\(store.configuredServerCount) 서버", "\(store.pollableServerCount)/\(store.configuredServerCount) 台服务器")
    }

    private var headerEmptyStateText: String {
        if !store.settings.isConfigured {
            return t("Open Settings with the gear button to configure a server.", "톱니바퀴 버튼으로 설정을 열어 서버를 추가하세요.", "点击齿轮打开设置，添加服务器。")
        }

        if store.pollableServerCount == 0 {
            return t("No enabled server is ready for polling.", "Polling할 활성 서버가 없습니다.", "没有可监控的已启用服务器。")
        }

        return t("Waiting for the first polling result.", "첫 polling 결과를 기다리는 중입니다.", "正在等待首次采集结果。")
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.serverStates) { state in
                serverSection(state)
            }
        }
    }

    private func serverToggleHelp(_ state: ServerRuntimeState) -> String {
        let action = store.isServerExpanded(for: state.id)
            ? t("Collapse this server", "이 서버 접기", "收起此服务器")
            : t("Expand this server", "이 서버 펼치기", "展开此服务器")
        guard let takenAt = state.snapshot?.takenAt else { return action }
        let time = takenAt.formatted(date: .omitted, time: .standard)
        return action + "\n" + t("Last update: \(time)", "마지막 업데이트: \(time)", "上次更新：\(time)")
    }

    /// Shown only when a server has missed refreshes, so a growing "Updated" value
    /// in the summary points to the server behind it.
    @ViewBuilder
    private func staleDataLabel(_ state: ServerRuntimeState) -> some View {
        // Re-evaluated whenever the popover redraws, which happens on every refresh
        // attempt of any server; the age inside keeps ticking on its own.
        if state.server.isEnabled, let takenAt = state.snapshot?.takenAt,
           NVBeaconStore.isSnapshotStale(takenAt: takenAt, pollIntervalSeconds: store.settings.pollIntervalSeconds) {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                let age = Self.ageText(context.date.timeIntervalSince(takenAt), language: language)
                Label(t("Last update \(age) ago", "마지막 업데이트 \(age) 전", "\(age)前更新"), systemImage: "clock.badge.exclamationmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help(state.lastErrorMessage ?? "")
            }
        }
    }

    nonisolated static func ageText(_ seconds: TimeInterval, language: AppInterfaceLanguage) -> String {
        let seconds = max(Int(seconds), 0)
        if seconds < 60 { return language.text("\(seconds)s", "\(seconds)초", "\(seconds) 秒") }
        if seconds < 3_600 { return language.text("\(seconds / 60)m", "\(seconds / 60)분", "\(seconds / 60) 分钟") }
        return language.text("\(seconds / 3_600)h \(seconds % 3_600 / 60)m", "\(seconds / 3_600)시간 \(seconds % 3_600 / 60)분", "\(seconds / 3_600) 小时 \(seconds % 3_600 / 60) 分钟")
    }

    private func serverSection(_ state: ServerRuntimeState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    store.setServerExpanded(!store.isServerExpanded(for: state.id), for: state.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(store.isServerExpanded(for: state.id) ? 90 : 0))
                        Label(state.server.displayName, systemImage: state.server.isEnabled ? "server.rack" : "pause.circle")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(serverToggleHelp(state))
                .accessibilityValue(store.isServerExpanded(for: state.id) ? t("Expanded", "펼침", "已展开") : t("Collapsed", "접힘", "已收起"))

                if !state.server.isEnabled {
                    Text(t("Disabled", "비활성", "已停用"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )
                }

                Spacer(minLength: 8)

                if state.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }

                if !store.isServerExpanded(for: state.id) {
                    if let snapshot = state.snapshot {
                        Text("GPU \(snapshot.busyCount(using: store.settings))/\(snapshot.gpus.count) · \(snapshot.averageUtilization)%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if state.server.isEnabled, let error = state.lastErrorMessage {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(error)
                    }
                }

                if state.server.isPollable {
                    Button {
                        store.refreshNow(serverID: state.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .help(t("Refresh this server now", "이 서버를 지금 새로고침", "立即刷新此服务器"))
                }
            }

            staleDataLabel(state)

            if store.isServerExpanded(for: state.id) {
                serverDetails(state)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func serverDetails(_ state: ServerRuntimeState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot = state.snapshot {
                HStack(spacing: 6) {
                    SummaryPill(title: t("Avg", "평균", "平均"), value: "\(snapshot.averageUtilization)%")
                    SummaryPill(title: t("Busy", "사용중", "使用中"), value: "\(snapshot.busyCount(using: store.settings))/\(snapshot.gpus.count)")
                    SummaryPill(title: t("Proc", "프로세스", "进程"), value: "\(snapshot.totalProcessCount)")
                    UpdatedPill(date: snapshot.takenAt, language: language)
                }

                if !store.settings.hostMetricsOptions.isEmpty {
                    HostInformationView(
                        snapshot: snapshot,
                        networkUsage: state.networkUsage,
                        options: store.settings.hostMetricsOptions,
                        isExpanded: Binding(
                            get: { store.isHostInfoExpanded(for: state.id) },
                            set: { store.setHostInfoExpanded($0, for: state.id) }
                        ),
                        language: language
                    )
                }

                gpuList(state, snapshot: snapshot)
            } else if state.server.isEnabled {
                Text(state.lastErrorMessage ?? t("Waiting for the first polling result.", "첫 polling 결과를 기다리는 중입니다.", "正在等待首次采集结果。"))
                    .font(.caption)
                    .foregroundStyle(state.lastErrorMessage == nil ? Color.secondary : Color.orange)
            } else {
                Text(t("This server is disabled in Settings.", "이 서버는 Settings에서 비활성화되어 있습니다.", "此服务器已在设置中停用。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if state.snapshot != nil, let lastErrorMessage = state.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if store.shouldHighlightMyProcesses, store.configuredServerCount > 1, let detectedSSHUsername = state.detectedSSHUsername {
                Label(
                    t("My processes: \(detectedSSHUsername)", "내 프로세스: \(detectedSSHUsername)", "我的进程：\(detectedSSHUsername)"),
                    systemImage: "person.crop.circle.badge.checkmark"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
            }
        }
    }

    private func gpuList(_ state: ServerRuntimeState, snapshot: GPUSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot.gpus) { gpu in
                let gpuKey = scopedGPUKey(serverID: state.id, gpuID: gpu.id)
                let isExpanded = expandedGPUIds.contains(gpuKey)
                let isLoadingDetails = store.isLoadingProcessDetails(for: gpu.id, on: state.id)
                GPUListRow(
                    gpu: gpu,
                    language: language,
                    isExpanded: isExpanded,
                    isLoadingDetails: isLoadingDetails,
                    hasCurrentUserProcess: store.hasCurrentUserProcess(on: gpu, on: state.id),
                    isWatchingIdle: store.isWatchingIdle(for: gpu, on: state.id),
                    isWatchingProcessExit: { process in
                        store.isWatchingExit(for: process, on: state.id)
                    },
                    isCurrentUserProcess: { process in
                        store.isCurrentUserProcess(process, on: state.id)
                    },
                    toggleIdleWatch: {
                        store.toggleIdleWatch(for: gpu, serverID: state.id)
                    },
                    toggleProcessExitWatch: { process in
                        store.toggleExitWatch(for: process, on: gpu, serverID: state.id)
                    },
                    toggleExpansion: {
                        let willExpand = !expandedGPUIds.contains(gpuKey)
                        toggleExpansion(for: gpuKey)

                        if willExpand {
                            store.loadProcessDetails(for: gpu.id, on: state.id)
                        }
                    }
                )
            }
        }
    }

    private var emptyState: some View {
        Text(t("No GPU data is available yet.", "표시할 GPU 데이터가 아직 없습니다.", "暂无 GPU 数据。"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    private func toggleExpansion(for gpuKey: String) {
        if expandedGPUIds.contains(gpuKey) {
            expandedGPUIds.remove(gpuKey)
        } else {
            expandedGPUIds.insert(gpuKey)
        }
    }

    private func scopedGPUKey(serverID: String, gpuID: Int) -> String {
        "\(serverID):\(gpuID)"
    }

    private var watchSummaryText: String {
        let processCount = store.watchedProcessCount
        let idleCount = store.watchedIdleGPUCount
        var parts = [String]()

        if processCount > 0 {
            parts.append(t("\(processCount) process exit", "\(processCount)개 프로세스 종료", "\(processCount) 个进程退出"))
        }

        if idleCount > 0 {
            parts.append(t("\(idleCount) GPU idle", "\(idleCount)개 GPU idle", "\(idleCount) 块 GPU 空闲"))
        }

        return t("Watching ", "감시 중: ", "正在监视：") + parts.joined(separator: " · ")
    }
}

private struct GPUListRow: View {
    let gpu: GPUReading
    let language: AppInterfaceLanguage
    let isExpanded: Bool
    let isLoadingDetails: Bool
    let hasCurrentUserProcess: Bool
    let isWatchingIdle: Bool
    let isWatchingProcessExit: (GPUProcessReading) -> Bool
    let isCurrentUserProcess: (GPUProcessReading) -> Bool
    let toggleIdleWatch: () -> Void
    let toggleProcessExitWatch: (GPUProcessReading) -> Void
    let toggleExpansion: () -> Void

    private func t(_ english: String, _ korean: String, _ simplifiedChinese: String) -> String {
        language.text(english, korean, simplifiedChinese)
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
                .help(isWatchingIdle ? t("Disable GPU idle alert", "GPU idle 알림 해제", "关闭 GPU 空闲通知") : t("Enable GPU idle alert", "GPU idle 알림 받기", "开启 GPU 空闲通知"))

                Button(action: toggleExpansion) {
                    GPUCardSummary(gpu: gpu, mine: hasCurrentUserProcess, badge: Text(t("Mine", "내 프로세스", "我的进程")),
                                   expanded: isExpanded, expandable: true, language: language)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isWatchingIdle {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 26, height: 1)

                    Label(t("Idle notification armed", "Idle 알림 설정됨", "已开启空闲通知"), systemImage: "star.fill")
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

                            Text(t("Loading process details...", "프로세스 상세를 불러오는 중...", "正在加载进程详情…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if gpu.processes.isEmpty {
                        Text(t("There are no active compute processes reported on this GPU.", "이 GPU에서 보고된 active compute process가 없습니다.", "此 GPU 暂无运行中的计算进程。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(gpu.processes) { process in
                            ProcessRow(
                                process: process,
                                language: language,
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
        .gpuCardSurface(mine: hasCurrentUserProcess, expanded: isExpanded)
    }
}

private func memoryTint(ratio: Double) -> Color {
    if ratio >= 0.95 { return .red }
    if ratio >= 0.85 { return .orange }
    return Color(red: 0.12, green: 0.54, blue: 0.94)
}

private func memoryUsageNotice(ratio: Double, language: AppInterfaceLanguage) -> String {
    if ratio >= 0.95 { return language.text(" · Very high usage", " · 매우 높은 사용량", " · 使用率过高") }
    if ratio >= 0.85 { return language.text(" · High usage", " · 높은 사용량", " · 使用率较高") }
    return ""
}

private struct HostInformationView: View {
    let snapshot: GPUSnapshot
    let networkUsage: NetworkUsage?
    let options: HostMetricsOptions
    @Binding var isExpanded: Bool
    let language: AppInterfaceLanguage

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if options.cpu {
                    HostCPUView(cpu: snapshot.hostCPU, isMeasuring: snapshot.hostCPUSample != nil, language: language)
                }
                if options.memory {
                    if options.cpu { Divider() }
                    HostMemoryView(memory: snapshot.hostMemory, language: language)
                }
                if options.network {
                    if options.cpu || options.memory { Divider() }
                    if let networkUsage {
                        NetworkUsageRow(usage: networkUsage, language: language)
                    } else {
                        Text(language.text("Network: Unavailable", "네트워크: 확인 불가", "网络不可用"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(language.text("Host Information", "호스트 정보", "主机信息"), systemImage: "desktopcomputer")
                .font(.caption.weight(.semibold))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

private struct HostCPUView: View {
    let cpu: Int?
    let isMeasuring: Bool
    let language: AppInterfaceLanguage

    var body: some View {
        if let cpu {
            ThinMetricBar(title: "CPU", valueText: "\(cpu)%", ratio: Double(cpu) / 100, tint: .orange)
        } else {
            Text(isMeasuring
                 ? language.text("CPU: Measuring…", "CPU: 측정 중…", "CPU 正在测量…")
                 : language.text("CPU: Unavailable", "CPU: 확인 불가", "CPU 数据不可用"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct HostMemoryView: View {
    let memory: HostMemoryReading?
    let language: AppInterfaceLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let memory {
                ThinMetricBar(
                    title: language.text("RAM", "RAM", "内存"),
                    valueText: "\(memory.usagePercent)% · \(HostMemoryReading.capacityText(kibibytes: memory.usedKiB)) / \(HostMemoryReading.capacityText(kibibytes: memory.totalKiB))",
                    ratio: memory.usageRatio,
                    tint: memoryTint(ratio: memory.usageRatio)
                )
                .help(language.text("Available: ", "사용 가능: ", "可用：") + HostMemoryReading.capacityText(kibibytes: memory.availableKiB) + memoryUsageNotice(ratio: memory.usageRatio, language: language))

                if let swapTotal = memory.swapTotalKiB, let swapUsed = memory.swapUsedKiB, let swapRatio = memory.swapUsageRatio {
                    if swapTotal > 0 {
                        ThinMetricBar(
                            title: language.text("Swap", "Swap", "交换空间"),
                            valueText: "\(HostMemoryReading.capacityText(kibibytes: swapUsed)) / \(HostMemoryReading.capacityText(kibibytes: swapTotal))",
                            ratio: swapRatio,
                            tint: memoryTint(ratio: swapRatio)
                        )
                    }
                } else {
                    Text(language.text("Swap: Unavailable", "Swap: 확인 불가", "交换空间数据不可用"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(language.text("RAM / Swap: Unavailable", "RAM / Swap: 확인 불가", "内存和交换空间数据不可用"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NetworkUsageRow: View {
    let usage: NetworkUsage
    let language: AppInterfaceLanguage

    private func t(_ english: String, _ korean: String, _ simplifiedChinese: String) -> String {
        language.text(english, korean, simplifiedChinese)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Label(t("Network", "네트워크", "网络"), systemImage: "network")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                NetworkRateLabel(
                    systemImage: "arrow.down",
                    value: NetworkUsageFormatter.rateText(usage.receivedBytesPerSecond),
                    tint: Color(red: 0.12, green: 0.54, blue: 0.94)
                )
                NetworkRateLabel(
                    systemImage: "arrow.up",
                    value: NetworkUsageFormatter.rateText(usage.transmittedBytesPerSecond),
                    tint: Color(red: 0.93, green: 0.45, blue: 0.15)
                )
            }

            Text("\(t("Total since boot", "부팅 후 누적", "开机以来累计")) \(usage.totalSummary)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(helpText)
    }

    private var helpText: String {
        var lines = [String]()

        if usage.interfaceNames.isEmpty {
            lines.append(t("The server did not report any network interface.", "서버에서 네트워크 인터페이스 정보를 가져오지 못했습니다.", "服务器未返回网络接口信息。"))
        } else {
            lines.append("\(t("Interfaces", "인터페이스", "网络接口")): \(usage.interfaceNames.joined(separator: ", "))")
        }

        lines.append("\(t("Total since boot", "부팅 후 누적", "开机以来累计")): \(usage.totalSummary)")

        if !usage.hasRates {
            lines.append(t("The transfer rate is measured from the next refresh on.", "전송 속도는 다음 새로고침부터 표시됩니다.", "传输速率从下次刷新起显示。"))
        }

        return lines.joined(separator: "\n")
    }
}

private struct NetworkRateLabel: View {
    let systemImage: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)

            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
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
            SummaryPill(title: language.text("Updated", "업데이트", "更新"), value: relativeText(referenceDate: context.date))
                .help(language.text(
                    "Oldest data shown: \(date.formatted(date: .omitted, time: .standard))",
                    "가장 오래된 데이터: \(date.formatted(date: .omitted, time: .standard))",
                    "最早一条数据的时间：\(date.formatted(date: .omitted, time: .standard))"
                ))
        }
    }

    private func relativeText(referenceDate: Date) -> String {
        let seconds = max(Int(referenceDate.timeIntervalSince(date)), 0)

        if seconds < 60 {
            return language.text("\(seconds)s", "\(seconds)s", "\(seconds) 秒")
        }

        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return language.text("\(minutes)m \(remainingSeconds)s", "\(minutes)m \(remainingSeconds)s", "\(minutes) 分 \(remainingSeconds) 秒")
    }
}

private struct ProcessRow: View {
    let process: GPUProcessReading
    let language: AppInterfaceLanguage
    let isCurrentUserProcess: Bool
    let isWatched: Bool
    let toggleWatch: () -> Void
    private let userColumnWidth: CGFloat = 52

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
                            Text(language.text("Mine", "내 프로세스", "我的进程"))
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

                        Text(isWatched ? language.text("Watching", "감시 중", "监视中") : language.text("Notify", "알림", "通知"))
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
                .help(isWatched ? language.text("Disable process exit alert", "프로세스 종료 알림 해제", "关闭进程退出通知") : language.text("Enable process exit alert", "프로세스 종료 알림 받기", "开启进程退出通知"))
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
