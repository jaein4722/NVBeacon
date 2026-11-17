import SwiftUI
import NVBeaconCore
import NVBeaconMobile

struct ServerDetailDisclosure {
    var gpus: Set<Int> = []
    var processes: Set<GPUProcessReading.ID> = []
}

struct ServerDetailView: View {
    @Bindable var store: MobileStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    let serverID: UUID
    @Binding var disclosure: ServerDetailDisclosure
    let edit: (MobileServer) -> Void
    @State private var trustPresented = false
    @AppStorage("hostMetricsExpanded") private var hostMetricsExpanded = false

    private var server: MobileServer? { store.servers.first { $0.id == serverID } }
    private var reading: ServerReading? { store.readings[serverID] }

    var body: some View {
        Group {
            if let server {
                detailContent(server)
                .navigationTitle(server.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .background(Color(uiColor: .systemGroupedBackground))
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if server.isEnabled {
                            Button("Refresh this server", systemImage: "arrow.clockwise") {
                                Task { await store.refresh(serverID: server.id) }
                            }
                            .disabled(store.refreshingServerIDs.contains(server.id))
                        }
                        Button("Edit", systemImage: "slider.horizontal.3") { edit(server) }
                    }
                }
                .sheet(isPresented: $trustPresented) {
                    HostTrustView(store: store, server: server, reading: reading)
                }
            }
        }
    }

    @ViewBuilder private func detailContent(_ server: MobileServer) -> some View {
        if #available(iOS 27.1, *), let snapshot = reading?.snapshot {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                if geometry.reservedRegions(kind: .division).contains(where: { region in
                    bounds.contains(CGPoint(x: region.frame.midX, y: region.frame.midY))
                }) {
                    ArrangementView {
                        detailScroll { overview(server) }
                    } secondary: {
                        detailScroll { gpuList(snapshot, server: server) }
                    }
                    .arrangementViewStyle(.split)
                } else {
                    fullDetail(server)
                }
            }
        } else {
            fullDetail(server)
        }
    }

    private func fullDetail(_ server: MobileServer) -> some View {
        detailScroll {
            overview(server)
            if let snapshot = reading?.snapshot { gpuList(snapshot, server: server) }
        }
    }

    private func detailScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, content: content)
        }
        .contentMargins(.top, 8, for: .scrollContent)
        .contentMargins(.horizontal, 12, for: .scrollContent)
        .refreshable { await store.refresh(serverID: serverID) }
    }

    @ViewBuilder private func overview(_ server: MobileServer) -> some View {
        if !server.isEnabled {
            Label("Monitoring is disabled. Edit this server to enable it.", systemImage: "pause.circle")
                .detailPanel()
        }
        if let issue = server.transferSetupIssue {
            Text("Mac Transfer").detailSectionTitle()
            Text(LocalizedStringKey(issue)).detailPanel()
        }
        if let error = reading?.error {
            Text("Connection needs attention").detailSectionTitle()
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    // Server output can contain anything, including Markdown links: never interpret it.
                    if reading?.errorIncludesRemoteOutput == true { Text(verbatim: error) } else { Text(LocalizedStringKey(error)) }
                } icon: { Image(systemName: "exclamationmark.triangle") }
                .foregroundStyle(.orange)
                if reading?.hostKey != nil {
                    Button("Verify Host Key", systemImage: "lock.shield") { trustPresented = true }
                } else if let fingerprint = reading?.fingerprint {
                    Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                }
            }.detailPanel()
        }
        if let snapshot = reading?.snapshot {
            MonitorSummaryGrid {
                MonitorSummaryTile("Average GPU", Text("\(snapshot.averageUtilization)%"))
                MonitorSummaryTile("Busy", Text("\(snapshot.gpus.filter { store.isBusy($0) }.count)/\(snapshot.gpus.count)"))
                MonitorSummaryTile("Processes", Text("\(snapshot.totalProcessCount)"))
                MonitorUpdatedTile(date: snapshot.takenAt)
            }
            if sizeClass == .regular, let samples = reading?.history, let last = samples.last {
                ServerLoadTrends(current: last, samples: samples)
            }
            if store.collectsCPU || store.collectsMemory || store.collectsNetwork {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        hostMetricsExpanded.toggle()
                    } label: {
                        HStack {
                            Text("Host information").font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: hostMetricsExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.bold()).foregroundStyle(.secondary)
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(hostMetricsExpanded ? Text("Expanded") : Text("Collapsed"))
                    if hostMetricsExpanded {
                        Divider()
                        hostMetrics(snapshot).padding(.top, 10).padding(.bottom, 12)
                    }
                }
                .detailPanel(verticalPadding: 0)
            }
        } else if server.isEnabled, reading?.error == nil {
            HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) }.detailPanel()
        }
    }

    @ViewBuilder private func gpuList(_ snapshot: GPUSnapshot, server: MobileServer) -> some View {
        Text("GPUs").detailSectionTitle()
        let column = typeSize.isAccessibilitySize ? GridItem.Size.flexible() : .adaptive(minimum: 260)
        LazyVGrid(columns: [GridItem(column, spacing: 10, alignment: .top)], spacing: 10) {
            ForEach(snapshot.gpus) { gpu in
                gpuRow(gpu, server: server, uid: snapshot.sshUserID)
            }
        }
    }

    private func gpuRow(_ gpu: GPUReading, server: MobileServer, uid: Int?) -> some View {
        let mine = gpu.processes.contains { store.isMine($0, on: server) }
        let expanded = disclosure.gpus.contains(gpu.index)
        let summary = GPUCardSummary(gpu: gpu, mine: mine, badge: Text("My processes"), expanded: expanded, expandable: true)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                if expanded { disclosure.gpus.remove(gpu.index) } else { disclosure.gpus.insert(gpu.index) }
            } label: {
                summary.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            if expanded {
                Divider()
                if gpu.processes.isEmpty {
                    Text("No active GPU processes").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(gpu.processes) { process in
                            MobileProcessRow(process: process, mine: store.isMine(process, on: server),
                                             login: server.username, loginID: uid,
                                             expanded: disclosure.processes.contains(process.id)) {
                                if !disclosure.processes.insert(process.id).inserted {
                                    disclosure.processes.remove(process.id)
                                }
                            }
                        }
                    }
                }
            }
        }
        .gpuCardSurface(mine: mine, expanded: expanded)
    }

    @ViewBuilder private func hostMetrics(_ snapshot: GPUSnapshot) -> some View {
        // One list cell: native List row insets aren't repeated for every metric.
        VStack(alignment: .leading, spacing: 10) {
            if store.collectsCPU {
                if let cpu = snapshot.hostCPU {
                    MonitorGauge(title: "CPU", value: cpu, color: .orange)
                } else { LabeledContent("CPU") { Text(snapshot.hostCPUSample == nil ? "Unavailable" : "Measuring…") } }
            }
            if store.collectsMemory {
                if let mem = snapshot.hostMemory {
                    MonitorGauge(title: "RAM", value: mem.usagePercent, color: MonitorInk.memoryTint(mem.usageRatio),
                                 detail: "\(mem.usagePercent)% · \(capacity(mem.usedKiB)) / \(capacity(mem.totalKiB))")
                    if let total = mem.swapTotalKiB, total > 0, let used = mem.swapUsedKiB, let ratio = mem.swapUsageRatio {
                        MonitorGauge(title: "Swap", value: Int((ratio * 100).rounded()), color: MonitorInk.memoryTint(ratio),
                                     detail: "\(capacity(used)) / \(capacity(total))")
                    } else if mem.swapTotalKiB == nil { LabeledContent("Swap") { Text("Unavailable") } }
                } else { LabeledContent("RAM") { Text("Unavailable") } }
            }
            if store.collectsNetwork {
                if let usage = reading?.networkUsage {
                    NetworkRateSummary(usage: usage)
                    LabeledContent("Total traffic", value: usage.totalSummary).foregroundStyle(.secondary)
                } else { LabeledContent("Network") { Text("Unavailable") } }
            }
        }.font(.caption).monospacedDigit()
    }

    private func capacity(_ kib: Int) -> String { HostMemoryReading.capacityText(kibibytes: kib) }


}

