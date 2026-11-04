import SwiftUI
import NVBeaconCore
import NVBeaconMobile

struct ServerDetailView: View {
    @Bindable var store: MobileStore
    let serverID: UUID
    let edit: (MobileServer) -> Void
    @State private var trustPresented = false
    @AppStorage("hostMetricsExpanded") private var hostMetricsExpanded = true

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
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(snapshot.averageUtilization)%").font(.largeTitle.bold()).monospacedDigit()
                                    Text("Average GPU utilization").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("\(snapshot.totalProcessCount)").font(.title.bold()).monospacedDigit()
                                    Text("GPU processes").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 8)
                        } footer: {
                            HStack {
                                Text(reading?.error == nil ? "Updated" : "Last successful update")
                                Text(snapshot.takenAt, style: .relative)
                                Text("ago")
                            }
                        }
                        if store.collectsCPU || store.collectsMemory || store.collectsNetwork {
                            Section {
                                DisclosureGroup("Host information", isExpanded: $hostMetricsExpanded) {
                                    hostMetrics(snapshot)
                                }
                            }
                        }
                        ForEach(snapshot.gpus) { gpu in
                            Section {
                                VStack(alignment: .leading, spacing: 16) {
                                    HStack {
                                        Label(gpu.name, systemImage: "cpu").font(.headline)
                                        Spacer()
                                        if gpu.processes.contains(where: { store.isMine($0, on: server) }) {
                                            Image(systemName: "person.fill").foregroundStyle(.tint).accessibilityLabel("My jobs")
                                        }
                                        if let temperature = gpu.temperatureCelsius {
                                            Label("\(temperature)°C", systemImage: "thermometer.medium")
                                                .font(.caption).foregroundStyle(temperature >= 85 ? .orange : .secondary)
                                        }
                                    }
                                    MetricBar(title: "Utilization", value: gpu.utilizationRatio, detail: "\(gpu.utilization)%")
                                    MetricBar(title: "VRAM", value: gpu.memoryUsageRatio, detail: gpu.memorySummary)
                                }.padding(.vertical, 8)
                                if gpu.processes.isEmpty {
                                    Label("No active GPU processes", systemImage: "moon.zzz").font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(gpu.processes) { process in
                                    DisclosureGroup {
                                        Text(process.commandSummary).font(.caption.monospaced()).textSelection(.enabled)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack {
                                                Text(process.displayProcessName).font(.subheadline).lineLimit(1)
                                                if store.isMine(process, on: server) { Label("Mine", systemImage: "person.fill").font(.caption).foregroundStyle(.tint) }
                                            }
                                            HStack {
                                                Text("PID \(process.pid) · \(process.userSummary)")
                                                Spacer()
                                                Text(process.memorySummary)
                                            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                        }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("GPU \(gpu.index)")
                                    Spacer()
                                    Text(store.isBusy(gpu) ? "Busy" : "Available")
                                }
                            }
                        }
                    } else if server.isEnabled, reading?.error == nil {
                        Section { HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) } }
                    }
                }
                .refreshable { await store.refresh() }
                .navigationTitle(server.displayName)
                .toolbar { Button("Edit", systemImage: "slider.horizontal.3") { edit(server) } }
                .sheet(isPresented: $trustPresented) {
                    HostTrustView(store: store, server: server, reading: reading)
                }
            }
        }
    }
    @ViewBuilder private func hostMetrics(_ snapshot: GPUSnapshot) -> some View {
        if store.collectsCPU {
            if let cpu = snapshot.hostCPU {
                MetricBar(title: "CPU", value: Double(cpu) / 100, detail: "\(cpu)%")
            } else {
                LabeledContent("CPU") { Text(snapshot.hostCPUSample == nil ? "Unavailable" : "Measuring…") }
            }
        }
        if store.collectsMemory {
            if let memory = snapshot.hostMemory {
                MetricBar(title: "RAM", value: memory.usageRatio,
                          detail: "\(HostMemoryReading.capacityText(kibibytes: memory.usedKiB)) / \(HostMemoryReading.capacityText(kibibytes: memory.totalKiB))")
                if let used = memory.swapUsedKiB, let total = memory.swapTotalKiB {
                    LabeledContent("Swap", value: "\(HostMemoryReading.capacityText(kibibytes: used)) / \(HostMemoryReading.capacityText(kibibytes: total))")
                }
            } else { LabeledContent("RAM") { Text("Unavailable") } }
        }
        if store.collectsNetwork {
            if let usage = reading?.networkUsage {
                LabeledContent("Network") {
                    if usage.hasRates { Text(verbatim: usage.rateSummary) }
                    else { Text("Measuring…") }
                }
                LabeledContent("Total traffic", value: usage.totalSummary)
            } else { LabeledContent("Network") { Text("Unavailable") } }
        }
    }

}

struct MetricBar: View {
    let title: LocalizedStringKey
    let value: Double
    let detail: String
    var body: some View {
        VStack(spacing: 6) {
            HStack { Text(title); Spacer(); Text(detail).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            ProgressView(value: min(1, max(0, value)))
                .tint(value >= 0.9 ? .orange : .green)
                .accessibilityLabel(title).accessibilityValue(detail)
        }
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
