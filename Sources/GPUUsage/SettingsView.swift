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
                    HStack(spacing: 8) {
                        Stepper("", value: $draft.pollIntervalSeconds, in: 3...300)
                            .labelsHidden()
                        Text("\(draft.pollIntervalSeconds) seconds")
                            .monospacedDigit()
                    }
                    .fixedSize()
                }
            } header: {
                Text("Polling")
            } footer: {
                Text("설정 변경은 자동으로 저장되고, polling 주기도 즉시 다시 시작됩니다.")
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

    private func releaseAutoApplySuppression() {
        DispatchQueue.main.async {
            suppressAutoApply = false
        }
    }
}
