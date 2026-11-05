import Foundation
import Testing
@testable import NVBeacon

// Opt-in metadata-only preflight of the installed Mac app. Never materialize a batch.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NVBEACON_TRANSFER_PREFLIGHT"] == "1"))
func installedMacTransferPreflight() async throws {
    let domain = try #require(UserDefaults(suiteName: "com.leejaein.NVBeacon"))
    guard let data = domain.data(forKey: "nvbeacon.settings") else {
        Issue.record("Installed Mac settings unavailable")
        return
    }
    let settings = try JSONDecoder().decode(AppSettings.self, from: data).normalized()
    let total = settings.configuredServers.count
    let rows = try await MacTransferPreparation.review(settings: settings)
    let resolved = rows.filter { $0.endpoint != nil }.count
    let keys = rows.compactMap(\.keyFile)
    let uniqueFiles = Set(keys.map(\.url)).count
    print("Mac transfer preflight: configured=\(total), reviewed=\(rows.count), resolved=\(resolved), suggestedKeys=\(keys.count), distinctKeyFiles=\(uniqueFiles)")
    #expect(rows.count == total)
}
