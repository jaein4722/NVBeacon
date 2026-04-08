import Combine
import Foundation

private struct GPUIdleWatchTrackingState: Sendable {
    var idleSince: Date?
    var hasHandledCurrentIdleStretch = false
}

@MainActor
final class NVBeaconStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var snapshot: GPUSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var notificationPermissionState: NotificationPermissionState = .unsupported
    @Published private(set) var passwordSessionState: SSHPasswordSessionState
    @Published private(set) var loadingProcessDetailGPUIds = Set<Int>()
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
    private let passwordAuthWarningAcknowledgedKey = "nvbeacon.password_auth_warning_acknowledged"
    private var pollingTask: Task<Void, Never>?
    private var idleWatchTrackingStates = [String: GPUIdleWatchTrackingState]()
    private var unlockedSSHPassword: String?
    private var passwordAuthWarningAcknowledgedThisSession = false
    private var detectedSSHUserID: Int?

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
        self.fetcher = fetcher
        self.notificationManager = notificationManager
        self.userDefaults = userDefaults
        self.passwordStore = passwordStore
        self.settings = settings
        self.detectedSSHUsername = Self.detectedSSHUsername(for: settings)
        self.passwordSessionState = Self.initialPasswordSessionState(
            settings: settings,
            passwordStore: passwordStore,
            userDefaults: userDefaults
        )
        self.watchedProcesses = Self.loadWatchedProcesses(from: userDefaults)
        self.watchedIdleGPUs = Self.loadWatchedIdleGPUs(from: userDefaults)
        self.notificationHistory = Self.loadNotificationHistory(from: userDefaults)
        self.lastErrorMessage = settings.isConfigured
            ? Self.initialStatusMessage(for: settings, passwordSessionState: self.passwordSessionState)
            : settings.resolvedLanguage.text("Enter an SSH target to start polling.", "SSH target를 입력하면 polling을 시작합니다.")

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

        if let snapshot {
            return settings.menuBarDisplayMode.titleText(for: snapshot, settings: settings, language: language)
        }

        if isRefreshing {
            return "GPU ..."
        }

        if lastErrorMessage != nil {
            return "GPU !"
        }

        return "GPU --"
    }

    var menuBarSymbolName: String {
        if lastErrorMessage != nil && settings.isConfigured {
            return "exclamationmark.triangle.fill"
        }

        return "memorychip.fill"
    }

    var menuBarToolTip: String {
        guard settings.isConfigured else {
            return t("NVBeacon: configure a server to start polling.", "NVBeacon: 서버를 설정하면 polling을 시작합니다.")
        }

        if let snapshot {
            let busyCount = snapshot.busyCount(using: settings)
            return t(
                "Average \(snapshot.averageUtilization)% · Busy \(busyCount)/\(snapshot.gpus.count) · Processes \(snapshot.totalProcessCount)",
                "평균 \(snapshot.averageUtilization)% · 사용중 \(busyCount)/\(snapshot.gpus.count) · 프로세스 \(snapshot.totalProcessCount)"
            )
        }

        if isRefreshing {
            return t("NVBeacon: refreshing server status.", "NVBeacon: 서버 상태를 새로 가져오는 중입니다.")
        }

        if let lastErrorMessage {
            return lastErrorMessage
        }

        return "NVBeacon"
    }

    var lastUpdatedRelativeText: String? {
        guard let snapshot else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: snapshot.takenAt, relativeTo: Date())
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

    func applySettings(_ newSettings: AppSettings) {
        let normalized = newSettings.normalized()
        let connectionChanged = normalized.connectionFingerprint != settings.connectionFingerprint
        let previousDetectedSSHUsername = detectedSSHUsername
        guard normalized != settings else { return }

        settings = normalized
        detectedSSHUsername = Self.detectedSSHUsername(for: normalized)
        if connectionChanged || detectedSSHUsername != previousDetectedSSHUsername {
            detectedSSHUserID = nil
        }
        persistSettings()
        noticeMessage = nil
        synchronizePasswordSessionStateAfterSettingsChange()

        if connectionChanged {
            watchedProcesses.removeAll()
            watchedIdleGPUs.removeAll()
            idleWatchTrackingStates.removeAll()
            persistWatchedProcesses()
            persistWatchedIdleGPUs()
        }

        configurePolling(resetState: true)
    }

    func savePasswordForCurrentSession(_ password: String) {
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        guard settings.sshAuthenticationMode == .passwordBased else { return }
        guard !trimmedPassword.isEmpty else {
            lastErrorMessage = t("Enter an SSH password before saving it.", "SSH 비밀번호를 입력한 뒤 저장하세요.")
            return
        }

        do {
            try passwordStore.savePassword(trimmedPassword)
            userDefaults.set(true, forKey: passwordStoredHintKey)
            unlockedSSHPassword = trimmedPassword
            passwordSessionState = .unlocked
            lastErrorMessage = nil
            noticeMessage = t("SSH password saved and unlocked for this app session.", "SSH 비밀번호를 저장했고 현재 앱 세션에서 해제했습니다.")
            refreshNow()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func unlockSavedPasswordForCurrentSession() {
        guard settings.sshAuthenticationMode == .passwordBased else { return }

        do {
            let password = try passwordStore.loadPassword()
            guard !password.isEmpty else {
                userDefaults.set(false, forKey: passwordStoredHintKey)
                unlockedSSHPassword = nil
                passwordSessionState = .missing
                lastErrorMessage = missingPasswordSessionMessage()
                noticeMessage = t("There is no saved SSH password in Keychain.", "Keychain에 저장된 SSH 비밀번호가 없습니다.")
                return
            }

            userDefaults.set(true, forKey: passwordStoredHintKey)
            unlockedSSHPassword = password
            passwordSessionState = .unlocked
            lastErrorMessage = nil
            noticeMessage = t("SSH password unlocked for this app session.", "현재 앱 세션에서 SSH 비밀번호를 해제했습니다.")
            refreshNow()
        } catch {
            passwordSessionState = hasSavedPasswordHint ? .locked : .missing
            lastErrorMessage = error.localizedDescription
        }
    }

    func forgetSavedPassword() {
        do {
            try passwordStore.deletePassword()
            userDefaults.set(false, forKey: passwordStoredHintKey)
            unlockedSSHPassword = nil
            passwordSessionState = settings.sshAuthenticationMode == .passwordBased ? .missing : .notRequired
            lastErrorMessage = settings.sshAuthenticationMode == .passwordBased ? missingPasswordSessionMessage() : nil
            noticeMessage = t("Removed the saved SSH password from Keychain.", "Keychain에서 저장된 SSH 비밀번호를 삭제했습니다.")
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

        do {
            try passwordStore.deletePassword()
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        settings = AppSettings()
        detectedSSHUsername = nil
        detectedSSHUserID = nil
        unlockedSSHPassword = nil
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

    func handleSystemWake() {
        restartPollingAndRefresh(resetErrorState: false)
    }

    func loadProcessDetails(for gpuID: Int) {
        Task {
            await refreshProcessDetails(for: gpuID)
        }
    }

    func isLoadingProcessDetails(for gpuID: Int) -> Bool {
        loadingProcessDetailGPUIds.contains(gpuID)
    }

    func isWatchingExit(for process: GPUProcessReading) -> Bool {
        watchedProcesses.contains { $0.matches(process) && $0.connectionFingerprint == settings.connectionFingerprint }
    }

    func isCurrentUserProcess(_ process: GPUProcessReading) -> Bool {
        guard settings.highlightsMyProcesses else { return false }

        if let detectedSSHUserID, let processUserID = process.userID {
            return processUserID == detectedSSHUserID
        }

        guard let detectedSSHUsername else { return false }
        return process.user?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == detectedSSHUsername
    }

    func hasCurrentUserProcess(on gpu: GPUReading) -> Bool {
        gpu.processes.contains(where: isCurrentUserProcess)
    }

    func isWatchingIdle(for gpu: GPUReading) -> Bool {
        watchedIdleGPUs.contains { $0.connectionFingerprint == settings.connectionFingerprint && $0.matches(gpu) }
    }

    func toggleExitWatch(for process: GPUProcessReading, on gpu: GPUReading) {
        Task {
            await toggleExitWatchTask(for: process, on: gpu)
        }
    }

    func toggleIdleWatch(for gpu: GPUReading) {
        Task {
            await toggleIdleWatchTask(for: gpu)
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

            switch state {
            case .authorized:
                noticeMessage = t("macOS notification permission enabled.", "macOS 알림 권한을 허용했습니다.")
                appendNotificationHistory(NotificationHistoryEntry(kind: .permissionEnabled, connectionLabel: settings.sshTarget))
            case .denied:
                noticeMessage = t("Notification permission was denied. Enable NVBeacon notifications in System Settings.", "알림 권한이 거부되었습니다. 시스템 설정에서 NVBeacon 알림을 허용하세요.")
                appendNotificationHistory(NotificationHistoryEntry(kind: .permissionDenied, connectionLabel: settings.sshTarget))
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
                appendNotificationHistory(NotificationHistoryEntry(kind: .testNotificationScheduled, connectionLabel: settings.sshTarget))
            }
        }
    }

    private func configurePolling(resetState: Bool) {
        pollingTask?.cancel()

        if resetState {
            lastErrorMessage = nil
        }

        guard settings.isConfigured else {
            snapshot = nil
            lastErrorMessage = t("Enter an SSH target to start polling.", "SSH target를 입력하면 polling을 시작합니다.")
            return
        }

        pollingTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    private func restartPollingAndRefresh(resetErrorState: Bool) {
        isRefreshing = false
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

    private func refresh() async {
        guard settings.isConfigured else { return }
        guard !isRefreshing else { return }

        isRefreshing = true
        let currentSettings = settings

        defer {
            isRefreshing = false
        }

        if currentSettings.sshAuthenticationMode == .passwordBased && currentSessionPassword().isEmpty {
            lastErrorMessage = missingPasswordSessionMessage()
            return
        }

        do {
            let password = currentSessionPassword()
            let fetchedSnapshot = try await fetcher.fetchSummary(
                settings: currentSettings,
                password: password.isEmpty ? nil : password
            )
            let mergedSnapshot = fetchedSnapshot.mergingResolvedProcessMetadata(from: self.snapshot)

            if currentSettings.highlightsMyProcesses,
               let _ = await resolveDetectedSSHUserIDIfNeeded(
                settings: currentSettings,
                password: password.isEmpty ? nil : password
            ) {
                // Summary polling already resolves process ownership via /proc,
                // so we only need the remote UID cache for "my process" checks.
            } else if !currentSettings.highlightsMyProcesses {
                detectedSSHUserID = nil
            }

            self.snapshot = mergedSnapshot
            await evaluateWatchedProcesses(using: mergedSnapshot, settings: currentSettings, password: password.isEmpty ? nil : password)
            await evaluateWatchedIdleGPUs(using: mergedSnapshot, settings: currentSettings)
            lastErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            lastErrorMessage = error.localizedDescription
        }
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

    private var hasSavedPasswordHint: Bool {
        userDefaults.bool(forKey: passwordStoredHintKey)
    }

    private func currentSessionPassword() -> String {
        guard settings.sshAuthenticationMode == .passwordBased else { return "" }
        return unlockedSSHPassword ?? ""
    }

    private func synchronizePasswordSessionStateAfterSettingsChange() {
        switch settings.sshAuthenticationMode {
        case .keyBased:
            unlockedSSHPassword = nil
            passwordSessionState = .notRequired
            if lastErrorMessage == missingPasswordSessionMessage() {
                lastErrorMessage = nil
            }
        case .passwordBased:
            if !currentSessionPassword().isEmpty {
                passwordSessionState = .unlocked
                lastErrorMessage = nil
            } else if hasSavedPasswordHint || migrateSavedPasswordHintIfNeeded() {
                passwordSessionState = .locked
                lastErrorMessage = missingPasswordSessionMessage()
            } else {
                passwordSessionState = .missing
                lastErrorMessage = missingPasswordSessionMessage()
            }
        }
    }

    private func migrateSavedPasswordHintIfNeeded() -> Bool {
        guard settings.sshAuthenticationMode == .passwordBased else { return false }
        guard !hasSavedPasswordHint else { return true }

        let hasPassword = passwordStore.hasPasswordWithoutPrompt()
        if hasPassword {
            userDefaults.set(true, forKey: passwordStoredHintKey)
        }
        return hasPassword
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

    private func refreshProcessDetails(for gpuID: Int) async {
        guard settings.isConfigured else { return }
        guard !loadingProcessDetailGPUIds.contains(gpuID) else { return }

        loadingProcessDetailGPUIds.insert(gpuID)
        let currentSettings = settings

        defer {
            loadingProcessDetailGPUIds.remove(gpuID)
        }

        if currentSettings.sshAuthenticationMode == .passwordBased && currentSessionPassword().isEmpty {
            lastErrorMessage = missingPasswordSessionMessage()
            return
        }

        do {
            let password = currentSessionPassword()
            guard let currentSnapshot = snapshot else {
                lastErrorMessage = nil
                return
            }
            guard let currentGPU = currentSnapshot.gpus.first(where: { $0.id == gpuID }) else {
                lastErrorMessage = nil
                return
            }
            guard !currentGPU.processes.isEmpty else {
                lastErrorMessage = nil
                return
            }

            let enrichedProcesses = try await fetcher.fetchProcessDetails(
                settings: currentSettings,
                processes: currentGPU.processes,
                password: password.isEmpty ? nil : password
            )
            applyProcessDetails(enrichedProcesses, toGPUWithID: gpuID)
            lastErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            lastErrorMessage = t("Failed to load process details: \(error.localizedDescription)", "프로세스 상세를 가져오지 못했습니다: \(error.localizedDescription)")
        }
    }

    private func applyProcessDetails(_ processes: [GPUProcessReading], toGPUWithID gpuID: Int) {
        guard let snapshot else { return }

        let updatedGPUs = snapshot.gpus.map { gpu in
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

        self.snapshot = GPUSnapshot(takenAt: snapshot.takenAt, gpus: updatedGPUs)
    }

    private func resolveDetectedSSHUserIDIfNeeded(settings: AppSettings, password: String?) async -> Int? {
        if let detectedSSHUserID {
            return detectedSSHUserID
        }

        guard let detectedSSHUsername else { return nil }

        do {
            let remoteUserID = try await fetcher.fetchRemoteUserID(
                settings: settings,
                username: detectedSSHUsername,
                password: password
            )
            detectedSSHUserID = remoteUserID
            return remoteUserID
        } catch {
            return nil
        }
    }

    private func toggleExitWatchTask(for process: GPUProcessReading, on gpu: GPUReading) async {
        if let existingIndex = watchedProcesses.firstIndex(where: { $0.matches(process) && $0.connectionFingerprint == settings.connectionFingerprint }) {
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

        let newWatch = ProcessExitWatch(settings: settings, gpu: gpu, process: process)
        watchedProcesses.append(newWatch)
        watchedProcesses.sort { lhs, rhs in
            if lhs.gpuIndex == rhs.gpuIndex {
                return lhs.pid < rhs.pid
            }

            return lhs.gpuIndex < rhs.gpuIndex
        }
        persistWatchedProcesses()
        noticeMessage = t("Process exit alert enabled.", "프로세스 종료 알림을 등록했습니다.")
        appendNotificationHistory(NotificationHistoryEntry(kind: .watchAdded, watch: newWatch))
    }

    private func toggleIdleWatchTask(for gpu: GPUReading) async {
        if let existingIndex = watchedIdleGPUs.firstIndex(where: { $0.connectionFingerprint == settings.connectionFingerprint && $0.matches(gpu) }) {
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

        let newWatch = GPUIdleWatch(settings: settings, gpu: gpu)
        watchedIdleGPUs.append(newWatch)
        watchedIdleGPUs.sort { $0.gpuIndex < $1.gpuIndex }
        if gpu.isIdle(memoryThresholdMB: settings.idleMemoryThresholdMB) {
            idleWatchTrackingStates[newWatch.id] = GPUIdleWatchTrackingState(idleSince: snapshot?.takenAt ?? Date())
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

    private func evaluateWatchedProcesses(using snapshot: GPUSnapshot, settings: AppSettings, password: String?) async {
        let matchingWatches = watchedProcesses.filter { $0.connectionFingerprint == settings.connectionFingerprint }
        guard !matchingWatches.isEmpty else { return }

        let visibleProcesses = snapshot.gpus.flatMap(\.processes)
        let hiddenWatches = matchingWatches.filter { watch in
            !visibleProcesses.contains(where: watch.matches(_:))
        }
        guard !hiddenWatches.isEmpty else { return }

        do {
            let remoteStatuses = try await fetcher.fetchProcessStatuses(
                settings: settings,
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

    private func evaluateWatchedIdleGPUs(using snapshot: GPUSnapshot, settings: AppSettings) async {
        let matchingWatches = watchedIdleGPUs.filter { $0.connectionFingerprint == settings.connectionFingerprint }
        let watchedIDs = Set(matchingWatches.map(\.id))
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
                noticeMessage = t("Sent a GPU idle alert for GPU \(gpuIndex).", "GPU \(gpuIndex) idle 알림을 보냈습니다.")
            } else {
                noticeMessage = t("Sent GPU idle alerts for \(notifiedGPUIndices.count) GPUs.", "\(notifiedGPUIndices.count)개 GPU idle 알림을 보냈습니다.")
            }
        } else if !failedNotificationGPUIndices.isEmpty {
            noticeMessage = t("A GPU idle state was detected, but scheduling the macOS notification failed.", "GPU idle 상태는 감지했지만 macOS 알림 예약에는 실패했습니다.")
        }
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

    private static func detectedSSHUsername(for settings: AppSettings) -> String? {
        settings.detectedSSHUsername()
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

    private static func initialPasswordSessionState(
        settings: AppSettings,
        passwordStore: SSHPasswordStore,
        userDefaults: UserDefaults
    ) -> SSHPasswordSessionState {
        guard settings.sshAuthenticationMode == .passwordBased else {
            return .notRequired
        }

        if userDefaults.bool(forKey: "nvbeacon.password_saved_hint") || passwordStore.hasPasswordWithoutPrompt() {
            userDefaults.set(true, forKey: "nvbeacon.password_saved_hint")
            return .locked
        }

        return .missing
    }

    private static func initialStatusMessage(for settings: AppSettings, passwordSessionState: SSHPasswordSessionState) -> String? {
        guard settings.isConfigured else { return nil }

        if settings.sshAuthenticationMode == .passwordBased, passwordSessionState != .unlocked {
            return settings.resolvedLanguage.text(
                "Open Settings and unlock the saved SSH password to resume password-based polling.",
                "Settings를 열고 저장된 SSH 비밀번호를 한 번 해제해야 password-based polling이 다시 시작됩니다."
            )
        }

        return nil
    }
}
