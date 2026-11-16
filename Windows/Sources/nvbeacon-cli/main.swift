import Foundation
import NVBeaconWindowsKit

// Console client for checking collection from a terminal:
//   nvbeacon-cli [--interval SECONDS] [--once] [--demo] [TARGET ...]
// Without targets it uses the enabled servers saved by the app's Settings window.

// --details also runs the process-details lookup (user names, full command lines) for
// every GPU with processes, and marks the SSH user's processes, like expanding GPUs
// in the flyout.
var arguments = Array(CommandLine.arguments.dropFirst())
let showsDetails = arguments.contains("--details")
arguments.removeAll { $0 == "--details" }

var options: LaunchOptions
do {
    options = try LaunchOptions.parse(arguments)
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
                            hostMetrics: options.targets.isEmpty ? settings.hostMetricsOptions : .init(),
                            highlightsMyProcesses: showsDetails, sshConfigHosts: SSHConfigHosts.load()) {}
repeat {
    await monitor.pollAll()
    if showsDetails {
        for state in monitor.snapshot {
            for gpu in state.snapshot?.gpus ?? [] where !gpu.processes.isEmpty {
                monitor.loadProcessDetails(serverID: state.id, gpuIndex: gpu.index)
            }
        }
        for _ in 0..<300 where monitor.snapshot.contains(where: { !$0.loadingDetailGPUs.isEmpty }) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    let stamp = Date().formatted(date: .omitted, time: .standard)
    print("[\(stamp)]")
    for state in monitor.snapshot {
        print(SummaryFormatter.report(state))
        if showsDetails {
            let mine = (state.snapshot?.gpus ?? []).flatMap(\.processes).filter(state.isCurrentUserProcess).map(\.pid)
            print("    login user: \(state.detectedSSHUsername ?? "?") (uid \(state.detectedSSHUserID.map(String.init) ?? "?")), mine: \(mine)"
                  + (state.detailError.map { ", details error: \($0)" } ?? ""))
        }
    }
    print("")
    if !options.once { try await Task.sleep(for: options.interval) }
} while !options.once
exit(monitor.snapshot.contains { $0.lastError != nil } ? 1 : 0)
