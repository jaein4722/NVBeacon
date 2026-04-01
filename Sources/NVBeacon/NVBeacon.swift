import SwiftUI

@main
struct NVBeaconApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(store: appDelegate.store, appUpdater: appDelegate.appUpdater)
        }
    }
}
