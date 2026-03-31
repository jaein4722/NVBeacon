import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: GPUUsageStore
    @State private var draft = AppSettings()
    @State private var draftPassword = ""
    @State private var sshConfigHosts = SSHConfigLoader.loadHosts()
    @State private var selectedSSHConfigAlias = ""
    @State private var autoApplyRevision = 0
    @State private var suppressAutoApply = true

    private var selectedSSHConfigHost: SSHConfigHost? {
        sshConfigHosts.first { $0.alias == selectedSSHConfigAlias }
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
            return "0.2.4"
        }
    }

    var body: some View {
        TabView {
            generalPane
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            notificationsPane
                .tabItem {
                    Label("Notifications", systemImage: "bell.badge")
                }

            appearancePane
                .tabItem {
                    Label("Appearance", systemImage: "menubar.rectangle")
                }

            advancedPane
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }

            aboutPane
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 720, height: 560)
        .onAppear {
            reloadSSHConfigHosts()
            loadCurrentSettings()
            Task {
                await store.refreshNotificationPermissionState()
            }
        }
        .onChange(of: draft) { _, _ in
            scheduleAutoApply()
        }
        .onChange(of: draftPassword) { _, _ in
            scheduleAutoApply()
        }
        .task(id: autoApplyRevision) {
            guard autoApplyRevision > 0 else { return }
            try? await Task.sleep(for: .milliseconds(350))
            applyDraftIfNeeded()
        }
    }

    private var generalPane: some View {
        Form {
            Section {
                if !sshConfigHosts.isEmpty {
                    LabeledContent("Saved Host") {
                        HStack(spacing: 8) {
                            Picker("Saved Host", selection: $selectedSSHConfigAlias) {
                                Text("Select a saved host").tag("")

                                ForEach(sshConfigHosts) { host in
                                    Text(host.displayName).tag(host.alias)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 260, maxWidth: 320)

                            Button("Reload") {
                                reloadSSHConfigHosts()
                            }

                            Button("Use") {
                                applySSHConfigHost()
                            }
                            .disabled(selectedSSHConfigHost == nil)
                        }
                    }

                    if let selectedSSHConfigHost {
                        Text(selectedSSHConfigHost.detailSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("SSH Target") {
                    TextField("", text: $draft.sshTarget, prompt: Text("gpu-prod or user@host"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 320)
                }

                LabeledContent("Auth Method") {
                    Picker("Auth Method", selection: $draft.sshAuthenticationMode) {
                        ForEach(SSHAuthenticationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Text(draft.sshAuthenticationMode.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Identity File") {
                    TextField("", text: $draft.sshIdentityFilePath, prompt: Text("Optional"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 320)
                }

                if draft.sshAuthenticationMode == .passwordBased {
                    LabeledContent("SSH Password") {
                        SecureField("", text: $draftPassword, prompt: Text("Optional"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(width: 240)
                    }
                }

                LabeledContent("SSH Port") {
                    TextField("", text: $draft.sshPort, prompt: Text("Optional"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 120)
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(draft.sshAuthenticationMode == .passwordBased
                     ? "SSH 비밀번호는 UserDefaults가 아니라 macOS Keychain에 저장됩니다."
                     : "Key-based 모드에서는 SSH 키와 ssh-agent를 사용하며, background polling 중 Keychain을 읽지 않습니다.")
            }

            Section {
                LabeledContent("Refresh Interval") {
                    NumericStepperField(
                        value: $draft.pollIntervalSeconds,
                        range: 1...300,
                        suffix: "s",
                        fieldWidth: 72
                    )
                }
            } header: {
                Text("Polling")
            } footer: {
                Text("설정 변경은 자동으로 저장되고, polling 주기도 즉시 다시 시작됩니다.")
            }
        }
        .formStyle(.grouped)
    }

    private var notificationsPane: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(store.notificationPermissionState.title)
                        .foregroundStyle(store.notificationPermissionState == .authorized ? .green : .secondary)
                }

                Text(store.notificationPermissionState.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button(store.notificationPermissionState == .authorized ? "Re-check Permission" : "Enable Notifications") {
                        store.requestNotificationPermission()
                    }

                    Button("Refresh Status") {
                        Task {
                            await store.refreshNotificationPermissionState()
                        }
                    }

                    if store.notificationPermissionState == .authorized {
                        Button("Send Test Notification") {
                            store.sendTestNotification()
                        }
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("이 권한은 프로세스 종료 알림과 GPU idle 알림에 함께 사용됩니다.")
            }

            Section {
                LabeledContent("Idle Duration") {
                    NumericStepperField(
                        value: $draft.idleNotificationSeconds,
                        range: 1...3_600,
                        suffix: "s",
                        fieldWidth: 72
                    )
                }

                LabeledContent("Memory Threshold") {
                    NumericStepperField(
                        value: $draft.idleMemoryThresholdMB,
                        range: 0...10_240,
                        suffix: "MB",
                        fieldWidth: 88
                    )
                }
            } header: {
                Text("GPU Idle Alert")
            } footer: {
                Text("별표된 GPU는 `util = 0%` 이고 memory가 임계치 이하인 상태가 지정 시간 이상 유지되면 알림을 보냅니다.")
            }

            Section {
                activeWatchesContent
            } header: {
                Text("Active Watches")
            }

            Section {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.recentNotificationHistory.isEmpty {
                            Text("최근 24시간 내 notification 설정 내역이 없습니다.")
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
                Text("Recent 24 Hours")
            }
        }
        .formStyle(.grouped)
    }

    private var appearancePane: some View {
        Form {
            Section {
                LabeledContent("Theme") {
                    Picker("Theme", selection: $draft.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Text(draft.appearanceMode.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show Dock icon", isOn: $draft.showsDockIcon)

                Text(draft.showsDockIcon
                     ? "Dock과 App Switcher에 GPUUsage 아이콘을 표시합니다."
                     : "메뉴바 전용 앱처럼 동작하며 Dock 아이콘을 숨깁니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Close popover on outside click", isOn: $draft.closesPopoverOnOutsideClick)

                Text(draft.closesPopoverOnOutsideClick
                     ? "팝오버 바깥 영역이나 다른 앱을 클릭하면 팝오버를 자동으로 닫습니다."
                     : "팝오버를 직접 다시 클릭할 때까지 유지합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Display") {
                    Picker("Display", selection: $draft.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Text(draft.menuBarDisplayMode.detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Menu Bar")
            }
        }
        .formStyle(.grouped)
    }

    private var advancedPane: some View {
        Form {
            Section {
                TextField("", text: $draft.remoteCommand, prompt: Text(AppSettings.defaultRemoteCommand))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
            } header: {
                Text("Remote Command")
            } footer: {
                Text("`SSH Target`에 alias를 넣으면 로컬 `~/.ssh/config`의 포트와 유저가 적용됩니다. PATH 문제가 있으면 `nvidia-smi` 대신 전체 경로를 넣으세요.")
            }

            Section {
                Button("Reload Current Settings") {
                    loadCurrentSettings()
                }

                Button("Clear Saved Settings", role: .destructive) {
                    store.resetConfiguration()
                    loadCurrentSettings()
                }
            } header: {
                Text("Saved State")
            } footer: {
                Text("`Clear Saved Settings`는 UserDefaults에 저장된 설정과 Keychain의 SSH 비밀번호를 함께 지웁니다.")
            }
        }
        .formStyle(.grouped)
    }

    private var aboutPane: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    Text(appVersionText)
                        .monospacedDigit()
                }

                LabeledContent("Current Target") {
                    Text(store.settings.isConfigured ? store.settings.sshTarget : "Not configured")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Refresh Interval") {
                    Text("\(store.settings.pollIntervalSeconds) seconds")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Menu Bar") {
                    Text(store.settings.menuBarDisplayMode.title)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Theme") {
                    Text(store.settings.appearanceMode.title)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Dock Icon") {
                    Text(store.settings.showsDockIcon ? "Visible" : "Hidden")
                        .foregroundStyle(.secondary)
                }

                if let snapshot = store.snapshot {
                    LabeledContent("Visible GPUs") {
                        Text("\(snapshot.gpus.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Processes") {
                        Text("\(snapshot.totalProcessCount)")
                            .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("GPUUsage")
            }

            Section {
                Text("로컬 Mac에서 `ssh`를 실행하고 원격 서버에서 `nvidia-smi`를 호출합니다.")
                Text("기본값은 키 기반 인증이며, 필요할 때만 비밀번호 인증을 켤 수 있습니다.")
                Text("프로세스 상세는 `nvidia-smi`와 `ps`를 함께 조회해 user, pid, command를 보여줍니다.")
            } header: {
                Text("How It Works")
            }
        }
        .formStyle(.grouped)
    }

    private func scheduleAutoApply() {
        guard !suppressAutoApply else { return }
        autoApplyRevision += 1
    }

    private func applyDraftIfNeeded() {
        guard !suppressAutoApply else { return }

        let normalizedDraft = draft.normalized()
        let trimmedPassword = draftPassword.trimmingCharacters(in: .newlines)

        store.applySettings(normalizedDraft, password: trimmedPassword)
    }

    private func loadCurrentSettings() {
        suppressAutoApply = true
        let currentSettings = store.settings

        if sshConfigHosts.contains(where: { $0.alias == currentSettings.sshTarget }) {
            selectedSSHConfigAlias = currentSettings.sshTarget
        } else if selectedSSHConfigAlias.isEmpty {
            selectedSSHConfigAlias = sshConfigHosts.first?.alias ?? ""
        }

        if let selectedSSHConfigHost, selectedSSHConfigHost.alias == currentSettings.sshTarget {
            draft = selectedSSHConfigHost.backfillingMissingFields(in: currentSettings)
        } else {
            draft = currentSettings
        }

        draftPassword = draft.sshAuthenticationMode == .passwordBased ? store.loadSavedPassword() : ""
        releaseAutoApplySuppression()
    }

    private func reloadSSHConfigHosts() {
        sshConfigHosts = SSHConfigLoader.loadHosts()

        if selectedSSHConfigAlias.isEmpty || !sshConfigHosts.contains(where: { $0.alias == selectedSSHConfigAlias }) {
            selectedSSHConfigAlias = sshConfigHosts.first?.alias ?? ""
        }
    }

    private func applySSHConfigHost() {
        guard let selectedSSHConfigHost else { return }
        draft = selectedSSHConfigHost.apply(to: draft)
    }

    @ViewBuilder
    private var activeWatchesContent: some View {
        if store.watchedIdleGPUs.isEmpty && store.watchedProcesses.isEmpty {
            Text("현재 설정된 notification watch가 없습니다.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !store.watchedIdleGPUs.isEmpty {
                    watchGroup(
                        title: "GPU Idle Alerts",
                        rows: store.watchedIdleGPUs.map { watch in
                            AnyView(
                                NotificationWatchRow(
                                    badgeTitle: "GPU Idle",
                                    badgeSystemImage: "star.fill",
                                    badgeTint: .yellow,
                                    title: watch.title,
                                    primaryMetadata: watch.subtitle,
                                    secondaryMetadata: "Idle \(draft.idleNotificationSeconds)s · <=\(draft.idleMemoryThresholdMB)MB",
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
                        title: "Process Exit Alerts",
                        rows: store.watchedProcesses.map { watch in
                            AnyView(
                                NotificationWatchRow(
                                    badgeTitle: "Process Exit",
                                    badgeSystemImage: "bell.fill",
                                    badgeTint: .orange,
                                    title: watch.displayProcessName,
                                    primaryMetadata: processWatchPrimaryMetadataText(for: watch),
                                    secondaryMetadata: watch.connectionLabel,
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

            DisableWatchButton(action: removeAction)
        }
        .padding(.vertical, 2)
    }
}

private struct NotificationHistoryRow: View {
    let entry: NotificationHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
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
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy.MM.dd. HH:mm:ss"
        return formatter.string(from: entry.timestamp)
    }
}

private func processWatchPrimaryMetadataText(for watch: ProcessExitWatch) -> String {
    let userText = watch.user?.isEmpty == false ? watch.user! : "--"
    return "User \(userText) · PID \(watch.pid) · GPU \(watch.gpuIndex)"
}

private struct NumericStepperField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let suffix: String
    let fieldWidth: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Stepper("", value: $value, in: range)
                .labelsHidden()

            TextField("", value: $value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: fieldWidth)
                .onChange(of: value) { _, newValue in
                    value = min(max(newValue, range.lowerBound), range.upperBound)
                }

            Text(suffix)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}

private struct DisableWatchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))

                Text("Disable")
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
