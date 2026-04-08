import AppKit
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = NVBeaconStore()
    let appUpdater = AppUpdater()
    let launchAtLoginManager = LaunchAtLoginManager()
    private let settingsOpenBridge = SettingsOpenBridge()
    private var statusItemController: StatusItemController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy(showsDockIcon: store.settings.showsDockIcon)
        bindAppearance()
        bindActivationPolicy()
        bindSystemWakeNotifications()
        applyAppearance(for: store.settings.appearanceMode)
        configureNotificationPresentation()
        appUpdater.startIfPossible()

        let statusItemController = StatusItemController(
            store: store,
            settingsOpenBridge: settingsOpenBridge
        )
        statusItemController.showSettingsAction = { [weak self] in
            self?.showSettingsWindow()
        }
        self.statusItemController = statusItemController

        if !store.settings.isConfigured {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.showSettingsWindow()
            }
        }
    }

    private func bindAppearance() {
        store.$settings
            .map(\.appearanceMode)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.applyAppearance(for: mode)
            }
            .store(in: &cancellables)
    }

    private func bindActivationPolicy() {
        store.$settings
            .map(\.showsDockIcon)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] showsDockIcon in
                self?.applyActivationPolicy(showsDockIcon: showsDockIcon)
            }
            .store(in: &cancellables)
    }

    private func bindSystemWakeNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .merge(with: notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.store.handleSystemWake()
            }
            .store(in: &cancellables)
    }

    private func applyAppearance(for mode: AppAppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func applyActivationPolicy(showsDockIcon: Bool) {
        let policy: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
        NSApp.setActivationPolicy(policy)

        if showsDockIcon {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func configureNotificationPresentation() {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            return
        }

        UNUserNotificationCenter.current().delegate = self
    }

    private func showSettingsWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let openSettings = settingsOpenBridge.open {
            openSettings()
            return
        }

        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
