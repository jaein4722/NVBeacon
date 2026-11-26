import Testing
@testable import NVBeaconCore

private struct Connection: SSHConnectionFingerprinting {
    var sshTarget = "alice@lab"
    var sshPort = "2222"
    var sshIdentityFilePath = "/keys/id_ed25519"
    var sshAuthenticationMode = SSHAuthenticationMode.keyBased
    var name = "Lab"
}

@Test func connectionFingerprintKeepsSavedFormat() {
    #expect(Connection().connectionFingerprint == "alice@lab|2222|/keys/id_ed25519|keyBased")
    #expect(Connection(sshTarget: "lab", sshPort: "", sshIdentityFilePath: "", sshAuthenticationMode: .passwordBased)
        .connectionFingerprint == "lab|||passwordBased")
}

@Test func connectionFingerprintChangesOnlyWithConnectionFields() {
    let base = Connection()
    var renamed = base
    renamed.name = "Renamed"
    #expect(renamed.connectionFingerprint == base.connectionFingerprint)

    var target = base
    target.sshTarget = "bob@lab"
    var port = base
    port.sshPort = "22"
    var key = base
    key.sshIdentityFilePath = "/keys/other"
    var mode = base
    mode.sshAuthenticationMode = .passwordBased
    for changed in [target, port, key, mode] {
        #expect(changed.connectionFingerprint != base.connectionFingerprint)
    }
}
