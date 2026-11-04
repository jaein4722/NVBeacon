import SwiftUI
import UniformTypeIdentifiers
import NVBeaconCore
import NVBeaconMobile

struct ServerEditor: View {
    let store: MobileStore
    @State var server: MobileServer
    @State private var credential = MobileCredential()
    @State private var error: String?
    @State private var keyImporterPresented = false
    @State private var deletePresented = false
    @State private var resetTrustPresented = false
    @State private var keyInfo: ImportedSSHKey?
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss
    private var isExisting: Bool { store.servers.contains { $0.id == server.id } }

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
                    DisclosureGroup("Remote commands") {
                        TextField("GPU command", text: $server.gpuCommand, axis: .vertical).font(.caption.monospaced())
                        TextField("Host info command (optional)", text: Binding(get: { server.hostCommand ?? "" },
                            set: { server.hostCommand = $0.isEmpty ? nil : $0 }), axis: .vertical).font(.caption.monospaced())
                        TextField("Memory command", text: $server.memoryCommand, axis: .vertical).font(.caption.monospaced())
                    }
                    if server.pinnedHostKey != nil {
                        Button("Reset Host Key Trust", role: .destructive) { resetTrustPresented = true }
                    }
                } footer: { Text("Commands run on the remote Linux server using your SSH account.") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
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
                        do { try store.save(server, credential: credential); dismiss() }
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
