import AVFoundation
import SwiftUI
import VisionKit
import NVBeaconMobile
import NVBeaconTransfer

/// The camera result stays in this presentation. It is never opened as a URL,
/// copied to Pasteboard, or included in the JSON document import path.
struct MacTransferView: View {
    let store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var phase = Phase.camera
    @State private var pendingInvitation: String?
    @State private var receiver = PairingReceiver()
    @State private var operation: Task<Void, Never>?

    @State private var imported: [MobileServer] = []

    private enum Phase {
        case networkIssue(PairingError)
        case camera, scanning, connecting, verifying(String)
        case review(IncomingMacTransfer, MacTransferReview)
        case acknowledging(String), saved(String), failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .networkIssue(let error):
                    ContentUnavailableView {
                        Label("Find your Mac", systemImage: "network")
                    } description: { Text(LocalizedStringKey(error.localizedDescription)) } actions: {
                        if error == .localNetworkDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                            Button("Open Settings") { openURL(settings) }
                        }
                        Button("Try Again") { retryConnection() }
                        Button("Scan New Code") { scanAgain() }
                    }
                case .camera:
                    ProgressView("Preparing camera…")
                case .scanning:
                    VStack {
                        Text("On your Mac, open Transfer to iPhone, then point your camera at its QR code.")
                            .padding()
                        if scenePhase == .active {
                            MacQRScanner(found: connect) { message in
                                guard case .scanning = phase, UIApplication.shared.applicationState == .active else { return }
                                phase = .failed(message)
                            }
                        }
                    }
                case .connecting:
                    ProgressView("Connecting to your Mac…")
                case .verifying(let code):
                    VStack(spacing: 18) {
                        Label("Compare on both devices", systemImage: "lock.shield").font(.headline)
                        Text(code).font(.largeTitle.monospacedDigit()).accessibilityLabel("Verification code \(code)")
                        Text("Approve the transfer on your Mac only if its code matches.")
                            .multilineTextAlignment(.center)
                    }.padding()
                case .review(let batch, let review):
                    List {
                        Section {
                            Text("\(review.added) new · \(review.filled) to complete · \(review.skipped) kept")
                            Text("After saving, you can review host fingerprints and connect the imported servers together.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(review.rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.name).font(.headline)
                                Text(row.address).font(.caption)
                                switch row.action {
                                case .add: Text("Add disabled server")
                                case .fill: Text("Add credentials to existing server")
                                case .skip: Text("Keep existing server")
                                }
                                if let credential = row.credentialLabel {
                                    Label(LocalizedStringKey(credential), systemImage: "key").font(.caption)
                                }
                                if let note = row.note { Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Section {
                            Button("Import All", action: { finish(batch, review: review) })
                        }
                    }
                case .acknowledging(let summary):
                    ProgressView("Saved. Notifying your Mac…").accessibilityHint(summary)
                case .saved(let detail):
                    if !imported.isEmpty {
                        TransferConnectionsView(store: store, servers: imported, summary: detail)
                    } else {
                        ContentUnavailableView {
                            Label("Transfer Complete", systemImage: "checkmark.circle")
                        } description: { Text(LocalizedStringKey(detail)) } actions: { Button("Done") { dismiss() } }
                    }
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Transfer Unavailable", systemImage: "exclamationmark.circle")
                    } description: { Text(LocalizedStringKey(message)) } actions: { Button("Close") { dismiss() } }
                }
            }
            .navigationTitle("Transfer from Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(acknowledging)
                }
            }
        }
        .interactiveDismissDisabled(acknowledging)
        .task(id: scenePhase == .active) {
            guard scenePhase == .active, case .camera = phase else { return }
            guard DataScannerViewController.isSupported else {
                phase = .failed("Scan the Mac’s QR code on an iPhone or iPad with a supported camera.")
                return
            }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            LocalNetworkPermission.requestOnEntry()
            guard granted, DataScannerViewController.isAvailable else {
                phase = .failed("Allow camera access in Settings and check that the camera is available.")
                return
            }
            phase = .scanning
        }
        .onDisappear { stop(); pendingInvitation = nil }
        .onChange(of: scenePhase) { _, status in
            if status == .active {
                if case .networkIssue(.localNetworkDenied) = phase { retryConnection(keepPermissionNotice: true) }
                else { receiver.resumeConnectionIfWaiting() }
            }
            if status == .background {
                switch phase {
                case .camera, .scanning:
                    phase = .camera
                    return
                default: break
                }
            }
            if status == .background, case .networkIssue = phase {
                stop()
                return
            }
            if status == .background {
                stop()
                pendingInvitation = nil
                if case .saved = phase { return }
                if case .acknowledging(let summary) = phase {
                    phase = .saved(String(localized: "\(summary) Your Mac may not have received confirmation.", bundle: languageBundle))
                    return
                }
                phase = .failed("Transfer closed. Start a new transfer on your Mac.")
            }
        }
    }

    private func connect(_ invitation: String) {
        guard case .scanning = phase else { return }
        pendingInvitation = invitation
        retryConnection()
    }

    private func scanAgain() {
        stop()
        pendingInvitation = nil
        phase = .scanning
    }

    private func retryConnection(keepPermissionNotice: Bool = false) {
        guard let invitation = pendingInvitation else { return }
        stop()
        let receiver = PairingReceiver()
        self.receiver = receiver
        if !keepPermissionNotice { phase = .connecting }
        operation = Task { @MainActor in
            do {
                let data = try await receiver.receive(invitation: invitation) { code in
                    guard !Task.isCancelled, self.receiver === receiver else { return }
                    pendingInvitation = nil
                    phase = .verifying(code)
                }
                let parse = Task.detached(priority: .userInitiated) { try IncomingMacTransfer(data: data) }
                let incoming = try await withTaskCancellationHandler { try await parse.value } onCancel: { parse.cancel() }
                try Task.checkCancellation()
                let review = try store.reviewTransfer(incoming)
                if review.alreadyImported {
                    try store.importTransfer(incoming, reviewed: review)
                    acknowledge("This transfer was already saved.")
                } else { phase = .review(incoming, review) }
            } catch {
                guard !Task.isCancelled else { return }
                receiver.cancel()
                if let problem = error as? PairingError, pendingInvitation != nil,
                   problem == .localNetworkDenied || problem == .macNotFound {
                    phase = .networkIssue(problem)
                    if problem == .localNetworkDenied {
                        // The OS can reject the first attempt before the permission prompt is answered.
                        // Retry only pre-handshake attempts and only while the QR is valid.
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        if !Task.isCancelled, scenePhase == .active { retryConnection(keepPermissionNotice: true) }
                    }
                } else {
                    pendingInvitation = nil
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func finish(_ incoming: IncomingMacTransfer, review: MacTransferReview) {
        guard case .review = phase else { return }
        do {
            imported = try store.importTransfer(incoming, reviewed: review)
            acknowledge(String(localized: "\(review.added) added, \(review.filled) completed, \(review.skipped) kept.", bundle: languageBundle))
        } catch {
            receiver.cancel()
            phase = .failed(error.localizedDescription)
        }
    }

    private var languageBundle: Bundle {
        let preferred = Bundle.preferredLocalizations(from: Bundle.main.localizations, forPreferences: [locale.identifier])
        guard let language = preferred.first, let url = Bundle.main.url(forResource: language, withExtension: "lproj")
        else { return .main }
        return Bundle(url: url) ?? .main
    }

    private var acknowledging: Bool {
        if case .acknowledging = phase { return true }
        return false
    }

    private func acknowledge(_ summary: String) {
        // Drop the in-memory credential payload as soon as storage commits.
        phase = .acknowledging(summary)
        operation = Task {
            do {
                try await receiver.acknowledge()
                guard !Task.isCancelled else { return }
                phase = .saved(summary)
            }
            catch {
                guard !Task.isCancelled else { return }
                phase = .saved(String(localized: "\(summary) Your Mac could not be notified. Your saved servers are ready.", bundle: languageBundle))
            }
        }
    }

    private func stop() {
        operation?.cancel()
        receiver.cancel()
        operation = nil
    }
}

private struct TransferConnectionsView: View {
    let store: MobileStore
    let servers: [MobileServer]
    let summary: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var keys: [UUID: TransferHostKey] = [:]
    @State private var failures: [UUID: String] = [:]
    @State private var excluded = Set<UUID>()
    @State private var attempt = 0
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Label("Transfer Complete", systemImage: "checkmark.circle")
                Text(LocalizedStringKey(summary))
            } footer: {
                Text("Compare the fingerprints with your servers’ SSH host keys. Selected servers will be trusted and monitoring will start.")
            }
            Section("Imported Servers") {
                ForEach(servers) { server in
                    VStack(alignment: .leading, spacing: 5) {
                        if let hostKey = keys[server.id] {
                            Toggle(server.displayName, isOn: Binding(
                                get: { !excluded.contains(server.id) },
                                set: { if $0 { excluded.remove(server.id) } else { excluded.insert(server.id) } }))
                            Text(server.endpoint).font(.caption)
                            Text(hostKey.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        } else {
                            Text(server.displayName)
                            if let issue = server.transferSetupIssue ?? failures[server.id] {
                                Text(LocalizedStringKey(issue)).font(.caption).foregroundStyle(.secondary)
                            } else { ProgressView("Looking up host key…").font(.caption) }
                        }
                    }
                }
            }
            Section {
                let selected = servers.compactMap { excluded.contains($0.id) ? nil : keys[$0.id] }
                Button("Trust and Connect (\(selected.count))") {
                    do {
                        try store.trustAndConnectTransferred(selected)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(selected.isEmpty)
                if !failures.isEmpty {
                    Button("Retry Unreachable Servers") { failures.removeAll(); attempt += 1 }
                }
                Button("Done") { dismiss() }
                if let error { Text(LocalizedStringKey(error)).foregroundStyle(.secondary) }
            }
        }
        .task(id: "\(attempt)-\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            await lookup()
        }
    }

    private func lookup() async {
        var remaining = servers.filter { $0.transferSetupIssue == nil && keys[$0.id] == nil && failures[$0.id] == nil }.makeIterator()
        await withTaskGroup(of: (UUID, Result<TransferHostKey, any Error>).self) { group in
            func enqueueNext() {
                guard let server = remaining.next() else { return }
                group.addTask {
                    do { return (server.id, .success(try await TransferHostKey.lookup(server))) }
                    catch { return (server.id, .failure(error)) }
                }
            }
            for _ in 0..<4 { enqueueNext() }
            while let (id, result) = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); return }
                switch result {
                case .success(let key): keys[id] = key
                case .failure(let error): failures[id] = error.localizedDescription
                }
                enqueueNext()
            }
        }
    }
}

private struct MacQRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    let failed: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                               recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                               isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        context.coordinator.startTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            do { try scanner.startScanning() }
            catch { failed("Camera scanning is unavailable. Open the camera again to retry.") }
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.startTask?.cancel()
        scanner.delegate = nil
        scanner.stopScanning()
    }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var startTask: Task<Void, Never>?
        let parent: MacQRScanner
        init(_ parent: MacQRScanner) { self.parent = parent }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                if let value = barcode.payloadStringValue {
                    scanner.stopScanning()
                    parent.found(value)
                    return
                }
            }
        }
        func dataScanner(_ scanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            parent.failed("The camera became unavailable. Start a new transfer to retry.")
        }
    }
}
