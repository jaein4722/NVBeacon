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

    private func t(_ key: String, _ arguments: Any...) -> String {
        language.text(key, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Review Server Import")).font(.title2.bold())
            Text(fileName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text(t("Add %@ servers. Your %@ existing servers will be kept. Imported servers start disabled.", backup.servers.count, existingServerCount))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(backup.servers.enumerated()), id: \.offset) { _, server in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(server.displayName).font(.headline)
                                LabeledContent(t("SSH target"), value: server.sshTarget)
                                LabeledContent(t("Port"), value: server.sshPort.isEmpty ? t("Default") : server.sshPort)
                                LabeledContent(t("Authentication"), value: server.sshAuthenticationMode.title(in: language))
                                LabeledContent(t("SSH connection"), value: server.sshConnectionReuseMode.title(in: language))
                                if !server.sshIdentityFilePath.isEmpty {
                                    Text(t("Identity file: ") + server.sshIdentityFilePath)
                                        .font(.caption).textSelection(.enabled)
                                }
                                Text(t("GPU command")).font(.caption.weight(.semibold))
                                Text(server.remoteCommand).font(.caption.monospaced()).textSelection(.enabled)
                                Text(t("Host information command")).font(.caption.weight(.semibold))
                                Text(server.hostCommand).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                    }
                }
            }
            Text(t("Keychain passwords are not included. Review the connection details and commands before adding the servers.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(t("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(t("Add Servers"), action: importServers).keyboardShortcut(.defaultAction)
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

    private func t(_ key: String, _ arguments: Any...) -> String {
        language.text(key, arguments: arguments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("Diagnostic Information")).font(.title2.bold())
            Text(t("Review this local snapshot before sharing it. Hosts, users, key paths, custom commands and raw errors are omitted.")).font(.callout).foregroundStyle(.secondary)
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
                    Label(t("Copied"), systemImage: "checkmark").foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("Close"), action: close).keyboardShortcut(.cancelAction)
                Button(t("Copy")) {
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
