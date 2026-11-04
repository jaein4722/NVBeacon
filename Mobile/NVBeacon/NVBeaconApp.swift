import SwiftUI
import NVBeaconMobile

@main
struct NVBeaconApp: App {
    @AppStorage("interfaceLanguage") private var language = "system"
    @AppStorage("interfaceAppearance") private var appearance = "system"
#if NVBEACON_DESIGN_LAB && targetEnvironment(simulator)
    @State private var store = DesignLabFixtures.store()
#else
    @State private var store = MobileStore()
#endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .environment(\.locale, language == "system" ? .autoupdatingCurrent : Locale(identifier: language))
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
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
