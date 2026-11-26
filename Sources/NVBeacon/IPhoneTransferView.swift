import AppKit
import CoreImage.CIFilterBuiltins
import LocalAuthentication
import NVBeaconTransfer
import SwiftUI

@MainActor
private final class IPhoneTransfer: ObservableObject {
    enum Stage {
        case preparing, review, starting, scanning(String), confirm(String), authorizing, sending, completed(Int, Int), failed(String)
    }
    @Published var stage: Stage = .preparing
    @Published var rows: [MacTransferRow] = []
    private var sender: PairingSender?
    private var operation: Task<Void, Never>?
    private var auth: LAContext?

    func review(_ settings: AppSettings, language: AppInterfaceLanguage) async {
        do {
            rows = try await MacTransferPreparation.review(settings: settings)
            try Task.checkCancellation()
            stage = .review
        } catch {
            if !Task.isCancelled {
                stage = .failed(language.text("Could not prepare the server list (1–100 servers)."))
            }
        }
    }

    func chooseKey(for id: String, language: AppInterfaceLanguage) {
        guard case .review = stage, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.title = language.text("Choose the private key for this server")
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let key = ReviewedKeyFile(url.path) {
            rows[index].keyFile = key
        } else {
            let alert = NSAlert()
            alert.messageText = language.text("Choose a readable private-key file up to 64 KiB.")
            alert.runModal()
        }
    }

    func start(language: AppInterfaceLanguage) {
        guard case .review = stage else { return }
        let sender = PairingSender()
        self.sender = sender
        stage = .starting
        sender.onFailure = { [weak self, weak sender] _ in
            guard let self, let sender, self.sender === sender else { return }
            self.stop()
            self.stage = .failed(language.text("The pairing expired or the iPhone disconnected. Start a new transfer."))
        }
        operation = Task {
            do {
                let invitation = try await sender.start { [weak self, weak sender] code in
                    guard let self, let sender, self.sender === sender else { return }
                    self.stage = .confirm(code)
                }
                try Task.checkCancellation()
                if case .starting = stage { stage = .scanning(invitation) }
            } catch {
                guard self.sender === sender else { return }
                stop()
                stage = .failed(language.text("Could not start pairing. Check Local Network permission and try again."))
            }
        }
    }

    func approve(language: AppInterfaceLanguage) {
        guard case .confirm = stage, let sender else { return }
        stage = .authorizing
        let context = LAContext()
        auth = context
        let reviewed = rows
        operation = Task {
            do {
                let authorized = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason:
                    language.text("Send SSH credentials to your iPhone."))
                guard authorized else { throw CancellationError() }
                try Task.checkCancellation()
                let batch = try await MacTransferPreparation.materialize(reviewed, batchID: UUID())
                let packet = try batch.encoded()
                try Task.checkCancellation()
                stage = .sending
                try await sender.send(packet)
                guard self.sender === sender else { return }
                stop()
                stage = .completed(batch.servers.count, batch.servers.filter { $0.setupIssue != nil }.count)
            } catch {
                guard self.sender === sender else { return }
                stop()
                stage = .failed(language.text("Transfer was not confirmed. Check the iPhone before trying again."))
            }
        }
    }

    func stop() {
        operation?.cancel()
        operation = nil
        auth?.invalidate()
        auth = nil
        let current = sender
        sender = nil
        current?.onFailure = nil
        current?.cancel()
    }
}

struct IPhoneTransferView: View {
    let settings: AppSettings
    let language: AppInterfaceLanguage
    let close: () -> Void
    @StateObject private var transfer = IPhoneTransfer()

    private func t(_ key: String, _ arguments: Any...) -> String {
        language.text(key, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                switch transfer.stage {
                case .confirm(let code):
                    Label(t("Verify the code"), systemImage: "lock.shield")
                        .font(.title2.bold())
                    Text(t("Check that the six digits match the code on your iPhone before approving the transfer."))
                        .foregroundStyle(.secondary)
                    Text(verbatim: code)
                        .font(.system(size: 36, weight: .semibold, design: .monospaced))
                        .tracking(3)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(code.map(String.init).joined(separator: " "))
                case .authorizing:
                    waiting(t("Approve on this Mac"),
                            detail: t("Use Touch ID or your Mac password to send SSH credentials to your iPhone."))
                case .sending:
                    waiting(t("Finish on your iPhone"),
                            detail: t("Review the servers on your iPhone and tap Import All. This window updates when saving finishes."))
                case .completed(let count, let needsSetup):
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30)).foregroundStyle(.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("Transfer complete")).font(.title2.bold())
                            Text(t("Your iPhone finished reviewing %@ server profiles.", count))
                            if needsSetup > 0 {
                                Text(t("%@ profiles need additional setup before connecting.", needsSetup))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                default:
                    Text(t("Transfer to iPhone")).font(.title2.bold())
                    transferStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(20)
            footer
        }
        .frame(width: 510, height: sheetHeight)
        .task { await transfer.review(settings, language: language) }
        .onDisappear { transfer.stop() }
    }

