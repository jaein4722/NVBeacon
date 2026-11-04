import Foundation
import Testing
@testable import NVBeacon

private func fixtureServer(_ id: String, enabled: Bool = true) -> ServerConfig {
    ServerConfig(id: id, name: "Fixture " + id, sshTarget: id + ".example.invalid", isEnabled: enabled)
}

@Test func pollingConfigurationIgnoresDisplayChangesAndServerOrder() {
    let original = AppSettings(servers: [fixtureServer("one"), fixtureServer("two")]).normalized()
    var edited = original
    edited.popoverWidth = 760
    edited.appearanceMode = .dark
    edited.languagePreference = .korean
    edited.showsDockIcon = true
    edited.closesPopoverOnOutsideClick = false
    edited.menuBarDisplayMode = .iconOnly
    edited.busyDetectionMode = .memoryThreshold
    edited.busyMemoryThresholdMB = 1024
    edited.idleNotificationSeconds = 120
    edited.servers.reverse()
    edited.servers[0].name = "Renamed"
    edited.servers.append(fixtureServer("disabled", enabled: false))
    #expect(PollingConfiguration(original) == PollingConfiguration(edited.normalized()))
}

@Test func pollingConfigurationDetectsChangesToActualCollection() {
    let original = AppSettings(servers: [fixtureServer("one")]).normalized()
    let changes: [(inout AppSettings) -> Void] = [
        { $0.pollIntervalSeconds += 1 },
        { $0.highlightsMyProcesses = false },
        { $0.collectsHostInfo = false },
        { $0.collectsHostCPU = false },
        { $0.collectsHostMemory = false },
        { $0.showsNetworkUsage = false },
        { $0.servers[0].sshTarget = "other.example.invalid" },
        { $0.servers[0].sshPort = "2222" },
        { $0.servers[0].sshIdentityFilePath = "/Users/test/.ssh/fixture" },
        { $0.servers[0].sshAuthenticationMode = .passwordBased },
        { $0.servers[0].sshConnectionReuseMode = .newConnectionEachRefresh },
        { $0.servers[0].remoteCommand = "/opt/bin/gpu-report" },
        { $0.servers[0].memoryCommand = "cat /host/proc/meminfo" },
        { $0.servers[0].isEnabled = false },
    ]
    for change in changes {
        var edited = original
        change(&edited)
        #expect(PollingConfiguration(original) != PollingConfiguration(edited.normalized()))
    }
}

@Test @MainActor func displayUpdatesKeepTheExistingPollingGeneration() throws {
    let suite = "nvbeacon-settings-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let original = AppSettings(servers: [fixtureServer("one", enabled: false)]).normalized()
    defaults.set(try JSONEncoder().encode(original), forKey: "nvbeacon.settings")
    let store = NVBeaconStore(userDefaults: defaults)
    let generation = store.pollingGeneration

    var edited = store.settings
    edited.popoverWidth = 720
    edited.appearanceMode = .dark
    store.applySettings(edited)
    #expect(store.pollingGeneration == generation)
    #expect(store.settings.popoverWidth == 720)

    edited.servers[0].name = "New label"
    store.applySettings(edited)
    #expect(store.pollingGeneration == generation)
    #expect(store.serverStates.first?.server.name == "New label")

    let backup = ServerSettingsBackup(settings: AppSettings(servers: [fixtureServer("imported")]))
    store.applySettings(try backup.addingServers(to: store.settings))
    #expect(store.pollingGeneration == generation)
    #expect(store.serverStates.count == 2)
    #expect(store.serverStates.last?.server.isEnabled == false)

    edited = store.settings
    edited.pollIntervalSeconds = 30
    store.applySettings(edited)
    #expect(store.pollingGeneration == generation + 1)
    let persisted = try JSONDecoder().decode(AppSettings.self, from: #require(defaults.data(forKey: "nvbeacon.settings")))
    #expect(persisted.popoverWidth == 720)
    #expect(persisted.pollIntervalSeconds == 30)
}

@Test func serverBackupRoundTripKeepsCommandsButImportsFreshDisabledServers() throws {
    var server = fixtureServer("backup-source")
    server.sshPort = "2222"
    server.sshIdentityFilePath = "/Users/test/.ssh/fixture"
    server.remoteCommand = "/opt/bin/nvidia-smi --query-gpu=fixture"
    server.memoryCommand = "cat /host/proc/meminfo"
    let source = AppSettings(servers: [server], popoverWidth: 800)
    let data = try ServerSettingsBackup(settings: source).encoded()
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("\"id\""))
    #expect(!text.contains("popoverWidth"))
    #expect(!text.contains("password_saved_hint"))

    let backup = try ServerSettingsBackup.decode(data)
    let existing = AppSettings(servers: [fixtureServer("existing", enabled: false)], popoverWidth: 620)
    let imported = try backup.addingServers(to: existing)
    #expect(imported.servers.count == 2)
    #expect(imported.servers[0] == existing.servers[0])
    #expect(imported.popoverWidth == 620)
    let added = imported.servers[1]
    #expect(added.id != server.id)
    #expect(!added.isEnabled)
    #expect(added.sshTarget == server.sshTarget)
    #expect(added.sshPort == server.sshPort)
    #expect(added.remoteCommand == server.remoteCommand)
    #expect(added.memoryCommand == server.memoryCommand)
    #expect(added.keychainAccount != server.keychainAccount)
    #expect(!added.allowsLegacyPasswordFallback)
    let again = try backup.addingServers(to: existing)
    #expect(again.servers[1].id != added.id)
}

