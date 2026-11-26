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

    private func t(_ key: String, _ arguments: Any...) -> String {
        language.text(key, arguments: arguments)
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
                    .help(t("Open GPU history"))
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
                    .help(t("Refresh now and restart polling if needed"))
                }

                displayModeButtons

                headerIconButton("gearshape", help: t("Settings"), action: onOpenSettings)
            }

            if store.totalGPUCount > 0 {
                HStack(spacing: 6) {
                    SummaryPill(title: t("Avg"), value: "\(store.fleetAverageUtilization)%")
                    SummaryPill(title: t("Busy"), value: "\(store.fleetBusyCount)/\(store.totalGPUCount)")
                    SummaryPill(title: t("Proc"), value: "\(store.totalProcessCount)")
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
                    t("My processes: %@", detectedSSHUsername),
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
            headerIconButton("macwindow", help: t("Show as Window")) {
                store.setDisplayMode(.window)
            }
        case .window:
            let pinned = store.settings.keepsWindowOnTop
            headerIconButton(pinned ? "pin.fill" : "pin", help: pinned
                ? t("Stop keeping the window on top")
                : t("Keep Window on Top"), tint: pinned ? .accentColor : .primary) {
                store.setKeepsWindowOnTop(!pinned)
            }
            .accessibilityAddTraits(pinned ? .isSelected : [])

            headerIconButton("menubar.arrow.up.rectangle", help: t("Show as Popover")) {
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
            return t("No server configured")
        }

        if store.configuredServerCount == 1, let server = store.serverStates.first?.server {
            return server.displayName
        }

        return t("%@/%@ servers", store.pollableServerCount, store.configuredServerCount)
    }

    private var headerEmptyStateText: String {
        if !store.settings.isConfigured {
            return t("Open Settings with the gear button to configure a server.")
        }

        if store.pollableServerCount == 0 {
            return t("No enabled server is ready for polling.")
        }

        return t("Waiting for the first polling result.")
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
            ? t("Collapse this server")
            : t("Expand this server")
        guard let takenAt = state.snapshot?.takenAt else { return action }
        let time = takenAt.formatted(date: .omitted, time: .standard)
        return action + "\n" + t("Last update: %@", time)
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
                Label(t("Last update %@ ago", age), systemImage: "clock.badge.exclamationmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help(state.lastErrorMessage ?? "")
            }
        }
    }

    nonisolated static func ageText(_ seconds: TimeInterval, language: AppInterfaceLanguage) -> String {
        let seconds = max(Int(seconds), 0)
        if seconds < 60 { return language.text("%@s", seconds) }
        if seconds < 3_600 { return language.text("%@m", seconds / 60) }
        return language.text("%@h %@m", seconds / 3_600, seconds % 3_600 / 60)
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
                .accessibilityValue(store.isServerExpanded(for: state.id) ? t("Expanded") : t("Collapsed"))

                if !state.server.isEnabled {
                    Text(t("Disabled"))
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
                    .help(t("Refresh this server now"))
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
                    SummaryPill(title: t("Avg"), value: "\(snapshot.averageUtilization)%")
                    SummaryPill(title: t("Busy"), value: "\(snapshot.busyCount(using: store.settings))/\(snapshot.gpus.count)")
                    SummaryPill(title: t("Proc"), value: "\(snapshot.totalProcessCount)")
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
                Text(state.lastErrorMessage ?? t("Waiting for the first polling result."))
                    .font(.caption)
                    .foregroundStyle(state.lastErrorMessage == nil ? Color.secondary : Color.orange)
            } else {
                Text(t("This server is disabled in Settings."))
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
                    t("My processes: %@", detectedSSHUsername),
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
        Text(t("No GPU data is available yet."))
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
            parts.append(t("%@ process exit", processCount))
        }

        if idleCount > 0 {
            parts.append(t("%@ GPU idle", idleCount))
        }

        return t("Watching ") + parts.joined(separator: " · ")
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

    private func t(_ key: String, _ arguments: Any...) -> String {
        language.text(key, arguments: arguments)
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
                .help(isWatchingIdle ? t("Disable GPU idle alert") : t("Enable GPU idle alert"))

                Button(action: toggleExpansion) {
                    GPUCardSummary(gpu: gpu, mine: hasCurrentUserProcess, badge: Text(t("Mine")),
                                   expanded: isExpanded, expandable: true, language: language)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isWatchingIdle {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 26, height: 1)

                    Label(t("Idle notification armed"), systemImage: "star.fill")
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

                            Text(t("Loading process details..."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if gpu.processes.isEmpty {
                        Text(t("There are no active compute processes reported on this GPU."))
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
    if ratio >= 0.95 { return language.text(" · Very high usage") }
    if ratio >= 0.85 { return language.text(" · High usage") }
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
                        Text(language.text("Network: Unavailable"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(language.text("Host Information"), systemImage: "desktopcomputer")
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
                 ? language.text("CPU: Measuring…")
                 : language.text("CPU: Unavailable"))
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
                    title: language.text("RAM"),
                    valueText: "\(memory.usagePercent)% · \(HostMemoryReading.capacityText(kibibytes: memory.usedKiB)) / \(HostMemoryReading.capacityText(kibibytes: memory.totalKiB))",
                    ratio: memory.usageRatio,
                    tint: memoryTint(ratio: memory.usageRatio)
                )
                .help(language.text("Available: ") + HostMemoryReading.capacityText(kibibytes: memory.availableKiB) + memoryUsageNotice(ratio: memory.usageRatio, language: language))

                if let swapTotal = memory.swapTotalKiB, let swapUsed = memory.swapUsedKiB, let swapRatio = memory.swapUsageRatio {
                    if swapTotal > 0 {
                        ThinMetricBar(
                            title: language.text("Swap"),
                            valueText: "\(HostMemoryReading.capacityText(kibibytes: swapUsed)) / \(HostMemoryReading.capacityText(kibibytes: swapTotal))",
                            ratio: swapRatio,
                            tint: memoryTint(ratio: swapRatio)
                        )
                    }
                } else {
                    Text(language.text("Swap: Unavailable"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(language.text("RAM / Swap: Unavailable"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct NetworkUsageRow: View {
    let usage: NetworkUsage
    let language: AppInterfaceLanguage

    private func t(_ key: String, _ arguments: Any...) -> String {
        language.text(key, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Label(t("Network"), systemImage: "network")
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

            Text("\(t("Total since boot")) \(usage.totalSummary)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(helpText)
    }

    private var helpText: String {
        var lines = [String]()

        if usage.interfaceNames.isEmpty {
            lines.append(t("The server did not report any network interface."))
        } else {
            lines.append("\(t("Interfaces")): \(usage.interfaceNames.joined(separator: ", "))")
        }

        lines.append("\(t("Total since boot")): \(usage.totalSummary)")

        if !usage.hasRates {
            lines.append(t("The transfer rate is measured from the next refresh on."))
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
            SummaryPill(title: language.text("Updated"), value: relativeText(referenceDate: context.date))
                .help(language.text("Oldest data shown: %@", date.formatted(date: .omitted, time: .standard)))
        }
    }

    private func relativeText(referenceDate: Date) -> String {
        let seconds = max(Int(referenceDate.timeIntervalSince(date)), 0)

        if seconds < 60 {
            return language.text("%@s", seconds)
        }

        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return language.text("%@m %@s", minutes, remainingSeconds)
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
                            Text(language.text("Mine"))
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

                        Text(isWatched ? language.text("Watching") : language.text("Notify"))
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
                .help(isWatched ? language.text("Disable process exit alert") : language.text("Enable process exit alert"))
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
