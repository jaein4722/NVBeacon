import SwiftUI
import UniformTypeIdentifiers
import NVBeaconCore
import NVBeaconMobile

struct ServerEditor: View {
    let store: MobileStore
    @State var server: MobileServer
    @State private var hostCommandDraft: String
    @State private var credential = MobileCredential()
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
        _hostCommandDraft = State(initialValue: RemoteMetricCommands.resolveHostCommand(
            server.hostCommand, legacyMemoryCommand: server.memoryCommand))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (optional)", text: $server.name)
                    TextField("Hostname or IP address", text: $server.host).keyboardType(.URL)
                    TextField("SSH username", text: $server.username)
                    LabeledContent("Port") {
                        TextField("22", value: $server.port, format: .number.grouping(.never))
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
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
                        SecureField("SSH password", text: $credential.secret)
                    } else {
                        Button(credential.secret.isEmpty ? "Import Private Key" : "Replace Imported Key", systemImage: "key") {
                            keyImporterPresented = true
                        }
                        if !credential.secret.isEmpty { Label("\(keyInfo?.algorithm ?? "SSH") key selected", systemImage: "checkmark.circle").foregroundStyle(.green) }
                        if keyInfo?.requiresPassphrase == true { SecureField("Key passphrase", text: $credential.passphrase) }
                    }
                } header: { Text("Credentials") } footer: {
                    Text("Stored only in this device’s Keychain. Ed25519, RSA and ECDSA keys are detected automatically in OpenSSH and unencrypted PEM files. Password authentication requires the server to allow it; interactive MFA is not supported.")
                }
                Section {
                    Toggle("Reuse SSH connection", isOn: Binding(get: { server.reusesConnection }, set: {
                        server.connectionReuseMode = $0 ? .reuseWhenPossible : .newConnectionEachRefresh
                    }))
                    DisclosureGroup("Remote commands") {
                        VStack(alignment: .leading) {
                            Text("GPU command").font(.subheadline)
                            TextField("GPU command", text: $server.gpuCommand, axis: .vertical)
                                .font(.caption.monospaced())
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
                if let error { Section { Text(LocalizedStringKey(error)).foregroundStyle(.red) } }
                if isExisting {
                    Section { Button("Delete Server", role: .destructive) { deletePresented = true } }
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle(isExisting ? "Edit Server" : "Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            var edited = server
                            let script = hostCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            let inherited = RemoteMetricCommands.hostInfo(memoryCommand: server.memoryCommand)
                            edited.hostCommand = script.isEmpty || script == inherited ? nil : script
                            try store.save(edited, credential: credential)
                            dismiss()
                        }
                        catch { self.error = error.localizedDescription }
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
            .fileImporter(isPresented: $keyImporterPresented, allowedContentTypes: [.data, .plainText]) { result in
                do {
                    let data = try readDocument(try result.get(), maximumBytes: 65_536)
                    guard let key = String(data: data, encoding: .utf8) else { throw MobileError.unsupportedKey }
                    keyInfo = try ImportedSSHKey(key)
                    credential = MobileCredential(secret: key)
                    error = nil
                } catch { self.error = error.localizedDescription }
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
    }
}
