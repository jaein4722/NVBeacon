import SwiftUI
import NVBeaconCore
import NVBeaconMobile

struct ServerDetailView: View {
    @Bindable var store: MobileStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    let serverID: UUID
    let edit: (MobileServer) -> Void
    @State private var expandedGPUs: Set<Int> = []
    @State private var trustPresented = false
    @AppStorage("hostMetricsExpanded") private var hostMetricsExpanded = false

    private var server: MobileServer? { store.servers.first { $0.id == serverID } }
    private var reading: ServerReading? { store.readings[serverID] }

    var body: some View {
        Group {
            if let server {
                List {
                    if !server.isEnabled {
                        Section { Label("Monitoring is disabled. Edit this server to enable it.", systemImage: "pause.circle") }
                    }
                    if let issue = server.transferSetupIssue {
                        Section("Mac Transfer") { Text(LocalizedStringKey(issue)) }
                    }
                    if let error = reading?.error {
                        Section {
                            Label(LocalizedStringKey(error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            if reading?.hostKey != nil {
                                Button("Verify Host Key", systemImage: "lock.shield") { trustPresented = true }
                            } else if let fingerprint = reading?.fingerprint {
                                Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        } header: { Text("Connection needs attention") }
                    }
                    if let snapshot = reading?.snapshot {
                        Section {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5),
                                                     count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 5) {
                                MonitorSummaryTile("Average GPU", Text("\(snapshot.averageUtilization)%"))
                                MonitorSummaryTile("Busy", Text("\(snapshot.gpus.filter { store.isBusy($0) }.count)/\(snapshot.gpus.count)"))
                                MonitorSummaryTile("Processes", Text("\(snapshot.totalProcessCount)"))
                                TimelineView(.periodic(from: .now, by: 1)) { tick in
                                    let age = max(0, Int(tick.date.timeIntervalSince(snapshot.takenAt)))
                                    MonitorSummaryTile("Updated", Text(verbatim: age < 60 ? "\(age)s" : "\(age / 60)m \(age % 60)s"))
                                }
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            if sizeClass == .regular, let samples = reading?.history, let last = samples.last {
                                ServerLoadTrends(current: last, samples: samples)
                            }
                        }
                        if store.collectsCPU || store.collectsMemory || store.collectsNetwork {
                            Section {
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
                                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                            }
                        }
                        Section("GPUs") {
                            ForEach(snapshot.gpus) { gpu in
                                gpuRow(gpu, server: server, uid: snapshot.sshUserID)
                            }
                        }
                    } else if server.isEnabled, reading?.error == nil {
                        Section { HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) } }
                    }
                }
                .refreshable { await store.refresh(serverID: server.id) }
                .navigationTitle(server.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .contentMargins(.top, 8, for: .scrollContent)
                .contentMargins(.horizontal, 12, for: .scrollContent)
                .listSectionSpacing(10)
                .toolbar {
                    if server.isEnabled { RefreshServerButton(store: store, id: server.id) }
                    Button("Edit", systemImage: "slider.horizontal.3") { edit(server) }
                }
                .sheet(isPresented: $trustPresented) {
                    HostTrustView(store: store, server: server, reading: reading)
                }
            }
        }
        .onChange(of: serverID) { expandedGPUs.removeAll() }
    }
    private func gpuRow(_ gpu: GPUReading, server: MobileServer, uid: Int?) -> some View {
        let mine = gpu.processes.contains { store.isMine($0, on: server) }
        let expanded = expandedGPUs.contains(gpu.index)
        let summary = GPUCardSummary(gpu: gpu, mine: mine, badge: Text("My processes"), expanded: expanded, expandable: true)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                if expanded { expandedGPUs.remove(gpu.index) } else { expandedGPUs.insert(gpu.index) }
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
                                             login: server.username, loginID: uid)
                        }
                    }
                }
            }
        }
        .gpuCardSurface(mine: mine, expanded: expanded)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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

private struct MobileProcessRow: View {
    let process: GPUProcessReading
    let mine: Bool
    let login: String
    let loginID: Int?
    @State private var expanded = false

    private var owner: Text {
        if let name = process.user, !name.isEmpty, name != "--" { return Text(verbatim: name) }
        if let id = process.userID { return Text(verbatim: id == loginID ? login : "UID \(id)") }
        return Text("Unknown owner")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { expanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ownerLabel.fixedSize()
                            Spacer(minLength: 2)
                            resourceLabel.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            ownerLabel
                            resourceLabel
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: process.displayProcessName).font(.subheadline.weight(.medium))
                            .lineLimit(expanded ? nil : 1).truncationMode(.middle)
                            .contentTransition(.identity)
                        Spacer(minLength: 4)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            if expanded && process.showsSeparateCommandSummary {
                Text(verbatim: process.commandSummary).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .transition(.identity)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((mine ? Color.green.opacity(0.08) : Color(uiColor: .systemGroupedBackground)), in: RoundedRectangle(cornerRadius: 11))
    }

    private var ownerLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: mine ? "person.fill" : "person")
            owner.fontWeight(.semibold)
        }.font(.caption).foregroundStyle(mine ? Color.green : .secondary)
    }

    private var resourceLabel: some View {
        Text(verbatim: "PID \(process.pid) · VRAM \(process.memorySummary)")
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
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
            .navigationTitle("SSH Host Key")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
