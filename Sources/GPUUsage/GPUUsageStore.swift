import Combine
import Foundation

@MainActor
final class GPUUsageStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var snapshot: GPUSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var loadingProcessDetailGPUIds = Set<Int>()

    private let fetcher: SSHMetricsFetcher
    private let userDefaults: UserDefaults
    private let passwordStore = SSHPasswordStore()
    private let settingsKey = "gpu_usage.settings"
    private var pollingTask: Task<Void, Never>?

    init(fetcher: SSHMetricsFetcher = SSHMetricsFetcher(), userDefaults: UserDefaults = .standard) {
        self.fetcher = fetcher
        self.userDefaults = userDefaults
        self.settings = Self.loadSettings(from: userDefaults)
        self.lastErrorMessage = self.settings.isConfigured ? nil : "SSH target를 입력하면 polling을 시작합니다."

        configurePolling(resetState: false)
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
            return settings.menuBarDisplayMode.titleText(for: snapshot)
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
            return "GPUUsage: 서버를 설정하면 polling을 시작합니다."
        }

        if let snapshot {
            return "Average \(snapshot.averageUtilization)% · Busy \(snapshot.busyCount)/\(snapshot.gpus.count) · Processes \(snapshot.totalProcessCount)"
        }

        if isRefreshing {
            return "GPUUsage: 서버 상태를 새로 가져오는 중입니다."
        }

        if let lastErrorMessage {
            return lastErrorMessage
        }

        return "GPUUsage"
    }

    var lastUpdatedRelativeText: String? {
        guard let snapshot else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: snapshot.takenAt, relativeTo: Date())
    }

    func applySettings(_ newSettings: AppSettings, password: String = "") {
        let normalized = newSettings.normalized()
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        if normalized.sshAuthenticationMode == .passwordBased {
            let existingPassword = (try? passwordStore.loadPassword()) ?? ""
            guard normalized != settings || trimmedPassword != existingPassword else { return }

            do {
                try passwordStore.savePassword(trimmedPassword)
            } catch {
                lastErrorMessage = error.localizedDescription
                return
            }
        } else {
            guard normalized != settings else { return }
        }

        settings = normalized
        persistSettings()
        configurePolling(resetState: true)
    }

    func loadSavedPassword() -> String {
        guard settings.sshAuthenticationMode == .passwordBased else { return "" }
        return (try? passwordStore.loadPassword()) ?? ""
    }

    func resetConfiguration() {
        pollingTask?.cancel()

        do {
            try passwordStore.deletePassword()
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        settings = AppSettings()
        snapshot = nil
        userDefaults.removeObject(forKey: settingsKey)
        lastErrorMessage = "SSH target를 입력하면 polling을 시작합니다."
        configurePolling(resetState: false)
    }

    func refreshNow() {
        Task {
            await refresh()
        }
    }

    func loadProcessDetails(for gpuID: Int) {
        Task {
            await refreshProcessDetails(for: gpuID)
        }
    }

    func isLoadingProcessDetails(for gpuID: Int) -> Bool {
        loadingProcessDetailGPUIds.contains(gpuID)
    }

    private func configurePolling(resetState: Bool) {
        pollingTask?.cancel()

        if resetState {
            lastErrorMessage = nil
        }

        guard settings.isConfigured else {
            snapshot = nil
            lastErrorMessage = "SSH target를 입력하면 polling을 시작합니다."
            return
        }

        pollingTask = Task { [weak self] in
            await self?.pollLoop()
        }
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

        do {
            let password = currentSettings.sshAuthenticationMode == .passwordBased ? loadSavedPassword() : ""
            let fetchedSnapshot = try await fetcher.fetchSummary(
                settings: currentSettings,
                password: password.isEmpty ? nil : password
            )
            self.snapshot = mergeProcessDetails(from: self.snapshot, into: fetchedSnapshot)
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
            lastErrorMessage = "설정을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func refreshProcessDetails(for gpuID: Int) async {
        guard settings.isConfigured else { return }
        guard !loadingProcessDetailGPUIds.contains(gpuID) else { return }
        guard let snapshot, let gpu = snapshot.gpus.first(where: { $0.id == gpuID }) else { return }
        guard !gpu.processes.isEmpty else { return }
        guard gpu.processes.contains(where: { !$0.hasResolvedMetadata }) else { return }

        loadingProcessDetailGPUIds.insert(gpuID)
        let currentSettings = settings

        defer {
            loadingProcessDetailGPUIds.remove(gpuID)
        }

        do {
            let password = currentSettings.sshAuthenticationMode == .passwordBased ? loadSavedPassword() : ""
            let enrichedProcesses = try await fetcher.fetchProcessDetails(
                settings: currentSettings,
                processes: gpu.processes,
                password: password.isEmpty ? nil : password
            )
            applyProcessDetails(enrichedProcesses, toGPUWithID: gpuID)
            lastErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            lastErrorMessage = "프로세스 상세를 가져오지 못했습니다: \(error.localizedDescription)"
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

    private func mergeProcessDetails(from previous: GPUSnapshot?, into latest: GPUSnapshot) -> GPUSnapshot {
        guard let previous else { return latest }

        let previousProcessesByID = Dictionary(
            uniqueKeysWithValues: previous.gpus
                .flatMap(\.processes)
                .filter(\.hasResolvedMetadata)
                .map { ($0.id, $0) }
        )

        let mergedGPUs = latest.gpus.map { gpu in
            let mergedProcesses = gpu.processes.map { process in
                previousProcessesByID[process.id] ?? process
            }

            return GPUReading(
                index: gpu.index,
                name: gpu.name,
                uuid: gpu.uuid,
                utilization: gpu.utilization,
                memoryUsedMB: gpu.memoryUsedMB,
                memoryTotalMB: gpu.memoryTotalMB,
                temperatureCelsius: gpu.temperatureCelsius,
                processes: mergedProcesses
            )
        }

        return GPUSnapshot(takenAt: latest.takenAt, gpus: mergedGPUs)
    }

    private static func loadSettings(from userDefaults: UserDefaults) -> AppSettings {
        guard
            let data = userDefaults.data(forKey: "gpu_usage.settings"),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }

        return settings.normalized()
    }
}
