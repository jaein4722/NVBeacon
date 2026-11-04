import Foundation
import Testing
import NVBeaconCore
import NVBeaconTransfer
@testable import NVBeaconMobile

private final class TransferVault: CredentialStorage, @unchecked Sendable {
    // Accessed only by the main-actor test and store.
    var items: [UUID: MobileCredential] = [:]
    var failingSecret: String?
    var rejectCleanup = false
    func read(_ id: UUID) -> MobileCredential? { items[id] }
    func write(_ credential: MobileCredential, for id: UUID) throws {
        if credential.secret == failingSecret { throw MobileError.keychain(-1) }
        items[id] = credential
    }
    func delete(_ id: UUID) throws {
        if rejectCleanup { throw MobileError.keychain(-2) }
        items.removeValue(forKey: id)
    }
}

private struct MacTransferFixture {
    let defaults: UserDefaults
    let suite: String
    let vault = TransferVault()

    init() throws {
        suite = "NVBeaconTransferTests.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func payload(_ batchID: UUID = UUID(), names: [String] = ["one", "two"]) throws -> IncomingMacTransfer {
        var auth: [UUID: TransferCredential] = [:]
        let records = names.map { name -> TransferServer in
            let reference = UUID()
            auth[reference] = .init(kind: "passwordBased", secret: "synthetic-\(name)")
            return TransferServer(id: UUID(), name: name, host: "\(name).example.invalid", username: "fixture", port: 2222,
                                  authentication: "passwordBased", gpuCommand: "gpu", memoryCommand: "ram",
                                  hostCommand: "host", credentialID: reference, setupIssue: nil)
        }
        return try IncomingMacTransfer(data: TransferBatch(id: batchID, servers: records, credentials: auth).encoded())
    }
}

@Test @MainActor func transferFillsUniqueEmptyProfileAndReplaysWithoutDuplicates() throws {
    let f = try MacTransferFixture()
    defer { f.defaults.removePersistentDomain(forName: f.suite) }
    let store = MobileStore(defaults: f.defaults, vault: f.vault)
    var existing = MobileServer()
    existing.name = "one"
    existing.host = "one.example.invalid"
    existing.username = "fixture"
    existing.port = 2222
    existing.isEnabled = false
    existing.authentication = .passwordBased
    // Exercise the actual JSON import first; it has no Keychain item.
    try store.importServers(.init(servers: [existing.backupEntry]))
    let original = try #require(store.servers.first)
    let incoming = try f.payload()
    let preview = try store.reviewTransfer(incoming)
    #expect(preview.added == 1 && preview.filled == 1)
    try store.importTransfer(incoming, reviewed: preview)
    #expect(store.servers[0].id == original.id)
    #expect(store.servers.allSatisfy { !$0.isEnabled && $0.trustedHostKey == nil })
    #expect(store.servers.last?.hostCommand == "host")
    #expect(try store.credential(for: original).secret == "synthetic-one")
    let saved = try #require(f.defaults.data(forKey: "mobileServers"))
    #expect(!String(decoding: saved, as: UTF8.self).contains("synthetic-"))
    #expect(!String(decoding: try store.exportServers(), as: UTF8.self).contains("synthetic-"))
    let restored = MobileStore(defaults: f.defaults, vault: f.vault)
    let replay = try restored.reviewTransfer(incoming)
    #expect(replay.alreadyImported)
    try restored.importTransfer(incoming, reviewed: replay)
    #expect(restored.servers == store.servers)
    let freshBatch = try restored.reviewTransfer(f.payload())
    #expect(freshBatch.skipped == 2 && freshBatch.added == 0 && freshBatch.filled == 0)
}

@Test @MainActor func bulkTrustUsesOnlyChosenUnchangedImportedProfiles() throws {
    let f = try MacTransferFixture()
    defer { f.defaults.removePersistentDomain(forName: f.suite) }
    let store = MobileStore(defaults: f.defaults, vault: f.vault)
    let first = try f.payload(names: ["one"])
    try store.importTransfer(first, reviewed: store.reviewTransfer(first))
    let incoming = try f.payload(names: ["one", "two", "three", "four"])
    let imported = try store.importTransfer(incoming, reviewed: store.reviewTransfer(incoming))
    #expect(imported.map(\.name) == ["two", "three", "four"])
    let proposals = imported.map { TransferHostKey(server: $0, key: "fixture-key", fingerprint: "fixture-fingerprint") }
    var edited = imported[1]
    edited.port = 22
    try store.save(edited, credential: store.credential(for: edited))
    #expect(throws: MacTransferImportError.self) { try store.trustAndConnectTransferred(Array(proposals.prefix(2))) }
    #expect(store.servers.allSatisfy { !$0.isEnabled && $0.pinnedHostKey == nil })
    try store.trustAndConnectTransferred([proposals[0]])
    #expect(store.servers.filter(\.isEnabled).map(\.id) == [imported[0].id])
    #expect(store.servers.filter { $0.pinnedHostKey != nil }.map(\.id) == [imported[0].id])
    #expect(try store.importTransfer(incoming, reviewed: store.reviewTransfer(incoming)).isEmpty)
}

