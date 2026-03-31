import Combine
import Foundation

@MainActor
final class GPUUsageStore: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var snapshot: GPUSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastErrorMessage: String?

    private let fetcher: SSHMetricsFetcher
    private let userDefaults: UserDefaults
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
        guard settings.isConfigured else { return "GPU --" }

        if let snapshot {
            return "GPU \(snapshot.averageUtilization)% · \(snapshot.busyCount)/\(snapshot.gpus.count)"
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

    var lastUpdatedRelativeText: String? {
        guard let snapshot else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: snapshot.takenAt, relativeTo: Date())
    }

    func applySettings(_ newSettings: AppSettings) {
        let normalized = newSettings.normalized()
        guard normalized != settings else { return }

        settings = normalized
        persistSettings()
        configurePolling(resetState: true)
    }

    func refreshNow() {
        Task {
            await refresh()
        }
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
            let snapshot = try await fetcher.fetch(settings: currentSettings)
            self.snapshot = snapshot
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
