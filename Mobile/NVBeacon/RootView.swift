import SwiftUI
import UniformTypeIdentifiers
import NVBeaconCore
import NVBeaconMobile

struct RootView: View {
    @Bindable var store: MobileStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("interfaceLanguage") private var language = "system"
    @AppStorage("interfaceAppearance") private var appearance = "system"
    @State private var editor: MobileServer?
    @State private var path: [UUID] = []
    @State private var editMode = EditMode.inactive
    @State private var selected: Set<UUID> = []
    @State private var deletionRequest: Set<UUID> = []
    @State private var confirmsDeletion = false
    @State private var importerPresented = false
    @State private var transferPresented = false
    @State private var exporterPresented = false
    @State private var exportDocument = ServerArchiveDocument()
    @State private var pendingImport: ServerSettingsBackup?

    var body: some View {
        TabView {
            monitor
            .tabItem { Label("Monitor", systemImage: "waveform.path.ecg") }

            NavigationStack {
                Form {
                    Section("Monitoring") {
                        Picker("Refresh interval", selection: $store.refreshInterval) {
                            ForEach([5, 10, 15, 30, 60, 120, 300], id: \.self) { Text("\($0) seconds").tag($0) }
                        }
                    }
                    Section("Host metrics") {
                        Toggle("CPU", isOn: $store.collectsCPU)
                        Toggle("RAM and swap", isOn: $store.collectsMemory)
                        Toggle("Network traffic", isOn: $store.collectsNetwork)
                    }
                    Section("Busy GPU detection") {
                        Toggle("Highlight my jobs", isOn: $store.highlightMine)
                        Picker("Count a GPU as busy by", selection: $store.busyMode) {
                            Text("Active process").tag(BusyDetectionMode.activeProcess)
                            Text("VRAM usage").tag(BusyDetectionMode.memoryThreshold)
                            Text("Process or VRAM").tag(BusyDetectionMode.activeProcessOrMemoryThreshold)
                            Text("GPU utilization").tag(BusyDetectionMode.utilizationThreshold)
                        }
                        if [.memoryThreshold, .activeProcessOrMemoryThreshold].contains(store.busyMode) {
                            Stepper("Above \(store.memoryThreshold) MB", value: $store.memoryThreshold, in: 0...10240, step: 50)
                        } else if store.busyMode == .utilizationThreshold {
                            Stepper("At least \(store.utilizationThreshold)%", value: $store.utilizationThreshold, in: 0...100)
                        }
                    }
                    Section("Appearance") {
                        Picker("Language", selection: $language) {
                            Text("System").tag("system")
                            Text(verbatim: "English").tag("en")
                            Text(verbatim: "한국어").tag("ko")
                        }
                        Picker("Theme", selection: $appearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
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
                        NavigationLink("Diagnostics") { MobileDiagnosticsView(store: store) }
                        Link("Project on GitHub", destination: URL(string: "https://github.com/jaein4722/NVBeacon")!)
                    }
                }
                .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $transferPresented) { MacTransferView(store: store) }
        .sheet(item: $editor) { ServerEditor(store: store, server: $0) }
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
        } message: { Text(LocalizedStringKey(store.message ?? "")) }
    }

    private var serverList: some View {
        let selection: Binding<Set<UUID>>? = editMode.isEditing ? $selected : nil
        return List(selection: selection) {
            Section {
                ForEach(store.servers) { server in
                    if editMode.isEditing {
                        ServerRow(server: server, reading: store.readings[server.id], store: store)
                            .tag(server.id)
                    } else if sizeClass == .regular {
                        Button {
                            path = [server.id]
                        } label: {
                            ServerRow(server: server, reading: store.readings[server.id], store: store)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(path.last == server.id ? Color.accentColor.opacity(0.12) : nil)
                        .moveDisabled(true)
                    } else {
                        NavigationLink(value: server.id) {
                            ServerRow(server: server, reading: store.readings[server.id], store: store)
                        }
                        .moveDisabled(true)
                    }
                }
                .onMove(perform: moveServers)
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
        .environment(\.editMode, $editMode)
    }

    @ToolbarContentBuilder private var monitorTools: some ToolbarContent {
        if !store.servers.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton().environment(\.editMode, $editMode)
            }
        }
        if editMode.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(selected.count == store.servers.count ? "Deselect All" : "Select All") {
                    selected = selected.count == store.servers.count ? [] : Set(store.servers.map(\.id))
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Delete (\(selected.count))", role: .destructive) {
                    deletionRequest = selected
                    confirmsDeletion = true
                }
                .disabled(selected.isEmpty)
                .confirmationDialog(
                    deletionRequest.count == 1 ? "Delete selected server?" : "Delete \(deletionRequest.count) selected servers?",
                    isPresented: $confirmsDeletion, titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        do {
                            try store.deleteServers(deletionRequest)
                            editMode = .inactive
                        } catch { store.message = error.localizedDescription }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Their saved credentials will also be deleted from this device.")
                }
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Server", systemImage: "plus") { editor = MobileServer() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Transfer from Mac", systemImage: "qrcode.viewfinder") { transferPresented = true }
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

    private var monitor: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    monitorList
                } detail: {
                    NavigationStack {
                        if let id = path.last {
                            ServerDetailView(store: store, serverID: id) { editor = $0 }
                        } else {
                            ContentUnavailableView("Select a server", systemImage: "server.rack")
                        }
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    monitorList.navigationDestination(for: UUID.self) { id in
                        ServerDetailView(store: store, serverID: id) { editor = $0 }
                    }
                }
            }
        }
        .onChange(of: editMode) { _, mode in
            if !mode.isEditing { selected.removeAll() }
        }
        .onChange(of: store.servers.map(\.id)) { _, ids in
            let remaining = Set(ids)
            selected.formIntersection(remaining)
            path.removeAll { !remaining.contains($0) }
            if ids.isEmpty { editMode = .inactive }
        }
    }

    private var monitorList: some View {
        Group {
            if store.servers.isEmpty {
                ContentUnavailableView {
                    Label("Your GPUs, anywhere", systemImage: "server.rack")
                } description: {
                    Text("Connect to a Linux server over SSH to see GPU utilization, memory, temperature, and running jobs.")
                } actions: {
                    Button("Add Server", systemImage: "plus") { editor = MobileServer() }
                        .buttonStyle(.borderedProminent)
                    Button("Transfer from Mac", systemImage: "qrcode.viewfinder") { transferPresented = true }
                    Button("Import Server Backup") { importerPresented = true }
                }
            } else {
                serverList
            }
        }
        .toolbar(editMode.isEditing ? .hidden : .automatic, for: .tabBar)
        .navigationTitle("NVBeacon")
        .toolbar { monitorTools }
    }

    private func moveServers(from offsets: IndexSet, to destination: Int) {
        var ids = store.servers.map(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        do { try store.reorderServers(ids) }
        catch { store.message = error.localizedDescription }
    }

}

extension ServerSettingsBackup: @retroactive Identifiable {
    public var id: String { servers.map(\.sshTarget).joined(separator: "\n") }
}

struct ServerRow: View {
    let server: MobileServer
    let reading: ServerReading?
    let store: MobileStore
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
                    Text("\(snapshot.gpus.filter { store.isBusy($0) }.count)/\(snapshot.gpus.count) busy")
                    Text("·")
                    Text("\(snapshot.averageUtilization)% utilization")
                    Spacer()
                    Text(snapshot.takenAt, style: .time)
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if snapshot.gpus.contains(where: { $0.processes.contains { store.isMine($0, on: server) } }) {
                    Label("My jobs", systemImage: "person.fill").font(.caption).foregroundStyle(.tint)
                }
            } else {
                Text(LocalizedStringKey(!server.isEnabled ? "Review connection settings to start monitoring" : reading?.error ?? "Waiting for first update…"))
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
