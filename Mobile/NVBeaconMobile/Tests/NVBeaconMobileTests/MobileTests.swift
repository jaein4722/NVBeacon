import Foundation
import Testing
import NVBeaconCore
@testable import NVBeaconMobile

@Test func endpointChangesInvalidateTrust() throws {
    var server = MobileServer()
    server.host = "gpu.example.com"
    server.username = "researcher"
    server.trustedHostKey = "previous-key"
    server.trustedEndpoint = server.endpoint
    #expect(try server.validated().pinnedHostKey == "previous-key")
    server.port = 2222
    #expect(server.pinnedHostKey == nil)
    #expect(try server.validated().trustedHostKey == nil)
}

@Test func importRequiresLocalCredentialsAndDoesNotTrustDesktopKeys() throws {
    let entry = ServerSettingsBackup.Entry(name: "Lab", sshTarget: "researcher@gpu.example.com", sshPort: "2222",
        sshIdentityFilePath: "/desktop/only/id_ed25519", sshAuthenticationMode: .keyBased,
        sshConnectionReuseMode: .reuseWhenPossible, remoteCommand: "custom-gpu", memoryCommand: "custom-memory")
    let server = MobileServer.importing(entry)
    #expect(server.host == "gpu.example.com")
    #expect(server.username == "researcher")
    #expect(server.port == 2222)
    #expect(!server.isEnabled)
    #expect(server.pinnedHostKey == nil)
    #expect(server.backupEntry.sshIdentityFilePath.isEmpty)
    #expect(server.backupEntry.remoteCommand == "custom-gpu")
    #expect(MobileServer.importing(entry).id != server.id)
}

@Test func aliasesWithoutUserMustBeEditedBeforeConnecting() {
    var server = MobileServer()
    server.host = "lab-alias"
    #expect(throws: MobileError.invalidServer) { try server.validated() }
    server.username = "researcher"
    server.port = 65536
    #expect(throws: MobileError.invalidServer) { try server.validated() }
}

@Test func desktopAliasAndWhitespacePortSurviveArchiveReview() throws {
    let entry = ServerSettingsBackup.Entry(name: "Lab", sshTarget: "lab-alias", sshPort: " 2222 ",
        sshIdentityFilePath: "", sshAuthenticationMode: .keyBased,
        sshConnectionReuseMode: .reuseWhenPossible, remoteCommand: "custom-gpu", memoryCommand: "custom-memory")
    let backup = ServerSettingsBackup(servers: [entry])
    try backup.validate()
    let server = MobileServer.importing(entry)
    #expect(server.port == 2222)
    #expect(server.username.isEmpty)
    #expect(server.backupEntry.sshTarget == "lab-alias")
    #expect(!server.isEnabled)
}

@Test @MainActor func rejectedHostKeyCannotAuthorizeEditedServer() throws {
    let name = "NVBeaconMobileTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = MobileStore(defaults: defaults)
    var server = MobileServer()
    server.host = "gpu.example.com"
    server.username = "researcher"
    server.isEnabled = false
    let backup = ServerSettingsBackup(servers: [server.backupEntry])
    try store.importServers(backup)
    let imported = try #require(store.servers.first)
    try store.trustHost(for: imported, key: "unrequested-key")
    #expect(store.servers.first?.pinnedHostKey == nil)
    let restored = MobileStore(defaults: defaults)
    #expect(restored.servers == store.servers)
    let data = try restored.exportServers()
    #expect(try ServerSettingsBackup.decode(data).servers.count == 1)
    #expect(!String(decoding: data, as: UTF8.self).contains("trustedHostKey"))
}

@Test func alreadyCancelledTransportDoesNotConnect() async {
    let transport = SSHTransport(server: MobileServer(), credential: .init())
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await transport.execute("unused")
    }
    do { _ = try await task.value; Issue.record("Cancelled transport executed") }
    catch { #expect(error is CancellationError) }
}
