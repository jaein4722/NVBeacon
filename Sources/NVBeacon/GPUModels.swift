import Foundation

enum MenuBarDisplayMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case averageAndBusy
    case averageOnly
    case busyOnly
    case iconOnly

    var id: String { rawValue }

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .averageAndBusy:
            return language.text("Average + Busy", "평균 + 사용중")
        case .averageOnly:
            return language.text("Average Util", "평균 사용률")
        case .busyOnly:
            return language.text("Busy Count", "사용중 개수")
        case .iconOnly:
            return language.text("Icon Only", "아이콘만")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .averageAndBusy:
            return language.text(
                "Show both average GPU utilization and busy GPU count.",
                "평균 GPU 사용률과 busy GPU 수를 함께 표시합니다."
            )
        case .averageOnly:
            return language.text(
                "Show only average GPU utilization in the menu bar.",
                "평균 GPU 사용률만 메뉴바에 표시합니다."
            )
        case .busyOnly:
            return language.text(
                "Show only the busy GPU count in the menu bar.",
                "busy GPU 개수만 메뉴바에 표시합니다."
            )
        case .iconOnly:
            return language.text(
                "Show only the icon without text. Issues are indicated by the icon color and symbol.",
                "텍스트 없이 아이콘만 표시합니다. 상태 이상은 아이콘 색/심볼로 구분합니다."
            )
        }
    }

    func titleText(for snapshot: GPUSnapshot, settings: AppSettings, language: AppInterfaceLanguage) -> String {
        let busyCount = snapshot.busyCount(using: settings)

        switch self {
        case .averageAndBusy:
            return "GPU \(snapshot.averageUtilization)% · \(busyCount)/\(snapshot.gpus.count)"
        case .averageOnly:
            return "GPU \(snapshot.averageUtilization)%"
        case .busyOnly:
            return "GPU \(busyCount)/\(snapshot.gpus.count)"
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

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .system:
            return language.text("System", "시스템")
        case .light:
            return language.text("Light", "라이트")
        case .dark:
            return language.text("Dark", "다크")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .system:
            return language.text(
                "Follow the macOS system appearance.",
                "macOS 시스템 설정을 그대로 따릅니다."
            )
        case .light:
            return language.text(
                "Always show NVBeacon in light mode.",
                "NVBeacon을 항상 라이트 모드로 표시합니다."
            )
        case .dark:
            return language.text(
                "Always show NVBeacon in dark mode.",
                "NVBeacon을 항상 다크 모드로 표시합니다."
            )
        }
    }
}

enum SSHAuthenticationMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case keyBased
    case passwordBased

    var id: String { rawValue }

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .keyBased:
            return language.text("Key-based", "키 기반")
        case .passwordBased:
            return language.text("Password-based", "비밀번호")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .keyBased:
            return language.text(
                "Use SSH keys and ssh-agent. The app does not read Keychain during background polling.",
                "SSH key와 ssh-agent를 사용합니다. background polling 중 Keychain을 읽지 않습니다."
            )
        case .passwordBased:
            return language.text(
                "Use the SSH password stored in the macOS Keychain.",
                "macOS Keychain에 저장된 SSH 비밀번호를 사용합니다."
            )
        }
    }
}

enum SSHPasswordSessionState: Equatable, Sendable {
    case notRequired
    case missing
    case locked
    case unlocked

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .notRequired:
            return language.text("Not required", "불필요")
        case .missing:
            return language.text("Not saved", "저장 안 됨")
        case .locked:
            return language.text("Locked", "잠김")
        case .unlocked:
            return language.text("Unlocked", "해제됨")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .notRequired:
            return language.text(
                "Key-based authentication is active, so no SSH password is needed.",
                "키 기반 인증을 사용 중이라 SSH 비밀번호가 필요하지 않습니다."
            )
        case .missing:
            return language.text(
                "Save an SSH password first. Background polling will stay paused until a password is saved and unlocked.",
                "먼저 SSH 비밀번호를 저장해야 합니다. 저장 후 세션에서 한 번 해제하기 전까지 background polling은 멈춘 상태를 유지합니다."
            )
        case .locked:
            return language.text(
                "A password is saved in Keychain, but this app session has not unlocked it yet. Unlock once to avoid repeated Keychain prompts during polling.",
                "Keychain에 저장된 비밀번호는 있지만 현재 앱 세션에서 아직 해제하지 않았습니다. polling 중 반복 prompt를 막으려면 한 번만 해제하세요."
            )
        case .unlocked:
            return language.text(
                "The saved SSH password is cached in memory for this app session. Background polling will not read Keychain again until the app restarts.",
                "저장된 SSH 비밀번호가 현재 앱 세션 메모리에 캐시되어 있습니다. 앱을 다시 시작하기 전까지 background polling은 Keychain을 다시 읽지 않습니다."
            )
        }
    }

    var supportsUnlockAction: Bool {
        self == .locked
    }

    var supportsForgetAction: Bool {
        self == .locked || self == .unlocked
    }
}