@Test func legacyPasswordFallbackIsLimitedToTheMigratedLegacyServer() {
    #expect(ServerConfig(id: "legacy-primary").allowsLegacyPasswordFallback)
    #expect(!fixtureServer("new-server").allowsLegacyPasswordFallback)
    #expect(!ServerConfig().allowsLegacyPasswordFallback)
}

@Test func serverBackupRejectsUnsupportedOrUnsafeFiles() throws {
    let valid = try ServerSettingsBackup(settings: AppSettings(servers: [fixtureServer("one")])).encoded()
    var json = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    json["version"] = 999
    let unsupported = try JSONSerialization.data(withJSONObject: json)
    #expect(throws: ServerSettingsBackup.BackupError.unsupportedFormat) {
        try ServerSettingsBackup.decode(unsupported)
    }
    #expect(throws: ServerSettingsBackup.BackupError.fileTooLarge) {
        try ServerSettingsBackup.decode(Data(repeating: 32, count: ServerSettingsBackup.maximumFileBytes + 1))
    }
    #expect(throws: ServerSettingsBackup.BackupError.invalidServerCount) {
        try ServerSettingsBackup(settings: AppSettings()).encoded()
    }
    for target in ["-oProxyCommand=fixture", "host\nother", "host with spaces"] {
        var server = fixtureServer("one")
        server.sshTarget = target
        #expect(throws: ServerSettingsBackup.BackupError.invalidServer) {
            try ServerSettingsBackup(settings: AppSettings(servers: [server])).encoded()
        }
    }
    var invalidPort = fixtureServer("one")
    invalidPort.sshPort = "70000"
    #expect(throws: ServerSettingsBackup.BackupError.invalidServer) {
        try ServerSettingsBackup(settings: AppSettings(servers: [invalidPort])).encoded()
    }
}

@Test func serverBackupDoesNotCarryUnknownCredentialsOrIDsFromImportedJSON() throws {
    let data = try ServerSettingsBackup(settings: AppSettings(servers: [fixtureServer("one")])).encoded()
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var entries = try #require(json["servers"] as? [[String: Any]])
    entries[0]["password"] = "fixture-password"
    entries[0]["privateKey"] = "fixture-private-key"
    entries[0]["id"] = "old-private-id"
    json["servers"] = entries
    let decoded = try ServerSettingsBackup.decode(JSONSerialization.data(withJSONObject: json))
    let exported = String(decoding: try decoded.encoded(), as: UTF8.self)
    for excluded in ["fixture-password", "fixture-private-key", "old-private-id"] {
        #expect(!exported.contains(excluded))
    }
    let imported = try decoded.addingServers(to: AppSettings())
    #expect(imported.servers[0].id != "old-private-id")
    #expect(!imported.servers[0].isEnabled)
}

