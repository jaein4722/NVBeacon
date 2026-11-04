import SwiftUI
import NVBeaconMobile

struct MobileDiagnosticsView: View {
    let store: MobileStore
    @State private var copied = false

    var body: some View {
        let report = store.diagnostics()
        List {
            Section {
                Text(verbatim: report).font(.footnote.monospaced()).textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    if copied { Label("Copied", systemImage: "checkmark") }
                    else { Label("Copy Report", systemImage: "doc.on.doc") }
                }
                ShareLink(item: report)
            } footer: {
                Text("Includes app and OS versions, polling settings and anonymous server status. Server addresses, usernames, credentials, commands and raw errors are omitted.")
            }
        }
        .navigationTitle("Diagnostics")
        .onChange(of: report) { _, _ in copied = false }
    }
}
