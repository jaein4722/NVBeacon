import SwiftUI
import UniformTypeIdentifiers
import NVBeaconCore
import NVBeaconMobile

struct ServerEditor: View {
    let store: MobileStore
    @State var server: MobileServer
    @State private var hostCommandDraft: String
    @State private var credential = MobileCredential()
    private enum Field: Hashable {
        case server(MobileServer.InvalidField), key, passphrase, password
    }
    @State private var portText: String
    @State private var commandsExpanded = false
    @FocusState private var focus: Field?
    @State private var issue: (field: Field, message: String)?
    @State private var error: String?
    @State private var keyImporterPresented = false
    @State private var deletePresented = false
    @State private var resetTrustPresented = false
    @State private var keyInfo: ImportedSSHKey?
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss
    private var isExisting: Bool { store.servers.contains { $0.id == server.id } }

    init(store: MobileStore, server: MobileServer) {
        self.store = store
        _server = State(initialValue: server)
        _portText = State(initialValue: String(server.port))
        _hostCommandDraft = State(initialValue: RemoteMetricCommands.resolveHostCommand(
            server.hostCommand, legacyMemoryCommand: server.memoryCommand))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in form(proxy) }
        }
    }

    private func form(_ proxy: ScrollViewProxy) -> some View {
        Form {
            Group {
                Section("Server") {
                    TextField("Name (optional)", text: $server.name)
                    fieldRow(.server(.host)) {
                        TextField("Hostname or IP address", text: $server.host).keyboardType(.URL)
                            .focused($focus, equals: .server(.host))
                    }
                    fieldRow(.server(.username)) {
                        TextField("SSH username", text: $server.username).focused($focus, equals: .server(.username))
                    }
                    fieldRow(.server(.port)) {
                        LabeledContent("Port") {
                            TextField("22", text: $portText).focused($focus, equals: .server(.port))
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
                    }
                    Toggle("Enable monitoring", isOn: $server.isEnabled)
                }
                Section {
                    Picker("Authentication", selection: $server.authentication) {
                        Text("SSH Key").tag(SSHAuthenticationMode.keyBased)
                        Text("Password").tag(SSHAuthenticationMode.passwordBased)
                    }
                    .onChange(of: server.authentication) { _, _ in credential = MobileCredential(); keyInfo = nil }
                    if server.authentication == .passwordBased {
                        fieldRow(.password) {
                            SecureField("SSH password", text: $credential.secret).focused($focus, equals: .password)
                        }
                    } else {
                        fieldRow(.key) {
                            Button(credential.secret.isEmpty ? "Import Private Key" : "Replace Imported Key", systemImage: "key") {
                                keyImporterPresented = true
                            }
                        }
                        if !credential.secret.isEmpty { Label("\(keyInfo?.algorithm ?? "SSH") key selected", systemImage: "checkmark.circle").foregroundStyle(.green) }
                        if keyInfo?.requiresPassphrase == true {
                            fieldRow(.passphrase) {
                                SecureField("Key passphrase", text: $credential.passphrase).focused($focus, equals: .passphrase)
                            }
                        }
                    }
                } header: { Text("Credentials") } footer: {
                    Text("Stored only in this device’s Keychain. Ed25519, RSA and ECDSA keys are detected automatically in OpenSSH and unencrypted PEM files. Password authentication requires the server to allow it; interactive MFA is not supported.")
                }
                Section {
                    Toggle("Reuse SSH connection", isOn: Binding(get: { server.reusesConnection }, set: {
                        server.connectionReuseMode = $0 ? .reuseWhenPossible : .newConnectionEachRefresh
                    }))
                    DisclosureGroup("Remote commands", isExpanded: $commandsExpanded) {
                        fieldRow(.server(.gpuCommand)) {
                            Text("GPU command").font(.subheadline)
                            TextField("GPU command", text: $server.gpuCommand, axis: .vertical)
                                .font(.caption.monospaced()).focused($focus, equals: .server(.gpuCommand))
                        }
                        VStack(alignment: .leading) {
                            Text("Host info command").font(.subheadline)
                            TextField("Host info command", text: $hostCommandDraft, axis: .vertical)
                                .font(.caption.monospaced()).lineLimit(3...8)
                            Button("Restore default host command") {
                                hostCommandDraft = RemoteMetricCommands.hostInfo(memoryCommand: server.memoryCommand)
                            }.font(.footnote)
                        }
                    }
                    if server.pinnedHostKey != nil {
                        Button("Reset Host Key Trust", role: .destructive) { resetTrustPresented = true }
                    }
                } footer: { Text("Commands run on the remote Linux server using your SSH account.") }
                if isExisting {
                    Section { Button("Delete Server", role: .destructive) { deletePresented = true } }
                }
            }
            .monitorRowInsets()
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle(isExisting ? "Edit Server" : "Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", systemImage: "checkmark") {
                    save(using: proxy)
                }.disabled(!loaded)
            }
        }
        .task {
            guard !loaded else { return }
            do {
                credential = try store.credential(for: server)
                if server.authentication == .keyBased { keyInfo = try? ImportedSSHKey(credential.secret) }
                loaded = true
            }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: server) { _, _ in issue = nil }
        .onChange(of: portText) { _, _ in issue = nil }
        .onChange(of: credential) { _, _ in issue = nil }
        .alert("NVBeacon", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(LocalizedStringKey(error ?? "")) }
        .fileImporter(isPresented: $keyImporterPresented, allowedContentTypes: [.data, .plainText]) { result in
            do {
                let data = try readDocument(try result.get(), maximumBytes: 65_536)
                guard let key = String(data: data, encoding: .utf8) else { throw MobileError.unsupportedKey }
                keyInfo = try ImportedSSHKey(key)
                credential = MobileCredential(secret: key)
                error = nil
            } catch let cancellation as CocoaError where cancellation.code == .userCancelled {
                return
            } catch { show(error.localizedDescription, at: .key, using: proxy) }
        }
        .confirmationDialog("Delete this server and its saved credentials?", isPresented: $deletePresented, titleVisibility: .visible) {
            Button("Delete Server", role: .destructive) {
                do { try store.delete(server); dismiss() }
                catch { self.error = error.localizedDescription }
            }
        }
        .confirmationDialog("Reset the pinned SSH host key? Verify the new fingerprint before trusting the next connection.", isPresented: $resetTrustPresented, titleVisibility: .visible) {
            Button("Reset Trust", role: .destructive) { server.trustedHostKey = nil; server.trustedEndpoint = nil }
        }
    }

    private func fieldRow<Content: View>(_ field: Field, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            if let issue, issue.field == field {
                Text(LocalizedStringKey(issue.message)).font(.footnote).foregroundStyle(.red)
            }
        }.id(field)
    }

    private func show(_ message: String, at field: Field, using proxy: ScrollViewProxy) {
        issue = (field, message)
        if field == .server(.gpuCommand) { commandsExpanded = true }
        Task { @MainActor in
            await Task.yield()
            guard issue?.field == field else { return }
            focus = field == .key ? nil : field
            proxy.scrollTo(field, anchor: .center)
        }
    }

    private func save(using proxy: ScrollViewProxy) {
        var edited = server
        edited.port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if let invalid = edited.firstInvalidField {
            let message = switch invalid {
            case .host: "Enter a hostname or IP address without a username or path."
            case .username: "Enter an SSH username without spaces."
            case .port: "Enter a port between 1 and 65535."
            case .gpuCommand: "Enter the GPU query command."
            }
            show(message, at: .server(invalid), using: proxy)
            return
        }
        let script = hostCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let inherited = RemoteMetricCommands.hostInfo(memoryCommand: server.memoryCommand)
        edited.hostCommand = script.isEmpty || script == inherited ? nil : script
        do {
            try store.save(edited, credential: credential)
            dismiss()
        } catch MobileError.missingCredential {
            if edited.authentication == .passwordBased {
                show("Enter the SSH password.", at: .password, using: proxy)
            } else {
                show("Import the private key for this server.", at: .key, using: proxy)
            }
        } catch let failure as MobileError {
            switch failure {
            case .keyPassphraseRequired, .cannotUnlockKey:
                show(failure.localizedDescription, at: keyInfo?.requiresPassphrase == true ? .passphrase : .key, using: proxy)
            case .invalidKeyFile, .unsupportedKey, .unsupportedKeyProtection, .unsupportedRSAKeySize:
                show(failure.localizedDescription, at: .key, using: proxy)
            default:
                error = failure.localizedDescription
            }
        } catch { self.error = error.localizedDescription }
    }
}
