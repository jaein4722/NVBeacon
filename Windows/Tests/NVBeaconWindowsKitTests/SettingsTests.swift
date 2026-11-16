import Foundation
import NVBeaconCore
import Testing
@testable import NVBeaconWindowsKit

@Test func settingsDecodeMissingFieldsAsMacOSDefaults() throws {
    let settings = try JSONDecoder().decode(WindowsSettings.self, from: Data(#"{"pollIntervalSeconds": 999, "popoverWidth": 10}"#.utf8))
    #expect(settings.busyDetectionMode == .activeProcess)
    #expect(settings.collectsHostInfo)
    let clamped = settings.sanitized()
    #expect(clamped.pollIntervalSeconds == 300)
    #expect(clamped.popoverWidth == 480)
}

/// The exact shape settings.js posts back (captured from the page), decoded the
/// way TrayApp does: JSONSerialization object → Data → WindowsSettings.
@Test func settingsPageApplyPayloadDecodes() throws {
    let payload = #"""
    {"type":"apply","settings":{"servers":[{"id":"A","name":"Lab GPU","sshTarget":"alice@gpu-a","sshPort":"","sshIdentityFilePath":"","sshAuthenticationMode":"keyBased","remoteCommand":"nvidia-smi","hostCommand":"host-default","isEnabled":true},{"id":"B","name":"","sshTarget":"lab-box","sshPort":"2222","sshIdentityFilePath":"C:\\Users\\me\\.ssh\\id_lab","sshAuthenticationMode":"passwordBased","remoteCommand":"custom","hostCommand":"host-default","isEnabled":false}],"pollIntervalSeconds":10,"busyDetectionMode":"memoryThreshold","busyMemoryThresholdMB":50,"busyUtilizationThresholdPercent":10,"collectsHostInfo":true,"collectsHostCPU":true,"collectsHostMemory":true,"showsNetworkUsage":true,"languagePreference":"system","appearanceMode":"system","popoverWidth":500,"closesPopoverOnOutsideClick":true}}
    """#
    let message = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let data = try JSONSerialization.data(withJSONObject: try #require(message["settings"]))
    let settings = try JSONDecoder().decode(WindowsSettings.self, from: data)
    #expect(settings.servers.count == 2)
    #expect(settings.servers[1].sshIdentityFilePath == #"C:\Users\me\.ssh\id_lab"#)
    #expect(settings.servers[1].sshAuthenticationMode == .passwordBased)
    #expect(settings.busyDetectionMode == .memoryThreshold)
}

@Test func settingsRoundTripAndMigrateServersText() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-settings-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("settings.json")
    let legacy = folder.appendingPathComponent("servers.txt")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "gpu-a\n# comment\nbob@gpu-b\n".write(to: legacy, atomically: true, encoding: .utf8)

    var migrated = SettingsStore.load(from: file, legacyServerFile: legacy)
    #expect(migrated.servers.map(\.sshTarget) == ["gpu-a", "bob@gpu-b"])

    migrated.servers[0].sshPort = "2222"
    migrated.appearanceMode = .dark
    try SettingsStore.save(migrated, to: file)
    #expect(SettingsStore.load(from: file, legacyServerFile: legacy) == migrated)
}

@Test func pollableRequiresEnabledKeyBasedServerWithTarget() {
    #expect(ServerSettings(sshTarget: "gpu").isPollable)
    #expect(!ServerSettings(sshTarget: "gpu", isEnabled: false).isPollable)
    #expect(!ServerSettings(sshTarget: "gpu", sshAuthenticationMode: .passwordBased).isPollable)
    #expect(!ServerSettings(sshTarget: " ").isPollable)
    #expect(ServerSettings(sshTarget: "gpu", sshPort: "70000").resolvedPort == nil)
    #expect(ServerSettings(sshTarget: "gpu", remoteCommand: "  ").resolvedRemoteCommand == RemoteMetricCommands.defaultGPUCommand)
    #expect(ServerSettings(name: "", sshTarget: "alice@gpu").displayName == "alice@gpu")
}

@Test func backupExportsAndImportsDisabledServers() throws {
    var settings = WindowsSettings()
    settings.servers = [ServerSettings(name: "Lab", sshTarget: "lab", sshPort: "22"), ServerSettings(sshTarget: "")]
    let data = try settings.backup().encoded()
    let backup = try ServerSettingsBackup.decode(data)
    #expect(backup.servers.count == 1)

    var other = WindowsSettings()
    other.servers = [ServerSettings(sshTarget: "existing")]
    other.importServers(from: backup)
    #expect(other.servers.map(\.sshTarget) == ["existing", "lab"])
    #expect(other.servers[1].isEnabled == false)
    #expect(other.servers[1].sshPort == "22")
}

@Test func sshConfigListsConcreteHosts() {
    let config = """
    Host *
      ServerAliveInterval 30
    Host gpu-a gpu-b
      HostName 10.0.0.5
      User alice
    Host gpu-a
      Port 2222
      IdentityFile "~/.ssh/id_lab"
    Host !bastion *.internal
      User nobody
    Match host gpu-b
      Port 9
    """
    let hosts = SSHConfigHosts.parse(config)
    #expect(hosts.map(\.alias) == ["gpu-a", "gpu-b"])
    #expect(hosts[0].hostName == "10.0.0.5")
    #expect(hosts[0].port == "2222")
    #expect(hosts[0].identityFile == "~/.ssh/id_lab")
    #expect(hosts[1].port == nil)
}

@Test func loginUserDetectionMatchesMacOS() {
    let hosts = [SSHConfigHost(alias: "lab", hostName: "10.0.0.5", user: "Alice")]
    func detect(_ target: String) -> String? {
        ServerMonitor.detectedSSHUsername(for: ServerSettings(sshTarget: target), sshConfigHosts: hosts, localUsername: "Gamjo")
    }
    #expect(detect("bob@gpu") == "bob")
    #expect(detect("lab") == "alice")
    #expect(detect("other") == "gamjo")
    #expect(detect("") == nil)
}

@Test func processDetailsMergeIntoTheCurrentListOnly() async throws {
    var settings = WindowsSettings()
    settings.servers = [ServerSettings(sshTarget: "demo:a100")]
    let monitor = ServerMonitor(servers: settings.servers, interval: .seconds(60), highlightsMyProcesses: true) {}
    await monitor.pollAll()
    let state = try #require(monitor.snapshot.first)
    #expect(state.detectedSSHUsername == "alice")
    #expect(state.detectedSSHUserID == 1001)
    let busy = try #require(state.snapshot?.gpus.first { !$0.processes.isEmpty })
    #expect(busy.processes.allSatisfy { state.isCurrentUserProcess($0) == ($0.user == "alice") })

    monitor.loadProcessDetails(serverID: state.id, gpuIndex: busy.index)
    for _ in 0..<50 where !(monitor.snapshot.first?.loadingDetailGPUs.isEmpty ?? true) {
        try await Task.sleep(for: .milliseconds(50))
    }
    let after = try #require(monitor.snapshot.first?.snapshot?.gpus.first { $0.index == busy.index })
    #expect(after.processes.allSatisfy { $0.commandLine?.contains("--seed") == true })
    #expect(after.processes.map(\.pid) == busy.processes.map(\.pid))
}

@Test func psCommandsAreTheMacOSText() {
    #expect(ServerMonitor.detailedPSLookupCommand(pids: [12, 7]) == #"ps -o pid= -o uid= -o user= -o args= -p "12,7" 2>/dev/null || true"#)
    #expect(ServerMonitor.remoteUIDLookupCommand(username: "o'neil") == #"id -u -- 'o'\''neil'"#)
}

@Test func transportPassesPortAndIdentityFile() {
    let arguments = SSHTransport.arguments(target: "gpu", port: 2222, identityFile: #"C:\keys\id_ed25519"#, remoteCommand: "true")
    let target = arguments.firstIndex(of: "gpu")!
    #expect(Array(arguments[(target - 4)..<target]) == ["-i", #"C:\keys\id_ed25519"#, "-p", "2222"])
}
