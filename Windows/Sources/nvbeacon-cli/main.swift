import Foundation
import NVBeaconWindowsKit

// Console client for checking collection from a terminal:
//   nvbeacon-cli [--interval SECONDS] [--once] [--demo] [TARGET ...]
// Without targets it uses the enabled servers saved by the app's Settings window.

var options: LaunchOptions
do {
    options = try LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\nusage: nvbeacon-cli [--interval SECONDS] [--once] [--demo] [TARGET ...]\n".utf8))
    exit(2)
}

let settings = SettingsStore.load()
let servers = options.targets.isEmpty
    ? settings.servers.filter(\.isPollable)
    : options.targets.map { ServerSettings(sshTarget: $0) }
guard !servers.isEmpty else {
    FileHandle.standardError.write(Data("No servers. Pass an SSH target or add one in NVBeacon Settings (\(SettingsStore.fileURL.path)).\n".utf8))
    exit(2)
}

let monitor = ServerMonitor(servers: servers, interval: options.interval,
                            hostMetrics: options.targets.isEmpty ? settings.hostMetricsOptions : .init()) {}
repeat {
    await monitor.pollAll()
    let stamp = Date().formatted(date: .omitted, time: .standard)
    print("[\(stamp)]")
    for state in monitor.snapshot { print(SummaryFormatter.report(state)) }
    print("")
    if !options.once { try await Task.sleep(for: options.interval) }
} while !options.once
exit(monitor.snapshot.contains { $0.lastError != nil } ? 1 : 0)
