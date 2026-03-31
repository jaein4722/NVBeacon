import Foundation

enum MenuBarDisplayMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case averageAndBusy
    case averageOnly
    case busyOnly
    case iconOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .averageAndBusy:
            return "Average + Busy"
        case .averageOnly:
            return "Average Util"
        case .busyOnly:
            return "Busy Count"
        case .iconOnly:
            return "Icon Only"
        }
    }

    var detailText: String {
        switch self {
        case .averageAndBusy:
            return "평균 GPU 사용률과 busy GPU 수를 함께 표시합니다."
        case .averageOnly:
            return "평균 GPU 사용률만 메뉴바에 표시합니다."
        case .busyOnly:
            return "busy GPU 개수만 메뉴바에 표시합니다."
        case .iconOnly:
            return "텍스트 없이 아이콘만 표시합니다. 상태 이상은 아이콘 색/심볼로 구분합니다."
        }
    }

    func titleText(for snapshot: GPUSnapshot) -> String {
        switch self {
        case .averageAndBusy:
            return "GPU \(snapshot.averageUtilization)% · \(snapshot.busyCount)/\(snapshot.gpus.count)"
        case .averageOnly:
            return "GPU \(snapshot.averageUtilization)%"
        case .busyOnly:
            return "GPU \(snapshot.busyCount)/\(snapshot.gpus.count)"
        case .iconOnly:
            return ""
        }
    }
}

enum AppAppearanceMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var detailText: String {
        switch self {
        case .system:
            return "macOS 시스템 설정을 그대로 따릅니다."
        case .light:
            return "GPUUsage를 항상 라이트 모드로 표시합니다."
        case .dark:
            return "GPUUsage를 항상 다크 모드로 표시합니다."
        }
    }
}