    @ViewBuilder private var footer: some View {
        switch transfer.stage {
        case .sending:
            EmptyView()
        default:
            Divider()
            HStack(spacing: 8) {
                Spacer()
                switch transfer.stage {
                case .completed:
                    Button(t("Done"), action: dismiss).keyboardShortcut(.defaultAction)
                case .confirm:
                    Button(t("Cancel"), action: dismiss).keyboardShortcut(.cancelAction)
                    Button(t("Codes Match — Approve")) { transfer.approve(language: language) }
                        .buttonStyle(.borderedProminent)
                case .review:
                    Button(t("Cancel"), action: dismiss).keyboardShortcut(.cancelAction)
                    Button(t("Show Pairing Code")) { transfer.start(language: language) }
                        .keyboardShortcut(.defaultAction)
                case .authorizing:
                    Button(t("Cancel"), action: dismiss).keyboardShortcut(.cancelAction)
                default:
                    Button(t("Close"), action: dismiss).keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
    }

    private var sheetHeight: CGFloat {
        switch transfer.stage {
        case .preparing, .review, .starting, .scanning: 440
        case .confirm, .authorizing, .sending, .completed, .failed: 235
        }
    }

    private func waiting(_ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView().controlSize(.small).padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dismiss() { transfer.stop(); close() }

    @ViewBuilder private var transferStep: some View {
        switch transfer.stage {
        case .preparing: ProgressView(t("Checking servers…"))
        case .review: review
        case .starting: ProgressView(t("Starting pairing…"))
        case .scanning(let invitation):
            Text(t("Connect both devices to the same local network. In NVBeacon on iPhone, choose Transfer from Mac and scan this code."))
                .fixedSize(horizontal: false, vertical: true)
            Link(t("Don't have NVBeacon on iPhone? Get it on the App Store"),
                 destination: URL(string: "https://apps.apple.com/app/nvbeacon/id6830951631")!)
                .font(.callout)
            if let image = qrImage(invitation) {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 218, height: 218).padding(20).background(.white)
                    .accessibilityLabel(t("One-time pairing QR code"))
                    .frame(maxWidth: .infinity)
            } else { Text(t("Could not display the pairing code.")) }
        case .failed(let message): Text(message)
        case .confirm, .authorizing, .sending, .completed: EmptyView()
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Review all %@ servers and their credential sources. Confirm each key file is the one you intend to copy.", transfer.rows.count))
            let ready = transfer.rows.filter(\.hasCredential).count
            Text(t("Credential sources: %@ · Settings only: %@", ready, transfer.rows.count - ready))
                .font(.subheadline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(transfer.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.server.displayName).font(.headline)
                            if let endpoint = row.endpoint {
                                Text("\(endpoint.user)@\(endpoint.host) · \(endpoint.port)").font(.caption)
                                if row.server.sshAuthenticationMode == .keyBased {
                                    HStack {
                                        Text(row.keyFile?.url.path ?? t("No key selected"))
                                            .font(.caption).lineLimit(2).truncationMode(.middle)
                                        Spacer()
                                        Button(t("Choose Key…")) { transfer.chooseKey(for: row.id, language: language) }
                                    }
                                } else {
                                    Text(row.hasCredential ? t("Saved Keychain password") :
                                            t("Password needed on iPhone")).font(.caption)
                                }
                            } else {
                                Text(t("Settings only · review this endpoint on iPhone.")).font(.caption)
                            }
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Text(t("Keys protected with a passphrase may need to be unlocked on iPhone. Servers arrive disabled."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func qrImage(_ invitation: String) -> NSImage? {
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(invitation.utf8)
        generator.correctionLevel = "M"
        guard let output = generator.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
