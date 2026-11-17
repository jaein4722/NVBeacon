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
    @State private var selectedServerID: UUID?
    @State private var serverDisclosure = ServerDetailDisclosure()
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var expandedServers: Set<UUID> = []
    @State private var editMode = EditMode.inactive
    @State private var selected: Set<UUID> = []
    @State private var deletionRequest: Set<UUID> = []
    @State private var confirmsDeletion = false
    @State private var importerPresented = false
    @State private var transferPresented = false
    @State private var exporterPresented = false
    @State private var exportDocument = ServerArchiveDocument()
    @State private var pendingImport: ServerSettingsBackup?
    @State private var selectedTab = 0

    init(store: MobileStore) {
        self.store = store
#if NVBEACON_SCREENSHOTS && targetEnvironment(simulator)
        let scene = ScreenshotFixtures.scene
        _selectedTab = State(initialValue: ["settings", "monitoring-settings"].contains(scene) ? 1 : 0)
        _transferPresented = State(initialValue: scene == "mac-transfer")
        if ["gpu-overview", "gpu-details", "host-details", "ipad-overview"].contains(scene) {
            _selectedServerID = State(initialValue: store.servers.first?.id)
            _compactColumn = State(initialValue: .detail)
            _serverDisclosure = State(initialValue: ["gpu-details", "ipad-overview"].contains(scene)
                ? ServerDetailDisclosure(gpus: [0], processes: ["gpu-0:28410:python train.py"])
                : ServerDetailDisclosure())
        }
#endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            monitor
            .tabItem { Label("Monitor", systemImage: "waveform.path.ecg") }
            .tag(0)

            NavigationStack {
                Form {
                    Group {
                        Section("General") {
                            Picker("Language", selection: $language) {
                                Text("System").tag("system")
                                Text(verbatim: "English").tag("en")
                                Text(verbatim: "한국어").tag("ko")
                            }
                        }
                        Section {
                            Picker("Refresh interval", selection: $store.refreshInterval) {
                                ForEach([5, 10, 15, 30, 60, 120, 300], id: \.self) { Text("\($0) seconds").tag($0) }
                            }
                        } header: { Text("Monitoring") } footer: {
                            Text("Applies to all servers. iOS pauses collection when you leave NVBeacon or lock your device, and NVBeacon refreshes when you return. Background monitoring and notifications are not available on iOS.")
                        }
                        Section {
                            Picker("Busy GPU detection", selection: $store.busyMode) {
                                Text("Active Process").tag(BusyDetectionMode.activeProcess)
                                Text("Memory Threshold").tag(BusyDetectionMode.memoryThreshold)
                                Text("Process or Memory").tag(BusyDetectionMode.activeProcessOrMemoryThreshold)
                                Text("Utilization Threshold").tag(BusyDetectionMode.utilizationThreshold)
                            }
                            if [.memoryThreshold, .activeProcessOrMemoryThreshold].contains(store.busyMode) {
                                Stepper(value: $store.memoryThreshold, in: 0...10240, step: 50) {
                                    settingLabel("Memory threshold", caption: "0–10,240 MB · Default 50 MB",
                                                 value: "\(store.memoryThreshold) MB")
                                }
                            } else if store.busyMode == .utilizationThreshold {
                                Stepper(value: $store.utilizationThreshold, in: 0...100) {
                                    settingLabel("Utilization threshold", caption: "0–100% · Default 10%",
                                                 value: "\(store.utilizationThreshold)%")
                                }
                            }
                            Toggle(isOn: $store.highlightMine) {
                                settingLabel("Highlight my processes",
                                             caption: "Highlight GPUs and rows with processes owned by your SSH user.")
                            }
                        } header: { Text("GPUs and Processes") } footer: {
                            // A menu picker pushes its value onto a new line under a two-line label.
                            Text(busyModeDetail)
                        }
                        Section {
                            Toggle("CPU", isOn: $store.collectsCPU)
                            Toggle("Memory (RAM / Swap)", isOn: $store.collectsMemory)
                            Toggle("Network", isOn: $store.collectsNetwork)
                        } header: { Text("Host Information") } footer: {
                            Text("Disabled items are not collected.")
                        }
                        Section("Display") {
                            Picker("Theme", selection: $appearance) {
                                Text("System").tag("system")
                                Text("Light").tag("light")
                                Text("Dark").tag("dark")
                            }
                        }
                        Section {
                            Button("Transfer from Mac…", systemImage: "qrcode.viewfinder") { transferPresented = true }
                            Button("Import Servers…", systemImage: "square.and.arrow.down") { importerPresented = true }
                            Button("Export Servers…", systemImage: "square.and.arrow.up", action: exportServers)
                                .disabled(store.servers.isEmpty)
                            NavigationLink("Diagnostic Information") { MobileDiagnosticsView(store: store) }
                        } header: { Text("Advanced") } footer: {
                            Text("Imported servers are added disabled. Mac SSH aliases, ProxyJump, and SSH agent connections are not imported.")
                        }
                        Section("About") {
                            LabeledContent("Version") {
                                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
                                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
                                Text(verbatim: "\(version) (\(build))").monospacedDigit()
                            }
                            NavigationLink("Open Source Licenses") { OpenSourceLicensesView() }
                            Link("Support", destination: URL(string: "https://jaein4722.github.io/NVBeacon/support.html")!)
                            Link("Privacy Policy", destination: URL(string: "https://jaein4722.github.io/NVBeacon/privacy.html")!)
                            Link("Project on GitHub", destination: URL(string: "https://github.com/jaein4722/NVBeacon")!)
                        }
                    }
                    .monitorRowInsets()
                }
                .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(1)
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
                    Group {
                        Section {
                            ForEach(Array(backup.servers.enumerated()), id: \.offset) { _, server in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.displayName).font(.headline)
                                    Text(server.sshTarget).font(.caption).foregroundStyle(.secondary)
                                    // Commands run on the server with the user's account: surface anything non-default.
                                    ForEach(server.customRemoteCommands, id: \.self) { command in
                                        Label("Custom remote command", systemImage: "exclamationmark.triangle")
                                            .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                                        Text(verbatim: command).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                            .lineLimit(6).textSelection(.enabled)
                                    }
                                }
                            }
                        } header: { Text("\(backup.servers.count) servers") } footer: {
                            Text("Servers will be added disabled. Review addresses, usernames, and custom commands, then add credentials on this device before enabling. Mac key paths and host trust are not imported.")
                        }
                    }
                    .monitorRowInsets()
                }
                .navigationTitle("Review Import")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { pendingImport = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import", systemImage: "square.and.arrow.down") {
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
            if !editMode.isEditing {
                Section("Fleet overview") {
                    FleetOverview(store: store)
                        .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(store.servers) { server in
                    if editMode.isEditing {
                        Label(server.displayName, systemImage: "server.rack").tag(server.id)
                            .monitorRowInsets()
                    } else {
                        let first = server.id == store.servers.first?.id
                        let last = server.id == store.servers.last?.id
                        let shape = UnevenRoundedRectangle(topLeadingRadius: first ? 18 : 0,
                                                           bottomLeadingRadius: last ? 18 : 0,
                                                           bottomTrailingRadius: last ? 18 : 0,
                                                           topTrailingRadius: first ? 18 : 0)
                        ServerMonitorRow(store: store, server: server, expanded: expandedServers.contains(server.id),
                                         showsInlineDetails: sizeClass != .regular,
                                         toggle: {
                                             if !expandedServers.insert(server.id).inserted { expandedServers.remove(server.id) }
                                         }, open: {
                                             selectedServerID = server.id
                                             compactColumn = .detail
                                         })
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                if sizeClass == .regular && selectedServerID == server.id {
                                    shape.fill(Color.accentColor.opacity(0.12))
                                }
                            }
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
                            .overlay(alignment: .bottom) {
                                if !last { Divider().padding(.horizontal, 14) }
                            }
                            .listRowInsets(EdgeInsets(top: first ? 4 : 0, leading: 4,
                                                     bottom: last ? 4 : 0, trailing: 4))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
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
        .contentMargins(.horizontal, 8, for: .scrollContent)
        .contentMargins(.top, 0, for: .scrollContent)
        .padding(.horizontal, editMode.isEditing ? 4 : 0)
        .refreshable { await store.refresh() }
        .environment(\.editMode, $editMode)
    }

    @ToolbarContentBuilder private var monitorTools: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") { editMode = .inactive }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(selected.count == store.servers.count ? "Deselect All" : "Select All",
                       systemImage: selected.count == store.servers.count ? "circle" : "checkmark.circle") {
                    selected = selected.count == store.servers.count ? [] : Set(store.servers.map(\.id))
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Delete (\(selected.count))", systemImage: "trash", role: .destructive) {
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
            if !store.servers.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit", systemImage: "pencil") { editMode = .active }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Server", systemImage: "plus") { editor = MobileServer() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Transfer from Mac…", systemImage: "qrcode.viewfinder") { transferPresented = true }
                    Button("Import Servers…", systemImage: "square.and.arrow.down") { importerPresented = true }
                    Button("Export Servers…", systemImage: "square.and.arrow.up", action: exportServers)
                        .disabled(store.servers.isEmpty)
                } label: {
                    Label("Server Backups", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
            }
        }
    }

    private func exportServers() {
        do {
            exportDocument = ServerArchiveDocument(data: try store.exportServers())
            exporterPresented = true
        } catch { store.message = error.localizedDescription }
    }

    private var busyModeDetail: LocalizedStringKey {
        switch store.busyMode {
        case .activeProcess: "Count a GPU as busy when `nvidia-smi` reports at least one active compute process."
        case .memoryThreshold: "Count a GPU as busy when used memory is above the configured threshold."
        case .activeProcessOrMemoryThreshold: "Count a GPU as busy when either an active process exists or used memory is above the threshold."
        case .utilizationThreshold: "Legacy behavior: count a GPU as busy when utilization is above the configured threshold."
        }
    }

    /// A setting's label with its one-line caption (docs/SETTINGS.md rule 3).
    private func settingLabel(_ title: LocalizedStringKey, caption: LocalizedStringKey, value: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            if let value {
                Spacer()
                Text(verbatim: value).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func selectServerForSplitView() {
#if NVBEACON_SCREENSHOTS && targetEnvironment(simulator)
        if sizeClass == .regular, ScreenshotFixtures.scene == "gpu-overview", store.servers.count > 1 {
            selectedServerID = store.servers[1].id
            compactColumn = .detail
            return
        }
#endif
        guard sizeClass == .regular, let id = selectedServerID ?? store.servers.first?.id else { return }
        selectedServerID = id
        compactColumn = .detail
    }

    private var monitor: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            monitorList
        } detail: {
            if let id = selectedServerID {
                ServerDetailView(store: store, serverID: id, disclosure: $serverDisclosure) { editor = $0 }
                    .id(id)
            } else {
                ContentUnavailableView("Select a server", systemImage: "server.rack")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selectedServerID) { _, _ in serverDisclosure = ServerDetailDisclosure() }
        .onChange(of: sizeClass, initial: true) { _, _ in selectServerForSplitView() }
        .onChange(of: editMode) { _, mode in
            if !mode.isEditing { selected.removeAll() }
        }
        .onChange(of: store.servers.map(\.id)) { _, ids in
            let remaining = Set(ids)
            selected.formIntersection(remaining)
            expandedServers.formIntersection(remaining)
            if let id = selectedServerID, !remaining.contains(id) {
                selectedServerID = nil
                compactColumn = .sidebar
            }
            if selectedServerID == nil { selectServerForSplitView() }
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
        .navigationBarTitleDisplayMode(.inline)
#if NVBEACON_DESIGN_LAB && targetEnvironment(simulator)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !editMode.isEditing { DesignLabSwitcher() }
        }
#endif
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

extension View {
    /// Keep content inside the curved ends of grouped rows, including single-row sections.
    func monitorRowInsets() -> some View {
        listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
    }
}
