import CryptoKit
import Darwin
import Foundation
import NVBeaconTransfer

/// Metadata shown on the Mac before authentication. No key contents or passwords.
struct MacTransferRow: Identifiable, Sendable {
    var id: String { server.id }
    let server: ServerConfig
    let endpoint: EffectiveSSHProfile?
    let issue: String?
    var keyFile: ReviewedKeyFile?
    let passwordAccount: String?
    var hasCredential: Bool { keyFile != nil || passwordAccount != nil }
}

struct ReviewedKeyFile: Sendable {
    let url: URL
    private let device: dev_t
    private let inode: ino_t
    private let bytes: off_t
    private let modified: timespec

    init?(_ path: String) {
        guard path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              (1...65_536).contains(metadata.st_size), access(url.path, R_OK) == 0 else { return nil }
        self.url = url
        device = metadata.st_dev
        inode = metadata.st_ino
        bytes = metadata.st_size
        modified = metadata.st_mtimespec
    }

    func read() throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw MacTransferError.keyUnavailable }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        func isReviewedFile() -> Bool {
            var s = stat()
            return fstat(fd, &s) == 0 && s.st_dev == device && s.st_ino == inode && s.st_size == bytes
                && s.st_mode & S_IFMT == S_IFREG && s.st_mtimespec.tv_sec == modified.tv_sec
                && s.st_mtimespec.tv_nsec == modified.tv_nsec
        }
        guard isReviewedFile(), let data = try file.read(upToCount: 65_537), data.count == bytes,
              isReviewedFile(), let text = String(data: data, encoding: .utf8)
        else { throw MacTransferError.keyUnavailable }
        return text
    }
}

enum MacTransferError: Error {
    case keyUnavailable
}

struct MacTransferPreparation {
    /// OpenSSH lists every default identity path when a profile has no IdentityFile.
    /// A user-selected file or a single configured identity can be offered for review.
    static func suggestedKey(_ server: ServerConfig, endpoint: EffectiveSSHProfile) -> ReviewedKeyFile? {
        if let saved = ReviewedKeyFile(server.sshIdentityFilePath) { return saved }
        // OpenSSH can ignore a missing -i file and still use an IdentityFile
        // from the host's SSH config. Offer it only when the choice is unique.
        let unique = Set(endpoint.identityFiles)
        guard unique.count == 1, let path = unique.first else { return nil }
        return ReviewedKeyFile(path)
    }

    static func review(settings: AppSettings, configFile: URL? = nil,
                       hasPassword: @Sendable (String) -> Bool = { SSHPasswordStore().hasPasswordWithoutPrompt(account: $0) }) async throws -> [MacTransferRow] {
        let servers = settings.normalized().configuredServers
        guard (1...ServerSettingsBackup.maximumServers).contains(servers.count) else {
            throw ServerSettingsBackup.BackupError.invalidServerCount
        }
        var rows: [MacTransferRow] = []
        for server in servers {
            try Task.checkCancellation()
            let endpoint: EffectiveSSHProfile
            do {
                endpoint = try await EffectiveSSHProfile.resolve(server, settings: settings, configFile: configFile)
            } catch {
                try Task.checkCancellation()
                rows.append(.init(server: server, endpoint: nil, issue: "Review the SSH endpoint on iPhone.",
                                  keyFile: nil, passwordAccount: nil))
                continue
            }
            if let proxy = endpoint.proxy {
                rows.append(.init(server: server, endpoint: nil, issue: "This server requires \(proxy). Configure a reachable endpoint.",
                                  keyFile: nil, passwordAccount: nil))
                continue
            }
            var account: String?
            var key: ReviewedKeyFile?
            if server.sshAuthenticationMode == .passwordBased {
                if hasPassword(server.keychainAccount) { account = server.keychainAccount }
                else if server.allowsLegacyPasswordFallback, hasPassword(SSHPasswordStore.legacyAccount) {
                    account = SSHPasswordStore.legacyAccount
                }
            } else {
                key = suggestedKey(server, endpoint: endpoint)
            }
            rows.append(.init(server: server, endpoint: endpoint, issue: nil, keyFile: key, passwordAccount: account))
        }
        return rows
    }

