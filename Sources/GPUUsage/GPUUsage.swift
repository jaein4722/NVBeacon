import SwiftUI

@main
struct GPUUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = GPUUsageStore()

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(store: store)
        } label: {
            Label(store.menuBarTitle, systemImage: store.menuBarSymbolName)
        }
        .menuBarExtraStyle(.window)
    }
}
