import CryptoKit
import Foundation
import Security
import SwiftASN1

private enum KeyFormatError: Error { case unsupported }

/// Converts common unencrypted PEM containers in memory, preserving the key pair.
public enum TransferPrivateKey {
    public static func openSSH(_ input: String) throws -> String {
        guard input.utf8.count <= 65_536 else { throw KeyFormatError.unsupported }
        let pem = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if pem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") { return pem + "\n" }
        let doc = try PEMDocument(pemString: pem)
        switch doc.discriminator {
        case "RSA PRIVATE KEY": return try rsa(doc.derBytes)
        case "EC PRIVATE KEY": return try ec(doc.derBytes[...], curve: nil)
        case "PRIVATE KEY":
            return try DER.sequence(DER.parse(doc.derBytes), identifier: .sequence) { fields in
                guard try Int(derEncoded: &fields) == 0, let algorithm = fields.next() else { throw KeyFormatError.unsupported }
                var curve: ASN1ObjectIdentifier?
                let oid = try DER.sequence(algorithm, identifier: .sequence) { parts in
                    let oid = try ASN1ObjectIdentifier(derEncoded: &parts)
                    if oid == ASN1ObjectIdentifier.AlgorithmIdentifier.idEcPublicKey {
                        guard let parameters = parts.next() else { throw KeyFormatError.unsupported }
                        curve = try curveIdentifier(parameters)
                    } else if oid == ASN1ObjectIdentifier.AlgorithmIdentifier.rsaEncryption, let parameter = parts.next() {
                        _ = try ASN1Null(derEncoded: parameter)
                    }
                    return oid
                }
                let inner = try ASN1OctetString(derEncoded: &fields).bytes
                switch oid {
                case ASN1ObjectIdentifier.AlgorithmIdentifier.rsaEncryption: return try rsa(Array(inner))
                case ASN1ObjectIdentifier.AlgorithmIdentifier.idEcPublicKey: return try ec(inner, curve: curve)
                case [1, 3, 101, 112]:
                    let seed = try ASN1OctetString(derEncoded: DER.parse(inner)).bytes
                    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
                    let point = key.publicKey.rawRepresentation
                    let pub = field(Data("ssh-ed25519".utf8)) + field(point)
                    return envelope(pub: pub, record: pub + field(key.rawRepresentation + point))
                default: throw KeyFormatError.unsupported
                }
            }
        default: throw KeyFormatError.unsupported
        }
    }