enum BusyDetectionMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case activeProcess
    case memoryThreshold
    case activeProcessOrMemoryThreshold
    case utilizationThreshold

    var id: String { rawValue }

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .activeProcess:
            return language.text("Active Process", "활성 프로세스")
        case .memoryThreshold:
            return language.text("Memory Threshold", "메모리 임계치")
        case .activeProcessOrMemoryThreshold:
            return language.text("Process or Memory", "프로세스 또는 메모리")
        case .utilizationThreshold:
            return language.text("Utilization Threshold", "사용률 임계치")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .activeProcess:
            return language.text(
                "Count a GPU as busy when `nvidia-smi` reports at least one active compute process.",
                "`nvidia-smi`에서 active compute process가 하나 이상 보이면 busy로 판단합니다."
            )
        case .memoryThreshold:
            return language.text(
                "Count a GPU as busy when used memory is above the configured threshold.",
                "사용 중인 메모리가 지정 임계치를 넘으면 busy로 판단합니다."
            )
        case .activeProcessOrMemoryThreshold:
            return language.text(
                "Count a GPU as busy when either an active process exists or used memory is above the threshold.",
                "active process가 있거나 사용 메모리가 임계치를 넘으면 busy로 판단합니다."
            )
        case .utilizationThreshold:
            return language.text(
                "Legacy behavior: count a GPU as busy when utilization is above the configured threshold.",
                "기존 방식입니다. 사용률이 지정 임계치를 넘으면 busy로 판단합니다."
            )
        }
    }
}

enum NotificationPermissionState: Equatable, Sendable {
    case unsupported
    case notDetermined
    case denied
    case authorized

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .unsupported:
            return language.text("Unavailable", "사용 불가")
        case .notDetermined:
            return language.text("Not enabled", "비활성화")
        case .denied:
            return language.text("Denied", "거부됨")
        case .authorized:
            return language.text("Enabled", "활성화")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .unsupported:
            return language.text(
                "macOS notifications are unavailable when running with `swift run`.",
                "개발용 `swift run` 실행에서는 macOS 알림을 사용할 수 없습니다."
            )
        case .notDetermined:
            return language.text(
                "Allow macOS notification permission to use process exit alerts.",
                "프로세스 종료 알림을 쓰려면 macOS 알림 권한을 허용해야 합니다."
            )
        case .denied:
            return language.text(
                "NVBeacon notifications are denied in macOS. Enable them in System Settings.",
                "macOS에서 NVBeacon 알림 권한이 거부된 상태입니다. 시스템 설정에서 허용해야 합니다."
            )
        case .authorized:
            return language.text(
                "Notifications are ready for process exit and GPU idle alerts.",
                "프로세스 종료 알림과 GPU idle 알림을 보낼 준비가 되어 있습니다."
            )
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
    var busyDetectionMode: BusyDetectionMode = .activeProcess
    var busyMemoryThresholdMB: Int = 50
    var busyUtilizationThresholdPercent: Int = 10
    var remoteCommand: String = Self.defaultRemoteCommand
    var menuBarDisplayMode: MenuBarDisplayMode = .averageAndBusy
    var languagePreference: AppLanguagePreference = .system
    var appearanceMode: AppAppearanceMode = .system
    var showsDockIcon: Bool = false
    var closesPopoverOnOutsideClick: Bool = true
    var idleNotificationSeconds: Int = 300
    var idleMemoryThresholdMB: Int = 50

    init(
        sshTarget: String = "",
        sshPort: String = "",
        sshIdentityFilePath: String = "",
        sshAuthenticationMode: SSHAuthenticationMode = .keyBased,
        pollIntervalSeconds: Int = 10,
        busyDetectionMode: BusyDetectionMode = .activeProcess,
        busyMemoryThresholdMB: Int = 50,
        busyUtilizationThresholdPercent: Int = 10,
        remoteCommand: String = Self.defaultRemoteCommand,
        menuBarDisplayMode: MenuBarDisplayMode = .averageAndBusy,
        languagePreference: AppLanguagePreference = .system,
        appearanceMode: AppAppearanceMode = .system,
        showsDockIcon: Bool = false,
        closesPopoverOnOutsideClick: Bool = true,
        idleNotificationSeconds: Int = 300,
        idleMemoryThresholdMB: Int = 50
    ) {
        self.sshTarget = sshTarget
        self.sshPort = sshPort
        self.sshIdentityFilePath = sshIdentityFilePath
        self.sshAuthenticationMode = sshAuthenticationMode
        self.pollIntervalSeconds = pollIntervalSeconds
        self.busyDetectionMode = busyDetectionMode
        self.busyMemoryThresholdMB = busyMemoryThresholdMB
        self.busyUtilizationThresholdPercent = busyUtilizationThresholdPercent
        self.remoteCommand = remoteCommand
        self.menuBarDisplayMode = menuBarDisplayMode
        self.languagePreference = languagePreference
        self.appearanceMode = appearanceMode
        self.showsDockIcon = showsDockIcon
        self.closesPopoverOnOutsideClick = closesPopoverOnOutsideClick
        self.idleNotificationSeconds = idleNotificationSeconds
        self.idleMemoryThresholdMB = idleMemoryThresholdMB
    }