    /// Called only after the user confirms the channel-bound code and authenticates locally.
    @concurrent static func materialize(_ rows: [MacTransferRow], batchID: UUID,
                            readPassword: @Sendable (String) throws -> String = { try SSHPasswordStore().loadPassword(account: $0) }) async throws -> TransferBatch {
        var servers: [TransferServer] = []
        var credentials: [UUID: TransferCredential] = [:]
        var keyIDs: [Data: UUID] = [:]
        var loadedFiles: [URL: (UUID, Bool)] = [:]
        for row in rows {
            try Task.checkCancellation()
            let s = row.server
            var id: UUID?
            var issue = row.issue
            if row.endpoint != nil {
                switch s.sshAuthenticationMode {
                case .passwordBased:
                    if let account = row.passwordAccount {
                        let password = try readPassword(account)
                        if !password.isEmpty {
                            let reference = UUID()
                            credentials[reference] = TransferCredential(kind: "passwordBased", secret: password)
                            id = reference
                        }
                    }
                    if id == nil { issue = "Enter the SSH password on iPhone." }
                case .keyBased:
                    if let file = row.keyFile {
                        if let cached = loadedFiles[file.url] {
                            id = cached.0
                            if cached.1 { issue = "Enter the private key passphrase on iPhone." }
                        } else if let original = try? file.read(),
                                  let secret = try? TransferPrivateKey.openSSH(original),
                                  let encrypted = supportedKeyEncryption(secret) {
                            let digest = Data(SHA256.hash(data: Data(original.utf8)))
                            let reference = keyIDs[digest] ?? UUID()
                            keyIDs[digest] = reference
                            loadedFiles[file.url] = (reference, encrypted)
                            credentials[reference] = TransferCredential(kind: "keyBased", secret: secret)
                            id = reference
                            if encrypted { issue = "Enter the private key passphrase on iPhone." }
                        }
                    }
                    if id == nil { issue = "Import a supported private key on iPhone." }
                }
            }
            servers.append(TransferServer(id: sourceID(s.id), name: s.displayName,
                host: row.endpoint?.host ?? "", username: row.endpoint?.user ?? "",
                port: row.endpoint?.port ?? s.resolvedPort ?? 22,
                authentication: s.sshAuthenticationMode.rawValue, gpuCommand: s.remoteCommand,
                memoryCommand: s.memoryCommand, hostCommand: s.hostCommand, credentialID: id, setupIssue: issue,
                connectionReuseMode: s.sshConnectionReuseMode.rawValue))
        }
        let batch = TransferBatch(id: batchID, servers: servers, credentials: credentials)
        try batch.validate()
        return batch
    }

    private static func sourceID(_ raw: String) -> UUID {
        if let id = UUID(uuidString: raw) { return id }
        let b = Array(SHA256.hash(data: Data(("NVBeacon.server." + raw).utf8)).prefix(16))
        return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
    }

    // Inspect the bounded envelope only. The iPhone's key loader validates/decrypts the private record.
    static func supportedKeyEncryption(_ text: String) -> Bool? {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              lines.last == "-----END OPENSSH PRIVATE KEY-----",
              var bytes = Data(base64Encoded: lines.dropFirst().dropLast().joined()),
              bytes.starts(with: Data("openssh-key-v1\0".utf8)) else { return nil }
        bytes.removeFirst(15)
        func word(_ source: inout Data) -> Int? {
            guard source.count >= 4 else { return nil }
            let value = source.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            source.removeFirst(4)
            return value
        }
        func field(_ source: inout Data) -> Data? {
            guard let length = word(&source), length <= source.count else { return nil }
            let value = source.prefix(length)
            source.removeFirst(length)
            return value
        }
        guard let cipher = field(&bytes), let kdf = field(&bytes), var options = field(&bytes),
              word(&bytes) == 1, var publicKey = field(&bytes), let privateRecord = field(&bytes),
              !privateRecord.isEmpty, bytes.isEmpty, let algorithm = field(&publicKey) else { return nil }
        switch String(decoding: algorithm, as: UTF8.self) {
        case "ssh-ed25519":
            guard field(&publicKey)?.count == 32 else { return nil }
        case "ssh-rsa":
            guard let e = field(&publicKey), (1...8).contains(e.count), let n = field(&publicKey) else { return nil }
            let magnitude = n.drop(while: { $0 == 0 })
            guard let first = magnitude.first, (2048...8192).contains(magnitude.count * 8 - first.leadingZeroBitCount)
            else { return nil }
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard let rawCurve = field(&publicKey), let point = field(&publicKey) else { return nil }
            let curve = String(decoding: rawCurve, as: UTF8.self)
            let widths = ["nistp256": 32, "nistp384": 48, "nistp521": 66]
            guard let width = widths[curve], algorithm == Data(("ecdsa-sha2-" + curve).utf8),
                  point.first == 4, point.count == 1 + 2 * width else { return nil }
        default: return nil
        }
        guard publicKey.isEmpty else { return nil }
        if cipher == Data("none".utf8) {
            return kdf == Data("none".utf8) && options.isEmpty && privateRecord.count.isMultiple(of: 8) ? false : nil
        }
        guard [Data("aes128-ctr".utf8), Data("aes256-ctr".utf8)].contains(cipher),
              privateRecord.count.isMultiple(of: 16), kdf == Data("bcrypt".utf8), let salt = field(&options), !salt.isEmpty,
              let rounds = word(&options), (1...256).contains(rounds), options.isEmpty else { return nil }
        return true
    }
}
