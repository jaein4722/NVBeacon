import Foundation
import Testing
@testable import NVBeacon

// Explicitly opt-in. Normal tests/PR CI never read real connection settings or
// contact a server. Credentials remain with the existing OpenSSH configuration.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NVBEACON_LIVE_SSH_SMOKE"] == "1"))
func liveSSHCollectionWithTheSharedCore() async throws {
    let defaults = try #require(UserDefaults(suiteName: "com.leejaein.NVBeacon"))
    let data = try #require(defaults.data(forKey: "nvbeacon.settings"))
    let settings = try JSONDecoder().decode(AppSettings.self, from: data).normalized()
    let servers = Array(settings.pollableServers.filter { $0.sshAuthenticationMode == .keyBased }.prefix(2))
    #expect(!servers.isEmpty)
    for (index, server) in servers.enumerated() {
        do {
            let snapshot = try await SSHMetricsFetcher().fetchSummary(settings: server.connectionSettings(from: settings))
            #expect(!snapshot.gpus.isEmpty)
            print("Live SSH smoke server \(index + 1): GPUs=\(snapshot.gpus.count), hostRAM=\(snapshot.hostMemory != nil)")
        } catch {
            // Do not put SSH targets, usernames, paths or raw remote output into
            // diagnostic test logs.
            Issue.record("Live SSH smoke server \(index + 1) failed: \(DiagnosticsReport.errorCategory(error.localizedDescription))")
        }
    }
}