    private enum CodingKeys: String, CodingKey {
        case sshTarget
        case sshPort
        case sshIdentityFilePath
        case sshAuthenticationMode
        case pollIntervalSeconds
        case busyDetectionMode
        case busyMemoryThresholdMB
        case busyUtilizationThresholdPercent
        case remoteCommand
        case menuBarDisplayMode
        case languagePreference
        case appearanceMode
        case showsDockIcon
        case closesPopoverOnOutsideClick
        case idleNotificationSeconds
        case idleMemoryThresholdMB
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sshTarget: try container.decodeIfPresent(String.self, forKey: .sshTarget) ?? "",
            sshPort: try container.decodeIfPresent(String.self, forKey: .sshPort) ?? "",
            sshIdentityFilePath: try container.decodeIfPresent(String.self, forKey: .sshIdentityFilePath) ?? "",
            sshAuthenticationMode: try container.decodeIfPresent(SSHAuthenticationMode.self, forKey: .sshAuthenticationMode) ?? .keyBased,
            pollIntervalSeconds: try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 10,
            busyDetectionMode: try container.decodeIfPresent(BusyDetectionMode.self, forKey: .busyDetectionMode) ?? .activeProcess,
            busyMemoryThresholdMB: try container.decodeIfPresent(Int.self, forKey: .busyMemoryThresholdMB) ?? 50,
            busyUtilizationThresholdPercent: try container.decodeIfPresent(Int.self, forKey: .busyUtilizationThresholdPercent) ?? 10,
            remoteCommand: try container.decodeIfPresent(String.self, forKey: .remoteCommand) ?? Self.defaultRemoteCommand,
            menuBarDisplayMode: try container.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .averageAndBusy,
            languagePreference: try container.decodeIfPresent(AppLanguagePreference.self, forKey: .languagePreference) ?? .system,
            appearanceMode: try container.decodeIfPresent(AppAppearanceMode.self, forKey: .appearanceMode) ?? .system,
            showsDockIcon: try container.decodeIfPresent(Bool.self, forKey: .showsDockIcon) ?? false,
            closesPopoverOnOutsideClick: try container.decodeIfPresent(Bool.self, forKey: .closesPopoverOnOutsideClick) ?? true,
            idleNotificationSeconds: try container.decodeIfPresent(Int.self, forKey: .idleNotificationSeconds) ?? 300,
            idleMemoryThresholdMB: try container.decodeIfPresent(Int.self, forKey: .idleMemoryThresholdMB) ?? 50
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
        copy.pollIntervalSeconds = min(max(pollIntervalSeconds, 1), 300)
        copy.busyMemoryThresholdMB = min(max(busyMemoryThresholdMB, 0), 10_240)
        copy.busyUtilizationThresholdPercent = min(max(busyUtilizationThresholdPercent, 0), 100)
        copy.idleNotificationSeconds = min(max(idleNotificationSeconds, 1), 3_600)
        copy.idleMemoryThresholdMB = min(max(idleMemoryThresholdMB, 0), 10_240)

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

    func isBusy(using settings: AppSettings) -> Bool {
        switch settings.busyDetectionMode {
        case .activeProcess:
            return !processes.isEmpty
        case .memoryThreshold:
            return memoryUsedMB > settings.busyMemoryThresholdMB
        case .activeProcessOrMemoryThreshold:
            return !processes.isEmpty || memoryUsedMB > settings.busyMemoryThresholdMB
        case .utilizationThreshold:
            return utilization >= settings.busyUtilizationThresholdPercent
        }
    }

    func isIdle(memoryThresholdMB: Int) -> Bool {
        utilization == 0 && memoryUsedMB <= memoryThresholdMB
    }
}

struct GPUSnapshot: Equatable, Sendable {
    let takenAt: Date
    let gpus: [GPUReading]

    var averageUtilization: Int {
        guard !gpus.isEmpty else { return 0 }
        return gpus.map(\.utilization).reduce(0, +) / gpus.count
    }