private extension View {
    func detailPanel(verticalPadding: CGFloat = 10) -> some View {
        padding(.horizontal, 12).padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func detailSectionTitle() -> some View {
        font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.leading, 8).padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct MobileProcessRow: View {
    let process: GPUProcessReading
    let mine: Bool
    let login: String
    let loginID: Int?
    let expanded: Bool
    let toggle: () -> Void

    private var owner: Text {
        if let name = process.user, !name.isEmpty, name != "--" { return Text(verbatim: name) }
        if let id = process.userID { return Text(verbatim: id == loginID ? login : "UID \(id)") }
        return Text("Unknown owner")
    }

    private var title: String {
        guard process.processName.hasPrefix("/") else { return process.displayProcessName }
        return (process.processName as NSString).lastPathComponent
    }

    private var details: [String] {
        let path = process.displayProcessName
        let command = process.commandSummary
        return [path != title ? path : "", command != path ? command : ""].filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if details.isEmpty {
                summary
            } else {
                Button {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction, toggle)
                } label: {
                    summary
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
                if expanded {
                    ForEach(details, id: \.self) { detail in
                        Text(verbatim: detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .transition(.identity)
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: title).font(.subheadline.weight(.semibold))
                    .lineLimit(expanded || details.isEmpty ? nil : 1)
                Spacer(minLength: 4)
                if !details.isEmpty {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ownerLabel
                    pid
                    Spacer(minLength: 2)
                    memory
                }
                VStack(alignment: .leading, spacing: 4) {
                    ownerLabel
                    pid
                    memory
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var ownerLabel: some View {
        Label { owner.fontWeight(.medium) } icon: { Image(systemName: mine ? "person.fill" : "person") }
            .foregroundStyle(mine ? Color.green : .secondary)
    }

    private var pid: some View { Text(verbatim: "PID \(process.pid)") }

    private var memory: some View {
        let size = GPUCapacityText.format(process.usedGPUMemoryMB)
        return Text(verbatim: "VRAM \(size.value) \(size.unit)")
    }
}

struct HostTrustView: View {
    let store: MobileStore
    let server: MobileServer
    let reading: ServerReading?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        Label("Verify this server", systemImage: "lock.shield").font(.headline)
                        Text("Compare this fingerprint with the SSH host key provided by your server administrator before trusting this connection.")
                        LabeledContent("Endpoint", value: server.endpoint)
                        Text(reading?.fingerprint ?? "Unavailable").font(.callout.monospaced()).textSelection(.enabled)
                    }
                    Section {
                        Button("Trust and Connect") {
                            do {
                                if let key = reading?.hostKey { try store.trustHost(for: server, key: key) }
                                dismiss()
                            } catch { store.message = error.localizedDescription; dismiss() }
                        }.disabled(reading?.hostKey == nil)
                    } footer: { Text("The key will be pinned to this address and port. Future key changes will block connections.") }
                }
                .monitorRowInsets()
            }
            .navigationTitle("SSH Host Key")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } } }
        }
    }
}