enum SSHAuthenticationMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case keyBased
    case passwordBased

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyBased:
            return "Key-based"
        case .passwordBased:
            return "Password-based"
        }
    }

    var detailText: String {
        switch self {
        case .keyBased:
            return "SSH key와 ssh-agent를 사용합니다. background polling 중 Keychain을 읽지 않습니다."
        case .passwordBased:
            return "macOS Keychain에 저장된 SSH 비밀번호를 사용합니다."
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    static let legacyDefaultRemoteCommand = "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    static let defaultRemoteCommand = "nvidia-smi --query-gpu=index,name,uuid,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"

    var sshTarget: String = ""
    var sshPort: String = ""
    var sshIdentityFilePath: String = ""
    var sshAuthenticationMode: SSHAuthenticationMode = .keyBased
    var pollIntervalSeconds: Int = 10
    var remoteCommand: String = Self.defaultRemoteCommand
    var menuBarDisplayMode: MenuBarDisplayMode = .averageAndBusy
    var appearanceMode: AppAppearanceMode = .system
    var showsDockIcon: Bool = false

    init(
        sshTarget: String = "",
        sshPort: String = "",
        sshIdentityFilePath: String = "",
        sshAuthenticationMode: SSHAuthenticationMode = .keyBased,
        pollIntervalSeconds: Int = 10,
        remoteCommand: String = Self.defaultRemoteCommand,
        menuBarDisplayMode: MenuBarDisplayMode = .averageAndBusy,
        appearanceMode: AppAppearanceMode = .system,
        showsDockIcon: Bool = false
    ) {
        self.sshTarget = sshTarget
        self.sshPort = sshPort
        self.sshIdentityFilePath = sshIdentityFilePath
        self.sshAuthenticationMode = sshAuthenticationMode
        self.pollIntervalSeconds = pollIntervalSeconds
        self.remoteCommand = remoteCommand
        self.menuBarDisplayMode = menuBarDisplayMode
        self.appearanceMode = appearanceMode
        self.showsDockIcon = showsDockIcon
    }

    private enum CodingKeys: String, CodingKey {
        case sshTarget
        case sshPort
        case sshIdentityFilePath
        case sshAuthenticationMode
        case pollIntervalSeconds
        case remoteCommand
        case menuBarDisplayMode
        case appearanceMode
        case showsDockIcon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sshTarget: try container.decodeIfPresent(String.self, forKey: .sshTarget) ?? "",
            sshPort: try container.decodeIfPresent(String.self, forKey: .sshPort) ?? "",
            sshIdentityFilePath: try container.decodeIfPresent(String.self, forKey: .sshIdentityFilePath) ?? "",
            sshAuthenticationMode: try container.decodeIfPresent(SSHAuthenticationMode.self, forKey: .sshAuthenticationMode) ?? .keyBased,
            pollIntervalSeconds: try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 10,
            remoteCommand: try container.decodeIfPresent(String.self, forKey: .remoteCommand) ?? Self.defaultRemoteCommand,
            menuBarDisplayMode: try container.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .averageAndBusy,
            appearanceMode: try container.decodeIfPresent(AppAppearanceMode.self, forKey: .appearanceMode) ?? .system,
            showsDockIcon: try container.decodeIfPresent(Bool.self, forKey: .showsDockIcon) ?? false
        )
    }

    var isConfigured: Bool {
        !sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func normalized() -> Self {
        var copy = self
        copy.sshTarget = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sshPort = sshPort.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sshIdentityFilePath = NSString(string: sshIdentityFilePath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        copy.pollIntervalSeconds = min(max(pollIntervalSeconds, 3), 300)

        let trimmedCommand = remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCommand.isEmpty || trimmedCommand == Self.legacyDefaultRemoteCommand {
            copy.remoteCommand = Self.defaultRemoteCommand
        } else {
            copy.remoteCommand = trimmedCommand
        }

        return copy
    }

    var resolvedPort: Int? {
        guard let port = Int(sshPort), (1...65535).contains(port) else {
            return nil
        }

        return port
    }

    var connectionFingerprint: String {
        [
            sshTarget,
            sshPort,
            sshIdentityFilePath,
            sshAuthenticationMode.rawValue,
        ].joined(separator: "|")
    }
}

struct GPUReading: Identifiable, Equatable, Sendable {
    let index: Int
    let name: String
    let uuid: String?
    let utilization: Int
    let memoryUsedMB: Int
    let memoryTotalMB: Int
    let temperatureCelsius: Int?
    let processes: [GPUProcessReading]

    var id: Int { index }

    var utilizationRatio: Double {
        Double(utilization) / 100.0
    }

    var memoryUsagePercent: Int {
        guard memoryTotalMB > 0 else { return 0 }
        return Int((Double(memoryUsedMB) / Double(memoryTotalMB) * 100.0).rounded())
    }

    var memoryUsageRatio: Double {
        Double(memoryUsagePercent) / 100.0
    }

    var memorySummary: String {
        "\(memoryUsedMB) / \(memoryTotalMB) MB"
    }

    var temperatureSummary: String {
        if let temperatureCelsius {
            return "\(temperatureCelsius) C"
        }

        return "--"
    }

    var processSummary: String {
        processes.isEmpty ? "No active processes" : "\(processes.count) active process\(processes.count == 1 ? "" : "es")"
    }
}

struct GPUSnapshot: Equatable, Sendable {
    let takenAt: Date
    let gpus: [GPUReading]

    var averageUtilization: Int {
        guard !gpus.isEmpty else { return 0 }
        return gpus.map(\.utilization).reduce(0, +) / gpus.count
    }

    var busyCount: Int {
        gpus.filter { $0.utilization >= 10 }.count
    }

    var totalProcessCount: Int {
        gpus.reduce(0) { $0 + $1.processes.count }
    }
}

struct GPUProcessReading: Identifiable, Equatable, Sendable {
    let gpuUUID: String
    let pid: Int
    let processName: String
    let usedGPUMemoryMB: Int
    let user: String?
    let commandLine: String?

    var id: String {
        "\(gpuUUID):\(pid):\(processName)"
    }

    var hasResolvedMetadata: Bool {
        user != nil || commandLine != nil
    }

    var memorySummary: String {
        "\(usedGPUMemoryMB) MB"
    }

    var userSummary: String {
        user ?? "--"
    }

    var commandSummary: String {
        guard let commandLine, !commandLine.isEmpty else {
            return processName
        }

        return commandLine
    }

    var displayProcessName: String {
        if !processName.isEmpty {
            return processName
        }

        return commandSummary
    }

    var showsSeparateCommandSummary: Bool {
        let normalizedProcessName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCommand = commandSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedCommand.isEmpty && normalizedProcessName != normalizedCommand
    }
}

struct RemoteProcessStatus: Equatable, Sendable {
    let pid: Int
    let user: String
    let commandLine: String?
}

struct ProcessExitWatch: Codable, Identifiable, Equatable, Sendable {
    let connectionFingerprint: String
    let connectionLabel: String
    let gpuUUID: String
    let gpuIndex: Int
    let gpuName: String
    let pid: Int
    let processName: String
    let usedGPUMemoryMB: Int
    let user: String?
    let commandLine: String?
    let createdAt: Date

    init(settings: AppSettings, gpu: GPUReading, process: GPUProcessReading, createdAt: Date = Date()) {
        self.connectionFingerprint = settings.connectionFingerprint
        self.connectionLabel = settings.sshTarget
        self.gpuUUID = process.gpuUUID
        self.gpuIndex = gpu.index
        self.gpuName = gpu.name
        self.pid = process.pid
        self.processName = process.processName
        self.usedGPUMemoryMB = process.usedGPUMemoryMB
        self.user = process.user
        self.commandLine = process.commandLine
        self.createdAt = createdAt
    }

    var id: String {
        "\(connectionFingerprint):\(gpuUUID):\(pid):\(processName)"
    }

    var displayProcessName: String {
        let trimmedName = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }

        let trimmedCommand = commandLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCommand.isEmpty {
            return trimmedCommand
        }

        return "PID \(pid)"
    }

    var subtitle: String {
        var parts = [connectionLabel, "GPU \(gpuIndex)", "PID \(pid)"]
        if let user, !user.isEmpty {
            parts.append(user)
        }
        return parts.joined(separator: " · ")
    }

    func matches(_ process: GPUProcessReading) -> Bool {
        process.gpuUUID == gpuUUID && process.pid == pid && process.processName == processName
    }

    func matches(_ status: RemoteProcessStatus) -> Bool {
        guard status.pid == pid else { return false }

        if let user, !user.isEmpty, user != status.user {
            return false
        }

        let normalizedCommand = normalized(commandLine)
        if !normalizedCommand.isEmpty {
            return normalizedCommand == normalized(status.commandLine)
        }

        return true
    }

    private func normalized(_ string: String?) -> String {
        string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum ProcessExitWatchEvaluator {
    static func exitedWatches(
        watches: [ProcessExitWatch],
        visibleProcesses: [GPUProcessReading],
        remoteStatuses: [RemoteProcessStatus]
    ) -> [ProcessExitWatch] {
        let visibleWatchIDs = Set(
            watches.compactMap { watch in
                visibleProcesses.contains(where: watch.matches(_:)) ? watch.id : nil
            }
        )
        let statusesByPID = Dictionary(uniqueKeysWithValues: remoteStatuses.map { ($0.pid, $0) })

        return watches.filter { watch in
            guard !visibleWatchIDs.contains(watch.id) else {
                return false
            }

            guard let remoteStatus = statusesByPID[watch.pid] else {
                return true
            }

            return !watch.matches(remoteStatus)
        }
    }
}
