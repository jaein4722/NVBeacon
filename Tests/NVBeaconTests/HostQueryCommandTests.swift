import Foundation
import Testing
@testable import NVBeacon

@Test func legacyMemoryCommandsMigrateIntoTheFullHostScript() throws {
    let server = ServerConfig(id: "fixture", sshTarget: "fixture.example.invalid",
                              memoryCommand: "cat /host/proc/meminfo")
    let original = AppSettings(servers: [server]).normalized()
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    json.removeValue(forKey: "hostCommand")
    var entries = try #require(json["servers"] as? [[String: Any]])
    entries[0].removeValue(forKey: "hostCommand")
    json["servers"] = entries
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json)).normalized()
    let migrated = try #require(restored.servers.first)
    #expect(migrated.id == server.id)
    #expect(migrated.remoteCommand == server.remoteCommand)
    #expect(migrated.hostCommand.contains("cat /host/proc/meminfo"))
    #expect(migrated.hostCommand.contains("/proc/stat"))
    #expect(migrated.hostCommand.contains("/sys/class/net"))
    #expect(restored.hostCommand == migrated.hostCommand)
    let legacy = AppSettings(sshTarget: "legacy.example.invalid", memoryCommand: "cat /legacy/proc/meminfo").normalized()
    #expect(legacy.servers.first?.hostCommand.contains("cat /legacy/proc/meminfo") == true)
}

@Test func hostCommandsPersistFollowTheSelectedServerAndRestoreDefaults() throws {
    let first = ServerConfig(id: "one", sshTarget: "one.example.invalid", hostCommand: "/opt/bin/host-report-one")
    let second = ServerConfig(id: "two", sshTarget: "two.example.invalid", hostCommand: " /opt/bin/host-report-two ")
    let original = AppSettings(servers: [first, second]).normalized()
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
    #expect(restored == original)
    #expect(restored.hostCommand == first.hostCommand)
    #expect(restored.servers[1].connectionSettings(from: restored).normalized().hostCommand == "/opt/bin/host-report-two")
    #expect(ServerConfig(hostCommand: " \n ").normalized().hostCommand == AppSettings.defaultHostCommand)
    var customized = first
    customized.memoryCommand = "cat /other/proc/meminfo"
    #expect(customized.hostCommand == first.hostCommand)
}

@Test func hostCommandsRoundTripInV2ArchivesAndV1ArchivesUpgrade() throws {
    let server = ServerConfig(id: "fixture", sshTarget: "fixture.example.invalid", memoryCommand: "cat /host/proc/meminfo",
                              hostCommand: "/opt/bin/whole-host-report")
    let source = ServerSettingsBackup(settings: AppSettings(servers: [server]))
    let decoded = try ServerSettingsBackup.decode(source.encoded())
    #expect(decoded.version == 2)
    let imported = try #require(decoded.addingServers(to: AppSettings()).servers.first)
    #expect(imported.hostCommand == server.hostCommand)
    #expect(!imported.isEnabled)

    var json = try #require(JSONSerialization.jsonObject(with: source.encoded()) as? [String: Any])
    json["version"] = 1
    var entries = try #require(json["servers"] as? [[String: Any]])
    entries[0].removeValue(forKey: "hostCommand")
    json["servers"] = entries
    let legacy = try ServerSettingsBackup.decode(JSONSerialization.data(withJSONObject: json))
    #expect(legacy.servers[0].hostCommand.contains("cat /host/proc/meminfo"))
    #expect(legacy.servers[0].hostCommand.contains("/proc/stat"))
    let reexport = try #require(JSONSerialization.jsonObject(with: legacy.encoded()) as? [String: Any])
    #expect(reexport["version"] as? Int == 2)
}

@Test func hostCommandChangesAffectPollingWhenAnyHostMetricIsEnabled() {
    let server = ServerConfig(id: "one", sshTarget: "one.example.invalid")
    var original = AppSettings(servers: [server], collectsHostMemory: false).normalized()
    var edited = original
    edited.servers[0].hostCommand = "/opt/bin/cpu-and-network"
    #expect(PollingConfiguration(original) != PollingConfiguration(edited))
    original.collectsHostInfo = false
    edited.collectsHostInfo = false
    #expect(PollingConfiguration(original) == PollingConfiguration(edited))
}
