import Foundation

enum DiagnosticsReport {
    /// Use an allowlist rather than trying to redact arbitrary command output.
    /// This is a local snapshot; generating it never contacts any server.
    static func make(
        settings: AppSettings,
        states: [ServerRuntimeState],
        appVersion: String,
        buildNumber: String,
        notificationStatus: String,
        pollingRestarts: Int,
        now: Date = Date()
    ) -> String {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let dateFormat = ISO8601DateFormatter()
        var lines = [
            "NVBeacon Diagnostics",
            "Generated: " + dateFormat.string(from: now),
            "App: " + appVersion + " (" + buildNumber + ")",
            "macOS: " + ProcessInfo.processInfo.operatingSystemVersionString,
            "Architecture: " + architecture,
            "Polling interval: " + String(settings.pollIntervalSeconds) + " s",
            "Polling restarts this session: " + String(pollingRestarts),
            "Popover width: " + String(settings.resolvedPopoverWidth) + " pt",
            "Process highlighting: " + String(settings.highlightsMyProcesses),
            "Notifications: " + notificationStatus,
            "Servers: " + String(states.count) + " configured / " + String(states.filter { $0.server.isEnabled }.count) + " enabled",
            "",
            "Host names, users, addresses, key paths, custom commands, process details",
            "and raw error messages are omitted. No passwords or private keys are read.",
        ]
        for (offset, state) in states.enumerated() {
            let server = state.server
            lines += [
                "",
                "Server " + String(offset + 1),
                "  Enabled: " + String(server.isEnabled),
                "  Authentication: " + server.sshAuthenticationMode.rawValue,
                "  SSH reuse: " + server.sshConnectionReuseMode.rawValue,
                "  Identity file configured: " + String(!server.sshIdentityFilePath.isEmpty),
                "  GPU command: " + (server.remoteCommand == AppSettings.defaultRemoteCommand ? "Default" : "Custom (omitted)"),
                "  Host command: " + (server.hostCommand == AppSettings.defaultHostCommand ? "Default" : "Custom (omitted)"),
                "  Refreshing: " + String(state.isRefreshing),
                "  Error category: " + errorCategory(state.lastErrorMessage),
            ]
            guard let snapshot = state.snapshot else {
                lines.append("  Last successful sample: None")
                continue
            }
            lines += [
                "  Last successful sample: " + dateFormat.string(from: snapshot.takenAt),
                "  Sample age: " + String(max(0, Int(now.timeIntervalSince(snapshot.takenAt)))) + " s",
                "  GPUs: " + String(snapshot.gpus.count),
                "  Processes: " + String(snapshot.totalProcessCount),
            ]
            for gpu in snapshot.gpus {
                // Names are hardware model labels; UUIDs and process owners/PIDs
                // are deliberately not included.
                let model = String(gpu.name.components(separatedBy: .controlCharacters).joined().prefix(120))
                lines.append("  GPU " + String(gpu.index) + ": " + model
                    + ", utilization=" + String(gpu.utilization) + "%"
                    + ", memory=" + String(gpu.memoryUsedMB) + "/" + String(gpu.memoryTotalMB) + " MB")
            }
            if let memory = snapshot.hostMemory {
                lines.append("  Host RAM KiB: total=" + String(memory.totalKiB) + ", available=" + String(memory.availableKiB))
                lines.append("  Swap KiB: total=" + (memory.swapTotalKiB.map(String.init) ?? "Unavailable")
                    + ", free=" + (memory.swapFreeKiB.map(String.init) ?? "Unavailable"))
            } else {
                lines.append("  Host RAM: Unavailable")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func errorCategory(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "None" }
        let text = message.lowercased()
        if text.contains("output exceeded") || (text.contains("출력") && text.contains("제한")) { return "Output limit" }
        if text.contains("timed out") || text.contains("시간 초과") { return "Timeout" }
        if text.contains("host key") || text.contains("host identification") { return "Host key verification" }
        if text.contains("permission denied") || text.contains("authentication") || text.contains("password")
            || text.contains("비밀번호") || text.contains("인증") { return "Authentication" }
        if text.contains("could not resolve") || text.contains("name or service") { return "Host resolution" }
        if text.contains("connection refused") { return "Connection refused" }
        if text.contains("no route") || text.contains("unreachable") { return "Network unreachable" }
        if text.contains("parsed") || text.contains("파싱") || text.contains("empty") || text.contains("비어") { return "Metrics output" }
        return "Other (details omitted)"
    }
}
