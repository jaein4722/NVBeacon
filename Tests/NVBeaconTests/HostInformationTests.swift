import Foundation
import Testing
@testable import NVBeacon

private func hostInfoServer(_ id: String) -> ServerConfig {
    ServerConfig(id: id, name: "Fixture " + id, sshTarget: id + ".example.invalid", isEnabled: false)
}

@Test func legacyHostSettingsDefaultToEnabledAndKeepTheNetworkChoice() throws {
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{\"showsNetworkUsage\":false}".utf8))
    #expect(settings.collectsHostInfo)
    #expect(settings.collectsHostCPU)
    #expect(settings.collectsHostMemory)
    #expect(!settings.showsNetworkUsage)
    #expect(settings.hostMetricsOptions == HostMetricsOptions(cpu: true, memory: true, network: false))
}

@Test func hostCollectionSwitchPreservesIndividualChoicesWhenRestored() throws {
    var original = AppSettings(collectsHostCPU: false, showsNetworkUsage: false)
    original.collectsHostInfo = false
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
    #expect(restored.hostMetricsOptions == .none)
    var enabled = restored
    enabled.collectsHostInfo = true
    #expect(enabled.hostMetricsOptions == HostMetricsOptions(cpu: false, memory: true, network: false))
    #expect(AppSettings().hostMetricsOptions == HostMetricsOptions())
}

@Test @MainActor func hostDisclosurePersistsPerServerWithoutRestartingCollection() throws {
    let suite = "nvbeacon-host-disclosure-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(servers: [hostInfoServer("one"), hostInfoServer("two")]).normalized()
    defaults.set(try JSONEncoder().encode(settings), forKey: "nvbeacon.settings")
    let store = NVBeaconStore(userDefaults: defaults)
    let generation = store.pollingGeneration
    #expect(store.isHostInfoExpanded(for: "one"))
    #expect(store.isHostInfoExpanded(for: "two"))
    #expect(store.isServerExpanded(for: "one"))
    #expect(store.isServerExpanded(for: "two"))
    store.setHostInfoExpanded(false, for: "one")
    store.setServerExpanded(false, for: "one")
    #expect(!store.isHostInfoExpanded(for: "one"))
    #expect(store.isHostInfoExpanded(for: "two"))
    #expect(!store.isServerExpanded(for: "one"))
    #expect(store.isServerExpanded(for: "two"))
    #expect(store.settings == settings)
    #expect(store.pollingGeneration == generation)

    let relaunched = NVBeaconStore(userDefaults: defaults)
    #expect(!relaunched.isHostInfoExpanded(for: "one"))
    #expect(relaunched.isHostInfoExpanded(for: "two"))
    #expect(!relaunched.isServerExpanded(for: "one"))
    #expect(relaunched.isServerExpanded(for: "two"))
    relaunched.setServerExpanded(true, for: "one")
    #expect(!relaunched.isHostInfoExpanded(for: "one"))
    var edited = relaunched.settings
    edited.servers[0].name = "Renamed"
    edited.servers.reverse()
    edited.collectsHostInfo = false
    relaunched.applySettings(edited)
    edited.collectsHostInfo = true
    relaunched.applySettings(edited)
    #expect(!relaunched.isHostInfoExpanded(for: "one"))
    relaunched.setHostInfoExpanded(true, for: "one")
    #expect(NVBeaconStore(userDefaults: defaults).isHostInfoExpanded(for: "one"))
    #expect(NVBeaconStore(userDefaults: defaults).isServerExpanded(for: "one"))
}

@Test @MainActor func removedServersLoseTheirSavedDisclosureState() throws {
    let suite = "nvbeacon-host-removal-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(servers: [hostInfoServer("one"), hostInfoServer("two")]).normalized()
    defaults.set(try JSONEncoder().encode(settings), forKey: "nvbeacon.settings")
    let store = NVBeaconStore(userDefaults: defaults)
    store.setHostInfoExpanded(false, for: "one")
    store.setServerExpanded(false, for: "one")
    var edited = store.settings
    edited.servers.removeAll { $0.id == "one" }
    store.applySettings(edited)
    edited.servers.append(hostInfoServer("one"))
    store.applySettings(edited)
    #expect(store.isHostInfoExpanded(for: "one"))
    #expect(store.isServerExpanded(for: "one"))
    #expect(defaults.stringArray(forKey: "nvbeacon.collapsed_host_sections") == [])
    #expect(defaults.stringArray(forKey: "nvbeacon.collapsed_servers") == [])
}

@Test @MainActor func choicesWhileHostCollectionIsOffDoNotRestartGPUPolling() throws {
    let suite = "nvbeacon-host-choices-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(servers: [hostInfoServer("one")], collectsHostInfo: false).normalized()
    defaults.set(try JSONEncoder().encode(settings), forKey: "nvbeacon.settings")
    let store = NVBeaconStore(userDefaults: defaults)
    let generation = store.pollingGeneration
    var edited = store.settings
    edited.collectsHostCPU = false
    edited.showsNetworkUsage = false
    store.applySettings(edited)
    #expect(store.pollingGeneration == generation)
    edited.collectsHostInfo = true
    store.applySettings(edited)
    #expect(store.pollingGeneration == generation + 1)
    #expect(store.settings.hostMetricsOptions == HostMetricsOptions(cpu: false, memory: true, network: false))
}

@Test func editingADisabledMemoryCommandDoesNotChangeTheCollectionConfiguration() {
    let server = ServerConfig(id: "one", sshTarget: "one.example.invalid")
    var original = AppSettings(servers: [server], collectsHostMemory: false).normalized()
    var edited = original
    edited.servers[0].memoryCommand = "cat /host/proc/meminfo"
    #expect(PollingConfiguration(original) == PollingConfiguration(edited))
    original.collectsHostMemory = true
    edited.collectsHostMemory = true
    #expect(PollingConfiguration(original) != PollingConfiguration(edited))
}
