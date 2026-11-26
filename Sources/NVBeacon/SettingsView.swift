import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: NVBeaconStore
    @ObservedObject var appUpdater: AppUpdater
    @ObservedObject var launchAtLoginManager: LaunchAtLoginManager
    @State private var draft = AppSettings()
    @State private var draftPassword = ""
    @State private var sshConfigHosts = SSHConfigLoader.loadHosts()
    @State private var selectedSSHConfigAlias = ""
    @State private var selectedServerID = ""
    @State private var pendingPasswordAuthServerID: String?
    @State private var autoApplyRevision = 0
    @State private var testingServerID: String?
    @State private var showsGPUHistoryConfirmation = false
    @State private var showsDeleteGPUHistoryConfirmation = false
    @State private var connectionTestResults: [String: ConnectionTestOutcome] = [:]
    @State private var suppressAutoApply = true
    @State private var suppressPasswordAuthWarning = false
    @State private var showPasswordAuthWarning = false
    @State private var showConnectionReuseHelp = false
    @State private var serverBackupDocument: ServerBackupDocument?
    @State private var showsServerExporter = false
    @State private var showsServerImporter = false
    @State private var utilitySheet: SettingsUtilitySheet?
    @State private var utilityError: String?
    @State private var utilityNotice: String?
    @State private var isPreparingExport = false
    @State private var isReadingBackup = false
    @State private var showsResetConfirmation = false

    private var selectedSSHConfigHost: SSHConfigHost? {
        sshConfigHosts.first { $0.alias == selectedSSHConfigAlias }
    }

    private var language: AppInterfaceLanguage {
        draft.resolvedLanguage
    }

    private func t(_ key: String, _ arguments: Any...) -> String {
        language.text(key, arguments: arguments)
    }

    private var selectedServerIndex: Int? {
        draft.servers.firstIndex { $0.id == selectedServerID }
    }

    private var selectedServer: ServerConfig? {
        selectedServerIndex.map { draft.servers[$0] }
    }

    private var selectedPasswordSessionState: SSHPasswordSessionState {
        guard let selectedServer else { return .notRequired }
        return store.passwordSessionState(for: selectedServer.id)
    }

    private func passwordSessionTint(for state: SSHPasswordSessionState) -> Color {
        switch state {
        case .unlocked:
            return .green
        case .locked:
            return .orange
        case .missing:
            return .secondary
        case .notRequired:
            return .secondary
        }
    }

    private var appVersionText: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildVersion) {
        case let (shortVersion?, buildVersion?) where shortVersion != buildVersion:
            return "\(shortVersion) (\(buildVersion))"
        case let (shortVersion?, _):
            return shortVersion
        default:
            return "0.9.1"
        }
    }

    private var buildVersionText: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    private var bundleIdentifierText: String {
        Bundle.main.bundleIdentifier ?? "com.leejaein.NVBeacon"
    }

    private var bundleIdentifierDisplayText: String {
        return bundleIdentifierText
    }

    private var repoURL: URL {
        URL(string: "https://github.com/jaein4722/NVBeacon")!
    }

    private var profileURL: URL {
        URL(string: "https://github.com/jaein4722")!
    }

    private var appIconImage: NSImage {
        NSApplication.shared.applicationIconImage
    }

    var body: some View {
        TabView {
            generalPane
                .tabItem {
                    Label(t("General"), systemImage: "gearshape")
                }

            serversPane
                .tabItem {
                    Label(t("Servers"), systemImage: "server.rack")
                }

            monitoringPane
                .tabItem {
                    Label(t("Monitoring"), systemImage: "waveform.path.ecg")
                }

            notificationsPane
                .tabItem {
                    Label(t("Notifications"), systemImage: "bell.badge")
                }

            displayPane
                .tabItem {
                    Label(t("Display"), systemImage: "menubar.rectangle")
                }

            advancedPane
                .tabItem {
                    Label(t("Advanced"), systemImage: "slider.horizontal.3")
                }

            aboutPane
                .tabItem {
                    Label(t("About"), systemImage: "info.circle")
                }
        }
        .frame(width: 720, height: 560)
        .onAppear {
            reloadSSHConfigHosts()
            loadCurrentSettings()
            launchAtLoginManager.refreshStatus()
            Task {
                await store.refreshNotificationPermissionState()
            }
        }
        // Login items can be approved or removed in System Settings while this window is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginManager.refreshStatus()
        }
        .onChange(of: draft) { _, _ in
            scheduleAutoApply()
        }
        // A result describes the settings it ran with; drop it once they change.
        .onChange(of: draft.servers) { oldServers, newServers in
            for server in newServers where oldServers.first(where: { $0.id == server.id }).map({ !$0.hasSameConnection(as: server) }) ?? false {
                connectionTestResults[server.id] = nil
            }
        }
        // The popover, the window and the menu can change these while Settings is open.
        .onChange(of: store.settings.displayMode) { _, mode in
            if draft.displayMode != mode { draft.displayMode = mode }
        }
        .onChange(of: store.settings.keepsWindowOnTop) { _, keepsOnTop in
            if draft.keepsWindowOnTop != keepsOnTop { draft.keepsWindowOnTop = keepsOnTop }
        }
        .task(id: autoApplyRevision) {
            guard autoApplyRevision > 0 else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            applyDraftIfNeeded()
        }
        .alert(t("Password-Based Authentication"), isPresented: $showPasswordAuthWarning) {
            Button(t("Do Not Show Again")) {
                store.acknowledgePasswordAuthWarning(skipFutureWarnings: true)
                enablePasswordAuthAfterWarning()
            }

            Button(t("Continue")) {
                store.acknowledgePasswordAuthWarning(skipFutureWarnings: false)
                enablePasswordAuthAfterWarning()
            }

            Button(t("Cancel"), role: .cancel) {
                pendingPasswordAuthServerID = nil
            }
        } message: {
            Text(
                t("Password-based authentication stores the password in Keychain, then keeps it in memory for the current app session after you unlock it once. This is less secure than SSH keys and should be used only when key-based authentication is not available.")
            )
        }
        .fileExporter(
            isPresented: $showsServerExporter,
            document: serverBackupDocument,
            contentType: .json,
            defaultFilename: "NVBeacon-servers"
        ) { result in
            switch result {
            case .success:
                utilityNotice = t("Server settings exported.")
            case .failure(let error):
                showUtilityError(error)
            }
        }
        .fileImporter(isPresented: $showsServerImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                readServerBackup(url)
            case .failure(let error):
                showUtilityError(error)
            }
        }
        .sheet(item: $utilitySheet) { sheet in
            switch sheet {
            case .importServers(let backup, let fileName):
                ServerImportReviewView(
                    backup: backup,
                    fileName: fileName,
                    existingServerCount: draft.configuredServers.count,
                    language: language,
                    importServers: { importServerBackup(backup) },
                    cancel: { utilitySheet = nil }
                )
            case .transfer:
                IPhoneTransferView(settings: draft, language: language) { utilitySheet = nil }
            case .diagnostics(let report):
                DiagnosticsPreviewView(report: report, language: language, close: { utilitySheet = nil })
            }
        }
        .alert(t("Unable to Complete Action"), isPresented: Binding(
            get: { utilityError != nil },
            set: { if !$0 { utilityError = nil } }
        )) {
            Button(t("OK"), role: .cancel) { utilityError = nil }
        } message: {
            Text(utilityError ?? "")
        }
    }

    // MARK: - Panes
    //
    // Settings rules (docs/SETTINGS.md): tabs by task; per-server settings only in
    // Servers; item help as a caption under the label, section-wide notes as a
    // footer; a switch's dependents are disabled, a picker's mode-specific fields
    // appear only for that mode; destructive actions last, red and confirmed.

    private var generalPane: some View {
        Form {
            Section {
                Toggle(
                    t("Launch NVBeacon at login"),
                    isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { launchAtLoginManager.setEnabled($0) }
                    )
                )
                .disabled(!launchAtLoginManager.canConfigure)

                LabeledContent {
                    Button(t("Refresh")) {
                        launchAtLoginManager.refreshStatus()
                    }
                    .disabled(!launchAtLoginManager.canConfigure)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Startup status"))
                        Text(launchAtLoginManager.lastErrorMessage ?? launchAtLoginManager.state.title(in: language))
                            .font(.caption)
                            .foregroundStyle(
                                launchAtLoginManager.lastErrorMessage != nil
                                ? .red
                                : launchAtLoginManager.state == .enabled
                                ? .green
                                : launchAtLoginManager.state == .requiresApproval
                                ? .orange
                                : .secondary
                            )
                    }
                }
            } header: {
                Text(t("Startup"))
            }

            Section {
                Toggle(
                    t("Check for updates automatically"),
                    isOn: Binding(
                        get: { appUpdater.automaticallyChecksForUpdates },
                        set: { appUpdater.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                .disabled(!appUpdater.availability.isAvailable)

                Toggle(
                    t("Download updates automatically"),
                    isOn: Binding(
                        get: { appUpdater.automaticallyDownloadsUpdates },
                        set: { appUpdater.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!appUpdater.availability.isAvailable || !appUpdater.automaticallyChecksForUpdates)

                LabeledContent {
                    Button(t("Check Now")) {
                        appUpdater.checkForUpdates()
                    }
                    .disabled(!appUpdater.canCheckForUpdates)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Check for updates"))
                        Text(lastUpdateCheckText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear { appUpdater.refreshLastUpdateCheckDate() }
            } header: {
                Text(t("Updates"))
            }

            Section {
                LabeledContent(t("Language")) {
                    Picker(t("Language"), selection: $draft.languagePreference) {
                        ForEach(AppLanguagePreference.choices, id: \.self) { preference in
                            Text(preference.title(in: language)).tag(preference)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Toggle(t("Show Dock icon"), isOn: $draft.showsDockIcon)
            } header: {
                Text(t("App"))
            }
        }
        .formStyle(.grouped)
    }

    private var serversPane: some View {
        Form {
            Section {
                serverPickerRow
            } header: {
                Text(t("Servers"))
            } footer: {
                Text(t("The popover uses this server order."))
            }

            Section {
                addServerRow
            } header: {
                Text(t("Add Server"))
            }

            Section {
                selectedServerEditor
            } header: {
                Text(t("Selected Server"))
            }

            Section {
                QueryCommandField(
                    command: selectedServerStringBinding(\.remoteCommand, defaultValue: AppSettings.defaultRemoteCommand),
                    defaultCommand: AppSettings.defaultRemoteCommand,
                    title: t("GPU Query Command"),
                    isEnabled: selectedServer != nil
                )
            } header: {
                Text(t("GPU Query Command"))
            } footer: {
                Text(t("Applies to the selected server. Leave empty to restore the default command."))
            }

            Section {
                QueryCommandField(
                    command: selectedServerStringBinding(\.hostCommand, defaultValue: AppSettings.defaultHostCommand),
                    defaultCommand: AppSettings.defaultHostCommand,
                    title: t("Host Information Query Command"),
                    isEnabled: selectedServer != nil
                )
            } header: {
                Text(t("Host Information Query Command"))
            } footer: {
                Text(t("Collects CPU, RAM/Swap, and network for the selected server in the same SSH refresh. Keep the section markers and collection switches when customizing. Leave empty to restore the default command."))
            }
        }
        .formStyle(.grouped)
    }

    private var monitoringPane: some View {
        Form {
            Section {
                LabeledContent {
                    NumericStepperField(
                        value: $draft.pollIntervalSeconds,
                        range: 1...300,
                        suffix: t("s"),
                        fieldWidth: 72
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Refresh interval"))
                        Text(t("1–300 s · Default 10 s"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("Collection"))
            } footer: {
                Text(t("Applies to all servers."))
            }

            Section {
                LabeledContent {
                    Picker(t("Busy GPU detection"), selection: $draft.busyDetectionMode) {
                        ForEach(BusyDetectionMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Busy GPU detection"))
                        Text(draft.busyDetectionMode.detailText(in: language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if draft.busyDetectionMode == .memoryThreshold || draft.busyDetectionMode == .activeProcessOrMemoryThreshold {
                    LabeledContent {
                        NumericStepperField(
                            value: $draft.busyMemoryThresholdMB,
                            range: 0...10_240,
                            suffix: "MB",
                            fieldWidth: 82
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("Memory threshold"))
                            Text(t("0–10,240 MB · Default 50 MB"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if draft.busyDetectionMode == .utilizationThreshold {
                    LabeledContent {
                        NumericStepperField(
                            value: $draft.busyUtilizationThresholdPercent,
                            range: 0...100,
                            suffix: "%",
                            fieldWidth: 72
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("Utilization threshold"))
                            Text(t("0–100% · Default 10%"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle(isOn: $draft.highlightsMyProcesses) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Highlight my processes"))
                        Text(t("Detect the SSH user's processes and highlight matching GPUs and rows. Turning this off also skips the extra owner checks."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("GPUs and Processes"))
            }

            Section {
                Toggle(t("Collect host information"), isOn: $draft.collectsHostInfo)
                Toggle("CPU", isOn: $draft.collectsHostCPU)
                    .disabled(!draft.collectsHostInfo)
                Toggle(t("Memory (RAM / Swap)"), isOn: $draft.collectsHostMemory)
                    .disabled(!draft.collectsHostInfo)
                Toggle(t("Network"), isOn: $draft.showsNetworkUsage)
                    .disabled(!draft.collectsHostInfo)
            } header: {
                Text(t("Host Information"))
            } footer: {
                Text(t("Disabled items are not collected. Collapsing a server's host information in the popover only hides it; collection continues."))
            }

            Section {
                Toggle(isOn: gpuHistoryRecordingBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Record GPU history"))
                        Text(t("Keep 24 hours of per-user GPU utilization on this Mac. Open it from the chart button in the popover."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button(t("Delete History…"), role: .destructive) {
                        showsDeleteGPUHistoryConfirmation = true
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Saved history"))
                        Text(t("Turning recording off keeps the saved history until you delete it."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("GPU History"))
            } footer: {
                Text(t("Each server runs nvidia-smi pmon at most once a minute while recording."))
            }
        }
        .formStyle(.grouped)
        .alert(t("Record GPU history?"), isPresented: $showsGPUHistoryConfirmation) {
            Button(t("Record")) {
                draft.recordsGPUHistory = true
            }
            Button(t("Cancel"), role: .cancel) {}
        } message: {
            Text(t("NVBeacon will keep 24 hours of per-user GPU utilization on this Mac, including the user names of other people on shared servers. Each server runs nvidia-smi pmon (about one second) at most once a minute. Storage is small: about 0.3 MB per GPU. You can delete the history at any time."))
        }
        .alert(t("Delete GPU history?"), isPresented: $showsDeleteGPUHistoryConfirmation) {
            Button(t("Delete"), role: .destructive) {
                Task { await store.deleteGPUHistory() }
            }
            Button(t("Cancel"), role: .cancel) {}
        } message: {
            Text(t("All saved GPU history on this Mac will be deleted. This cannot be undone."))
        }
    }

    /// Turning recording on asks first; turning it off does not.
    private var gpuHistoryRecordingBinding: Binding<Bool> {
        Binding(
            get: { draft.recordsGPUHistory },
            set: { isOn in
                if isOn && !draft.recordsGPUHistory {
                    showsGPUHistoryConfirmation = true
                } else {
                    draft.recordsGPUHistory = isOn
                }
            }
        )
    }

    private var notificationsPane: some View {
        Form {
            Section {
                LabeledContent(t("Status")) {
                    Text(store.notificationPermissionState.title(in: language))
                        .foregroundStyle(store.notificationPermissionState == .authorized ? .green : .secondary)
                }

                HStack(spacing: 8) {
                    Button(store.notificationPermissionState == .authorized ? t("Re-check Permission") : t("Enable Notifications")) {
                        store.requestNotificationPermission()
                    }

                    Button(t("Refresh Status")) {
                        Task {
                            await store.refreshNotificationPermissionState()
                        }
                    }

                    if store.notificationPermissionState == .authorized {
                        Button(t("Send Test Notification")) {
                            store.sendTestNotification()
                        }
                    }
                }
            } header: {
                Text(t("Permission"))
            }

            Section {
                LabeledContent {
                    NumericStepperField(
                        value: $draft.idleNotificationSeconds,
                        range: 1...3_600,
                        suffix: t("s"),
                        fieldWidth: 72
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Idle duration"))
                        Text(t("1–3,600 s · Default 300 s"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    NumericStepperField(
                        value: $draft.idleMemoryThresholdMB,
                        range: 0...10_240,
                        suffix: "MB",
                        fieldWidth: 88
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Memory threshold"))
                        Text(t("0–10,240 MB · Default 50 MB"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("GPU Idle Alert"))
            } footer: {
                Text(t("Starred GPUs send an alert when they stay idle this long with memory at or below the threshold."))
            }

            Section {
                activeWatchesContent
            } header: {
                Text(t("Active Watches"))
            }

            Section {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.recentNotificationHistory.isEmpty {
                            Text(t("There is no notification history in the last 24 hours."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(store.recentNotificationHistory.enumerated()), id: \.element.id) { index, entry in
                                NotificationHistoryRow(entry: entry, language: language)

                                if index < store.recentNotificationHistory.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 150, maxHeight: 240)
            } header: {
                Text(t("Recent 24 Hours"))
            }
        }
        .formStyle(.grouped)
    }

    private var displayPane: some View {
        Form {
            Section {
                LabeledContent {
                    Picker(t("Menu bar text"), selection: $draft.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Menu bar text"))
                        Text(draft.menuBarDisplayMode.detailText(in: language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Picker(t("Display mode"), selection: $draft.displayMode) {
                        ForEach(MonitorDisplayMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Display mode"))
                        Text(t("Window keeps NVBeacon open like a normal app window."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if draft.displayMode == .window {
                    Toggle(t("Keep window on top"), isOn: $draft.keepsWindowOnTop)
                }

                LabeledContent(t("Theme")) {
                    Picker(t("Theme"), selection: $draft.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text(t("Menu Bar and Window"))
            }

            Section {
                LabeledContent {
                    NumericStepperField(
                        value: $draft.popoverWidth,
                        range: AppSettings.popoverWidthRange,
                        suffix: t("pt"),
                        fieldWidth: 72,
                        step: 20
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Width"))
                        Text(t("480–800 pt · Default 500 pt"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Picker(t("Height"), selection: $draft.popoverHeightMode) {
                        ForEach(PopoverHeightMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text(t("Height"))
                }

                if draft.popoverHeightMode == .fixed {
                    LabeledContent {
                        NumericStepperField(
                            value: $draft.popoverHeight,
                            range: AppSettings.popoverHeightRange,
                            suffix: t("pt"),
                            fieldWidth: 72,
                            step: 20
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("Fixed height"))
                            Text(t("320–1100 pt · Default 600 pt"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle(isOn: $draft.closesPopoverOnOutsideClick) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Close on outside click"))
                        Text(t("Also closes when you switch to another app."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("Popover"))
            }
        }
        .formStyle(.grouped)
    }

    private var advancedPane: some View {
        Form {
            Section {
                HStack {
                    Button(t("Export Servers…"), action: exportServerBackup)
                        .disabled(draft.configuredServers.isEmpty || isReadingBackup || isPreparingExport)
                    Button(t("Import Servers…")) { showsServerImporter = true }
                        .disabled(isReadingBackup || isPreparingExport)
                    if isReadingBackup || isPreparingExport { ProgressView().controlSize(.small) }
                }
                Button(t("Transfer All Servers to iPhone…")) { utilitySheet = .transfer }
                    .disabled(draft.configuredServers.isEmpty || isReadingBackup || isPreparingExport)
                if let utilityNotice {
                    Text(utilityNotice).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(t("Server Backup and Transfer"))
            } footer: {
                Text(t("Exports host names, key-file paths and remote commands. Keychain passwords, private-key contents and notification watches are excluded. Imports add disabled servers without replacing existing settings."))
            }

            Section {
                Button(t("Copy Diagnostic Information…"), action: showDiagnostics)
            } header: {
                Text(t("Support"))
            } footer: {
                Text(t("Preview a report of the current app and collection state. No additional SSH commands are run."))
            }

            Section {
                Button(t("Reload Current Settings")) {
                    loadCurrentSettings()
                }

                Button(t("Clear Saved Settings…"), role: .destructive) {
                    showsResetConfirmation = true
                }
                .confirmationDialog(
                    t("Clear all saved settings?"),
                    isPresented: $showsResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(t("Clear Saved Settings"), role: .destructive) {
                        store.resetConfiguration()
                        loadCurrentSettings()
                    }
                } message: {
                    Text(t("This removes every server, its saved password in Keychain, all GPU and process alerts, and the notification history. It cannot be undone."))
                }
            } header: {
                Text(t("Saved Settings"))
            }
        }
        .formStyle(.grouped)
    }

    private var aboutPane: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Link(destination: repoURL) {
                        Image(nsImage: appIconImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 112, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
                    }
                    .buttonStyle(.plain)
                    .help(t("Open the GitHub repository"))

                    Text("NVBeacon")
                        .font(.title2.weight(.semibold))

                    Text(t("Remote NVIDIA GPU monitoring from your macOS menu bar."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(t("Version %@", appVersionText))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Link(destination: repoURL) {
                            AboutActionLabel(title: t("Repository"), systemImage: "shippingbox")
                        }
                        .buttonStyle(.plain)

                        Link(destination: profileURL) {
                            AboutActionLabel(title: t("GitHub Profile"), systemImage: "person.crop.circle")
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        appUpdater.checkForUpdates()
                    } label: {
                        AboutActionLabel(
                            title: t("Check for Updates…"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!appUpdater.canCheckForUpdates)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)

                AboutCard(title: t("Build Information")) {
                    AboutInfoRow(title: t("Version"), value: appVersionText)
                    AboutInfoRow(title: t("Build"), value: buildVersionText)
                    AboutInfoRow(title: t("Bundle Identifier"), value: bundleIdentifierDisplayText)
                    AboutInfoRow(title: t("Repository"), value: "github.com/jaein4722/NVBeacon")
                    AboutInfoRow(title: t("Developer"), value: "github.com/jaein4722")
                }

                AboutCard(title: t("Runtime Snapshot")) {
                    AboutInfoRow(title: t("Process Watches"), value: "\(store.watchedProcesses.count)")
                    AboutInfoRow(title: t("GPU Idle Watches"), value: "\(store.watchedIdleGPUs.count)")

                    if store.totalGPUCount > 0 {
                        AboutInfoRow(title: t("Visible GPUs"), value: "\(store.totalGPUCount)")
                        AboutInfoRow(title: t("Busy GPUs"), value: "\(store.fleetBusyCount)")
                        AboutInfoRow(title: t("Processes"), value: "\(store.totalProcessCount)")
                        AboutInfoRow(title: t("Average Utilization"), value: "\(store.fleetAverageUtilization)%")
                        AboutInfoRow(title: t("Server Errors"), value: "\(store.failedServerCount)")
                    } else {
                        Text(t("GPU data has not been loaded yet."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var lastUpdateCheckText: String {
        guard appUpdater.availability.isAvailable else {
            return appUpdater.availability.title(in: language)
        }
        guard let date = appUpdater.lastUpdateCheckDate else {
            return t("Not checked yet")
        }
        let formatter = DateFormatter()
        formatter.locale = language == .english ? Locale(identifier: "en_US") : language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return t("Last checked: %@", formatter.string(from: date))
    }

    private func scheduleAutoApply() {
        guard !suppressAutoApply else { return }
        autoApplyRevision += 1
    }

    private func exportServerBackup() {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        let settings = draft
        Task { @MainActor in
            defer { isPreparingExport = false }
            do {
                let backup = try await ServerSettingsBackup.portableExport(settings: settings)
                serverBackupDocument = ServerBackupDocument(data: try backup.encoded())
                utilityNotice = nil
                showsServerExporter = true
            } catch let error as ServerSettingsBackup.ExportError {
                utilityError = error.message(in: language)
            } catch {
                showUtilityError(error)
            }
        }
    }

    private func showUtilityError(_ error: Error) {
        if let backupError = error as? ServerSettingsBackup.BackupError {
            utilityError = backupError.message(in: language)
            return
        }
        let error = error as NSError
        guard error.domain != NSCocoaErrorDomain || error.code != NSUserCancelledError else { return }
        utilityError = error.localizedDescription
    }

    private func readServerBackup(_ url: URL) {
        isReadingBackup = true
        utilityNotice = nil
        Task { @MainActor in
            defer { isReadingBackup = false }
            do {
                let backup = try await Task.detached(priority: .userInitiated) {
                    try ServerSettingsBackup.read(from: url)
                }.value
                utilitySheet = .importServers(backup, url.lastPathComponent)
            } catch {
                showUtilityError(error)
            }
        }
    }

    private func importServerBackup(_ backup: ServerSettingsBackup) {
        do {
            let imported = try backup.addingServers(to: draft)
            store.applySettings(imported)
            loadCurrentSettings()
            utilityNotice = t("Added %@ disabled servers.", backup.servers.count)
            utilitySheet = nil
        } catch {
            utilitySheet = nil
            showUtilityError(error)
        }
    }

    private func showDiagnostics() {
        utilitySheet = .diagnostics(DiagnosticsReport.make(
            settings: store.settings,
            states: store.serverStates,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            buildNumber: buildVersionText,
            notificationStatus: store.notificationPermissionState.title(in: .english),
            pollingRestarts: max(0, store.pollingGeneration - 1)
        ))
    }

    private func applyDraftIfNeeded() {
        guard !suppressAutoApply else { return }

        let normalizedDraft = draft.normalized()
        store.applySettings(normalizedDraft)
    }

    private func loadCurrentSettings() {
        suppressAutoApply = true
        let currentSettings = store.settings.normalized()

        draft = currentSettings

        if selectedServerID.isEmpty || !draft.servers.contains(where: { $0.id == selectedServerID }) {
            selectedServerID = draft.servers.first?.id ?? ""
        }

        if selectedSSHConfigAlias.isEmpty {
            selectedSSHConfigAlias = sshConfigHosts.first?.alias ?? ""
        }
        draftPassword = ""
        releaseAutoApplySuppression()
    }

    private func reloadSSHConfigHosts() {
        sshConfigHosts = SSHConfigLoader.loadHosts()

        if selectedSSHConfigAlias.isEmpty || !sshConfigHosts.contains(where: { $0.alias == selectedSSHConfigAlias }) {
            selectedSSHConfigAlias = sshConfigHosts.first?.alias ?? ""
        }
    }

    private func addBlankServer() {
        let newServer = ServerConfig(name: t("New Server"))
        draft.servers.append(newServer)
        selectedServerID = newServer.id
    }

    private func addSSHConfigServer() {
        guard let selectedSSHConfigHost else {
            addBlankServer()
            return
        }

        let newServer = selectedSSHConfigHost.newServer()
        draft.servers.append(newServer)
        selectedServerID = newServer.id
    }

    private func removeSelectedServer() {
        guard let selectedServerIndex else { return }
        let removedServerID = draft.servers[selectedServerIndex].id
        draft.servers.remove(at: selectedServerIndex)
        draftPassword = ""

        if selectedServerID == removedServerID {
            selectedServerID = draft.servers.first?.id ?? ""
        }

        if draft.servers.isEmpty {
            draft.sshTarget = ""
            draft.sshPort = ""
            draft.sshIdentityFilePath = ""
            draft.remoteCommand = AppSettings.defaultRemoteCommand
            draft.memoryCommand = AppSettings.defaultMemoryCommand
            draft.hostCommand = AppSettings.defaultHostCommand
        }
    }

    private func moveSelectedServerUp() {
        guard let selectedServerIndex, selectedServerIndex > 0 else { return }
        draft.servers.swapAt(selectedServerIndex, selectedServerIndex - 1)
        selectedServerID = draft.servers[selectedServerIndex - 1].id
    }

    private func moveSelectedServerDown() {
        guard let selectedServerIndex, selectedServerIndex < draft.servers.count - 1 else { return }
        draft.servers.swapAt(selectedServerIndex, selectedServerIndex + 1)
        selectedServerID = draft.servers[selectedServerIndex + 1].id
    }

    private func saveDraftPassword() {
        let trimmedPassword = draftPassword.trimmingCharacters(in: .newlines)
        guard !trimmedPassword.isEmpty else { return }
        guard let selectedServer else { return }
        store.savePassword(trimmedPassword, for: selectedServer.id)
        draftPassword = ""
    }

    private func applyPasswordSettingsImmediately() {
        store.applySettings(draft.normalized())
    }

    private func shouldPresentPasswordAuthWarning(for newValue: SSHAuthenticationMode) -> Bool {
        guard !suppressPasswordAuthWarning else { return false }
        guard newValue == .passwordBased else { return false }
        guard store.shouldWarnBeforeEnablingPasswordAuth else { return false }
        return true
    }

    private func presentPasswordAuthWarning(for serverID: String) {
        suppressPasswordAuthWarning = true
        pendingPasswordAuthServerID = serverID
        showPasswordAuthWarning = true
        DispatchQueue.main.async {
            suppressPasswordAuthWarning = false
        }
    }

    private func enablePasswordAuthAfterWarning() {
        suppressPasswordAuthWarning = true
        if let pendingPasswordAuthServerID,
           let index = draft.servers.firstIndex(where: { $0.id == pendingPasswordAuthServerID }) {
            draft.servers[index].sshAuthenticationMode = .passwordBased
        }
        pendingPasswordAuthServerID = nil
        DispatchQueue.main.async {
            suppressPasswordAuthWarning = false
        }
    }

    private func selectedServerStringBinding(_ keyPath: WritableKeyPath<ServerConfig, String>, defaultValue: String = "") -> Binding<String> {
        Binding(
            get: {
                guard let selectedServerIndex else { return defaultValue }
                return draft.servers[selectedServerIndex][keyPath: keyPath]
            },
            set: { newValue in
                guard let selectedServerIndex else { return }
                draft.servers[selectedServerIndex][keyPath: keyPath] = newValue
            }
        )
    }

    private func selectedServerBoolBinding(_ keyPath: WritableKeyPath<ServerConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: {
                guard let selectedServerIndex else { return false }
                return draft.servers[selectedServerIndex][keyPath: keyPath]
            },
            set: { newValue in
                guard let selectedServerIndex else { return }
                draft.servers[selectedServerIndex][keyPath: keyPath] = newValue
            }
        )
    }

    private func selectedServerAuthModeBinding() -> Binding<SSHAuthenticationMode> {
        Binding(
            get: {
                selectedServer?.sshAuthenticationMode ?? .keyBased
            },
            set: { newValue in
                guard let selectedServerIndex else { return }
                let serverID = draft.servers[selectedServerIndex].id

                if shouldPresentPasswordAuthWarning(for: newValue) {
                    presentPasswordAuthWarning(for: serverID)
                    return
                }

                draft.servers[selectedServerIndex].sshAuthenticationMode = newValue
                if newValue != .passwordBased {
                    draftPassword = ""
                }
            }
        )
    }

    private func selectedServerConnectionReuseBinding() -> Binding<SSHConnectionReuseMode> {
        Binding(
            get: {
                selectedServer?.sshConnectionReuseMode ?? .reuseWhenPossible
            },
            set: { newValue in
                guard let selectedServerIndex else { return }
                draft.servers[selectedServerIndex].sshConnectionReuseMode = newValue
            }
        )
    }

    private var serverPickerRow: some View {
        LabeledContent(t("Current")) {
            HStack(spacing: 8) {
                Picker(t("Server"), selection: $selectedServerID) {
                    ForEach(draft.servers) { server in
                        Text(server.displayName).tag(server.id)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 240, maxWidth: 300)
                .disabled(draft.servers.isEmpty)

                Button {
                    moveSelectedServerUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled((selectedServerIndex ?? 0) <= 0)
                .help(t("Move selected server up"))

                Button {
                    moveSelectedServerDown()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(selectedServerIndex == nil || selectedServerIndex == draft.servers.count - 1)
                .help(t("Move selected server down"))

                Button(role: .destructive) {
                    removeSelectedServer()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedServer == nil)
                .help(t("Remove selected server"))
            }
        }
    }

    private var addServerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(t("action::New Server")) {
                    addBlankServer()
                }

                if !sshConfigHosts.isEmpty {
                    Button(t("Reload Saved Hosts")) {
                        reloadSSHConfigHosts()
                    }
                }
            }

            if !sshConfigHosts.isEmpty {
                savedHostAddRow
            } else {
                Text(t("No saved hosts were found in ~/.ssh/config."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var savedHostAddRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(t("Saved host")) {
                HStack(spacing: 8) {
                    Picker(t("Saved host"), selection: $selectedSSHConfigAlias) {
                        Text(t("Select a saved host")).tag("")

                        ForEach(sshConfigHosts) { host in
                            Text(host.displayName).tag(host.alias)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 260, maxWidth: 320)

                    Button(t("Add Saved Host")) {
                        addSSHConfigServer()
                    }
                    .disabled(selectedSSHConfigHost == nil)
                }
            }

            if let selectedSSHConfigHost {
                Text(selectedSSHConfigHost.detailSummary(in: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var selectedServerEditor: some View {
        if let selectedServer {
            Toggle(t("Enabled"), isOn: selectedServerBoolBinding(\.isEnabled))

            LabeledContent(t("Name")) {
                TextField("", text: selectedServerStringBinding(\.name), prompt: Text(selectedServer.sshTarget.isEmpty ? "GPU Server" : selectedServer.sshTarget))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 240)
            }

            LabeledContent(t("SSH target")) {
                TextField("", text: selectedServerStringBinding(\.sshTarget), prompt: Text(t("gpu-prod or user@host")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 320)
            }

            LabeledContent(t("SSH port")) {
                TextField("", text: selectedServerStringBinding(\.sshPort), prompt: Text(t("Optional")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 120)
            }

            LabeledContent(t("Authentication")) {
                Picker(t("Authentication"), selection: selectedServerAuthModeBinding()) {
                    ForEach(SSHAuthenticationMode.allCases) { mode in
                        Text(mode.title(in: language)).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            LabeledContent(t("Key file")) {
                TextField("", text: selectedServerStringBinding(\.sshIdentityFilePath), prompt: Text(t("Optional")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 320)
            }

            LabeledContent {
                HStack(spacing: 8) {
                    Picker(t("SSH connection"), selection: selectedServerConnectionReuseBinding()) {
                        ForEach(SSHConnectionReuseMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Button {
                        showConnectionReuseHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("About SSH connection reuse"))
                    .popover(isPresented: $showConnectionReuseHelp, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(t("About SSH connection reuse"))
                                .font(.headline)
                            Text(selectedServer.sshConnectionReuseMode.helpText(in: language))
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(width: 320, alignment: .leading)
                    }
                }
            } label: {
                Text(t("SSH connection"))
            }

            if selectedServer.sshAuthenticationMode == .passwordBased {
                LabeledContent(t("Password session")) {
                    Text(selectedPasswordSessionState.title(in: language))
                        .foregroundStyle(passwordSessionTint(for: selectedPasswordSessionState))
                }

                LabeledContent(t("SSH password")) {
                    SecureField("", text: $draftPassword, prompt: Text(t("Optional")))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 240)
                }

                HStack(spacing: 8) {
                    Button(t("Save Password")) {
                        applyPasswordSettingsImmediately()
                        saveDraftPassword()
                    }
                    .disabled(draftPassword.trimmingCharacters(in: .newlines).isEmpty)

                    Button(t("Unlock Saved Password")) {
                        applyPasswordSettingsImmediately()
                        store.unlockSavedPassword(for: selectedServer.id)
                    }
                    .disabled(!selectedPasswordSessionState.supportsUnlockAction)

                    Button(t("Forget Saved Password"), role: .destructive) {
                        applyPasswordSettingsImmediately()
                        store.forgetSavedPassword(for: selectedServer.id)
                    }
                    .disabled(!selectedPasswordSessionState.supportsForgetAction)
                }
            }
            connectionTestRow(for: selectedServer)
        } else {
            Text(t("Add a server to start monitoring remote GPUs."))
                .foregroundStyle(.secondary)
        }
    }

    private func connectionTestRow(for server: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(t("Test Connection")) {
                    runConnectionTest(for: server)
                }
                .disabled(testingServerID != nil || server.sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if testingServerID == server.id {
                    ProgressView()
                        .controlSize(.small)
                    Text(t("Connecting…"))
                        .foregroundStyle(.secondary)
                }
            }

            if testingServerID != server.id, let outcome = connectionTestResults[server.id] {
                switch outcome {
                case .success(let gpuCount):
                    Label(t("Connected · %@ GPUs", gpuCount), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure(let message):
                    VStack(alignment: .leading, spacing: 2) {
                        Label(DiagnosticsReport.errorCategoryTitle(message, in: language), systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func runConnectionTest(for server: ServerConfig) {
        testingServerID = server.id
        connectionTestResults[server.id] = nil
        let typedPassword = server.sshAuthenticationMode == .passwordBased ? draftPassword : nil
        Task { @MainActor in
            let outcome = await store.testConnection(server, password: typedPassword)
            connectionTestResults[server.id] = outcome
            testingServerID = nil
        }
    }

    @ViewBuilder
    private var activeWatchesContent: some View {
        if store.watchedIdleGPUs.isEmpty && store.watchedProcesses.isEmpty {
            Text(t("There are no configured notification watches."))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !store.watchedIdleGPUs.isEmpty {
                    watchGroup(
                        title: t("GPU Idle Alerts"),
                        rows: store.watchedIdleGPUs.map { watch in
                            AnyView(
                                NotificationWatchRow(
                                    badgeTitle: t("GPU Idle"),
                                    badgeSystemImage: "star.fill",
                                    badgeTint: .yellow,
                                    title: watch.title,
                                    primaryMetadata: watch.subtitle,
                                    secondaryMetadata: t("Idle %@s · <=%@MB", draft.idleNotificationSeconds, draft.idleMemoryThresholdMB),
                                    disableTitle: t("Disable"),
                                    removeAction: {
                                        store.removeIdleWatch(watch)
                                    }
                                )
                            )
                        }
                    )
                }

                if !store.watchedProcesses.isEmpty {
                    watchGroup(
                        title: t("Process Exit Alerts"),
                        rows: store.watchedProcesses.map { watch in
                            AnyView(
                                NotificationWatchRow(
                                    badgeTitle: t("Process Exit"),
                                    badgeSystemImage: "bell.fill",
                                    badgeTint: .orange,
                                    title: watch.displayProcessName,
                                    primaryMetadata: processWatchPrimaryMetadataText(for: watch, in: language),
                                    secondaryMetadata: watch.connectionLabel,
                                    disableTitle: t("Disable"),
                                    removeAction: {
                                        store.removeProcessWatch(watch)
                                    }
                                )
                            )
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func watchGroup(title: String, rows: [AnyView]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                row

                if index < rows.count - 1 {
                    Divider()
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func releaseAutoApplySuppression() {
        DispatchQueue.main.async {
            suppressAutoApply = false
        }
    }
}

private struct NotificationWatchRow: View {
    let badgeTitle: String
    let badgeSystemImage: String
    let badgeTint: Color
    let title: String
    let primaryMetadata: String
    let secondaryMetadata: String
    let disableTitle: String
    let removeAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label(badgeTitle, systemImage: badgeSystemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(badgeTint)

                Text(title)
                    .font(.body.weight(.semibold))

                Text(primaryMetadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(secondaryMetadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            DisableWatchButton(title: disableTitle, action: removeAction)
        }
        .padding(.vertical, 2)
    }
}

private struct NotificationHistoryRow: View {
    let entry: NotificationHistoryEntry
    let language: AppInterfaceLanguage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title(in: language))
                    .font(.body.weight(.semibold))

                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            Text(timestampText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var timestampText: String {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = "yyyy.MM.dd. HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }
}

private struct AboutCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct AboutActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.title3.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .labelStyle(.titleAndIcon)
    }
}

private struct AboutInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.subheadline.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }
}

private func processWatchPrimaryMetadataText(for watch: ProcessExitWatch, in language: AppInterfaceLanguage) -> String {
    let userText = watch.user?.isEmpty == false ? watch.user! : "--"
    return language.text("User %@ · PID %@ · GPU %@", userText, watch.pid, watch.gpuIndex)
}

private struct NumericStepperField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String
    let fieldWidth: CGFloat
    var step: Int = 1
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    private func bounded(_ number: Int) -> Int {
        min(max(number, range.lowerBound), range.upperBound)
    }

    private func commitInput() {
        let number = Int(inputText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? value
        value = bounded(number)
        inputText = String(value)
    }

    private var stepperValue: Binding<Int> {
        Binding(
            get: { bounded(Int(inputText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? value) },
            set: { newValue in
                value = bounded(newValue)
                inputText = String(value)
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Stepper("", value: stepperValue, in: range, step: step)
                .labelsHidden()

            TextField("", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: fieldWidth)
                .focused($isInputFocused)
                .onSubmit(commitInput)

            Text(suffix)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .onAppear { inputText = String(value) }
        .onChange(of: isInputFocused) { _, isFocused in
            if !isFocused { commitInput() }
        }
        .onChange(of: value) { _, newValue in
            if !isInputFocused { inputText = String(newValue) }
        }
    }
}

private struct QueryCommandField: View {
    @Binding var command: String
    let defaultCommand: String
    let title: String
    let isEnabled: Bool

    private var displayedCommand: Binding<String> {
        Binding(
            get: { RemoteMetricCommands.singleLineCommand(command) },
            set: { value in
                // Merely focusing a field must not rewrite a saved script.
                if value != RemoteMetricCommands.singleLineCommand(command) {
                    command = value
                }
            }
        )
    }

    var body: some View {
        TextField("", text: displayedCommand, prompt: Text(RemoteMetricCommands.singleLineCommand(defaultCommand)))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
            .lineLimit(1)
            .accessibilityLabel(title)
            .disabled(!isEnabled)
    }
}

private struct DisableWatchButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))

                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(0.1))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.red.opacity(0.24), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
    }
}
