import Combine
import Foundation

private struct GPUIdleWatchTrackingState: Sendable {
    var idleSince: Date?
    var hasHandledCurrentIdleStretch = false
}

private struct ServerRefreshContext: Sendable {
    let serverID: String
    let server: ServerConfig
    let connectionSettings: AppSettings
    let password: String?
    let detectedSSHUsername: String?
    let detectedSSHUserID: Int?
}

private enum ServerRefreshResult: Sendable {
    case success(serverID: String, snapshot: GPUSnapshot, detectedSSHUserID: Int?)
    case failure(serverID: String, message: String)
    case cancelled(serverID: String)
}

@MainActor
final class NVBeaconStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var serverStates: [ServerRuntimeState]
    @Published private(set) var snapshot: GPUSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var notificationPermissionState: NotificationPermissionState = .unsupported
    @Published private(set) var passwordSessionState: SSHPasswordSessionState
    @Published private(set) var loadingProcessDetailGPUIds = Set<String>()
    @Published private(set) var watchedProcesses = [ProcessExitWatch]()
    @Published private(set) var watchedIdleGPUs = [GPUIdleWatch]()
    @Published private(set) var notificationHistory = [NotificationHistoryEntry]()
    @Published private(set) var detectedSSHUsername: String?

    private let fetcher: SSHMetricsFetcher
    private let notificationManager: ProcessExitNotificationManager
    private let userDefaults: UserDefaults
    private let passwordStore: SSHPasswordStore
    private let settingsKey = "nvbeacon.settings"
    private let watchedProcessesKey = "nvbeacon.process_exit_watches"
    private let watchedIdleGPUsKey = "nvbeacon.gpu_idle_watches"
    private let notificationHistoryKey = "nvbeacon.notification_history"
    private let passwordStoredHintKey = "nvbeacon.password_saved_hint"
    private let passwordStoredHintPrefix = "nvbeacon.password_saved_hint."
    private let passwordAuthWarningAcknowledgedKey = "nvbeacon.password_auth_warning_acknowledged"
    private var pollingTask: Task<Void, Never>?
    private var idleWatchTrackingStates = [String: GPUIdleWatchTrackingState]()
    private var unlockedSSHPasswords = [String: String]()
    private var passwordAuthWarningAcknowledgedThisSession = false

    private var language: AppInterfaceLanguage {
        settings.resolvedLanguage
    }

    private func t(_ english: String, _ korean: String) -> String {
        language.text(english, korean)
    }

    init(
        fetcher: SSHMetricsFetcher = SSHMetricsFetcher(),
        notificationManager: ProcessExitNotificationManager = ProcessExitNotificationManager(),
        userDefaults: UserDefaults = .standard
    ) {
        let passwordStore = SSHPasswordStore()
        let settings = Self.loadSettings(from: userDefaults)
        let initialServerStates = Self.initialServerStates(
            for: settings,
            passwordStore: passwordStore,
            userDefaults: userDefaults
        )

        self.fetcher = fetcher
        self.notificationManager = notificationManager
        self.userDefaults = userDefaults
        self.passwordStore = passwordStore
        self.settings = settings
        self.serverStates = initialServerStates
        self.detectedSSHUsername = initialServerStates.first?.detectedSSHUsername
        self.passwordSessionState = initialServerStates.first?.passwordSessionState ?? .notRequired
        self.watchedProcesses = Self.loadWatchedProcesses(from: userDefaults)
        self.watchedIdleGPUs = Self.loadWatchedIdleGPUs(from: userDefaults)
        self.notificationHistory = Self.loadNotificationHistory(from: userDefaults)
        self.lastErrorMessage = settings.isConfigured
            ? Self.initialStatusMessage(for: initialServerStates, language: settings.resolvedLanguage)
            : settings.resolvedLanguage.text("Enter an SSH target to start polling.", "SSH target를 입력하면 polling을 시작합니다.")

        syncAggregateRuntimeState()
        configurePolling(resetState: false)
        Task { [weak self] in
            await self?.refreshNotificationPermissionState()
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    var menuBarTitle: String {
        if settings.menuBarDisplayMode == .iconOnly {
            return ""
        }

        guard settings.isConfigured else { return "GPU --" }

        if totalGPUCount > 0 {
            return menuBarTitleText()
        }

        if isRefreshing {
            return "GPU ..."
        }

        if hasServerError {
            return "GPU !"
        }

        return settings.pollableServers.isEmpty ? "GPU off" : "GPU --"
    }

    var menuBarSymbolName: String {
        if hasServerError && settings.isConfigured {
            return "exclamationmark.triangle.fill"
        }

        return "memorychip.fill"
    }

    var menuBarToolTip: String {
        guard settings.isConfigured else {
            return t("NVBeacon: configure a server to start polling.", "NVBeacon: 서버를 설정하면 polling을 시작합니다.")
        }

        if totalGPUCount > 0 {
            var lines = [
                t(
                    "Average \(fleetAverageUtilization)% · Busy \(fleetBusyCount)/\(totalGPUCount) · Processes \(totalProcessCount)",
                    "평균 \(fleetAverageUtilization)% · 사용중 \(fleetBusyCount)/\(totalGPUCount) · 프로세스 \(totalProcessCount)"
                )
            ]

            let serverLines = serverStates.map { state in
                if let snapshot = state.snapshot {
                    let busyCount = snapshot.busyCount(using: settings)
                    return "\(state.server.displayName): \(snapshot.averageUtilization)% · \(busyCount)/\(snapshot.gpus.count)"
                }

                if let error = state.lastErrorMessage {
                    return "\(state.server.displayName): \(error)"
                }

                return "\(state.server.displayName): --"
            }
            lines.append(contentsOf: serverLines)
            return lines.joined(separator: "\n")
        }

        if isRefreshing {
            return t("NVBeacon: refreshing server status.", "NVBeacon: 서버 상태를 새로 가져오는 중입니다.")
        }

        if let lastErrorMessage {
            return lastErrorMessage
        }

        if settings.pollableServers.isEmpty {
            return t("NVBeacon: no enabled server is ready for polling.", "NVBeacon: polling할 활성 서버가 없습니다.")
        }

        return "NVBeacon"
    }

    var lastUpdatedRelativeText: String? {
        guard let latestSnapshotDate else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: latestSnapshotDate, relativeTo: Date())
    }

    var shouldHighlightMyProcesses: Bool {
        settings.highlightsMyProcesses
    }

    var watchedProcessCount: Int {
        watchedProcesses.count
    }

    var watchedIdleGPUCount: Int {
        watchedIdleGPUs.count
    }

    var watchedNotificationCount: Int {
        watchedProcessCount + watchedIdleGPUCount
    }

    var recentNotificationHistory: [NotificationHistoryEntry] {
        NotificationHistoryEntry.recentEntries(from: notificationHistory)
    }

    var shouldWarnBeforeEnablingPasswordAuth: Bool {
        !passwordAuthWarningAcknowledgedThisSession && !userDefaults.bool(forKey: passwordAuthWarningAcknowledgedKey)
    }

    var configuredServerCount: Int {
        serverStates.count
    }

    var pollableServerCount: Int {
        serverStates.filter { $0.server.isPollable }.count
    }

    var failedServerCount: Int {
        serverStates.filter { $0.lastErrorMessage != nil }.count
    }

    var totalGPUCount: Int {
        serverStates.reduce(0) { $0 + ($1.snapshot?.gpus.count ?? 0) }
    }

    var totalProcessCount: Int {
        serverStates.reduce(0) { $0 + ($1.snapshot?.totalProcessCount ?? 0) }
    }

    var fleetAverageUtilization: Int {
        let allGPUs = serverStates.compactMap(\.snapshot).flatMap(\.gpus)
        guard !allGPUs.isEmpty else { return 0 }
        return allGPUs.map(\.utilization).reduce(0, +) / allGPUs.count
    }

    var fleetBusyCount: Int {
        serverStates.reduce(0) { total, state in
            total + (state.snapshot?.busyCount(using: settings) ?? 0)
        }
    }

    var latestSnapshotDate: Date? {
        serverStates.compactMap { $0.snapshot?.takenAt }.max()
    }

    private var hasServerError: Bool {
        serverStates.contains { $0.lastErrorMessage != nil }
    }

    private func menuBarTitleText() -> String {
        switch settings.menuBarDisplayMode {
        case .averageAndBusy:
            return "GPU \(fleetAverageUtilization)% · \(fleetBusyCount)/\(totalGPUCount)"
        case .averageOnly:
            return "GPU \(fleetAverageUtilization)%"
        case .busyOnly:
            return "GPU \(fleetBusyCount)/\(totalGPUCount)"
        case .iconOnly:
            return ""
        }
    }

    func applySettings(_ newSettings: AppSettings) {
        let normalized = newSettings.normalized()
        guard normalized != settings else { return }

        let previousServerStates = Dictionary(uniqueKeysWithValues: serverStates.map { ($0.id, $0) })
        let previousServerIDs = Set(serverStates.map(\.id))

        settings = normalized
        noticeMessage = nil
        reconcileServerStates(previousServerStates: previousServerStates)

        let currentServerIDs = Set(serverStates.map(\.id))
        for removedServerID in previousServerIDs.subtracting(currentServerIDs) {
            unlockedSSHPasswords.removeValue(forKey: removedServerID)
        }

        reconcileWatchesWithCurrentServers()
        persistSettings()
        syncAggregateRuntimeState()
        configurePolling(resetState: true)
    }

    func savePasswordForCurrentSession(_ password: String) {
        guard let serverID = serverStates.first?.id else { return }
        savePassword(password, for: serverID)
    }

    func savePassword(_ password: String, for serverID: String) {
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        guard let server = server(for: serverID) else { return }
        guard server.sshAuthenticationMode == .passwordBased else { return }
        guard !trimmedPassword.isEmpty else {
            lastErrorMessage = t("Enter an SSH password before saving it.", "SSH 비밀번호를 입력한 뒤 저장하세요.")
            return
        }

        do {
            try passwordStore.savePassword(trimmedPassword, account: server.keychainAccount)
            userDefaults.set(true, forKey: passwordStoredHintKey(for: serverID))
            if serverStates.count == 1 {
                userDefaults.set(true, forKey: passwordStoredHintKey)
            }
            unlockedSSHPasswords[serverID] = trimmedPassword
            updateServerState(serverID) { state in
                state.passwordSessionState = .unlocked
                state.lastErrorMessage = nil
            }
            lastErrorMessage = nil
            noticeMessage = t("SSH password saved and unlocked for this app session.", "SSH 비밀번호를 저장했고 현재 앱 세션에서 해제했습니다.")
            syncAggregateRuntimeState()
            refreshNow()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func unlockSavedPasswordForCurrentSession() {
        guard let serverID = serverStates.first?.id else { return }
        unlockSavedPassword(for: serverID)
    }

    func unlockSavedPassword(for serverID: String) {
        guard let server = server(for: serverID) else { return }
        guard server.sshAuthenticationMode == .passwordBased else { return }

        do {
            let password = try loadPassword(for: server)
            guard !password.isEmpty else {
                userDefaults.set(false, forKey: passwordStoredHintKey(for: serverID))
                unlockedSSHPasswords.removeValue(forKey: serverID)
                updateServerState(serverID) { state in
                    state.passwordSessionState = .missing
                    state.lastErrorMessage = missingPasswordSessionMessage()
                }
                lastErrorMessage = missingPasswordSessionMessage()
                noticeMessage = t("There is no saved SSH password in Keychain.", "Keychain에 저장된 SSH 비밀번호가 없습니다.")
                syncAggregateRuntimeState()
                return
            }

            userDefaults.set(true, forKey: passwordStoredHintKey(for: serverID))
            unlockedSSHPasswords[serverID] = password
            updateServerState(serverID) { state in
                state.passwordSessionState = .unlocked
                state.lastErrorMessage = nil
            }
            lastErrorMessage = nil
            noticeMessage = t("SSH password unlocked for this app session.", "현재 앱 세션에서 SSH 비밀번호를 해제했습니다.")
            syncAggregateRuntimeState()
            refreshNow()
        } catch {
            updateServerState(serverID) { state in
                state.passwordSessionState = hasSavedPasswordHint(for: server) ? .locked : .missing
                state.lastErrorMessage = error.localizedDescription
            }
            lastErrorMessage = error.localizedDescription
            syncAggregateRuntimeState()
        }
    }

    func forgetSavedPassword() {
        guard let serverID = serverStates.first?.id else { return }
        forgetSavedPassword(for: serverID)
    }

    func forgetSavedPassword(for serverID: String) {
        guard let server = server(for: serverID) else { return }

        do {
            try passwordStore.deletePassword(account: server.keychainAccount)
            userDefaults.set(false, forKey: passwordStoredHintKey(for: serverID))
            if serverStates.count == 1 {
                userDefaults.set(false, forKey: passwordStoredHintKey)
            }
            unlockedSSHPasswords.removeValue(forKey: serverID)
            updateServerState(serverID) { state in
                state.passwordSessionState = server.sshAuthenticationMode == .passwordBased ? .missing : .notRequired
                state.lastErrorMessage = server.sshAuthenticationMode == .passwordBased ? missingPasswordSessionMessage() : nil
            }
            lastErrorMessage = server.sshAuthenticationMode == .passwordBased ? missingPasswordSessionMessage() : nil
            noticeMessage = t("Removed the saved SSH password from Keychain.", "Keychain에서 저장된 SSH 비밀번호를 삭제했습니다.")
            syncAggregateRuntimeState()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func acknowledgePasswordAuthWarning(skipFutureWarnings: Bool) {
        passwordAuthWarningAcknowledgedThisSession = true
        if skipFutureWarnings {
            userDefaults.set(true, forKey: passwordAuthWarningAcknowledgedKey)
        }
    }

    func resetConfiguration() {
        pollingTask?.cancel()

        for server in settings.configuredServers {
            try? passwordStore.deletePassword(account: server.keychainAccount)
            userDefaults.removeObject(forKey: passwordStoredHintKey(for: server.id))
        }

        do {
            try passwordStore.deletePassword()
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        settings = AppSettings()
        serverStates = []
        detectedSSHUsername = nil
        unlockedSSHPasswords = [:]
        passwordSessionState = .notRequired
        snapshot = nil
        watchedProcesses = []
        watchedIdleGPUs = []
        idleWatchTrackingStates = [:]
        notificationHistory = []
        userDefaults.removeObject(forKey: settingsKey)
        userDefaults.removeObject(forKey: watchedProcessesKey)
        userDefaults.removeObject(forKey: watchedIdleGPUsKey)
        userDefaults.removeObject(forKey: notificationHistoryKey)
        userDefaults.removeObject(forKey: passwordStoredHintKey)
        lastErrorMessage = t("Enter an SSH target to start polling.", "SSH target를 입력하면 polling을 시작합니다.")
        noticeMessage = nil
        configurePolling(resetState: false)
    }

    func refreshNow() {
        restartPollingAndRefresh(resetErrorState: false)
    }

    func refreshNow(serverID: String) {
        Task {
            await refresh(serverIDs: [serverID])
        }
    }

    func handleSystemWake() {
        restartPollingAndRefresh(resetErrorState: false)
    }

    func loadProcessDetails(for gpuID: Int) {
        guard let serverID = serverStates.first?.id else { return }
        loadProcessDetails(for: gpuID, on: serverID)
    }

    func loadProcessDetails(for gpuID: Int, on serverID: String) {
        Task {
            await refreshProcessDetails(for: gpuID, on: serverID)
        }
    }

    func isLoadingProcessDetails(for gpuID: Int) -> Bool {
        guard let serverID = serverStates.first?.id else { return false }
        return isLoadingProcessDetails(for: gpuID, on: serverID)
    }

    func isLoadingProcessDetails(for gpuID: Int, on serverID: String) -> Bool {
        loadingProcessDetailGPUIds.contains(scopedGPUKey(serverID: serverID, gpuID: gpuID))
    }

    func passwordSessionState(for serverID: String) -> SSHPasswordSessionState {
        serverState(for: serverID)?.passwordSessionState ?? .notRequired
    }

    func isWatchingExit(for process: GPUProcessReading) -> Bool {
        guard let serverID = serverStates.first?.id else { return false }
        return isWatchingExit(for: process, on: serverID)
    }

    func isWatchingExit(for process: GPUProcessReading, on serverID: String) -> Bool {
        guard let server = server(for: serverID) else { return false }
        return watchedProcesses.contains { $0.matches(process) && $0.connectionFingerprint == server.connectionFingerprint }
    }

    func isCurrentUserProcess(_ process: GPUProcessReading) -> Bool {
        guard let serverID = serverStates.first?.id else { return false }
        return isCurrentUserProcess(process, on: serverID)
    }

    func isCurrentUserProcess(_ process: GPUProcessReading, on serverID: String) -> Bool {
        guard settings.highlightsMyProcesses else { return false }
        guard let state = serverState(for: serverID) else { return false }

        if let detectedSSHUserID = state.detectedSSHUserID, let processUserID = process.userID {
            return processUserID == detectedSSHUserID
        }

        guard let detectedSSHUsername = state.detectedSSHUsername else { return false }
        return process.user?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == detectedSSHUsername
    }

    func hasCurrentUserProcess(on gpu: GPUReading) -> Bool {
        guard let serverID = serverStates.first?.id else { return false }
        return hasCurrentUserProcess(on: gpu, on: serverID)
    }

    func hasCurrentUserProcess(on gpu: GPUReading, on serverID: String) -> Bool {
        gpu.processes.contains { isCurrentUserProcess($0, on: serverID) }
    }

    func isWatchingIdle(for gpu: GPUReading) -> Bool {
        guard let serverID = serverStates.first?.id else { return false }
        return isWatchingIdle(for: gpu, on: serverID)
    }

    func isWatchingIdle(for gpu: GPUReading, on serverID: String) -> Bool {
        guard let server = server(for: serverID) else { return false }
        return watchedIdleGPUs.contains { $0.connectionFingerprint == server.connectionFingerprint && $0.matches(gpu) }
    }

    func toggleExitWatch(for process: GPUProcessReading, on gpu: GPUReading) {
        guard let serverID = serverStates.first?.id else { return }
        toggleExitWatch(for: process, on: gpu, serverID: serverID)
    }

    func toggleExitWatch(for process: GPUProcessReading, on gpu: GPUReading, serverID: String) {
        Task {
            await toggleExitWatchTask(for: process, on: gpu, serverID: serverID)
        }
    }

    func toggleIdleWatch(for gpu: GPUReading) {
        guard let serverID = serverStates.first?.id else { return }
        toggleIdleWatch(for: gpu, serverID: serverID)
    }

    func toggleIdleWatch(for gpu: GPUReading, serverID: String) {
        Task {
            await toggleIdleWatchTask(for: gpu, serverID: serverID)
        }
    }

    func removeProcessWatch(_ watch: ProcessExitWatch) {
        guard let existingIndex = watchedProcesses.firstIndex(where: { $0.id == watch.id }) else { return }

        let removedWatch = watchedProcesses.remove(at: existingIndex)
        persistWatchedProcesses()
        noticeMessage = t("Process exit alert disabled.", "프로세스 종료 알림을 해제했습니다.")
        appendNotificationHistory(NotificationHistoryEntry(kind: .watchRemoved, watch: removedWatch))
    }

    func removeIdleWatch(_ watch: GPUIdleWatch) {
        guard let existingIndex = watchedIdleGPUs.firstIndex(where: { $0.id == watch.id }) else { return }

        let removedWatch = watchedIdleGPUs.remove(at: existingIndex)
        idleWatchTrackingStates.removeValue(forKey: removedWatch.id)
        persistWatchedIdleGPUs()
        noticeMessage = t("GPU idle alert disabled.", "GPU idle 알림을 해제했습니다.")
        appendNotificationHistory(NotificationHistoryEntry(kind: .idleWatchRemoved, idleWatch: removedWatch))
    }

    func refreshNotificationPermissionState() async {
        notificationPermissionState = await notificationManager.authorizationStatus()
    }

    func requestNotificationPermission() {
        Task {
            let state = await notificationManager.requestAuthorization()
            notificationPermissionState = state

            let connectionLabel = serverStates.first?.server.displayName
            switch state {
            case .authorized:
                noticeMessage = t("macOS notification permission enabled.", "macOS 알림 권한을 허용했습니다.")
                appendNotificationHistory(NotificationHistoryEntry(kind: .permissionEnabled, connectionLabel: connectionLabel))
            case .denied:
                noticeMessage = t("Notification permission was denied. Enable NVBeacon notifications in System Settings.", "알림 권한이 거부되었습니다. 시스템 설정에서 NVBeacon 알림을 허용하세요.")
                appendNotificationHistory(NotificationHistoryEntry(kind: .permissionDenied, connectionLabel: connectionLabel))
            case .notDetermined:
                noticeMessage = t("Could not determine the notification permission state.", "알림 권한 상태를 확인하지 못했습니다.")
            case .unsupported:
                noticeMessage = t("macOS notifications are available only when running the bundled app (.app).", "번들 앱(.app)으로 실행할 때만 macOS 알림을 사용할 수 있습니다.")
            }
        }
    }

    func sendTestNotification() {
        Task {
            let state = await notificationManager.authorizationStatus()
            notificationPermissionState = state

            guard state == .authorized else {
                noticeMessage = t("Allow macOS notification permission first.", "먼저 macOS 알림 권한을 허용하세요.")
                return
            }

            let didSchedule = await notificationManager.sendTestNotification()
            noticeMessage = didSchedule
                ? t("A test notification will be sent in 1 second.", "1초 뒤 테스트 알림을 보냅니다.")
                : t("Failed to schedule the test notification.", "테스트 알림 예약에 실패했습니다.")

            if didSchedule {
                appendNotificationHistory(NotificationHistoryEntry(kind: .testNotificationScheduled, connectionLabel: serverStates.first?.server.displayName))
            }
        }
    }

    private func configurePolling(resetState: Bool) {
        pollingTask?.cancel()

        if resetState {
            for index in serverStates.indices {
                serverStates[index].lastErrorMessage = nil
            }
            lastErrorMessage = nil
        }

        guard settings.isConfigured else {
            snapshot = nil
            lastErrorMessage = t("Enter an SSH target to start polling.", "SSH target를 입력하면 polling을 시작합니다.")
            return
        }

        guard !settings.pollableServers.isEmpty else {
            snapshot = nil
            lastErrorMessage = t("Enable at least one configured server to start polling.", "Polling을 시작하려면 설정된 서버를 하나 이상 활성화하세요.")
            return
        }

        pollingTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    private func restartPollingAndRefresh(resetErrorState: Bool) {
        isRefreshing = false
        for index in serverStates.indices {
            serverStates[index].isRefreshing = false
        }
        configurePolling(resetState: resetErrorState)
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()

            do {
                try await Task.sleep(for: .seconds(settings.pollIntervalSeconds))
            } catch {
                break
            }
        }
    }

    private func refresh(serverIDs: Set<String>? = nil) async {
        let targetStates = serverStates.filter { state in
            state.server.isPollable && (serverIDs?.contains(state.id) ?? true)
        }
        guard !targetStates.isEmpty else {
            syncAggregateRuntimeState()
            return
        }
        guard !isRefreshing else { return }

        var contexts = [ServerRefreshContext]()

        for state in targetStates {
            let server = state.server
            let password = currentSessionPassword(for: server.id)

            if server.sshAuthenticationMode == .passwordBased && password.isEmpty {
                updateServerState(server.id) { state in
                    state.lastErrorMessage = missingPasswordSessionMessage()
                    state.passwordSessionState = synchronizedPasswordSessionState(for: server)
                }
                continue
            }

            updateServerState(server.id) { state in
                state.isRefreshing = true
            }

            contexts.append(
                ServerRefreshContext(
                    serverID: server.id,
                    server: server,
                    connectionSettings: server.connectionSettings(from: settings),
                    password: password.isEmpty ? nil : password,
                    detectedSSHUsername: state.detectedSSHUsername,
                    detectedSSHUserID: state.detectedSSHUserID
                )
            )
        }

        syncAggregateRuntimeState()
        guard !contexts.isEmpty else { return }

        await withTaskGroup(of: ServerRefreshResult.self) { group in
            for context in contexts {
                group.addTask { [fetcher] in
                    do {
                        let fetchedSnapshot = try await fetcher.fetchSummary(
                            settings: context.connectionSettings,
                            password: context.password
                        )

                        var detectedUserID = context.detectedSSHUserID
                        if context.connectionSettings.highlightsMyProcesses,
                           detectedUserID == nil,
                           let username = context.detectedSSHUsername {
                            detectedUserID = try? await fetcher.fetchRemoteUserID(
                                settings: context.connectionSettings,
                                username: username,
                                password: context.password
                            )
                        } else if !context.connectionSettings.highlightsMyProcesses {
                            detectedUserID = nil
                        }

                        return .success(
                            serverID: context.serverID,
                            snapshot: fetchedSnapshot,
                            detectedSSHUserID: detectedUserID
                        )
                    } catch is CancellationError {
                        return .cancelled(serverID: context.serverID)
                    } catch {
                        return .failure(serverID: context.serverID, message: error.localizedDescription)
                    }
                }
            }

            for await result in group {
                switch result {
                case .success(let serverID, let fetchedSnapshot, let detectedSSHUserID):
                    guard let state = serverState(for: serverID) else { continue }
                    let mergedSnapshot = fetchedSnapshot.mergingResolvedProcessMetadata(from: state.snapshot)
                    updateServerState(serverID) { state in
                        state.snapshot = mergedSnapshot
                        state.detectedSSHUserID = settings.highlightsMyProcesses ? detectedSSHUserID : nil
                        state.lastErrorMessage = nil
                        state.isRefreshing = false
                    }

                    if let server = server(for: serverID) {
                        let password = currentSessionPassword(for: serverID)
                        await evaluateWatchedProcesses(
                            using: mergedSnapshot,
                            server: server,
                            password: password.isEmpty ? nil : password
                        )
                        await evaluateWatchedIdleGPUs(using: mergedSnapshot, server: server)
                    }
                case .failure(let serverID, let message):
                    updateServerState(serverID) { state in
                        state.lastErrorMessage = message
                        state.isRefreshing = false
                    }
                case .cancelled(let serverID):
                    updateServerState(serverID) { state in
                        state.isRefreshing = false
                    }
                }
            }
        }

        syncAggregateRuntimeState()
    }

    private func persistSettings() {
        do {
            let data = try JSONEncoder().encode(settings)
            userDefaults.set(data, forKey: settingsKey)
        } catch {
            lastErrorMessage = t("Failed to save settings: \(error.localizedDescription)", "설정을 저장하지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func persistWatchedProcesses() {
        do {
            let data = try JSONEncoder().encode(watchedProcesses)
            userDefaults.set(data, forKey: watchedProcessesKey)
        } catch {
            lastErrorMessage = t("Failed to save watches: \(error.localizedDescription)", "감시 목록을 저장하지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func persistWatchedIdleGPUs() {
        do {
            let data = try JSONEncoder().encode(watchedIdleGPUs)
            userDefaults.set(data, forKey: watchedIdleGPUsKey)
        } catch {
            lastErrorMessage = t("Failed to save GPU idle watches: \(error.localizedDescription)", "GPU idle 감시 목록을 저장하지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func persistNotificationHistory() {
        do {
            let data = try JSONEncoder().encode(notificationHistory)
            userDefaults.set(data, forKey: notificationHistoryKey)
        } catch {
            lastErrorMessage = t("Failed to save notification history: \(error.localizedDescription)", "알림 이력을 저장하지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func hasSavedPasswordHint(for server: ServerConfig) -> Bool {
        userDefaults.bool(forKey: passwordStoredHintKey(for: server.id))
            || (serverStates.count <= 1 && userDefaults.bool(forKey: passwordStoredHintKey))
    }

    private func migrateSavedPasswordHintIfNeeded(for server: ServerConfig) -> Bool {
        guard server.sshAuthenticationMode == .passwordBased else { return false }
        guard !hasSavedPasswordHint(for: server) else { return true }

        let hasPassword = passwordStore.hasPasswordWithoutPrompt(account: server.keychainAccount)
            || shouldUseLegacyPasswordFallback(for: server) && passwordStore.hasPasswordWithoutPrompt()
        if hasPassword {
            userDefaults.set(true, forKey: passwordStoredHintKey(for: server.id))
        }
        return hasPassword
    }

    private func passwordStoredHintKey(for serverID: String) -> String {
        passwordStoredHintPrefix + serverID
    }

    private func currentSessionPassword(for serverID: String) -> String {
        guard server(for: serverID)?.sshAuthenticationMode == .passwordBased else { return "" }
        return unlockedSSHPasswords[serverID] ?? ""
    }

    private func loadPassword(for server: ServerConfig) throws -> String {
        let serverPassword = try passwordStore.loadPassword(account: server.keychainAccount)
        if !serverPassword.isEmpty {
            return serverPassword
        }

        guard shouldUseLegacyPasswordFallback(for: server) else {
            return ""
        }

        let legacyPassword = try passwordStore.loadPassword()
        if !legacyPassword.isEmpty {
            try? passwordStore.savePassword(legacyPassword, account: server.keychainAccount)
            userDefaults.set(true, forKey: passwordStoredHintKey(for: server.id))
        }
        return legacyPassword
    }

    private func shouldUseLegacyPasswordFallback(for server: ServerConfig) -> Bool {
        server.id == "legacy-primary" || serverStates.count <= 1
    }

    private func synchronizedPasswordSessionState(for server: ServerConfig) -> SSHPasswordSessionState {
        switch server.sshAuthenticationMode {
        case .keyBased:
            unlockedSSHPasswords.removeValue(forKey: server.id)
            return .notRequired
        case .passwordBased:
            if !(unlockedSSHPasswords[server.id] ?? "").isEmpty {
                return .unlocked
            }
            if hasSavedPasswordHint(for: server) || migrateSavedPasswordHintIfNeeded(for: server) {
                return .locked
            }
            return .missing
        }
    }

    private func missingPasswordSessionMessage() -> String {
        t(
            "Open Settings and unlock the saved SSH password to resume password-based polling.",
            "Settings를 열고 저장된 SSH 비밀번호를 한 번 해제해야 password-based polling이 다시 시작됩니다."
        )
    }

    private func appendNotificationHistory(_ entry: NotificationHistoryEntry) {
        let cutoff = Date().addingTimeInterval(-(7 * 24 * 3600))
        notificationHistory.append(entry)
        notificationHistory.removeAll { $0.timestamp < cutoff }
        if notificationHistory.count > 200 {
            notificationHistory = Array(notificationHistory.suffix(200))
        }
        persistNotificationHistory()
    }

    private func refreshProcessDetails(for gpuID: Int, on serverID: String) async {
        guard let server = server(for: serverID) else { return }
        guard server.isPollable else { return }

        let scopedKey = scopedGPUKey(serverID: serverID, gpuID: gpuID)
        guard !loadingProcessDetailGPUIds.contains(scopedKey) else { return }

        loadingProcessDetailGPUIds.insert(scopedKey)

        defer {
            loadingProcessDetailGPUIds.remove(scopedKey)
        }

        if server.sshAuthenticationMode == .passwordBased && currentSessionPassword(for: serverID).isEmpty {
            updateServerState(serverID) { state in
                state.lastErrorMessage = missingPasswordSessionMessage()
            }
            syncAggregateRuntimeState()
            return
        }

        do {
            let password = currentSessionPassword(for: serverID)
            guard let currentSnapshot = serverState(for: serverID)?.snapshot else {
                syncAggregateRuntimeState()
                return
            }
            guard let currentGPU = currentSnapshot.gpus.first(where: { $0.id == gpuID }) else {
                syncAggregateRuntimeState()
                return
            }
            guard !currentGPU.processes.isEmpty else {
                syncAggregateRuntimeState()
                return
            }

            let enrichedProcesses = try await fetcher.fetchProcessDetails(
                settings: server.connectionSettings(from: settings),
                processes: currentGPU.processes,
                password: password.isEmpty ? nil : password
            )
            applyProcessDetails(enrichedProcesses, toGPUWithID: gpuID, on: serverID)
            updateServerState(serverID) { state in
                state.lastErrorMessage = nil
            }
            syncAggregateRuntimeState()
        } catch is CancellationError {
            return
        } catch {
            updateServerState(serverID) { state in
                state.lastErrorMessage = t("Failed to load process details: \(error.localizedDescription)", "프로세스 상세를 가져오지 못했습니다: \(error.localizedDescription)")
            }
            syncAggregateRuntimeState()
        }
    }

    private func applyProcessDetails(_ processes: [GPUProcessReading], toGPUWithID gpuID: Int, on serverID: String) {
        guard let currentSnapshot = serverState(for: serverID)?.snapshot else { return }

        let updatedGPUs = currentSnapshot.gpus.map { gpu in
            guard gpu.id == gpuID else { return gpu }

            return GPUReading(
                index: gpu.index,
                name: gpu.name,
                uuid: gpu.uuid,
                utilization: gpu.utilization,
                memoryUsedMB: gpu.memoryUsedMB,
                memoryTotalMB: gpu.memoryTotalMB,
                temperatureCelsius: gpu.temperatureCelsius,
                processes: processes
            )
        }

        updateServerState(serverID) { state in
            state.snapshot = GPUSnapshot(takenAt: currentSnapshot.takenAt, gpus: updatedGPUs, hostMemory: currentSnapshot.hostMemory)
        }
    }

    private func toggleExitWatchTask(for process: GPUProcessReading, on gpu: GPUReading, serverID: String) async {
        guard let server = server(for: serverID) else { return }

        if let existingIndex = watchedProcesses.firstIndex(where: { $0.matches(process) && $0.connectionFingerprint == server.connectionFingerprint }) {
            let removedWatch = watchedProcesses.remove(at: existingIndex)
            persistWatchedProcesses()
            noticeMessage = t("Process exit alert disabled.", "프로세스 종료 알림을 해제했습니다.")
            appendNotificationHistory(NotificationHistoryEntry(kind: .watchRemoved, watch: removedWatch))
            return
        }

        guard notificationManager.isSupportedEnvironment else {
            notificationPermissionState = .unsupported
            noticeMessage = t("Process exit alerts are available only when running the bundled app (.app).", "프로세스 종료 알림은 번들 앱(.app)으로 실행할 때만 사용할 수 있습니다.")
            return
        }

        let isAuthorized = await notificationManager.requestAuthorizationIfNeeded()
        notificationPermissionState = await notificationManager.authorizationStatus()
        guard isAuthorized else {
            noticeMessage = t("Process exit alert could not be enabled because macOS notification permission is missing.", "macOS 알림 권한이 없어 종료 알림을 등록하지 못했습니다.")
            return
        }

        let newWatch = ProcessExitWatch(server: server, gpu: gpu, process: process)
        watchedProcesses.append(newWatch)
        watchedProcesses.sort { lhs, rhs in
            if lhs.connectionLabel == rhs.connectionLabel {
                if lhs.gpuIndex == rhs.gpuIndex {
                    return lhs.pid < rhs.pid
                }

                return lhs.gpuIndex < rhs.gpuIndex
            }

            return lhs.connectionLabel.localizedCaseInsensitiveCompare(rhs.connectionLabel) == .orderedAscending
        }
        persistWatchedProcesses()
        noticeMessage = t("Process exit alert enabled.", "프로세스 종료 알림을 등록했습니다.")
        appendNotificationHistory(NotificationHistoryEntry(kind: .watchAdded, watch: newWatch))
    }

    private func toggleIdleWatchTask(for gpu: GPUReading, serverID: String) async {
        guard let server = server(for: serverID) else { return }

        if let existingIndex = watchedIdleGPUs.firstIndex(where: { $0.connectionFingerprint == server.connectionFingerprint && $0.matches(gpu) }) {
            let removedWatch = watchedIdleGPUs.remove(at: existingIndex)
            idleWatchTrackingStates.removeValue(forKey: removedWatch.id)
            persistWatchedIdleGPUs()
            noticeMessage = t("GPU idle alert disabled.", "GPU idle 알림을 해제했습니다.")
            appendNotificationHistory(NotificationHistoryEntry(kind: .idleWatchRemoved, idleWatch: removedWatch))
            return
        }

        guard notificationManager.isSupportedEnvironment else {
            notificationPermissionState = .unsupported
            noticeMessage = t("GPU idle alerts are available only when running the bundled app (.app).", "GPU idle 알림은 번들 앱(.app)으로 실행할 때만 사용할 수 있습니다.")
            return
        }

        let isAuthorized = await notificationManager.requestAuthorizationIfNeeded()
        notificationPermissionState = await notificationManager.authorizationStatus()
        guard isAuthorized else {
            noticeMessage = t("GPU idle alert could not be enabled because macOS notification permission is missing.", "macOS 알림 권한이 없어 GPU idle 알림을 등록하지 못했습니다.")
            return
        }

        let newWatch = GPUIdleWatch(server: server, gpu: gpu)
        watchedIdleGPUs.append(newWatch)
        watchedIdleGPUs.sort { lhs, rhs in
            if lhs.connectionLabel == rhs.connectionLabel {
                return lhs.gpuIndex < rhs.gpuIndex
            }

            return lhs.connectionLabel.localizedCaseInsensitiveCompare(rhs.connectionLabel) == .orderedAscending
        }
        if gpu.isIdle(memoryThresholdMB: settings.idleMemoryThresholdMB) {
            idleWatchTrackingStates[newWatch.id] = GPUIdleWatchTrackingState(idleSince: serverState(for: serverID)?.snapshot?.takenAt ?? Date())
        }
        persistWatchedIdleGPUs()
        noticeMessage = t("GPU idle alert enabled.", "GPU idle 알림을 등록했습니다.")
        appendNotificationHistory(
            NotificationHistoryEntry(
                kind: .idleWatchAdded,
                idleWatch: newWatch,
                detail: "Idle \(settings.idleNotificationSeconds)s · <=\(settings.idleMemoryThresholdMB)MB"
            )
        )
    }

    private func evaluateWatchedProcesses(using snapshot: GPUSnapshot, server: ServerConfig, password: String?) async {
        let matchingWatches = watchedProcesses.filter { $0.connectionFingerprint == server.connectionFingerprint }
        guard !matchingWatches.isEmpty else { return }

        let visibleProcesses = snapshot.gpus.flatMap(\.processes)
        let hiddenWatches = matchingWatches.filter { watch in
            !visibleProcesses.contains(where: watch.matches(_:))
        }
        guard !hiddenWatches.isEmpty else { return }

        do {
            let remoteStatuses = try await fetcher.fetchProcessStatuses(
                settings: server.connectionSettings(from: settings),
                pids: hiddenWatches.map(\.pid),
                password: password
            )
            let exitedWatches = ProcessExitWatchEvaluator.exitedWatches(
                watches: hiddenWatches,
                visibleProcesses: visibleProcesses,
                remoteStatuses: remoteStatuses
            )

            guard !exitedWatches.isEmpty else { return }

            var notifiedProcesses = [String]()

            for watch in exitedWatches {
                let didSchedule = await notificationManager.sendExitNotification(for: watch)
                if didSchedule {
                    notifiedProcesses.append(watch.displayProcessName)
                    appendNotificationHistory(NotificationHistoryEntry(kind: .exitNotificationScheduled, watch: watch))
                }
            }

            let exitedWatchIDs = Set(exitedWatches.map(\.id))
            watchedProcesses.removeAll { exitedWatchIDs.contains($0.id) }
            persistWatchedProcesses()

            if notifiedProcesses.isEmpty {
                noticeMessage = t("A process exit was detected, but scheduling the macOS notification failed.", "프로세스 종료는 감지했지만 macOS 알림 예약에는 실패했습니다.")
            } else if notifiedProcesses.count == 1 {
                noticeMessage = t("Sent an exit alert for \(notifiedProcesses[0]).", "\(notifiedProcesses[0]) 종료 알림을 보냈습니다.")
            } else {
                noticeMessage = t("Sent exit alerts for \(notifiedProcesses.count) processes.", "\(notifiedProcesses.count)개 프로세스 종료 알림을 보냈습니다.")
            }
        } catch {
            return
        }
    }

    private func evaluateWatchedIdleGPUs(using snapshot: GPUSnapshot, server: ServerConfig) async {
        let matchingWatches = watchedIdleGPUs.filter { $0.connectionFingerprint == server.connectionFingerprint }
        let watchedIDs = Set(watchedIdleGPUs.map(\.id))
        idleWatchTrackingStates = idleWatchTrackingStates.filter { watchedIDs.contains($0.key) }

        guard !matchingWatches.isEmpty else { return }

        var notifiedGPUIndices = [Int]()
        var failedNotificationGPUIndices = [Int]()

        for watch in matchingWatches {
            guard let gpu = snapshot.gpus.first(where: watch.matches(_:)) else {
                idleWatchTrackingStates.removeValue(forKey: watch.id)
                continue
            }

            var trackingState = idleWatchTrackingStates[watch.id] ?? GPUIdleWatchTrackingState()
            let isIdle = gpu.isIdle(memoryThresholdMB: settings.idleMemoryThresholdMB)

            if !isIdle {
                trackingState.idleSince = nil
                trackingState.hasHandledCurrentIdleStretch = false
                idleWatchTrackingStates[watch.id] = trackingState
                continue
            }

            if trackingState.idleSince == nil {
                trackingState.idleSince = snapshot.takenAt
            }

            guard let idleSince = trackingState.idleSince else {
                idleWatchTrackingStates[watch.id] = trackingState
                continue
            }

            let idleDuration = snapshot.takenAt.timeIntervalSince(idleSince)
            let threshold = TimeInterval(settings.idleNotificationSeconds)

            guard idleDuration >= threshold, !trackingState.hasHandledCurrentIdleStretch else {
                idleWatchTrackingStates[watch.id] = trackingState
                continue
            }

            let didSchedule = await notificationManager.sendIdleNotification(
                for: watch,
                idleDurationSeconds: Int(idleDuration.rounded()),
                memoryUsedMB: gpu.memoryUsedMB
            )
            trackingState.hasHandledCurrentIdleStretch = true
            idleWatchTrackingStates[watch.id] = trackingState

            if didSchedule {
                notifiedGPUIndices.append(watch.gpuIndex)
                appendNotificationHistory(
                    NotificationHistoryEntry(
                        kind: .idleNotificationScheduled,
                        idleWatch: watch,
                        detail: "Idle \(Int(idleDuration.rounded()))s · \(gpu.memoryUsedMB)MB"
                    )
                )
            } else {
                failedNotificationGPUIndices.append(watch.gpuIndex)
            }
        }

        if !notifiedGPUIndices.isEmpty {
            if notifiedGPUIndices.count == 1, let gpuIndex = notifiedGPUIndices.first {
                noticeMessage = t("Sent a GPU idle alert for \(server.displayName) GPU \(gpuIndex).", "\(server.displayName) GPU \(gpuIndex) idle 알림을 보냈습니다.")
            } else {
                noticeMessage = t("Sent GPU idle alerts for \(notifiedGPUIndices.count) GPUs.", "\(notifiedGPUIndices.count)개 GPU idle 알림을 보냈습니다.")
            }
        } else if !failedNotificationGPUIndices.isEmpty {
            noticeMessage = t("A GPU idle state was detected, but scheduling the macOS notification failed.", "GPU idle 상태는 감지했지만 macOS 알림 예약에는 실패했습니다.")
        }
    }

    private func reconcileServerStates(previousServerStates: [String: ServerRuntimeState]) {
        serverStates = settings.configuredServers.map { server in
            var state = previousServerStates[server.id] ?? ServerRuntimeState(
                server: server,
                lastErrorMessage: initialStatusMessage(for: server),
                passwordSessionState: Self.initialPasswordSessionState(
                    for: server,
                    passwordStore: passwordStore,
                    userDefaults: userDefaults,
                    allowLegacyPasswordFallback: settings.configuredServers.count <= 1
                ),
                detectedSSHUsername: Self.detectedSSHUsername(for: server)
            )

            let connectionChanged = state.server.connectionFingerprint != server.connectionFingerprint
            state.server = server
            state.detectedSSHUsername = Self.detectedSSHUsername(for: server)
            state.passwordSessionState = synchronizedPasswordSessionState(for: server)

            if connectionChanged {
                state.snapshot = nil
                state.detectedSSHUserID = nil
                state.lastErrorMessage = initialStatusMessage(for: server)
                unlockedSSHPasswords.removeValue(forKey: server.id)
            } else if state.passwordSessionState == .notRequired && state.lastErrorMessage == missingPasswordSessionMessage() {
                state.lastErrorMessage = nil
            }

            state.isRefreshing = false
            return state
        }
    }

    private func reconcileWatchesWithCurrentServers() {
        let validFingerprints = Set(settings.configuredServers.map(\.connectionFingerprint))
        let oldProcessCount = watchedProcesses.count
        let oldIdleCount = watchedIdleGPUs.count

        watchedProcesses.removeAll { !validFingerprints.contains($0.connectionFingerprint) }
        watchedIdleGPUs.removeAll { !validFingerprints.contains($0.connectionFingerprint) }

        if watchedProcesses.count != oldProcessCount {
            persistWatchedProcesses()
        }

        if watchedIdleGPUs.count != oldIdleCount {
            persistWatchedIdleGPUs()
        }

        let watchedIdleIDs = Set(watchedIdleGPUs.map(\.id))
        idleWatchTrackingStates = idleWatchTrackingStates.filter { watchedIdleIDs.contains($0.key) }
    }

    private func syncAggregateRuntimeState() {
        isRefreshing = serverStates.contains { $0.isRefreshing }
        detectedSSHUsername = serverStates.first?.detectedSSHUsername
        passwordSessionState = serverStates.first?.passwordSessionState ?? .notRequired
        snapshot = aggregateSnapshot()

        if !settings.isConfigured {
            lastErrorMessage = t("Enter an SSH target to start polling.", "SSH target를 입력하면 polling을 시작합니다.")
        } else if settings.pollableServers.isEmpty {
            lastErrorMessage = t("Enable at least one configured server to start polling.", "Polling을 시작하려면 설정된 서버를 하나 이상 활성화하세요.")
        } else {
            lastErrorMessage = serverStates.first(where: { $0.lastErrorMessage != nil })?.lastErrorMessage
        }
    }

    private func aggregateSnapshot() -> GPUSnapshot? {
        let snapshots = serverStates.compactMap(\.snapshot)
        guard !snapshots.isEmpty else { return nil }

        let latestDate = snapshots.compactMap(\.takenAt).max() ?? Date()
        return GPUSnapshot(
            takenAt: latestDate,
            gpus: snapshots.flatMap(\.gpus)
        )
    }

    private func stateIndex(for serverID: String) -> Int? {
        serverStates.firstIndex { $0.id == serverID }
    }

    private func serverState(for serverID: String) -> ServerRuntimeState? {
        guard let index = stateIndex(for: serverID) else { return nil }
        return serverStates[index]
    }

    private func server(for serverID: String) -> ServerConfig? {
        serverState(for: serverID)?.server
    }

    private func updateServerState(_ serverID: String, _ update: (inout ServerRuntimeState) -> Void) {
        guard let index = stateIndex(for: serverID) else { return }
        update(&serverStates[index])
    }

    private func scopedGPUKey(serverID: String, gpuID: Int) -> String {
        "\(serverID):\(gpuID)"
    }

    private static func loadSettings(from userDefaults: UserDefaults) -> AppSettings {
        guard
            let data = userDefaults.data(forKey: "nvbeacon.settings"),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }

        return settings.normalized()
    }

    private static func detectedSSHUsername(for server: ServerConfig) -> String? {
        server.detectedSSHUsername()
    }

    private static func loadWatchedProcesses(from userDefaults: UserDefaults) -> [ProcessExitWatch] {
        guard
            let data = userDefaults.data(forKey: "nvbeacon.process_exit_watches"),
            let watches = try? JSONDecoder().decode([ProcessExitWatch].self, from: data)
        else {
            return []
        }

        return watches
    }

    private static func loadWatchedIdleGPUs(from userDefaults: UserDefaults) -> [GPUIdleWatch] {
        guard
            let data = userDefaults.data(forKey: "nvbeacon.gpu_idle_watches"),
            let watches = try? JSONDecoder().decode([GPUIdleWatch].self, from: data)
        else {
            return []
        }

        return watches
    }

    private static func loadNotificationHistory(from userDefaults: UserDefaults) -> [NotificationHistoryEntry] {
        guard
            let data = userDefaults.data(forKey: "nvbeacon.notification_history"),
            let history = try? JSONDecoder().decode([NotificationHistoryEntry].self, from: data)
        else {
            return []
        }

        return history
    }

    private static func initialServerStates(
        for settings: AppSettings,
        passwordStore: SSHPasswordStore,
        userDefaults: UserDefaults
    ) -> [ServerRuntimeState] {
        settings.configuredServers.map { server in
            ServerRuntimeState(
                server: server,
                lastErrorMessage: initialStatusMessage(for: server, language: settings.resolvedLanguage),
                passwordSessionState: initialPasswordSessionState(
                    for: server,
                    passwordStore: passwordStore,
                    userDefaults: userDefaults,
                    allowLegacyPasswordFallback: settings.configuredServers.count <= 1
                ),
                detectedSSHUsername: detectedSSHUsername(for: server)
            )
        }
    }

    private static func initialPasswordSessionState(
        for server: ServerConfig,
        passwordStore: SSHPasswordStore,
        userDefaults: UserDefaults,
        allowLegacyPasswordFallback: Bool
    ) -> SSHPasswordSessionState {
        guard server.sshAuthenticationMode == .passwordBased else {
            return .notRequired
        }

        let hasServerHint = userDefaults.bool(forKey: "nvbeacon.password_saved_hint.\(server.id)")
        let hasLegacyHint = allowLegacyPasswordFallback && userDefaults.bool(forKey: "nvbeacon.password_saved_hint")
        let hasPassword = passwordStore.hasPasswordWithoutPrompt(account: server.keychainAccount)
            || allowLegacyPasswordFallback && passwordStore.hasPasswordWithoutPrompt()

        if hasServerHint || hasLegacyHint || hasPassword {
            userDefaults.set(true, forKey: "nvbeacon.password_saved_hint.\(server.id)")
            return .locked
        }

        return .missing
    }

    private func initialStatusMessage(for server: ServerConfig) -> String? {
        Self.initialStatusMessage(for: server, language: language)
    }

    private static func initialStatusMessage(for server: ServerConfig, language: AppInterfaceLanguage) -> String? {
        guard server.isConfigured else { return nil }

        if !server.isEnabled {
            return nil
        }

        if server.sshAuthenticationMode == .passwordBased {
            return language.text(
                "Open Settings and unlock the saved SSH password to resume password-based polling.",
                "Settings를 열고 저장된 SSH 비밀번호를 한 번 해제해야 password-based polling이 다시 시작됩니다."
            )
        }

        return nil
    }

    private static func initialStatusMessage(for states: [ServerRuntimeState], language: AppInterfaceLanguage) -> String? {
        if states.contains(where: { $0.server.isPollable }) {
            return states.first(where: { $0.lastErrorMessage != nil })?.lastErrorMessage
        }

        return language.text(
            "Enable at least one configured server to start polling.",
            "Polling을 시작하려면 설정된 서버를 하나 이상 활성화하세요."
        )
    }
}
