import Foundation
import NVBeaconCore
import NVBeaconWindowsKit

/// Windows port of the macOS diagnostics report: an allowlist of facts, never
/// host names, users, addresses, key paths, custom commands or process details.
enum DiagnosticsReport {
    static var appVersion: String { AppIdentity.version.map { $0 + " (Windows)" } ?? "Windows development build" }

    static func make(settings: WindowsSettings, states: [ServerState], now: Date = Date()) -> String {
        let dateFormat = ISO8601DateFormatter()
        let savedPasswords = SSHPasswordStore().savedServerIDs()
        var lines = [
            "NVBeacon Diagnostics",
            "Generated: " + dateFormat.string(from: now),
            "App: " + appVersion,
            "Windows: " + ProcessInfo.processInfo.operatingSystemVersionString,
            "Architecture: x86_64",
            "Polling interval: " + String(settings.pollIntervalSeconds) + " s",
            "Popover width: " + String(settings.popoverWidth) + " pt",
            "Busy detection: " + settings.busyDetectionMode.rawValue,
            "Host information: cpu=\(settings.hostMetricsOptions.cpu), memory=\(settings.hostMetricsOptions.memory), network=\(settings.hostMetricsOptions.network)",
            "Servers: " + String(states.count) + " configured / " + String(states.filter { $0.server.isEnabled }.count) + " enabled",
            "",
            "Host names, users, addresses, key paths, custom commands, process details",
            "and raw error messages are omitted. Passwords and private keys are not included.",
        ]
        for (offset, state) in states.enumerated() {
            let server = state.server
            lines += [
                "",
                "Server " + String(offset + 1),
                "  Enabled: " + String(server.isEnabled),
                "  Authentication: " + server.sshAuthenticationMode.rawValue,
                "  SSH reuse: " + server.sshConnectionReuseMode.rawValue,
                "  Password saved: " + (server.sshAuthenticationMode == .passwordBased ? String(savedPasswords.contains(server.id)) : "not required"),
                "  Password rejected: " + String(state.passwordRejected),
                "  Identity file configured: " + String(!server.sshIdentityFilePath.trimmingCharacters(in: .whitespaces).isEmpty),
                "  Port configured: " + String(server.resolvedPort != nil),
                "  GPU command: " + (server.resolvedRemoteCommand == RemoteMetricCommands.defaultGPUCommand ? "Default" : "Custom (omitted)"),
                "  Host command: " + (server.resolvedHostCommand == RemoteMetricCommands.defaultHostCommand ? "Default" : "Custom (omitted)"),
                "  Refreshing: " + String(state.isRefreshing),
                "  Error category: " + errorCategory(state.lastError),
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
                let model = String(gpu.name.components(separatedBy: .controlCharacters).joined().prefix(120))
                lines.append("  GPU " + String(gpu.index) + ": " + model
                    + ", utilization=" + String(gpu.utilization) + "%"
                    + ", memory=" + String(gpu.memoryUsedMB) + "/" + String(gpu.memoryTotalMB) + " MB")
            }
            if let memory = snapshot.hostMemory {
                lines.append("  Host RAM KiB: total=" + String(memory.totalKiB) + ", available=" + String(memory.availableKiB))
            } else {
                lines.append("  Host RAM: Unavailable")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The categories in Korean, for Settings › Servers › Test Connection.
    static func koreanCategory(_ category: String) -> String {
        [
            "None": "없음", "Output limit": "출력 한도 초과", "Timeout": "시간 초과",
            "Host key verification": "호스트 키 확인", "Authentication": "인증", "Host resolution": "호스트 이름 확인",
            "Connection refused": "연결 거부", "Network unreachable": "네트워크 연결 불가",
            "OpenSSH client missing": "OpenSSH 클라이언트 없음", "Metrics output": "수집 결과", "Other (details omitted)": "기타",
        ][category] ?? category
    }

    static func errorCategory(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "None" }
        let text = message.lowercased()
        if text.contains("output exceeded") { return "Output limit" }
        if text.contains("timed out") { return "Timeout" }
        if text.contains("host key") || text.contains("host identification") { return "Host key verification" }
        if text.contains("permission denied") || text.contains("authentication") || text.contains("password") { return "Authentication" }
        if text.contains("could not resolve") || text.contains("name or service") { return "Host resolution" }
        if text.contains("connection refused") { return "Connection refused" }
        if text.contains("no route") || text.contains("unreachable") { return "Network unreachable" }
        if text.contains("openssh client not found") { return "OpenSSH client missing" }
        if text.contains("parsed") || text.contains("empty") { return "Metrics output" }
        return "Other (details omitted)"
    }
}
