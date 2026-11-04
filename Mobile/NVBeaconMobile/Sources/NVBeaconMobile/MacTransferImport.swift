import Foundation
import NVBeaconCore
import NVBeaconTransfer

struct MobileTransferState: Codable {
    var servers: [MobileServer] = []
    var receipts: Set<UUID> = []
    var journal: [JournalEntry] = []

    struct JournalEntry: Codable {
        let id: UUID
        let wasEmptyItem: Bool
    }
}

/// Kept in memory between authenticated receipt and the user's import decision.
public struct IncomingMacTransfer: Sendable {
    let id: UUID
    let servers: [TransferServer]
    let credentials: [UUID: CheckedCredential]

    struct CheckedCredential: Sendable {
        let value: MobileCredential?
        let issue: String?
    }

    public init(data: Data) throws {
        let batch = try TransferBatch.decode(data)
        id = batch.id
        servers = batch.servers
        // Validate each shared key once, even if several servers use it.
        credentials = try batch.credentials.mapValues { input in
            try Task.checkCancellation()
            let credential = MobileCredential(secret: input.secret, passphrase: input.passphrase)
            guard input.kind == SSHAuthenticationMode.keyBased.rawValue else {
                return CheckedCredential(value: credential, issue: nil)
            }
            do {
                let info = try ImportedSSHKey(input.secret)
                if info.requiresPassphrase && input.passphrase.isEmpty {
                    return CheckedCredential(value: credential, issue: "Enter the imported key’s passphrase in Edit Server before enabling monitoring.")
                }
                do {
                    try SSHTransport.validatePrivateKey(credential)
                    return CheckedCredential(value: credential, issue: nil)
                } catch where info.requiresPassphrase {
                    return CheckedCredential(value: .init(secret: input.secret),
                        issue: "The imported key could not be unlocked. Check its passphrase in Edit Server.")
                }
            } catch { }
            return CheckedCredential(value: nil, issue: "This key could not be imported. Choose a supported private key in Edit Server.")
        }
    }
}

public struct MacTransferReview: Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let address: String
        public let action: Action
        public let credentialLabel: String?
        public let note: String?
    }

    public enum Action: Equatable, Sendable {
        case add
        case fill(UUID)
        case skip
    }

    public let rows: [Row]
    public let alreadyImported: Bool
    public var added: Int { rows.filter { $0.action == .add }.count }
    public var filled: Int { rows.filter { if case .fill = $0.action { true } else { false } }.count }
    public var skipped: Int { rows.filter { $0.action == .skip }.count }
}

enum MacTransferImportError: LocalizedError {
    case changed
    case recovery

    var errorDescription: String? {
        switch self {
        case .changed: "Your saved servers changed. Review the transfer again."
        case .recovery: "Unlock your device, then try again to finish cleaning up an interrupted import."
        }
    }
}
