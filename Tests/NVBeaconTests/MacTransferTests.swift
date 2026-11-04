import Foundation
import Testing
import NVBeaconTransfer
@testable import NVBeacon

private func withTransferFixture(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

@Test func transferReviewLimitsIdentitySourcesAndIncludesEveryConfiguredServer() async throws {
    try await withTransferFixture { directory in
        let config = directory.appendingPathComponent("config")
        let key = directory.appendingPathComponent("key")
        try Data("placeholder".utf8).write(to: key)
        try """
        Host fixture
          HostName gpu.example.invalid
          User researcher
          Port 2202
          IdentityFile "\(key.path)"
        Host proxied
          ProxyJump jump.example.invalid
        """.write(to: config, atomically: true, encoding: .utf8)
        let rows = try await MacTransferPreparation.review(settings: AppSettings(servers: [
            ServerConfig(name: "Fixture", sshTarget: "fixture"), ServerConfig(sshTarget: "proxied", isEnabled: false),
            ServerConfig(sshTarget: "default.example.invalid")
        ]), configFile: config, hasPassword: { _ in false })
        #expect(rows.count == 3)
        #expect(rows[0].endpoint?.user == "researcher")
        #expect(rows[0].endpoint?.host == "gpu.example.invalid")
        #expect(rows[0].endpoint?.port == 2202)
        #expect(rows[0].keyFile?.url == key.standardizedFileURL.resolvingSymlinksInPath())
        #expect(rows[1].issue != nil && rows[1].keyFile == nil)
        #expect(rows[2].keyFile == nil)
        let batch = try await MacTransferPreparation.materialize(rows, batchID: UUID(), readPassword: { _ in
            Issue.record("Unexpected password read"); return ""
        })
        #expect(batch.servers.count == 3)
        #expect(batch.credentials.isEmpty)
        #expect(batch.servers.allSatisfy { $0.setupIssue != nil })
    }
}

@Test func missingSavedIdentityFallsBackToTheSingleConfiguredKey() async throws {
    try await withTransferFixture { directory in
        let key = directory.appendingPathComponent("configured key")
        let other = directory.appendingPathComponent("second key")
        try Data("fixture".utf8).write(to: key)
        try Data("fixture".utf8).write(to: other)
        let config = directory.appendingPathComponent("config")
        let profile = ServerConfig(sshTarget: "lab", sshIdentityFilePath: directory.appendingPathComponent("removed-key").path)
        let settings = AppSettings(servers: [profile])
        let single = "Host lab\n  HostName gpu.example.invalid\n  IdentityFile \"\(key.path)\"\n"
        try single.write(to: config, atomically: true, encoding: .utf8)
        let resolved = try await MacTransferPreparation.review(settings: settings, configFile: config)
        #expect(resolved.first?.keyFile?.url == key.standardizedFileURL.resolvingSymlinksInPath())
        try (single + "  IdentityFile \"\(other.path)\"\n").write(to: config, atomically: true, encoding: .utf8)
        let ambiguous = try await MacTransferPreparation.review(settings: settings, configFile: config)
        #expect(ambiguous.first?.keyFile == nil)
    }
}

@Test func transferPreservesIdentityOfTraditionalRSAPEM() async throws {
    try await withTransferFixture { directory in
        let source = directory.appendingPathComponent("fixture.pem")
        let converted = directory.appendingPathComponent("transferred")
        let runner = ProcessCommandRunner()
        let keygen = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        let generated = try await runner.run(executable: keygen,
            arguments: ["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "", "-f", source.path])
        try #require(generated.exitStatus == 0)
        let endpoint = EffectiveSSHProfile(host: "gpu.example.invalid", user: "fixture", port: 22, proxy: nil, identityFiles: [])
        let row = MacTransferRow(server: ServerConfig(sshTarget: "fixture"), endpoint: endpoint, issue: nil,
                                 keyFile: ReviewedKeyFile(source.path), passwordAccount: nil)
        let batch = try await MacTransferPreparation.materialize([row], batchID: UUID())
        let recovered = try TransferBatch.decode(batch.encoded())
        try #require(recovered.servers.first?.setupIssue == nil)
        let ref = try #require(recovered.servers.first?.credentialID)
        guard let identity = recovered.credentials[ref] else { Issue.record("Missing transferred RSA key"); return }
        try Data(identity.secret.utf8).write(to: converted)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: converted.path)
        let originalPublic = try await runner.run(executable: keygen, arguments: ["-y", "-f", source.path])
        let transferredPublic = try await runner.run(executable: keygen, arguments: ["-y", "-f", converted.path])
        #expect(originalPublic.exitStatus == 0 && transferredPublic.exitStatus == 0)
        #expect(originalPublic.standardOutput == transferredPublic.standardOutput)
        let message = directory.appendingPathComponent("message")
        try Data("fixture".utf8).write(to: message)
        let signed = try await runner.run(executable: keygen,
            arguments: ["-Y", "sign", "-f", converted.path, "-n", "fixture", message.path])
        #expect(signed.exitStatus == 0)
    }
}

@Test func transferRejectsChangedIdentityAndKeepsCredentialsOutOfJSON() async throws {
    try await withTransferFixture { directory in
        let key = directory.appendingPathComponent("key")
        let runner = ProcessCommandRunner()
        let result = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"),
            arguments: ["-q", "-t", "ed25519", "-a", "4", "-N", "fixture-only", "-f", key.path])
        try #require(result.exitStatus == 0)
        let reviewed = try #require(ReviewedKeyFile(key.path))
        let endpoint = EffectiveSSHProfile(host: "gpu.example.invalid", user: "fixture", port: 22, proxy: nil, identityFiles: [])
        let one = ServerConfig(id: "legacy-primary", sshTarget: "fixture", sshIdentityFilePath: key.path)
        let two = ServerConfig(sshTarget: "fixture2", sshIdentityFilePath: key.path)
        let pass = ServerConfig(sshTarget: "password", sshAuthenticationMode: .passwordBased)
        let rows = [one, two].map { MacTransferRow(server: $0, endpoint: endpoint, issue: nil, keyFile: reviewed, passwordAccount: nil) }
            + [MacTransferRow(server: pass, endpoint: endpoint, issue: nil, keyFile: nil, passwordAccount: pass.keychainAccount)]
        let batch = try await MacTransferPreparation.materialize(rows, batchID: UUID(), readPassword: { _ in "fixture-password" })
        #expect(batch.credentials.count == 2)
        #expect(batch.servers[0].credentialID == batch.servers[1].credentialID)
        #expect(batch.servers[0].setupIssue != nil)
        #expect(batch.servers[2].setupIssue == nil)
        let restored = try TransferBatch.decode(batch.encoded())
        #expect(restored.servers.count == 3)
        let json = String(decoding: try ServerSettingsBackup(settings: AppSettings(servers: [one, two, pass])).encoded(), as: UTF8.self)
        #expect(!json.contains("fixture-password"))
        #expect(!json.contains("BEGIN OPENSSH PRIVATE KEY"))
        try FileManager.default.removeItem(at: key)
        try Data("different".utf8).write(to: key)
        #expect(throws: MacTransferError.self) { try reviewed.read() }
    }
}
