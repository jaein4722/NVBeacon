import Foundation
import NVBeaconTransfer
import NIO
import CCitadelBcrypt
import _CryptoExtras
@preconcurrency import Citadel
@preconcurrency import Crypto

/// Metadata is available before decrypting the OpenSSH private record.
public struct ImportedSSHKey {
    public let algorithm: String
    public var requiresPassphrase: Bool { rounds != nil }
    private let type: String
    private let publicBlob: ByteBuffer
    private let privateBlob: ByteBuffer
    private let aesKeyLength: Int
    private let salt: [UInt8]
    private let rounds: UInt32?

    public init(_ text: String) throws {
        guard text.utf8.count <= 65_536 else { throw MobileError.unsupportedKey }
        guard let normalized = try? TransferPrivateKey.openSSH(text) else { throw MobileError.unsupportedKey }
        let lines = normalized.split(whereSeparator: \.isNewline)
        guard lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              lines.last == "-----END OPENSSH PRIVATE KEY-----",
              let data = Data(base64Encoded: lines.dropFirst().dropLast().joined()) else {
            throw MobileError.unsupportedKey
        }
        var buffer = ByteBuffer(bytes: data)
        guard buffer.readString(length: 15) == "openssh-key-v1\0",
              let cipher = buffer.field()?.string, let kdf = buffer.field()?.string,
              var options = buffer.field(), buffer.readInteger(as: UInt32.self) == 1,
              let pub = buffer.field(), let secret = buffer.field(), secret.readableBytes > 0,
              buffer.readableBytes == 0 else { throw MobileError.invalidKeyFile }
        if cipher == "none" {
            guard kdf == "none", options.readableBytes == 0, secret.readableBytes.isMultiple(of: 8)
            else { throw MobileError.invalidKeyFile }
            aesKeyLength = 0
            salt = []
            rounds = nil
        } else {
            guard ["aes128-ctr", "aes256-ctr"].contains(cipher), kdf == "bcrypt",
                  let saltField = options.field(), saltField.readableBytes > 0,
                  let iterations = options.readInteger(as: UInt32.self), (1...256).contains(iterations),
                  options.readableBytes == 0, secret.readableBytes.isMultiple(of: 16)
            else { throw MobileError.unsupportedKeyProtection }
            aesKeyLength = cipher == "aes128-ctr" ? 16 : 32
            salt = Array(saltField.readableBytesView)
            rounds = iterations
        }
        publicBlob = pub
        privateBlob = secret
        var body = pub
        guard let tag = body.field()?.string else { throw MobileError.invalidKeyFile }
        type = tag
        switch tag {
        case "ssh-ed25519":
            guard body.field()?.readableBytes == 32 else { throw MobileError.invalidKeyFile }
            algorithm = "Ed25519"
        case "ssh-rsa":
            guard let e = body.field(), (1...8).contains(e.readableBytes), let n = body.field()
            else { throw MobileError.invalidKeyFile }
            let magnitude = n.readableBytesView.drop(while: { $0 == 0 })
            guard let first = magnitude.first,
                  (2048...8192).contains(magnitude.count * 8 - first.leadingZeroBitCount)
            else { throw MobileError.unsupportedRSAKeySize }
            algorithm = "RSA"
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard let curve = body.field()?.string, tag == "ecdsa-sha2-" + curve,
                  let point = body.field(), point.readableBytesView.first == 4,
                  point.readableBytes == 1 + 2 * Self.scalarWidth(curve)
            else { throw MobileError.invalidKeyFile }
            algorithm = "ECDSA P-" + String(curve.dropFirst("nistp".count))
        default: throw MobileError.unsupportedKey
        }
        guard body.readableBytes == 0 else { throw MobileError.invalidKeyFile }
    }

    private static func scalarWidth(_ curve: String) -> Int {
        switch curve { case "nistp256": 32; case "nistp384": 48; default: 66 }
    }

