import SwiftUI

@MainActor
final class SettingsOpenBridge {
    var open: (() -> Void)?
}

struct SettingsActionRelayView: View {
    @Environment(\.openSettings) private var openSettings
    let bridge: SettingsOpenBridge

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .task {
                bridge.open = {
                    openSettings()
                }
            }
            .onDisappear {
                bridge.open = nil
            }
    }
}
