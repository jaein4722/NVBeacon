import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ServerBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw ServerSettingsBackup.BackupError.unsupportedFormat
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        makeFileWrapper()
    }

    func makeFileWrapper() -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: data)
        var attributes = wrapper.fileAttributes
        attributes[FileAttributeKey.posixPermissions.rawValue] = 0o600
        wrapper.fileAttributes = attributes
        return wrapper
    }
}

enum SettingsUtilitySheet: Identifiable {
    case importServers(ServerSettingsBackup, String)
    case diagnostics(String)
    case transfer

    var id: String {
        switch self {
        case .importServers: "import"
        case .diagnostics: "diagnostics"
        case .transfer: "transfer"
        }
    }
}

struct ServerImportReviewView: View {
    let backup: ServerSettingsBackup
    let fileName: String
    let existingServerCount: Int
    let language: AppInterfaceLanguage
    let importServers: () -> Void
    let cancel: () -> Void

    private func t(_ english: String, _ korean: String) -> String { language.text(english, korean) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Review Server Import", "서버 가져오기 확인")).font(.title2.bold())
            Text(fileName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text(t(
                "Add \(backup.servers.count) servers. Your \(existingServerCount) existing servers will be kept. Imported servers start disabled.",
                "서버 \(backup.servers.count)개를 추가합니다. 기존 서버 \(existingServerCount)개는 유지되며, 가져온 서버는 비활성화 상태로 시작합니다."
            ))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(backup.servers.enumerated()), id: \.offset) { _, server in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(server.displayName).font(.headline)
                                LabeledContent(t("SSH target", "SSH 대상"), value: server.sshTarget)
                                LabeledContent(t("Port", "포트"), value: server.sshPort.isEmpty ? t("Default", "기본값") : server.sshPort)
                                LabeledContent(t("Authentication", "인증 방식"), value: server.sshAuthenticationMode.title(in: language))
                                LabeledContent(t("SSH connection", "SSH 연결"), value: server.sshConnectionReuseMode.title(in: language))
                                if !server.sshIdentityFilePath.isEmpty {
                                    Text(t("Identity file: ", "Identity 파일: ") + server.sshIdentityFilePath)
                                        .font(.caption).textSelection(.enabled)
                                }
                                Text(t("GPU command", "GPU 명령")).font(.caption.weight(.semibold))
                                Text(server.remoteCommand).font(.caption.monospaced()).textSelection(.enabled)
                                Text(t("Host information command", "호스트 정보 수집 명령")).font(.caption.weight(.semibold))
                                Text(server.hostCommand).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                    }
                }
            }
            Text(t(
                "Keychain passwords are not included. Review the connection details and commands before adding the servers.",
                "Keychain 비밀번호는 포함되지 않습니다. 연결 정보와 명령을 확인한 뒤 서버를 추가하세요."
            )).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(t("Cancel", "취소"), action: cancel).keyboardShortcut(.cancelAction)
                Button(t("Add Servers", "서버 추가"), action: importServers).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 650, height: 580)
    }
}

struct DiagnosticsPreviewView: View {
    let report: String
    let language: AppInterfaceLanguage
    let close: () -> Void
    @State private var copied = false

    private func t(_ english: String, _ korean: String) -> String { language.text(english, korean) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Diagnostic Information", "진단 정보")).font(.title2.bold())
            Text(t(
                "Review this local snapshot before sharing it. Hosts, users, key paths, custom commands and raw errors are omitted.",
                "공유 전에 내용을 확인하세요. 호스트·사용자·키 경로·커스텀 명령·원문 오류는 제외한 현재 상태입니다."
            )).font(.callout).foregroundStyle(.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                if copied {
                    Label(t("Copied", "복사됨"), systemImage: "checkmark").foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("Close", "닫기"), action: close).keyboardShortcut(.cancelAction)
                Button(t("Copy", "복사")) {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(report, forType: .string)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 650, height: 580)
    }
}
