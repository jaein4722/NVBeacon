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

    private func t(_ english: String, _ korean: String) -> String {
        language.text(english, korean)
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
            return "0.8.1"
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
                    Label(t("General", "일반"), systemImage: "gearshape")
                }

            serversPane
                .tabItem {
                    Label(t("Servers", "서버"), systemImage: "server.rack")
                }

            monitoringPane
                .tabItem {
                    Label(t("Monitoring", "수집"), systemImage: "waveform.path.ecg")
                }

            notificationsPane
                .tabItem {
                    Label(t("Notifications", "알림"), systemImage: "bell.badge")
                }

            displayPane
                .tabItem {
                    Label(t("Display", "표시"), systemImage: "menubar.rectangle")
                }

            advancedPane
                .tabItem {
                    Label(t("Advanced", "고급"), systemImage: "slider.horizontal.3")
                }

            aboutPane
                .tabItem {
                    Label(t("About", "정보"), systemImage: "info.circle")
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
        .alert(t("Password-Based Authentication", "비밀번호 기반 인증"), isPresented: $showPasswordAuthWarning) {
            Button(t("Do Not Show Again", "다시 보지 않기")) {
                store.acknowledgePasswordAuthWarning(skipFutureWarnings: true)
                enablePasswordAuthAfterWarning()
            }

            Button(t("Continue", "계속")) {
                store.acknowledgePasswordAuthWarning(skipFutureWarnings: false)
                enablePasswordAuthAfterWarning()
            }

            Button(t("Cancel", "취소"), role: .cancel) {
                pendingPasswordAuthServerID = nil
            }
        } message: {
            Text(
                t(
                    "Password-based authentication stores the password in Keychain, then keeps it in memory for the current app session after you unlock it once. This is less secure than SSH keys and should be used only when key-based authentication is not available.",
                    "비밀번호 기반 인증은 비밀번호를 키체인에 저장한 뒤, 한 번 해제하면 현재 앱 세션 동안 메모리에 유지합니다. 이는 SSH 키 기반 인증보다 덜 안전하므로 키 기반 인증을 사용할 수 없을 때만 권장됩니다."
                )
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
                utilityNotice = t("Server settings exported.", "서버 설정을 내보냈습니다.")
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
        .alert(t("Unable to Complete Action", "작업을 완료할 수 없습니다"), isPresented: Binding(
            get: { utilityError != nil },
            set: { if !$0 { utilityError = nil } }
        )) {
            Button(t("OK", "확인"), role: .cancel) { utilityError = nil }
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
                    t("Launch NVBeacon at login", "로그인 시 NVBeacon 실행"),
                    isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { launchAtLoginManager.setEnabled($0) }
                    )
                )
                .disabled(!launchAtLoginManager.canConfigure)

                LabeledContent {
                    Button(t("Refresh", "새로고침")) {
                        launchAtLoginManager.refreshStatus()
                    }
                    .disabled(!launchAtLoginManager.canConfigure)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Startup status", "시작 상태"))
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
                Text(t("Startup", "시작"))
            }

            Section {
                Toggle(
                    t("Check for updates automatically", "업데이트 자동 확인"),
                    isOn: Binding(
                        get: { appUpdater.automaticallyChecksForUpdates },
                        set: { appUpdater.setAutomaticallyChecksForUpdates($0) }
                    )
                )
                .disabled(!appUpdater.availability.isAvailable)

                Toggle(
                    t("Download updates automatically", "업데이트 자동 다운로드"),
                    isOn: Binding(
                        get: { appUpdater.automaticallyDownloadsUpdates },
                        set: { appUpdater.setAutomaticallyDownloadsUpdates($0) }
                    )
                )
                .disabled(!appUpdater.availability.isAvailable || !appUpdater.automaticallyChecksForUpdates)

                LabeledContent {
                    Button(t("Check Now", "지금 확인")) {
                        appUpdater.checkForUpdates()
                    }
                    .disabled(!appUpdater.canCheckForUpdates)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Check for updates", "업데이트 확인"))
                        Text(lastUpdateCheckText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear { appUpdater.refreshLastUpdateCheckDate() }
            } header: {
                Text(t("Updates", "업데이트"))
            }

            Section {
                LabeledContent(t("Language", "언어")) {
                    Picker(t("Language", "언어"), selection: $draft.languagePreference) {
                        ForEach(AppLanguagePreference.allCases) { preference in
                            Text(preference.title(in: language)).tag(preference)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Toggle(t("Show Dock icon", "Dock 아이콘 표시"), isOn: $draft.showsDockIcon)
            } header: {
                Text(t("App", "앱"))
            }
        }
        .formStyle(.grouped)
    }

    private var serversPane: some View {
        Form {
            Section {
                serverPickerRow
            } header: {
                Text(t("Servers", "서버"))
            } footer: {
                Text(t("The popover uses this server order.", "팝오버는 이 서버 순서를 사용합니다."))
            }

            Section {
                addServerRow
            } header: {
                Text(t("Add Server", "서버 추가"))
            }

            Section {
                selectedServerEditor
            } header: {
                Text(t("Selected Server", "선택한 서버"))
            }

            Section {
                QueryCommandField(
                    command: selectedServerStringBinding(\.remoteCommand, defaultValue: AppSettings.defaultRemoteCommand),
                    defaultCommand: AppSettings.defaultRemoteCommand,
                    title: t("GPU Query Command", "GPU 조회 명령"),
                    isEnabled: selectedServer != nil
                )
            } header: {
                Text(t("GPU Query Command", "GPU 조회 명령"))
            } footer: {
                Text(t("Applies to the selected server. Leave empty to restore the default command.", "선택한 서버에 적용됩니다. 비워 두면 기본 명령으로 돌아갑니다."))
            }

            Section {
                QueryCommandField(
                    command: selectedServerStringBinding(\.hostCommand, defaultValue: AppSettings.defaultHostCommand),
                    defaultCommand: AppSettings.defaultHostCommand,
                    title: t("Host Information Query Command", "호스트 정보 조회 명령"),
                    isEnabled: selectedServer != nil
                )
            } header: {
                Text(t("Host Information Query Command", "호스트 정보 조회 명령"))
            } footer: {
                Text(t("Collects CPU, RAM/Swap, and network for the selected server in the same SSH refresh. Keep the section markers and collection switches when customizing. Leave empty to restore the default command.", "선택한 서버의 CPU·RAM/Swap·네트워크를 같은 SSH 새로고침에서 수집합니다. 수정할 때 영역 구분자와 항목별 수집 조건을 유지하세요. 비워 두면 기본 명령으로 돌아갑니다."))
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
                        suffix: "s",
                        fieldWidth: 72
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Refresh interval", "새로고침 주기"))
                        Text(t("1–300 s · Default 10 s", "1–300초 · 기본값 10초"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("Collection", "수집"))
            } footer: {
                Text(t("Applies to all servers.", "모든 서버에 적용됩니다."))
            }

            Section {
                LabeledContent {
                    Picker(t("Busy GPU detection", "사용 중 판정"), selection: $draft.busyDetectionMode) {
                        ForEach(BusyDetectionMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Busy GPU detection", "사용 중 판정"))
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
                            Text(t("Memory threshold", "메모리 기준"))
                            Text(t("0–10,240 MB · Default 50 MB", "0–10,240MB · 기본값 50MB"))
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
                            Text(t("Utilization threshold", "사용률 기준"))
                            Text(t("0–100% · Default 10%", "0–100% · 기본값 10%"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle(isOn: $draft.highlightsMyProcesses) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Highlight my processes", "내 프로세스 강조"))
                        Text(t("Detect the SSH user's processes and highlight matching GPUs and rows. Turning this off also skips the extra owner checks.", "SSH 사용자의 프로세스를 찾아 해당 GPU와 행을 강조합니다. 끄면 추가 소유자 확인도 하지 않습니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("GPUs and Processes", "GPU와 프로세스"))
            }

            Section {
                Toggle(t("Collect host information", "호스트 정보 수집"), isOn: $draft.collectsHostInfo)
                Toggle("CPU", isOn: $draft.collectsHostCPU)
                    .disabled(!draft.collectsHostInfo)
                Toggle(t("Memory (RAM / Swap)", "메모리 (RAM / Swap)"), isOn: $draft.collectsHostMemory)
                    .disabled(!draft.collectsHostInfo)
                Toggle(t("Network", "네트워크"), isOn: $draft.showsNetworkUsage)
                    .disabled(!draft.collectsHostInfo)
            } header: {
                Text(t("Host Information", "호스트 정보"))
            } footer: {
                Text(t("Disabled items are not collected. Collapsing a server's host information in the popover only hides it; collection continues.", "끈 항목은 수집하지 않습니다. 팝오버에서 호스트 정보를 접으면 화면에서만 숨겨지고 수집은 계속됩니다."))
            }

            Section {
                Toggle(isOn: gpuHistoryRecordingBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Record GPU history", "GPU 기록 저장"))
                        Text(t("Keep 24 hours of per-user GPU utilization on this Mac. Open it from the chart button in the popover.", "이 Mac에 최근 24시간의 사용자별 GPU 사용률을 저장합니다. 팝오버의 차트 버튼으로 엽니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Button(t("Delete History…", "기록 삭제…"), role: .destructive) {
                        showsDeleteGPUHistoryConfirmation = true
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Saved history", "저장된 기록"))
                        Text(t("Turning recording off keeps the saved history until you delete it.", "기록을 꺼도 저장된 기록은 삭제할 때까지 남아 있습니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("GPU History", "GPU 기록"))
            } footer: {
                Text(t("Each server runs nvidia-smi pmon at most once a minute while recording.", "기록하는 동안 서버마다 최대 1분에 한 번 nvidia-smi pmon을 실행합니다."))
            }
        }
        .formStyle(.grouped)
        .alert(t("Record GPU history?", "GPU 기록을 저장할까요?"), isPresented: $showsGPUHistoryConfirmation) {
            Button(t("Record", "저장")) {
                draft.recordsGPUHistory = true
            }
            Button(t("Cancel", "취소"), role: .cancel) {}
        } message: {
            Text(t("NVBeacon will keep 24 hours of per-user GPU utilization on this Mac, including the user names of other people on shared servers. Each server runs nvidia-smi pmon (about one second) at most once a minute. Storage is small: about 0.3 MB per GPU. You can delete the history at any time.",
                   "이 Mac에 최근 24시간의 사용자별 GPU 사용률을 저장합니다. 공용 서버라면 다른 사용자의 이름도 함께 저장됩니다. 서버마다 최대 1분에 한 번 nvidia-smi pmon(약 1초)을 실행합니다. 저장 공간은 GPU 하나당 약 0.3MB로 작습니다. 기록은 언제든 삭제할 수 있습니다."))
        }
        .alert(t("Delete GPU history?", "GPU 기록을 삭제할까요?"), isPresented: $showsDeleteGPUHistoryConfirmation) {
            Button(t("Delete", "삭제"), role: .destructive) {
                Task { await store.deleteGPUHistory() }
            }
            Button(t("Cancel", "취소"), role: .cancel) {}
        } message: {
            Text(t("All saved GPU history on this Mac will be deleted. This cannot be undone.",
                   "이 Mac에 저장된 GPU 기록이 모두 삭제됩니다. 되돌릴 수 없습니다."))
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
                LabeledContent(t("Status", "상태")) {
                    Text(store.notificationPermissionState.title(in: language))
                        .foregroundStyle(store.notificationPermissionState == .authorized ? .green : .secondary)
                }

                HStack(spacing: 8) {
                    Button(store.notificationPermissionState == .authorized ? t("Re-check Permission", "권한 다시 확인") : t("Enable Notifications", "알림 권한 허용")) {
                        store.requestNotificationPermission()
                    }

                    Button(t("Refresh Status", "상태 새로고침")) {
                        Task {
                            await store.refreshNotificationPermissionState()
                        }
                    }

                    if store.notificationPermissionState == .authorized {
                        Button(t("Send Test Notification", "테스트 알림 보내기")) {
                            store.sendTestNotification()
                        }
                    }
                }
            } header: {
                Text(t("Permission", "권한"))
            }

            Section {
                LabeledContent {
                    NumericStepperField(
                        value: $draft.idleNotificationSeconds,
                        range: 1...3_600,
                        suffix: "s",
                        fieldWidth: 72
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Idle duration", "유휴 시간"))
                        Text(t("1–3,600 s · Default 300 s", "1–3,600초 · 기본값 300초"))
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
                        Text(t("Memory threshold", "메모리 기준"))
                        Text(t("0–10,240 MB · Default 50 MB", "0–10,240MB · 기본값 50MB"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("GPU Idle Alert", "GPU 유휴 알림"))
            } footer: {
                Text(t("Starred GPUs send an alert when they stay idle this long with memory at or below the threshold.", "별표한 GPU가 이 시간 동안 기준 이하의 메모리로 쉬고 있으면 알림을 보냅니다."))
            }

            Section {
                activeWatchesContent
            } header: {
                Text(t("Active Watches", "감시 중"))
            }

            Section {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.recentNotificationHistory.isEmpty {
                            Text(t("There is no notification history in the last 24 hours.", "최근 24시간 동안 알림 기록이 없습니다."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(store.recentNotificationHistory.enumerated()), id: \.element.id) { index, entry in
                                NotificationHistoryRow(entry: entry)

                                if index < store.recentNotificationHistory.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 150, maxHeight: 240)
            } header: {
                Text(t("Recent 24 Hours", "최근 24시간"))
            }
        }
        .formStyle(.grouped)
    }

    private var displayPane: some View {
        Form {
            Section {
                LabeledContent {
                    Picker(t("Menu bar text", "메뉴바 텍스트"), selection: $draft.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Menu bar text", "메뉴바 텍스트"))
                        Text(draft.menuBarDisplayMode.detailText(in: language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Picker(t("Display mode", "표시 방식"), selection: $draft.displayMode) {
                        ForEach(MonitorDisplayMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Display mode", "표시 방식"))
                        Text(t("Window keeps NVBeacon open like a normal app window.", "창은 NVBeacon을 일반 앱 창처럼 계속 띄워 둡니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if draft.displayMode == .window {
                    Toggle(t("Keep window on top", "창을 항상 위에 표시"), isOn: $draft.keepsWindowOnTop)
                }

                LabeledContent(t("Theme", "테마")) {
                    Picker(t("Theme", "테마"), selection: $draft.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            } header: {
                Text(t("Menu Bar and Window", "메뉴바와 창"))
            }

            Section {
                LabeledContent {
                    NumericStepperField(
                        value: $draft.popoverWidth,
                        range: AppSettings.popoverWidthRange,
                        suffix: "pt",
                        fieldWidth: 72,
                        step: 20
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Width", "너비"))
                        Text(t("480–800 pt · Default 500 pt", "480–800pt · 기본값 500pt"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent {
                    Picker(t("Height", "높이"), selection: $draft.popoverHeightMode) {
                        ForEach(PopoverHeightMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text(t("Height", "높이"))
                }

                if draft.popoverHeightMode == .fixed {
                    LabeledContent {
                        NumericStepperField(
                            value: $draft.popoverHeight,
                            range: AppSettings.popoverHeightRange,
                            suffix: "pt",
                            fieldWidth: 72,
                            step: 20
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t("Fixed height", "고정 높이"))
                            Text(t("320–1100 pt · Default 600 pt", "320–1100pt · 기본값 600pt"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle(isOn: $draft.closesPopoverOnOutsideClick) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t("Close on outside click", "바깥을 클릭하면 닫기"))
                        Text(t("Also closes when you switch to another app.", "다른 앱으로 전환해도 닫습니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(t("Popover", "팝오버"))
            }
        }
        .formStyle(.grouped)
    }

    private var advancedPane: some View {
        Form {
            Section {
                HStack {
                    Button(t("Export Servers…", "서버 내보내기…"), action: exportServerBackup)
                        .disabled(draft.configuredServers.isEmpty || isReadingBackup || isPreparingExport)
                    Button(t("Import Servers…", "서버 가져오기…")) { showsServerImporter = true }
                        .disabled(isReadingBackup || isPreparingExport)
                    if isReadingBackup || isPreparingExport { ProgressView().controlSize(.small) }
                }
                Button(t("Transfer All Servers to iPhone…", "iPhone으로 모든 서버 전송…")) { utilitySheet = .transfer }
                    .disabled(draft.configuredServers.isEmpty || isReadingBackup || isPreparingExport)
                if let utilityNotice {
                    Text(utilityNotice).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(t("Server Backup and Transfer", "서버 백업과 전송"))
            } footer: {
                Text(t(
                    "Exports host names, key-file paths and remote commands. Keychain passwords, private-key contents and notification watches are excluded. Imports add disabled servers without replacing existing settings.",
                    "호스트·키 파일 경로·원격 명령을 내보냅니다. 키체인 비밀번호·개인 키 내용·알림 감시는 제외됩니다. 가져온 서버는 비활성 상태로 추가되며 기존 설정을 덮어쓰지 않습니다."
                ))
            }

            Section {
                Button(t("Copy Diagnostic Information…", "진단 정보 복사…"), action: showDiagnostics)
            } header: {
                Text(t("Support", "문제 신고"))
            } footer: {
                Text(t("Preview a report of the current app and collection state. No additional SSH commands are run.", "앱과 수집 상태를 미리 확인하고 복사합니다. 추가 SSH 명령은 실행하지 않습니다."))
            }

            Section {
                Button(t("Reload Current Settings", "현재 설정 다시 불러오기")) {
                    loadCurrentSettings()
                }

                Button(t("Clear Saved Settings…", "저장된 설정 지우기…"), role: .destructive) {
                    showsResetConfirmation = true
                }
                .confirmationDialog(
                    t("Clear all saved settings?", "저장된 설정을 모두 지울까요?"),
                    isPresented: $showsResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(t("Clear Saved Settings", "저장된 설정 지우기"), role: .destructive) {
                        store.resetConfiguration()
                        loadCurrentSettings()
                    }
                } message: {
                    Text(t("This removes every server, its saved password in Keychain, all GPU and process alerts, and the notification history. It cannot be undone.",
                           "모든 서버와 키체인에 저장된 비밀번호, GPU·프로세스 알림, 알림 기록이 삭제됩니다. 되돌릴 수 없습니다."))
                }
            } header: {
                Text(t("Saved Settings", "저장된 설정"))
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
                    .help(t("Open the GitHub repository", "GitHub 저장소 열기"))

                    Text("NVBeacon")
                        .font(.title2.weight(.semibold))

                    Text(t("Remote NVIDIA GPU monitoring from your macOS menu bar.", "macOS 메뉴바에서 원격 NVIDIA GPU를 확인하는 앱입니다."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("Version \(appVersionText)")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Link(destination: repoURL) {
                            AboutActionLabel(title: t("Repository", "저장소"), systemImage: "shippingbox")
                        }
                        .buttonStyle(.plain)

                        Link(destination: profileURL) {
                            AboutActionLabel(title: t("GitHub Profile", "GitHub 프로필"), systemImage: "person.crop.circle")
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        appUpdater.checkForUpdates()
                    } label: {
                        AboutActionLabel(
                            title: t("Check for Updates…", "업데이트 확인…"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!appUpdater.canCheckForUpdates)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)

                AboutCard(title: t("Build Information", "빌드 정보")) {
                    AboutInfoRow(title: t("Version", "버전"), value: appVersionText)
                    AboutInfoRow(title: t("Build", "빌드"), value: buildVersionText)
                    AboutInfoRow(title: t("Bundle Identifier", "번들 식별자"), value: bundleIdentifierDisplayText)
                    AboutInfoRow(title: t("Repository", "저장소"), value: "github.com/jaein4722/NVBeacon")
                    AboutInfoRow(title: t("Developer", "개발자"), value: "github.com/jaein4722")
                }

                AboutCard(title: t("Runtime Snapshot", "현재 상태")) {
                    AboutInfoRow(title: t("Process Watches", "프로세스 감시"), value: "\(store.watchedProcesses.count)")
                    AboutInfoRow(title: t("GPU Idle Watches", "GPU 유휴 감시"), value: "\(store.watchedIdleGPUs.count)")

                    if store.totalGPUCount > 0 {
                        AboutInfoRow(title: t("Visible GPUs", "표시 중인 GPU"), value: "\(store.totalGPUCount)")
                        AboutInfoRow(title: t("Busy GPUs", "사용 중인 GPU"), value: "\(store.fleetBusyCount)")
                        AboutInfoRow(title: t("Processes", "프로세스"), value: "\(store.totalProcessCount)")
                        AboutInfoRow(title: t("Average Utilization", "평균 사용률"), value: "\(store.fleetAverageUtilization)%")
                        AboutInfoRow(title: t("Server Errors", "서버 오류"), value: "\(store.failedServerCount)")
                    } else {
                        Text(t("GPU data has not been loaded yet.", "GPU 데이터가 아직 로드되지 않았습니다."))
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
            return t("Not checked yet", "아직 확인하지 않음")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .korean ? "ko_KR" : "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return t("Last checked: \(formatter.string(from: date))", "마지막 확인: \(formatter.string(from: date))")
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
            utilityNotice = t("Added \(backup.servers.count) disabled servers.", "비활성 서버 \(backup.servers.count)개를 추가했습니다.")
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
        let newServer = ServerConfig(name: t("New Server", "새 서버"))
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
        LabeledContent(t("Current", "현재")) {
            HStack(spacing: 8) {
                Picker(t("Server", "서버"), selection: $selectedServerID) {
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
                .help(t("Move selected server up", "선택된 서버를 위로 이동"))

                Button {
                    moveSelectedServerDown()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(selectedServerIndex == nil || selectedServerIndex == draft.servers.count - 1)
                .help(t("Move selected server down", "선택된 서버를 아래로 이동"))

                Button(role: .destructive) {
                    removeSelectedServer()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selectedServer == nil)
                .help(t("Remove selected server", "선택된 서버 삭제"))
            }
        }
    }

    private var addServerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(t("New Server", "새 서버")) {
                    addBlankServer()
                }

                if !sshConfigHosts.isEmpty {
                    Button(t("Reload Saved Hosts", "저장된 호스트 새로고침")) {
                        reloadSSHConfigHosts()
                    }
                }
            }

            if !sshConfigHosts.isEmpty {
                savedHostAddRow
            } else {
                Text(t("No saved hosts were found in ~/.ssh/config.", "~/.ssh/config에서 저장된 호스트를 찾지 못했습니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var savedHostAddRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(t("Saved host", "저장된 호스트")) {
                HStack(spacing: 8) {
                    Picker(t("Saved host", "저장된 호스트"), selection: $selectedSSHConfigAlias) {
                        Text(t("Select a saved host", "저장된 호스트 선택")).tag("")

                        ForEach(sshConfigHosts) { host in
                            Text(host.displayName).tag(host.alias)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 260, maxWidth: 320)

                    Button(t("Add Saved Host", "저장된 호스트 추가")) {
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
            Toggle(t("Enabled", "활성화"), isOn: selectedServerBoolBinding(\.isEnabled))

            LabeledContent(t("Name", "이름")) {
                TextField("", text: selectedServerStringBinding(\.name), prompt: Text(selectedServer.sshTarget.isEmpty ? "GPU Server" : selectedServer.sshTarget))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 240)
            }

            LabeledContent(t("SSH target", "SSH 대상")) {
                TextField("", text: selectedServerStringBinding(\.sshTarget), prompt: Text("gpu-prod or user@host"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 320)
            }

            LabeledContent(t("SSH port", "SSH 포트")) {
                TextField("", text: selectedServerStringBinding(\.sshPort), prompt: Text(t("Optional", "선택 사항")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 120)
            }

            LabeledContent(t("Authentication", "인증 방식")) {
                Picker(t("Authentication", "인증 방식"), selection: selectedServerAuthModeBinding()) {
                    ForEach(SSHAuthenticationMode.allCases) { mode in
                        Text(mode.title(in: language)).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            LabeledContent(t("Key file", "키 파일")) {
                TextField("", text: selectedServerStringBinding(\.sshIdentityFilePath), prompt: Text(t("Optional", "선택 사항")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 320)
            }

            LabeledContent {
                HStack(spacing: 8) {
                    Picker(t("SSH connection", "SSH 연결"), selection: selectedServerConnectionReuseBinding()) {
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
                    .accessibilityLabel(t("About SSH connection reuse", "SSH 연결 재사용 안내"))
                    .popover(isPresented: $showConnectionReuseHelp, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(t("About SSH connection reuse", "SSH 연결 재사용 안내"))
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
                Text(t("SSH connection", "SSH 연결"))
            }

            if selectedServer.sshAuthenticationMode == .passwordBased {
                LabeledContent(t("Password session", "비밀번호 세션")) {
                    Text(selectedPasswordSessionState.title(in: language))
                        .foregroundStyle(passwordSessionTint(for: selectedPasswordSessionState))
                }

                LabeledContent(t("SSH password", "SSH 비밀번호")) {
                    SecureField("", text: $draftPassword, prompt: Text(t("Optional", "선택 사항")))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 240)
                }

                HStack(spacing: 8) {
                    Button(t("Save Password", "비밀번호 저장")) {
                        applyPasswordSettingsImmediately()
                        saveDraftPassword()
                    }
                    .disabled(draftPassword.trimmingCharacters(in: .newlines).isEmpty)

                    Button(t("Unlock Saved Password", "저장된 비밀번호 해제")) {
                        applyPasswordSettingsImmediately()
                        store.unlockSavedPassword(for: selectedServer.id)
                    }
                    .disabled(!selectedPasswordSessionState.supportsUnlockAction)

                    Button(t("Forget Saved Password", "저장된 비밀번호 삭제"), role: .destructive) {
                        applyPasswordSettingsImmediately()
                        store.forgetSavedPassword(for: selectedServer.id)
                    }
                    .disabled(!selectedPasswordSessionState.supportsForgetAction)
                }
            }
            connectionTestRow(for: selectedServer)
        } else {
            Text(t("Add a server to start monitoring remote GPUs.", "원격 GPU 모니터링을 시작하려면 서버를 추가하세요."))
                .foregroundStyle(.secondary)
        }
    }

    private func connectionTestRow(for server: ServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(t("Test Connection", "연결 테스트")) {
                    runConnectionTest(for: server)
                }
                .disabled(testingServerID != nil || server.sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if testingServerID == server.id {
                    ProgressView()
                        .controlSize(.small)
                    Text(t("Connecting…", "연결 중…"))
                        .foregroundStyle(.secondary)
                }
            }

            if testingServerID != server.id, let outcome = connectionTestResults[server.id] {
                switch outcome {
                case .success(let gpuCount):
                    Label(t("Connected · \(gpuCount) GPUs", "연결됨 · GPU \(gpuCount)개"), systemImage: "checkmark.circle.fill")
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
            Text(t("There are no configured notification watches.", "현재 설정된 알림 감시가 없습니다."))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !store.watchedIdleGPUs.isEmpty {
                    watchGroup(
                        title: t("GPU Idle Alerts", "GPU 유휴 알림"),
                        rows: store.watchedIdleGPUs.map { watch in
                            AnyView(
                                NotificationWatchRow(
                                    badgeTitle: t("GPU Idle", "GPU Idle"),
                                    badgeSystemImage: "star.fill",
                                    badgeTint: .yellow,
                                    title: watch.title,
                                    primaryMetadata: watch.subtitle,
                                    secondaryMetadata: t("Idle \(draft.idleNotificationSeconds)s · <=\(draft.idleMemoryThresholdMB)MB", "유휴 \(draft.idleNotificationSeconds)초 · \(draft.idleMemoryThresholdMB)MB 이하"),
                                    disableTitle: t("Disable", "해제"),
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
                        title: t("Process Exit Alerts", "프로세스 종료 알림"),
                        rows: store.watchedProcesses.map { watch in
                            AnyView(
                                NotificationWatchRow(
                                    badgeTitle: t("Process Exit", "프로세스 종료"),
                                    badgeSystemImage: "bell.fill",
                                    badgeTint: .orange,
                                    title: watch.displayProcessName,
                                    primaryMetadata: processWatchPrimaryMetadataText(for: watch),
                                    secondaryMetadata: watch.connectionLabel,
                                    disableTitle: t("Disable", "해제"),
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
    private let language = AppLocalizer.currentLanguage()

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

private func processWatchPrimaryMetadataText(for watch: ProcessExitWatch) -> String {
    let language = AppLocalizer.currentLanguage()
    let userText = watch.user?.isEmpty == false ? watch.user! : "--"
    return language.text("User \(userText) · PID \(watch.pid) · GPU \(watch.gpuIndex)", "사용자 \(userText) · PID \(watch.pid) · GPU \(watch.gpuIndex)")
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
