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
    server.isEnabled = false
    let retrieved = try await TransferHostKey.lookup(server)
    server.trustedEndpoint = server.endpoint
    let pub = try String(contentsOf: folder.appendingPathComponent("host.pub"), encoding: .utf8)
    server.trustedHostKey = pub.split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
    #expect(retrieved.key == server.trustedHostKey)
    let plainKey = try String(contentsOf: folder.appendingPathComponent(variant + "-plain"), encoding: .utf8)
    #expect(try !ImportedSSHKey(plainKey).requiresPassphrase)
    var credentials = [MobileCredential(secret: key, passphrase: "fixture-only"), .init(secret: plainKey)]
    for suffix in variant == "ed25519" ? ["-pkcs8"] : ["-pem", "-pkcs8"] {
        let pem = try String(contentsOf: folder.appendingPathComponent(variant + suffix), encoding: .utf8)
        credentials.append(.init(secret: pem))
    }
    for credential in credentials {
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

@Test func shortP521PEMScalarIsPaddedBeforeImport() throws {
    // SEC1 version 1, scalar 1, named curve secp521r1. No embedded public key.
    let der = Data([0x30, 0x0f, 0x02, 0x01, 0x01, 0x04, 0x01, 0x01,
                    0xa0, 0x07, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23])
    let pem = "-----BEGIN EC PRIVATE KEY-----\n" + der.base64EncodedString() + "\n-----END EC PRIVATE KEY-----"
    #expect(try ImportedSSHKey(pem).algorithm == "ECDSA P-521")
    try SSHTransport.validatePrivateKey(.init(secret: pem))
}
#endif
