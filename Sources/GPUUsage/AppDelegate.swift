import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = GPUUsageStore()
    private let settingsOpenBridge = SettingsOpenBridge()
    private var statusItemController: StatusItemController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy(showsDockIcon: store.settings.showsDockIcon)
        bindAppearance()
        bindActivationPolicy()
        applyAppearance(for: store.settings.appearanceMode)

        let statusItemController = StatusItemController(store: store, settingsOpenBridge: settingsOpenBridge)
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
