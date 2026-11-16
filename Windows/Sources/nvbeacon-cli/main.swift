import Foundation
import NVBeaconWindowsKit

// Console client for checking collection from a terminal:
//   nvbeacon-cli [--interval SECONDS] [--once] [TARGET ...]
// Without targets it reads %APPDATA%\NVBeacon\servers.txt.

var options: LaunchOptions
do {
    options = try LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("\(error)\nusage: nvbeacon-cli [--interval SECONDS] [--once] [TARGET ...]\n".utf8))
    exit(2)
}
if options.targets.isEmpty { options.targets = LaunchOptions.loadServerFile() }
guard !options.targets.isEmpty else {
    FileHandle.standardError.write(Data("No servers. Pass an SSH target or edit \(LaunchOptions.serverFile.path)\n".utf8))
    exit(2)
}

let monitor = ServerMonitor(targets: options.targets, interval: options.interval) {}
repeat {
    await monitor.pollAll()
    let stamp = Date().formatted(date: .omitted, time: .standard)
    print("[\(stamp)]")
    for state in monitor.snapshot { print(SummaryFormatter.report(state)) }
    print("")
    if !options.once { try await Task.sleep(for: options.interval) }
} while !options.once
exit(monitor.snapshot.contains { $0.lastError != nil } ? 1 : 0)
