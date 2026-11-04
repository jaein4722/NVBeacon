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
                stage = .failed(language.text("Could not prepare the server list (1–100 servers).", "서버 목록을 준비할 수 없습니다(1~100개)."))
            }
        }
    }

    func chooseKey(for id: String, language: AppInterfaceLanguage) {
        guard case .review = stage, let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.title = language.text("Choose the private key for this server", "이 서버에 사용할 개인 키 선택")
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let key = ReviewedKeyFile(url.path) {
            rows[index].keyFile = key
        } else {
            let alert = NSAlert()
            alert.messageText = language.text("Choose a readable private-key file up to 64 KiB.", "읽을 수 있는 64 KiB 이하 개인 키 파일을 선택하세요.")
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
            self.stage = .failed(language.text("The pairing expired or the iPhone disconnected. Start a new transfer.",
                                                "페어링 시간이 만료됐거나 iPhone 연결이 끊겼습니다. 새 전송을 시작하세요."))
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
                stage = .failed(language.text("Could not start pairing. Check Local Network permission and try again.",
                                              "페어링을 시작할 수 없습니다. 로컬 네트워크 권한을 확인하고 다시 시도하세요."))
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
                    language.text("Send SSH credentials to your iPhone.", "iPhone으로 SSH 인증정보를 전송합니다."))
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
                stage = .failed(language.text("Transfer was not confirmed. Check the iPhone before trying again.",
                                              "전송 완료를 확인하지 못했습니다. 다시 시도하기 전에 iPhone을 확인하세요."))
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

    private func t(_ en: String, _ ko: String) -> String { language.text(en, ko) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                switch transfer.stage {
                case .confirm(let code):
                    Label(t("Verify the code", "확인 코드 대조"), systemImage: "lock.shield")
                        .font(.title2.bold())
                    Text(t("Check that the six digits match the code on your iPhone before approving the transfer.",
                           "iPhone에 표시된 여섯 자리 코드가 아래와 일치하면 전송을 승인하세요."))
                        .foregroundStyle(.secondary)
                    Text(verbatim: code)
                        .font(.system(size: 36, weight: .semibold, design: .monospaced))
                        .tracking(3)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(code.map(String.init).joined(separator: " "))
                case .authorizing:
                    waiting(t("Approve on this Mac", "Mac에서 전송 승인"),
                            detail: t("Use Touch ID or your Mac password to send SSH credentials to your iPhone.",
                                      "Touch ID 또는 Mac 암호로 SSH 인증정보 전송을 승인하세요."))
                case .sending:
                    waiting(t("Finish on your iPhone", "iPhone에서 가져오기"),
                            detail: t("Review the servers on your iPhone and tap Import All. This window updates when saving finishes.",
                                      "iPhone에서 서버 목록을 확인하고 ‘모두 가져오기’를 누르세요. 저장이 끝나면 여기에 결과가 표시됩니다."))
                case .completed(let count, let needsSetup):
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30)).foregroundStyle(.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t("Transfer complete", "전송 완료")).font(.title2.bold())
                            Text(t("Your iPhone finished reviewing \(count) server profiles.",
                                   "iPhone에서 서버 설정 \(count)개를 확인했습니다."))
                            if needsSetup > 0 {
                                Text(t("\(needsSetup) profiles need additional setup before connecting.",
                                       "연결하기 전에 서버 \(needsSetup)개의 추가 설정이 필요합니다."))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                default:
                    Text(t("Transfer to iPhone", "iPhone으로 전송")).font(.title2.bold())
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
                    Button(t("Done", "완료"), action: dismiss).keyboardShortcut(.defaultAction)
                case .confirm:
                    Button(t("Cancel", "취소"), action: dismiss).keyboardShortcut(.cancelAction)
                    Button(t("Codes Match — Approve", "코드 일치 · 전송 승인")) { transfer.approve(language: language) }
                        .buttonStyle(.borderedProminent)
                case .review:
                    Button(t("Cancel", "취소"), action: dismiss).keyboardShortcut(.cancelAction)
                    Button(t("Show Pairing Code", "페어링 코드 표시")) { transfer.start(language: language) }
                        .keyboardShortcut(.defaultAction)
                case .authorizing:
                    Button(t("Cancel", "취소"), action: dismiss).keyboardShortcut(.cancelAction)
                default:
                    Button(t("Close", "닫기"), action: dismiss).keyboardShortcut(.cancelAction)
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
        case .preparing: ProgressView(t("Checking servers…", "서버 확인 중…"))
        case .review: review
        case .starting: ProgressView(t("Starting pairing…", "페어링 준비 중…"))
        case .scanning(let invitation):
            Text(t("Connect both devices to the same local network. In NVBeacon on iPhone, choose Transfer from Mac and scan this code.",
                   "두 기기를 같은 로컬 네트워크에 연결하세요. iPhone의 NVBeacon에서 Mac에서 가져오기를 선택하고 코드를 스캔하세요."))
                .fixedSize(horizontal: false, vertical: true)
            if let image = qrImage(invitation) {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 218, height: 218).padding(20).background(.white)
                    .accessibilityLabel(t("One-time pairing QR code", "일회용 페어링 QR 코드"))
                    .frame(maxWidth: .infinity)
            } else { Text(t("Could not display the pairing code.", "페어링 코드를 표시할 수 없습니다.")) }
        case .failed(let message): Text(message)
        case .confirm, .authorizing, .sending, .completed: EmptyView()
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("Review all \(transfer.rows.count) servers and their credential sources. Confirm each key file is the one you intend to copy.",
                   "서버 \(transfer.rows.count)개와 인증정보 출처를 검토하세요. 각 개인 키가 복사하려는 파일과 일치하는지 확인하세요."))
            let ready = transfer.rows.filter(\.hasCredential).count
            Text(t("Credential sources: \(ready) · Settings only: \(transfer.rows.count - ready)",
                   "인증정보 출처 확인 \(ready)개 · 설정만 이전 \(transfer.rows.count - ready)개"))
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
                                        Text(row.keyFile?.url.path ?? t("No key selected", "선택된 키 없음"))
                                            .font(.caption).lineLimit(2).truncationMode(.middle)
                                        Spacer()
                                        Button(t("Choose Key…", "키 선택…")) { transfer.chooseKey(for: row.id, language: language) }
                                    }
                                } else {
                                    Text(row.hasCredential ? t("Saved Keychain password", "Keychain에 저장된 비밀번호") :
                                            t("Password needed on iPhone", "iPhone에서 비밀번호 입력 필요")).font(.caption)
                                }
                            } else {
                                Text(t("Settings only · review this endpoint on iPhone.", "설정만 이전 · iPhone에서 접속 경로 확인 필요")).font(.caption)
                            }
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Text(t("Keys protected with a passphrase may need to be unlocked on iPhone. Servers arrive disabled.",
                   "암호가 걸린 키는 iPhone에서 키 암호 입력이 필요할 수 있습니다. 가져온 서버는 비활성 상태로 추가됩니다."))
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
