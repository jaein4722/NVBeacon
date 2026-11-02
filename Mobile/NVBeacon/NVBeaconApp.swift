import SwiftUI
import NVBeaconMobile

@main
struct NVBeaconApp: App {
    @State private var store = MobileStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .tint(.green)
                .task(id: MonitorIdentity(active: scenePhase == .active, generation: store.generation)) {
                    if scenePhase == .active { await store.monitor() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { store.suspend() }
                }
        }
    }
}

private struct MonitorIdentity: Hashable {
    let active: Bool
    let generation: UUID
}
