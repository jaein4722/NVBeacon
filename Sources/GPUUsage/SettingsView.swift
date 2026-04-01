import AppKit
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

    private var language: AppInterfaceLanguage {
        draft.resolvedLanguage
    }

    private func t(_ english: String, _ korean: String) -> String {
        language.text(english, korean)
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
            return "0.3.1"
        }
    }

    private var buildVersionText: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    private var bundleIdentifierText: String {
        Bundle.main.bundleIdentifier ?? "com.leejaein.GPUUsage"
    }

    private var repoURL: URL {
        URL(string: "https://github.com/jaein4722/GPUUsage")!
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

            notificationsPane
                .tabItem {
                    Label(t("Notifications", "알림"), systemImage: "bell.badge")
                }

            appearancePane
                .tabItem {
                    Label(t("Appearance", "표시"), systemImage: "menubar.rectangle")
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
                    LabeledContent(t("Saved Host", "저장된 호스트")) {
                        HStack(spacing: 8) {
                            Picker(t("Saved Host", "저장된 호스트"), selection: $selectedSSHConfigAlias) {
                                Text(t("Select a saved host", "저장된 호스트 선택")).tag("")

                                ForEach(sshConfigHosts) { host in
                                    Text(host.displayName).tag(host.alias)
                                }
                            }
                            .labelsHidden()
                            .frame(minWidth: 260, maxWidth: 320)

                            Button(t("Reload", "새로고침")) {
                                reloadSSHConfigHosts()
                            }

                            Button(t("Use", "사용")) {
                                applySSHConfigHost()
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

                LabeledContent(t("SSH Target", "SSH 대상")) {
                    TextField("", text: $draft.sshTarget, prompt: Text("gpu-prod or user@host"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 320)
                }

                LabeledContent(t("Auth Method", "인증 방식")) {
                    Picker(t("Auth Method", "인증 방식"), selection: $draft.sshAuthenticationMode) {
                        ForEach(SSHAuthenticationMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Text(draft.sshAuthenticationMode.detailText(in: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(t("Identity File", "Identity 파일")) {
                    TextField("", text: $draft.sshIdentityFilePath, prompt: Text(t("Optional", "선택 사항")))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 320)
                }

                if draft.sshAuthenticationMode == .passwordBased {
                    LabeledContent(t("SSH Password", "SSH 비밀번호")) {
                        SecureField("", text: $draftPassword, prompt: Text(t("Optional", "선택 사항")))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(width: 240)
                    }
                }

                LabeledContent("SSH Port") {
                    TextField("", text: $draft.sshPort, prompt: Text(t("Optional", "선택 사항")))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 120)
                }
            } header: {
                Text(t("Connection", "연결"))
            } footer: {
                Text(
                    draft.sshAuthenticationMode == .passwordBased
                    ? t("SSH passwords are stored in the macOS Keychain, not in UserDefaults.", "SSH 비밀번호는 UserDefaults가 아니라 macOS Keychain에 저장됩니다.")
                    : t("Key-based mode uses SSH keys and ssh-agent, and does not read Keychain during background polling.", "Key-based 모드에서는 SSH 키와 ssh-agent를 사용하며, background polling 중 Keychain을 읽지 않습니다.")
                )
            }

            Section {
                LabeledContent(t("Refresh Interval", "새로고침 주기")) {
                    NumericStepperField(
                        value: $draft.pollIntervalSeconds,
                        range: 1...300,
                        suffix: "s",
                        fieldWidth: 72
                    )
                }

                LabeledContent(t("Busy Detection", "Busy 판정")) {
                    Picker(t("Busy Detection", "Busy 판정"), selection: $draft.busyDetectionMode) {
                        ForEach(BusyDetectionMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Text(draft.busyDetectionMode.detailText(in: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if draft.busyDetectionMode == .memoryThreshold || draft.busyDetectionMode == .activeProcessOrMemoryThreshold {
                    LabeledContent(t("Busy Memory Threshold", "Busy 메모리 임계치")) {
                        NumericStepperField(
                            value: $draft.busyMemoryThresholdMB,
                            range: 0...10_240,
                            suffix: "MB",
                            fieldWidth: 82
                        )
                    }
                }

                if draft.busyDetectionMode == .utilizationThreshold {
                    LabeledContent(t("Busy Util Threshold", "Busy 사용률 임계치")) {
                        NumericStepperField(
                            value: $draft.busyUtilizationThresholdPercent,
                            range: 0...100,
                            suffix: "%",
                            fieldWidth: 72
                        )
                    }
                }
            } header: {
                Text(t("Polling", "폴링"))
            } footer: {
                Text(t("Changes are applied automatically, and polling restarts immediately.", "설정 변경은 자동으로 저장되고, polling 주기도 즉시 다시 시작됩니다."))
            }
        }
        .formStyle(.grouped)
    }

    private var notificationsPane: some View {
        Form {
            Section {
                LabeledContent(t("Status", "상태")) {
                    Text(store.notificationPermissionState.title(in: language))
                        .foregroundStyle(store.notificationPermissionState == .authorized ? .green : .secondary)
                }

                Text(store.notificationPermissionState.detailText(in: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
            } footer: {
                Text(t("This permission is used for both process exit alerts and GPU idle alerts.", "이 권한은 프로세스 종료 알림과 GPU idle 알림에 함께 사용됩니다."))
            }

            Section {
                LabeledContent(t("Idle Duration", "Idle 시간")) {
                    NumericStepperField(
                        value: $draft.idleNotificationSeconds,
                        range: 1...3_600,
                        suffix: "s",
                        fieldWidth: 72
                    )
                }

                LabeledContent(t("Memory Threshold", "메모리 임계치")) {
                    NumericStepperField(
                        value: $draft.idleMemoryThresholdMB,
                        range: 0...10_240,
                        suffix: "MB",
                        fieldWidth: 88
                    )
                }
            } header: {
                Text(t("GPU Idle Alert", "GPU Idle 알림"))
            } footer: {
                Text(t("Starred GPUs send an alert when `util = 0%` and memory stays below the threshold for the configured duration.", "별표된 GPU는 `util = 0%` 이고 memory가 임계치 이하인 상태가 지정 시간 이상 유지되면 알림을 보냅니다."))
            }

            Section {
                activeWatchesContent
            } header: {
                Text(t("Active Watches", "활성 Watch"))
            }

            Section {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.recentNotificationHistory.isEmpty {
                            Text(t("There is no notification history in the last 24 hours.", "최근 24시간 내 notification 설정 내역이 없습니다."))
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

    private var appearancePane: some View {
        Form {
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

                Text(draft.languagePreference.detailText(in: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(t("Theme", "테마")) {
                    Picker(t("Theme", "테마"), selection: $draft.appearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Text(draft.appearanceMode.detailText(in: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(t("Show Dock icon", "Dock 아이콘 표시"), isOn: $draft.showsDockIcon)

                Text(draft.showsDockIcon
                     ? t("Show the GPUUsage icon in the Dock and App Switcher.", "Dock과 App Switcher에 GPUUsage 아이콘을 표시합니다.")
                     : t("Run as a menu bar app and hide the Dock icon.", "메뉴바 전용 앱처럼 동작하며 Dock 아이콘을 숨깁니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(t("Close popover on outside click", "바깥 클릭 시 팝오버 닫기"), isOn: $draft.closesPopoverOnOutsideClick)

                Text(draft.closesPopoverOnOutsideClick
                     ? t("Automatically close the popover when you click outside it or switch to another app.", "팝오버 바깥 영역이나 다른 앱을 클릭하면 팝오버를 자동으로 닫습니다.")
                     : t("Keep the popover open until you explicitly toggle it again.", "팝오버를 직접 다시 클릭할 때까지 유지합니다."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(t("Display", "표시")) {
                    Picker(t("Display", "표시"), selection: $draft.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases) { mode in
                            Text(mode.title(in: language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                Text(draft.menuBarDisplayMode.detailText(in: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(t("Menu Bar", "메뉴바"))
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
                Text(t("Remote Command", "원격 명령"))
            } footer: {
                Text(t("If `SSH Target` is an alias, the app uses the matching port and user from local `~/.ssh/config`. If PATH is different in a non-interactive shell, use the full path to `nvidia-smi`.", "`SSH Target`에 alias를 넣으면 로컬 `~/.ssh/config`의 포트와 유저가 적용됩니다. PATH 문제가 있으면 `nvidia-smi` 대신 전체 경로를 넣으세요."))
            }

            Section {
                Button(t("Reload Current Settings", "현재 설정 다시 불러오기")) {
                    loadCurrentSettings()
                }

                Button(t("Clear Saved Settings", "저장된 설정 지우기"), role: .destructive) {
                    store.resetConfiguration()
                    loadCurrentSettings()
                }
            } header: {
                Text(t("Saved State", "저장 상태"))
            } footer: {
                Text(t("`Clear Saved Settings` removes saved settings from UserDefaults and the SSH password from Keychain.", "`Clear Saved Settings`는 UserDefaults에 저장된 설정과 Keychain의 SSH 비밀번호를 함께 지웁니다."))
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

                    Text("GPUUsage")
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
                            Label("Repository", systemImage: "shippingbox")
                        }

                        Link(destination: profileURL) {
                            Label("GitHub Profile", systemImage: "person.crop.circle")
                        }
                    }
                    .labelStyle(.titleAndIcon)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)

                AboutCard(title: t("Build Information", "빌드 정보")) {
                    AboutInfoRow(title: t("Version", "버전"), value: appVersionText)
                    AboutInfoRow(title: t("Build", "빌드"), value: buildVersionText)
                    AboutInfoRow(title: t("Bundle Identifier", "번들 식별자"), value: bundleIdentifierText)
                    AboutInfoRow(title: t("Repository", "저장소"), value: "github.com/jaein4722/GPUUsage")
                    AboutInfoRow(title: t("Developer", "개발자"), value: "github.com/jaein4722")
                }

                AboutCard(title: t("Current Configuration", "현재 설정")) {
                    AboutInfoRow(
                        title: t("Current Target", "현재 대상"),
                        value: store.settings.isConfigured ? store.settings.sshTarget : t("Not configured", "미설정")
                    )
                    AboutInfoRow(
                        title: t("Authentication", "인증 방식"),
                        value: store.settings.sshAuthenticationMode.title(in: language)
                    )
                    AboutInfoRow(
                        title: t("Refresh Interval", "새로고침 주기"),
                        value: t("\(store.settings.pollIntervalSeconds) seconds", "\(store.settings.pollIntervalSeconds)초")
                    )
                    AboutInfoRow(title: t("Menu Bar", "메뉴바"), value: store.settings.menuBarDisplayMode.title(in: language))
                    AboutInfoRow(title: t("Language", "언어"), value: store.settings.languagePreference.title(in: language))
                    AboutInfoRow(title: t("Theme", "테마"), value: store.settings.appearanceMode.title(in: language))
                    AboutInfoRow(
                        title: t("Dock Icon", "Dock 아이콘"),
                        value: store.settings.showsDockIcon ? t("Visible", "표시") : t("Hidden", "숨김")
                    )
                    AboutInfoRow(
                        title: t("Notifications", "알림"),
                        value: store.notificationPermissionState.title(in: language)
                    )
                    AboutInfoRow(
                        title: t("Busy Detection", "Busy 판정"),
                        value: store.settings.busyDetectionMode.title(in: language)
                    )
                }

                AboutCard(title: t("Runtime Snapshot", "현재 상태")) {
                    AboutInfoRow(title: t("Process Watches", "프로세스 감시"), value: "\(store.watchedProcesses.count)")
                    AboutInfoRow(title: t("GPU Idle Watches", "GPU idle 감시"), value: "\(store.watchedIdleGPUs.count)")

                    if let snapshot = store.snapshot {
                        let busyCount = snapshot.busyCount(using: store.settings)
                        AboutInfoRow(title: t("Visible GPUs", "표시 중인 GPU"), value: "\(snapshot.gpus.count)")
                        AboutInfoRow(title: t("Busy GPUs", "사용 중인 GPU"), value: "\(busyCount)")
                        AboutInfoRow(title: t("Processes", "프로세스"), value: "\(snapshot.totalProcessCount)")
                        AboutInfoRow(title: t("Average Utilization", "평균 사용률"), value: "\(snapshot.averageUtilization)%")
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
            Text(t("There are no configured notification watches.", "현재 설정된 notification watch가 없습니다."))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if !store.watchedIdleGPUs.isEmpty {
                    watchGroup(
                        title: t("GPU Idle Alerts", "GPU Idle 알림"),
                        rows: store.watchedIdleGPUs.map { watch in
                            AnyView(
                                NotificationWatchRow(
                                    badgeTitle: t("GPU Idle", "GPU Idle"),
                                    badgeSystemImage: "star.fill",
                                    badgeTint: .yellow,
                                    title: watch.title,
                                    primaryMetadata: watch.subtitle,
                                    secondaryMetadata: t("Idle \(draft.idleNotificationSeconds)s · <=\(draft.idleMemoryThresholdMB)MB", "Idle \(draft.idleNotificationSeconds)초 · <=\(draft.idleMemoryThresholdMB)MB"),
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
