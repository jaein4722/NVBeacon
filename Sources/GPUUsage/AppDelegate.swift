import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = GPUUsageStore()
    private let settingsOpenBridge = SettingsOpenBridge()
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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