    func busyCount(using settings: AppSettings) -> Int {
        gpus.filter { $0.isBusy(using: settings) }.count
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

    func subtitle(language: AppInterfaceLanguage) -> String {
        var parts = [
            connectionLabel,
            "GPU \(gpuIndex)",
            language.text("PID \(pid)", "PID \(pid)")
        ]
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

struct GPUIdleWatch: Codable, Identifiable, Equatable, Sendable {
    let connectionFingerprint: String
    let connectionLabel: String
    let gpuUUID: String?
    let gpuIndex: Int
    let gpuName: String
    let createdAt: Date

    init(settings: AppSettings, gpu: GPUReading, createdAt: Date = Date()) {
        self.connectionFingerprint = settings.connectionFingerprint
        self.connectionLabel = settings.sshTarget
        self.gpuUUID = gpu.uuid
        self.gpuIndex = gpu.index
        self.gpuName = gpu.name
        self.createdAt = createdAt
    }

    var id: String {
        let identifier = gpuUUID ?? "gpu-\(gpuIndex)"
        return "\(connectionFingerprint):\(identifier)"
    }

    var title: String {
        "GPU \(gpuIndex)"
    }

    var subtitle: String {
        [gpuName, connectionLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    func matches(_ gpu: GPUReading) -> Bool {
        if let gpuUUID, let currentUUID = gpu.uuid {
            return gpuUUID == currentUUID
        }

        return gpu.index == gpuIndex
    }
}

enum NotificationHistoryKind: String, Codable, Equatable, Sendable {
    case permissionEnabled
    case permissionDenied
    case watchAdded
    case watchRemoved
    case idleWatchAdded
    case idleWatchRemoved
    case testNotificationScheduled
    case exitNotificationScheduled
    case idleNotificationScheduled

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .permissionEnabled:
            return language.text("Permission enabled", "권한 허용")
        case .permissionDenied:
            return language.text("Permission denied", "권한 거부")
        case .watchAdded:
            return language.text("Process watch enabled", "프로세스 watch 등록")
        case .watchRemoved:
            return language.text("Process watch removed", "프로세스 watch 해제")
        case .idleWatchAdded:
            return language.text("GPU idle watch enabled", "GPU idle watch 등록")
        case .idleWatchRemoved:
            return language.text("GPU idle watch removed", "GPU idle watch 해제")
        case .testNotificationScheduled:
            return language.text("Test notification sent", "테스트 알림 전송")
        case .exitNotificationScheduled:
            return language.text("Process exit notification sent", "프로세스 종료 알림 전송")
        case .idleNotificationScheduled:
            return language.text("GPU idle notification sent", "GPU idle 알림 전송")
        }
    }
}

struct NotificationHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: NotificationHistoryKind
    let connectionLabel: String?
    let gpuIndex: Int?
    let pid: Int?
    let user: String?
    let processName: String?
    let detail: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: NotificationHistoryKind,
        connectionLabel: String? = nil,
        gpuIndex: Int? = nil,
        pid: Int? = nil,
        user: String? = nil,
        processName: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.connectionLabel = connectionLabel
        self.gpuIndex = gpuIndex
        self.pid = pid
        self.user = user
        self.processName = processName
        self.detail = detail
    }

    init(kind: NotificationHistoryKind, watch: ProcessExitWatch, detail: String? = nil) {
        self.init(
            kind: kind,
            connectionLabel: watch.connectionLabel,
            gpuIndex: watch.gpuIndex,
            pid: watch.pid,
            user: watch.user,
            processName: watch.displayProcessName,
            detail: detail
        )
    }

    init(kind: NotificationHistoryKind, idleWatch: GPUIdleWatch, detail: String? = nil) {
        self.init(
            kind: kind,
            connectionLabel: idleWatch.connectionLabel,
            gpuIndex: idleWatch.gpuIndex,
            processName: idleWatch.title,
            detail: detail ?? idleWatch.gpuName
        )
    }

    func title(in language: AppInterfaceLanguage) -> String {
        kind.title(in: language)
    }

    var subtitle: String {
        var parts = [String]()

        if let processName, !processName.isEmpty {
            parts.append(processName)
        }

        if let user, !user.isEmpty {
            parts.append(user)
        }

        if let pid {
            parts.append("PID \(pid)")
        }

        if let gpuIndex {
            parts.append("GPU \(gpuIndex)")
        }

        if let connectionLabel, !connectionLabel.isEmpty {
            parts.append(connectionLabel)
        }

        if let detail, !detail.isEmpty {
            parts.append(detail)
        }

        return parts.joined(separator: " · ")
    }

    static func recentEntries(from entries: [NotificationHistoryEntry], now: Date = Date(), within hours: Double = 24) -> [NotificationHistoryEntry] {
        let cutoff = now.addingTimeInterval(-(hours * 3600))
        return entries
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp > $1.timestamp }
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