@Test func exportedBackupWrapperPreservesItsFileTypeAndWritesPrivatePermissions() throws {
    let data = try ServerSettingsBackup(settings: AppSettings(servers: [fixtureServer("one")])).encoded()
    let wrapper = ServerBackupDocument(data: data).makeFileWrapper()
    #expect(wrapper.isRegularFile)
    #expect(wrapper.fileAttributes[FileAttributeKey.type.rawValue] as? String == FileAttributeType.typeRegular.rawValue)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-export-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("servers.json")
    try wrapper.write(to: file, options: .atomic, originalContentsURL: nil)
    #expect(try Data(contentsOf: file) == data)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func diagnosticsOmitConnectionDetailsCommandsAndRawErrors() {
    let secret = "fixture-sensitive-token"
    var server = fixtureServer("one")
    server.name = "private-server-name"
    server.sshTarget = "fixture-user@private.example.invalid"
    server.sshIdentityFilePath = "/Users/test/.ssh/private-fixture"
    server.remoteCommand = "gpu-query --token=" + secret
    server.memoryCommand = "memory-query --token=" + secret
    server.hostCommand = "host-query --token=" + secret
    let process = GPUProcessReading(gpuUUID: "GPU-private-uuid", pid: 424242, processName: "private-process",
                                    usedGPUMemoryMB: 100, userID: 501, user: "fixture-user",
                                    commandLine: "python --token=" + secret)
    let gpu = GPUReading(index: 0, name: "NVIDIA Test GPU", uuid: "GPU-private-uuid",
                         utilization: 50, memoryUsedMB: 100, memoryTotalMB: 1000,
                         temperatureCelsius: 40, processes: [process])
    let snapshot = GPUSnapshot(takenAt: Date(timeIntervalSince1970: 1000), gpus: [gpu],
                               hostMemory: HostMemoryReading(totalKiB: 1000, availableKiB: 500,
                                                             swapTotalKiB: 0, swapFreeKiB: 0))
    let state = ServerRuntimeState(
        server: server, snapshot: snapshot,
        lastErrorMessage: "Permission denied for " + server.sshTarget + " token=" + secret,
        detectedSSHUsername: "fixture-user"
    )
    let report = DiagnosticsReport.make(
        settings: AppSettings(servers: [server]), states: [state],
        appVersion: "0.6.0", buildNumber: "1", notificationStatus: "Authorized",
        pollingRestarts: 0, now: Date(timeIntervalSince1970: 1010)
    )
    for omitted in [secret, server.name, server.sshTarget, server.sshIdentityFilePath,
                    server.remoteCommand, server.memoryCommand, server.hostCommand, "fixture-user", "GPU-private-uuid",
                    "424242", "private-process", "python --token", state.id] {
        #expect(!report.contains(omitted))
    }
    #expect(report.contains("Authentication"))
    #expect(report.contains("NVIDIA Test GPU"))
    #expect(report.contains("Sample age: 10 s"))
    #expect(report.contains("Host RAM KiB: total=1000, available=500"))
    #expect(report.contains("Custom (omitted)"))
}

@Test func portableExportResolvesOpenSSHProfilesOnlyForTheArchive() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = directory.appendingPathComponent("config")
    let hosts = directory.appendingPathComponent("hosts")
    try "Include \"\(hosts.path)\"\n".write(to: config, atomically: true, encoding: .utf8)
    try """
        Host lab
          HostName gpu.example.invalid
          User researcher
          Port 2200
        """.write(to: hosts, atomically: true, encoding: .utf8)

    var server = fixtureServer("profile")
    server.sshTarget = "lab"
    var override = fixtureServer("override")
    override.sshTarget = "alternate@lab"
    override.sshPort = "2222"
    let settings = AppSettings(servers: [server, override])
    let archive = try await ServerSettingsBackup.portableExport(settings: settings, configFile: config)
    let decoded = try ServerSettingsBackup.decode(archive.encoded())
    #expect(decoded.servers.map(\.sshTarget) == ["researcher@gpu.example.invalid", "alternate@gpu.example.invalid"])
    #expect(decoded.servers.map(\.sshPort) == ["2200", "2222"])
    #expect(decoded.servers.map(\.name) == [server.name, override.name])
    #expect(settings.servers.first?.sshTarget == "lab")
    for directive in ["ProxyJump gateway", "ProxyCommand false"] {
        try "Host lab\n  \(directive)\n".write(to: hosts, atomically: true, encoding: .utf8)
        await #expect(throws: ServerSettingsBackup.ExportError.self) {
            try await ServerSettingsBackup.portableExport(settings: settings, configFile: config)
        }
    }
}