    // CCitadelBcrypt expects its caller to supply SHA-512. All three key
    // types use this single initialization and the same bounded decrypt path.
    private static let initializeBcrypt: Void = citadel_set_crypto_hash_sha512 { output, input, count in
        let digest = SHA512.hash(data: Data(bytes: input!, count: Int(count)))
        digest.withUnsafeBytes { output!.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 64) }
    }

    private func decrypt(_ passphrase: String) throws -> ByteBuffer {
        guard let rounds else { return privateBlob }
        guard !passphrase.isEmpty else { throw MobileError.keyPassphraseRequired }
        _ = Self.initializeBcrypt
        let password = Array(passphrase.utf8)
        var material = [UInt8](repeating: 0, count: aesKeyLength + 16)
        let length = material.count
        guard citadel_bcrypt_pbkdf(password, password.count, salt, salt.count, &material, length, rounds) == 0
        else { throw MobileError.cannotUnlockKey }
        let plaintext = try AES._CTR.decrypt(Data(privateBlob.readableBytesView),
            using: SymmetricKey(data: material.prefix(aesKeyLength)),
            nonce: AES._CTR.Nonce(nonceBytes: material.suffix(16)))
        return ByteBuffer(bytes: plaintext)
    }

    func authentication(username: String, passphrase: String) throws -> @Sendable () -> SSHAuthenticationMethod {
        let plaintext = try decrypt(passphrase)
        var record = plaintext
        guard let check = record.readInteger(as: UInt32.self), record.readInteger(as: UInt32.self) == check
        else { throw requiresPassphrase ? MobileError.cannotUnlockKey : MobileError.invalidKeyFile }
        var pub = publicBlob
        guard record.field()?.string == type, pub.field()?.string == type else { throw MobileError.invalidKeyFile }

        if type == "ssh-rsa" {
            // Citadel imports RSA components from an OpenSSH container. Pass
            // an in-memory plaintext container with the required 8-byte padding.
            for _ in 0..<6 {
                guard let component = record.field(), component.readableBytes > 0 else { throw MobileError.invalidKeyFile }
            }
            guard record.field() != nil else { throw MobileError.invalidKeyFile } // comment
            var payload = Data(plaintext.readableBytesView.prefix(record.readerIndex - plaintext.readerIndex))
            try checkPadding(record)
            for i in 0..<((8 - payload.count % 8) % 8) { payload.append(UInt8(i + 1)) }
            var envelope = ByteBuffer(string: "openssh-key-v1\0")
            envelope.putField(Data("none".utf8))
            envelope.putField(Data("none".utf8))
            envelope.putField(Data())
            envelope.writeInteger(UInt32(1))
            envelope.putField(Data(publicBlob.readableBytesView))
            envelope.putField(payload)
            let key = try Insecure.RSA.PrivateKey(sshRsa: "-----BEGIN OPENSSH PRIVATE KEY-----\n" +
                Data(envelope.readableBytesView).base64EncodedString() + "\n-----END OPENSSH PRIVATE KEY-----")
            guard key.publicKey.rawRepresentation.elementsEqual(pub.readableBytesView) else { throw MobileError.invalidKeyFile }
            return { .rsa(username: username, privateKey: key) }
        }

        if type == "ssh-ed25519" {
            guard let point = pub.field(), record.field() == point, let secret = record.field(),
                  secret.readableBytes == 64, secret.readableBytesView.suffix(32).elementsEqual(point.readableBytesView),
                  record.field() != nil else { throw MobileError.invalidKeyFile }
            try checkPadding(record)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(secret.readableBytesView.prefix(32)))
            guard key.publicKey.rawRepresentation.elementsEqual(point.readableBytesView) else { throw MobileError.invalidKeyFile }
            return { .ed25519(username: username, privateKey: key) }
        }

        guard let curve = pub.field(), record.field() == curve, let point = pub.field(), record.field() == point,
              let scalar = record.field(), record.field() != nil else { throw MobileError.invalidKeyFile }
        try checkPadding(record)
        let bytes = scalar.readableBytesView
        guard let first = bytes.first, first < 128,
              first != 0 || (bytes.count > 1 && bytes.dropFirst().first! >= 128)
        else { throw MobileError.invalidKeyFile }
        let magnitude = bytes.drop(while: { $0 == 0 })
        let width = Self.scalarWidth(curve.string ?? "")
        guard magnitude.count <= width else { throw MobileError.invalidKeyFile }
        let raw = Data(repeating: 0, count: width - magnitude.count) + Data(magnitude)
        switch type {
        case "ecdsa-sha2-nistp256":
            let key = try P256.Signing.PrivateKey(rawRepresentation: raw)
            guard key.publicKey.x963Representation.elementsEqual(point.readableBytesView) else { throw MobileError.invalidKeyFile }
            return { .p256(username: username, privateKey: key) }
        case "ecdsa-sha2-nistp384":
            let key = try P384.Signing.PrivateKey(rawRepresentation: raw)
            guard key.publicKey.x963Representation.elementsEqual(point.readableBytesView) else { throw MobileError.invalidKeyFile }
            return { .p384(username: username, privateKey: key) }
        default:
            let key = try P521.Signing.PrivateKey(rawRepresentation: raw)
            guard key.publicKey.x963Representation.elementsEqual(point.readableBytesView) else { throw MobileError.invalidKeyFile }
            return { .p521(username: username, privateKey: key) }
        }
    }

    private func checkPadding(_ remaining: ByteBuffer) throws {
        guard remaining.readableBytes < (requiresPassphrase ? 16 : 8),
              remaining.readableBytesView.enumerated().allSatisfy({ $0.element == UInt8($0.offset + 1) })
        else { throw MobileError.invalidKeyFile }
    }
}

private extension ByteBuffer {
    mutating func field() -> ByteBuffer? {
        guard let length = readInteger(as: UInt32.self) else { return nil }
        return readSlice(length: Int(length))
    }

    mutating func putField(_ data: Data) {
        writeInteger(UInt32(data.count))
        writeBytes(data)
    }

    var string: String? { getString(at: readerIndex, length: readableBytes) }
}
