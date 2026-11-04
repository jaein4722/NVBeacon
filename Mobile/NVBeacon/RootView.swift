import SwiftUI
import UniformTypeIdentifiers
import NVBeaconCore
import NVBeaconMobile

struct RootView: View {
    @Bindable var store: MobileStore
    @State private var editorPresented = false
    @State private var importerPresented = false
    @State private var exporterPresented = false
    @State private var exportDocument = ServerArchiveDocument()
    @State private var pendingImport: ServerSettingsBackup?

    var body: some View {
        TabView {
            NavigationStack {
                Group {
                    if store.servers.isEmpty {
                        ContentUnavailableView {
                            Label("Your GPUs, anywhere", systemImage: "server.rack")
                        } description: {
                            Text("Connect to a Linux server over SSH to see GPU utilization, memory, temperature, and running jobs.")
                        } actions: {
                            Button("Add Server", systemImage: "plus") { editorPresented = true }
                                .buttonStyle(.borderedProminent)
                            Button("Import Server Backup") { importerPresented = true }
                        }
                    } else {
                        List {
                            Section {
                                ForEach(store.servers) { server in
                                    NavigationLink {
                                        ServerDetailView(store: store, serverID: server.id)
                                    } label: {
                                        ServerRow(server: server, reading: store.readings[server.id])
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("Servers")
                                    Spacer()
                                    if store.isRefreshing { ProgressView().controlSize(.mini) }
                                }
                            } footer: {
                                Text("Updates every \(store.refreshInterval) seconds while NVBeacon is open. Pull to refresh.")
                            }
                        }
                        .refreshable { await store.refresh() }
                    }
                }
                .navigationTitle("NVBeacon")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add Server", systemImage: "plus") { editorPresented = true }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Import Servers", systemImage: "square.and.arrow.down") { importerPresented = true }
                            Button("Export Servers", systemImage: "square.and.arrow.up") {
                                do {
                                    exportDocument = ServerArchiveDocument(data: try store.exportServers())
                                    exporterPresented = true
                                } catch { store.message = error.localizedDescription }
                            }.disabled(store.servers.isEmpty)
                        } label: {
                            Label("Server Backups", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                        }
                    }
                }
            }
            .tabItem { Label("Monitor", systemImage: "waveform.path.ecg") }

            NavigationStack {
                Form {
                    Section("Monitoring") {
                        Picker("Refresh interval", selection: $store.refreshInterval) {
                            ForEach([5, 10, 15, 30, 60, 120, 300], id: \.self) { Text("\($0) seconds").tag($0) }
                        }
                    }
                    Section {
                        Label("Foreground monitoring", systemImage: "iphone")
                        Text("iOS pauses SSH polling when you leave the app or lock your device. Open NVBeacon to reconnect and refresh. Continuous background monitoring and job notifications are not available in this first iOS version.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Connecting") {
                        Text("Use a reachable hostname or IP address and an explicit SSH username. Connect your VPN first for private servers. Mac SSH aliases, ProxyJump, and SSH agent connections are not imported.")
                        Text("Passwords and imported SSH private keys stay in this device’s Keychain. Verify the host fingerprint on your first connection.")
                    }.font(.footnote)
                    Section("About") {
                        LabeledContent("NVBeacon for iOS", value: "Preview")
                        Link("Project on GitHub", destination: URL(string: "https://github.com/jaein4722/NVBeacon")!)
                    }
                }
                .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $editorPresented) { ServerEditor(store: store, server: MobileServer()) }
        .fileImporter(isPresented: $importerPresented, allowedContentTypes: [.json]) { result in
            do {
                let data = try readDocument(try result.get(), maximumBytes: ServerSettingsBackup.maximumFileBytes)
                pendingImport = try ServerSettingsBackup.decode(data)
            } catch { store.message = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporterPresented, document: exportDocument, contentType: .json,
                      defaultFilename: "NVBeacon-servers") { result in
            if case .failure(let error) = result { store.message = error.localizedDescription }
        }
        .sheet(item: $pendingImport) { backup in
            NavigationStack {
                List {
                    Section {
                        ForEach(Array(backup.servers.enumerated()), id: \.offset) { _, server in
                            VStack(alignment: .leading) {
                                Text(server.displayName).font(.headline)
                                Text(server.sshTarget).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text("\(backup.servers.count) servers") } footer: {
                        Text("Servers will be added disabled. Review addresses, usernames, and custom commands, then add credentials on this device before enabling. Mac key paths and host trust are not imported.")
                    }
                }
                .navigationTitle("Review Import")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { pendingImport = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") {
                            do { try store.importServers(backup); pendingImport = nil }
                            catch { pendingImport = nil; store.message = error.localizedDescription }
                        }
                    }
                }
            }
        }
        .alert("NVBeacon", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
}

extension ServerSettingsBackup: @retroactive Identifiable {
    public var id: String { servers.map(\.sshTarget).joined(separator: "\n") }
}

struct ServerRow: View {
    let server: MobileServer
    let reading: ServerReading?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "server.rack").foregroundStyle(.green)
                Text(server.displayName).font(.headline)
                Spacer()
                if !server.isEnabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                else if reading?.error != nil { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
            }
            if server.isEnabled, let snapshot = reading?.snapshot {
                HStack {
                    Text("\(snapshot.gpus.count) GPUs")
                    Text("·")
                    Text("\(snapshot.averageUtilization)% utilization")
                    Spacer()
                    Text(snapshot.takenAt, style: .time)
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text(!server.isEnabled ? "Review connection settings to start monitoring" : reading?.error ?? "Waiting for first update…")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }.padding(.vertical, 6)
    }
}

struct ServerArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

func readDocument(_ url: URL, maximumBytes: Int) throws -> Data {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw ServerSettingsBackup.BackupError.fileTooLarge }
    return data
}