    private static func word(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private static func field(_ bytes: Data) -> Data { word(UInt32(bytes.count)) + bytes }

    private static func curveIdentifier(_ parameters: ASN1Node) throws -> ASN1ObjectIdentifier {
        if parameters.identifier == .objectIdentifier { return try ASN1ObjectIdentifier(derEncoded: parameters) }
        // Some ssh-keygen builds emit explicit X9.62 parameters. Accept only exact
        // standard parameter sets (openssl ecparam -name NAME -param_enc explicit -outform DER).
        guard parameters.identifier == .sequence else { throw KeyFormatError.unsupported }
        switch SHA256.hash(data: parameters.encodedBytes).map({ String(format: "%02x", $0) }).joined() {
        case "40c3c405abfc62e096cb6491f85f967d6d75ede716604629654910c475d4b846": return .NamedCurves.secp256r1
        case "19a03321b63c6490867791325fc61a4df548ffaf40b94e499793a6267e5a72dd": return .NamedCurves.secp384r1
        // OpenSSL pads the P-521 coefficient b to 66 bytes; LibreSSL uses 65.
        case "686637285b0a49a8325eceb3d37203c016dcaa29ecf697455e4b8abfda69c186",
             "ad610f22837ba5f87ff997b7b2ba4f1f0df9ee4065febbf5d7b07a94cdfe96b8": return .NamedCurves.secp521r1
        default: throw KeyFormatError.unsupported
        }
    }

    private static func ec(_ der: ArraySlice<UInt8>, curve outerCurve: ASN1ObjectIdentifier?) throws -> String {
        try DER.sequence(DER.parse(der), identifier: .sequence) { fields in
            guard try Int(derEncoded: &fields) == 1 else { throw KeyFormatError.unsupported }
            let scalar = try ASN1OctetString(derEncoded: &fields).bytes
            let innerCurve = try DER.optionalExplicitlyTagged(&fields, tagNumber: 0, tagClass: .contextSpecific) {
                try curveIdentifier($0)
            }
            if let outerCurve, let innerCurve, outerCurve != innerCurve { throw KeyFormatError.unsupported }
            let publicBits = try DER.optionalExplicitlyTagged(&fields, tagNumber: 1, tagClass: .contextSpecific) {
                try ASN1BitString(derEncoded: $0)
            }
            // LibreSSL may omit the scalar's leading zero octets (often on P-521).
            func padded(_ width: Int) throws -> Data {
                guard (1...width).contains(scalar.count) else { throw KeyFormatError.unsupported }
                return Data(repeating: 0, count: width - scalar.count) + scalar
            }
            let curve: String
            let point: Data
            switch outerCurve ?? innerCurve {
            case ASN1ObjectIdentifier.NamedCurves.secp256r1:
                curve = "nistp256"
                point = try P256.Signing.PrivateKey(rawRepresentation: padded(32)).publicKey.x963Representation
            case ASN1ObjectIdentifier.NamedCurves.secp384r1:
                curve = "nistp384"
                point = try P384.Signing.PrivateKey(rawRepresentation: padded(48)).publicKey.x963Representation
            case ASN1ObjectIdentifier.NamedCurves.secp521r1:
                curve = "nistp521"
                point = try P521.Signing.PrivateKey(rawRepresentation: padded(66)).publicKey.x963Representation
            default: throw KeyFormatError.unsupported
            }
            if let publicBits {
                guard publicBits.paddingBits == 0, publicBits.bytes.elementsEqual(point) else { throw KeyFormatError.unsupported }
            }
            let pub = field(Data(("ecdsa-sha2-" + curve).utf8)) + field(Data(curve.utf8)) + field(point)
            let magnitude = scalar.drop(while: { $0 == 0 })
            let prefix = (magnitude.first ?? 0) >= 128 ? Data([0]) : Data()
            return envelope(pub: pub, record: pub + field(prefix + magnitude))
        }
    }

    private static func rsa(_ der: [UInt8]) throws -> String {
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
        guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes, nil),
              (256...1024).contains(SecKeyGetBlockSize(key)) else { throw KeyFormatError.unsupported }

        func integer(_ nodes: inout ASN1NodeCollection.Iterator) throws -> Data {
            let magnitude = try ArraySlice<UInt8>(derEncoded: &nodes)
            guard let first = magnitude.first, first != 0 else { throw KeyFormatError.unsupported }
            // SSH mpint uses signed big-endian integers.
            return field((first >= 128 ? Data([0]) : Data()) + Data(magnitude))
        }

        return try DER.sequence(DER.parse(der), identifier: .sequence) { nodes in
            guard try Int(derEncoded: &nodes) == 0 else { throw KeyFormatError.unsupported }
            let n = try integer(&nodes), e = try integer(&nodes), d = try integer(&nodes)
            let p = try integer(&nodes), q = try integer(&nodes)
            _ = try integer(&nodes) // d mod (p-1)
            _ = try integer(&nodes) // d mod (q-1)
            let inverseQ = try integer(&nodes)
            let algorithm = field(Data("ssh-rsa".utf8))
            let pub = algorithm + e + n
            return envelope(pub: pub, record: algorithm + n + e + d + inverseQ + p + q)
        }
    }

    private static func envelope(pub: Data, record: Data) -> String {
        let check = word(UInt32.random(in: .min ... .max))
        var padded = check + check + record + field(Data())
        for index in 0..<((8 - padded.count % 8) % 8) { padded.append(UInt8(index + 1)) }
        let none = field(Data("none".utf8))
        let bytes = Data("openssh-key-v1\0".utf8) + none + none + field(Data()) + word(1) + field(pub) + field(padded)
        let body = bytes.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + body + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}
