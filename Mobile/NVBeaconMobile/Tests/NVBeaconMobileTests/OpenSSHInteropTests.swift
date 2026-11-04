#if os(macOS)
import Foundation
import Testing
@testable import NVBeaconMobile

// scripts/test_ios_ssh_keys.sh owns the ephemeral sshd, keys and pinned host key.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NVBEACON_KEY_FIXTURE"] != nil),
      arguments: ["ed25519", "rsa", "256", "384", "521"])
func importedKeyAuthenticatesToOpenSSH(_ variant: String) async throws {
    let env = ProcessInfo.processInfo.environment
    let folder = URL(fileURLWithPath: try #require(env["NVBEACON_KEY_FIXTURE"]))
    let key = try String(contentsOf: folder.appendingPathComponent(variant), encoding: .utf8)
    let info = try ImportedSSHKey(key)
    let expected = ["ed25519": "Ed25519", "rsa": "RSA"][variant] ?? "ECDSA P-" + variant
    #expect(info.algorithm == expected)
    #expect(info.requiresPassphrase)
    #expect(throws: MobileError.keyPassphraseRequired) { try SSHTransport.validatePrivateKey(.init(secret: key)) }
    #expect(throws: MobileError.cannotUnlockKey) { try SSHTransport.validatePrivateKey(.init(secret: key, passphrase: "incorrect")) }
    var server = MobileServer()
    server.host = "127.0.0.1"
    server.port = try #require(env["NVBEACON_KEY_PORT"].flatMap(Int.init))
    server.username = NSUserName()
    server.trustedEndpoint = server.endpoint
    let pub = try String(contentsOf: folder.appendingPathComponent("host.pub"), encoding: .utf8)
    server.trustedHostKey = pub.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
    let plainKey = try String(contentsOf: folder.appendingPathComponent(variant + "-plain"), encoding: .utf8)
    #expect(try !ImportedSSHKey(plainKey).requiresPassphrase)
    for credential in [MobileCredential(secret: key, passphrase: "fixture-only"), .init(secret: plainKey)] {
        let transport = SSHTransport(server: server, credential: credential)
        let output = try await transport.execute("printf keys-ok")
        #expect(output.exitStatus == 0)
        #expect(output.standardOutput == "keys-ok")
    }
}

@Test func excessiveKeyDerivationWorkIsRejectedDuringImport() throws {
    // A valid-looking encrypted envelope must be rejected before bcrypt runs.
    func word(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
    func field(_ bytes: Data) -> Data { word(UInt32(bytes.count)) + bytes }
    let options = field(Data(repeating: 1, count: 16)) + word(UInt32.max)
    let pub = field(Data("ssh-ed25519".utf8)) + field(Data(repeating: 2, count: 32))
    var envelope = Data("openssh-key-v1\0".utf8)
    envelope += field(Data("aes256-ctr".utf8))
    envelope += field(Data("bcrypt".utf8))
    envelope += field(options) + word(1) + field(pub) + field(Data(repeating: 0, count: 16))
    let text = ["-----BEGIN OPENSSH PRIVATE KEY-----", envelope.base64EncodedString(),
                "-----END OPENSSH PRIVATE KEY-----"].joined(separator: "\n")
    #expect(throws: MobileError.unsupportedKeyProtection) { try ImportedSSHKey(text) }
}
#endif
