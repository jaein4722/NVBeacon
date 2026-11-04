import Foundation
import Testing
import NVBeaconCore
@testable import NVBeaconMobile

private struct TestCredentials: CredentialStorage {
    func read(_ id: UUID) throws -> MobileCredential? { .init(secret: "test-only-password") }
    func write(_ credential: MobileCredential, for id: UUID) throws {}
    func delete(_ id: UUID) throws {}
}

private actor ResponseSequence {
    private var count = 0
    func fetch() throws -> GPUSnapshot {
        count += 1
        if count > 1 { throw MobileError.connectionClosed }
        return GPUSnapshot(takenAt: Date(), gpus: [])
    }
}

@Test @MainActor func failedRefreshRetainsLastSuccessfulSnapshot() async throws {
    let name = "NVBeaconMobileTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var server = MobileServer()
    server.host = "gpu.example.com"
    server.username = "researcher"
    server.authentication = .passwordBased
    defaults.set(try JSONEncoder().encode([server]), forKey: "mobileServers")
    let responses = ResponseSequence()
    let store = MobileStore(defaults: defaults, vault: TestCredentials()) { _, _ in try await responses.fetch() }
    await store.refresh()
    let original = try #require(store.readings[server.id]?.snapshot)
    await store.refresh()
    #expect(store.readings[server.id]?.snapshot == original)
    #expect(store.readings[server.id]?.error == MobileError.connectionClosed.localizedDescription)
    #expect(!store.isRefreshing)
}

@Test @MainActor func firstHostKeyRequiresExplicitTrustAndIsNotExported() async throws {
    let name = "NVBeaconMobileTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var server = MobileServer()
    server.host = "gpu.example.com"
    server.username = "researcher"
    server.authentication = .passwordBased
    defaults.set(try JSONEncoder().encode([server]), forKey: "mobileServers")
    let store = MobileStore(defaults: defaults, vault: TestCredentials()) { _, _ in
        throw MobileError.hostKeyRequired(key: "test-host-key", fingerprint: "test-fingerprint")
    }
    await store.refresh()
    #expect(store.servers[0].pinnedHostKey == nil)
    #expect(store.readings[server.id]?.hostKey == "test-host-key")
    try store.trustHost(for: server, key: "test-host-key")
    #expect(store.servers[0].pinnedHostKey == "test-host-key")
    let exported = String(decoding: try store.exportServers(), as: UTF8.self)
    #expect(!exported.contains("test-host-key"))
    #expect(!exported.contains("test-only-password"))
}

private actor DelayedResponse {
    private var started = false
    private var continuation: CheckedContinuation<GPUSnapshot, Never>?
    func fetch() async -> GPUSnapshot {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
    func finish() { continuation?.resume(returning: GPUSnapshot(takenAt: Date(), gpus: [])); continuation = nil }
}

@Test @MainActor func editingDuringRefreshDiscardsPreviousEndpointResponse() async throws {
    let name = "NVBeaconMobileTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var server = MobileServer()
    server.host = "gpu.example.com"
    server.username = "researcher"
    server.authentication = .passwordBased
    defaults.set(try JSONEncoder().encode([server]), forKey: "mobileServers")
    let delayed = DelayedResponse()
    let store = MobileStore(defaults: defaults, vault: TestCredentials()) { _, _ in await delayed.fetch() }
    let refresh = Task { await store.refresh() }
    await delayed.waitUntilStarted()
    server.host = "replacement.example.com"
    try store.save(server, credential: .init(secret: "test-only-password"))
    await delayed.finish()
    await refresh.value
    #expect(store.readings[server.id] == nil)
    #expect(store.servers[0].host == "replacement.example.com")
    #expect(!store.isRefreshing)
}

@Test @MainActor func cancellationDoesNotBecomeAConnectionError() async throws {
    let name = "NVBeaconMobileTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var server = MobileServer()
    server.host = "gpu.example.com"
    server.username = "researcher"
    server.authentication = .passwordBased
    defaults.set(try JSONEncoder().encode([server]), forKey: "mobileServers")
    let store = MobileStore(defaults: defaults, vault: TestCredentials()) { _, _ in
        try await Task.sleep(for: .seconds(60))
        return GPUSnapshot(takenAt: Date(), gpus: [])
    }
    let refresh = Task { await store.refresh() }
    while !store.isRefreshing { await Task.yield() }
    refresh.cancel()
    await refresh.value
    #expect(store.readings[server.id]?.error == nil)
    #expect(!store.isRefreshing)
}

@Test @MainActor func sceneSuspensionAlsoCancelsManualRefresh() async throws {
    let name = "NVBeaconMobileTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    var server = MobileServer()
    server.host = "gpu.example.com"
    server.username = "researcher"
    server.authentication = .passwordBased
    defaults.set(try JSONEncoder().encode([server]), forKey: "mobileServers")
    let store = MobileStore(defaults: defaults, vault: TestCredentials()) { _, _ in
        try await Task.sleep(for: .seconds(60))
        return GPUSnapshot(takenAt: Date(), gpus: [])
    }
    let refresh = Task { await store.refresh() }
    while !store.isRefreshing { await Task.yield() }
    store.suspend()
    await refresh.value
    #expect(store.readings[server.id]?.error == nil)
    #expect(!store.isRefreshing)
}

@Test @MainActor func reorderingAndBulkRemovalPersistWithoutRestartingPollingForMoves() throws {
    let name = "NVBeaconMobileTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let original = (0..<4).map { index in
        var server = MobileServer()
        server.name = "Fixture \(index)"
        return server
    }
    defaults.set(try JSONEncoder().encode(original), forKey: "mobileServers")
    let store = MobileStore(defaults: defaults, vault: TestCredentials())
    let generation = store.generation
    let order = [original[3], original[0], original[2], original[1]]
    try store.reorderServers(order.map(\.id))
    #expect(store.generation == generation)
    #expect(MobileStore(defaults: defaults).servers == order)
    try store.deleteServers([original[0].id, original[1].id])
    #expect(store.generation != generation)
    #expect(MobileStore(defaults: defaults).servers == [original[3], original[2]])
}

@Test @MainActor func keychainFailureDuringBulkRemovalLeavesFailedAndLaterProfilesAvailable() throws {
    struct FailingVault: CredentialStorage {
        let failingID: UUID
        func read(_ id: UUID) throws -> MobileCredential? { nil }
        func write(_ credential: MobileCredential, for id: UUID) throws {}
        func delete(_ id: UUID) throws {
            if id == failingID { throw MobileError.keychain(-1) }
        }
    }
    let name = "NVBeaconMobileTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let servers = [MobileServer(), MobileServer(), MobileServer()]
    defaults.set(try JSONEncoder().encode(servers), forKey: "mobileServers")
    let store = MobileStore(defaults: defaults, vault: FailingVault(failingID: servers[1].id))
    #expect(throws: MobileError.keychain(-1)) { try store.deleteServers(Set(servers.map(\.id))) }
    #expect(MobileStore(defaults: defaults).servers == Array(servers.dropFirst()))
}