@Test @MainActor func failedTransferRecoversAndCanBeRetriedWithoutChangingExistingProfiles() throws {
    let f = try MacTransferFixture()
    defer { f.defaults.removePersistentDomain(forName: f.suite) }
    let store = MobileStore(defaults: f.defaults, vault: f.vault)
    var original = MobileServer()
    original.host = "one.example.invalid"
    original.username = "fixture"
    original.authentication = .passwordBased
    original.isEnabled = false
    original.port = 2222
    try store.save(original, credential: .init())
    let incoming = try f.payload(names: ["one", "new", "fail"])
    let preview = try store.reviewTransfer(incoming)
    f.vault.failingSecret = "synthetic-fail"
    f.vault.rejectCleanup = true
    #expect(throws: MacTransferImportError.self) { try store.importTransfer(incoming, reviewed: preview) }
    #expect(store.servers.count == 1)
    f.vault.rejectCleanup = false
    f.vault.failingSecret = nil
    // Simulate another app launch after cleanup failed due to Keychain lock.
    let restored = MobileStore(defaults: f.defaults, vault: f.vault)
    #expect(restored.servers == [original])
    #expect(f.vault.items == [original.id: MobileCredential()])
    let retry = try restored.reviewTransfer(incoming)
    try restored.importTransfer(incoming, reviewed: retry)
    #expect(restored.servers.count == 3)
}

@Test @MainActor func ambiguousProfilesAndNewlyEnteredCredentialsArePreserved() throws {
    let f = try MacTransferFixture()
    defer { f.defaults.removePersistentDomain(forName: f.suite) }
    let store = MobileStore(defaults: f.defaults, vault: f.vault)
    var server = MobileServer()
    server.host = "one.example.invalid"
    server.username = "fixture"
    server.port = 2222
    server.authentication = .passwordBased
    server.isEnabled = false
    try store.save(server, credential: .init())
    let incoming = try f.payload(names: ["one"])
    let preview = try store.reviewTransfer(incoming)
    try store.save(server, credential: .init(secret: "local-existing"))
    #expect(throws: MacTransferImportError.self) { try store.importTransfer(incoming, reviewed: preview) }
    #expect(try store.credential(for: server).secret == "local-existing")
    server.id = UUID()
    try store.save(server, credential: .init())
    #expect(try store.reviewTransfer(incoming).skipped == 1)
}

@Test @MainActor func receiptFlushFailureRollsBackKeychainAndDestinationsBeforeRetry() throws {
    final class FaultDefaults: UserDefaults, @unchecked Sendable {
        var flushes = 0
        override func synchronize() -> Bool {
            flushes += 1
            return flushes != 2 && super.synchronize()
        }
    }
    let name = "NVBeaconTransferTests.\(UUID())"
    let defaults = try #require(FaultDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let f = try MacTransferFixture()
    defer { f.defaults.removePersistentDomain(forName: f.suite) }
    let incoming = try f.payload()
    let store = MobileStore(defaults: defaults, vault: f.vault)
    let review = try store.reviewTransfer(incoming)
    #expect(throws: MacTransferImportError.self) { try store.importTransfer(incoming, reviewed: review) }
    let restored = MobileStore(defaults: defaults, vault: f.vault)
    #expect(restored.servers.isEmpty && f.vault.items.isEmpty)
    #expect(try !restored.reviewTransfer(incoming).alreadyImported)
    try restored.importTransfer(incoming, reviewed: review)
    #expect(restored.servers.count == 2)
}

#if os(macOS)
@Test @MainActor func encryptedKeyWithoutMacPassphraseIsSavedForLaterUnlock() throws {
    let f = try MacTransferFixture()
    defer { f.defaults.removePersistentDomain(forName: f.suite) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let keyURL = folder.appendingPathComponent("fixture")
    let generator = Process()
    generator.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    generator.arguments = ["-q", "-t", "ed25519", "-a", "4", "-N", "fixture-only", "-f", keyURL.path]
    try generator.run()
    generator.waitUntilExit()
    try #require(generator.terminationStatus == 0)
    let key = try String(contentsOf: keyURL, encoding: .utf8)
    let ref = UUID()
    let remote = TransferServer(id: UUID(), name: "Lab", host: "gpu.example.invalid", username: "fixture",
                                port: 22, authentication: "keyBased", gpuCommand: "gpu", memoryCommand: "ram",
                                hostCommand: nil, credentialID: ref, setupIssue: nil)
    let incoming = try IncomingMacTransfer(data: TransferBatch(id: UUID(), servers: [remote],
        credentials: [ref: .init(kind: "keyBased", secret: key)]).encoded())
    let store = MobileStore(defaults: f.defaults, vault: f.vault)
    let review = try store.reviewTransfer(incoming)
    #expect(review.rows.first?.note?.contains("passphrase") == true)
    try store.importTransfer(incoming, reviewed: review)
    let saved = try #require(store.servers.first)
    #expect(!saved.isEnabled && saved.transferSetupIssue != nil)
    #expect(try store.credential(for: saved) == MobileCredential(secret: key))
    let metadata = try #require(f.defaults.data(forKey: "mobileServers"))
    #expect(!String(decoding: metadata, as: UTF8.self).contains("BEGIN OPENSSH PRIVATE KEY"))
}
#endif
