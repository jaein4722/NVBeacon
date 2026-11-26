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
            return language.text("Average + Busy", "평균 + 사용 중", "平均使用率 + 使用中数量")
        case .averageOnly:
            return language.text("Average Util", "평균 사용률", "平均使用率")
        case .busyOnly:
            return language.text("Busy Count", "사용 중 개수", "使用中数量")
        case .iconOnly:
            return language.text("Icon Only", "아이콘만", "仅图标")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .averageAndBusy:
            return language.text(
                "Show both average GPU utilization and busy GPU count.",
                "평균 GPU 사용률과 사용 중인 GPU 수를 함께 표시합니다.",
                "同时显示 GPU 平均使用率和使用中的 GPU 数量。"
            )
        case .averageOnly:
            return language.text(
                "Show only average GPU utilization in the menu bar.",
                "평균 GPU 사용률만 메뉴바에 표시합니다.",
                "菜单栏仅显示 GPU 平均使用率。"
            )
        case .busyOnly:
            return language.text(
                "Show only the busy GPU count in the menu bar.",
                "사용 중인 GPU 개수만 메뉴바에 표시합니다.",
                "菜单栏仅显示使用中的 GPU 数量。"
            )
        case .iconOnly:
            return language.text(
                "Show only the icon without text. Issues are indicated by the icon color and symbol.",
                "텍스트 없이 아이콘만 표시합니다. 상태 이상은 아이콘 색/심볼로 구분합니다.",
                "菜单栏仅显示图标。颜色和图标样式会提示异常状态。"
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

/// Where the monitor appears. The choice is saved, so window mode survives relaunches.
enum MonitorDisplayMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case popover
    case window

    var id: String { rawValue }

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .popover:
            return language.text("Popover", "팝오버", "弹出面板")
        case .window:
            return language.text("Window", "창", "窗口")
        }
    }
}

/// How tall the popover is: fit the content (default) or a fixed height that scrolls.
enum PopoverHeightMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case automatic
    case fixed

    var id: String { rawValue }

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .automatic:
            return language.text("Fit Content", "내용에 맞춤", "随内容调整")
        case .fixed:
            return language.text("Fixed", "고정", "固定")
        }
    }
}

/// Result of Settings → Test Connection.
enum ConnectionTestOutcome: Equatable, Sendable {
    case success(gpuCount: Int)
    case failure(message: String)
}

enum AppAppearanceMode: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .system:
            return language.text("System", "시스템", "跟随系统")
        case .light:
            return language.text("Light", "라이트", "浅色")
        case .dark:
            return language.text("Dark", "다크", "深色")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .system:
            return language.text(
                "Follow the macOS system appearance.",
                "macOS 시스템 설정을 그대로 따릅니다.",
                "跟随 macOS 的外观设置。"
            )
        case .light:
            return language.text(
                "Always show NVBeacon in light mode.",
                "NVBeacon을 항상 라이트 모드로 표시합니다.",
                "始终以浅色模式显示 NVBeacon。"
            )
        case .dark:
            return language.text(
                "Always show NVBeacon in dark mode.",
                "NVBeacon을 항상 다크 모드로 표시합니다.",
                "始终以深色模式显示 NVBeacon。"
            )
        }
    }
}

extension SSHAuthenticationMode {
    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .keyBased:
            return language.text("Key-based", "키 기반", "SSH 密钥")
        case .passwordBased:
            return language.text("Password-based", "비밀번호", "SSH 密码")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .keyBased:
            return language.text(
                "Use SSH keys and ssh-agent. The app does not read Keychain during background polling.",
                "SSH 키와 ssh-agent를 사용합니다. 백그라운드 수집 중에는 키체인을 읽지 않습니다.",
                "使用 SSH 密钥和 ssh-agent。后台轮询时，应用不会读取钥匙串。"
            )
        case .passwordBased:
            return language.text(
                "Use the SSH password stored in the macOS Keychain.",
                "macOS 키체인에 저장된 SSH 비밀번호를 사용합니다.",
                "使用 macOS 钥匙串中保存的 SSH 密码。"
            )
        }
    }
}

extension SSHConnectionReuseMode {
    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .reuseWhenPossible:
            return language.text("Reuse connection (Recommended)", "연결 재사용 (권장)", "复用连接（推荐）")
        case .newConnectionEachRefresh:
            return language.text("New connection every refresh", "매 새로고침마다 새 연결", "每次刷新时新建连接")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .reuseWhenPossible:
            return language.text(
                "Keep one SSH connection open briefly and reuse it for repeated refreshes. This is usually faster and can reduce repeated login overhead.",
                "SSH 연결을 잠시 유지하고 반복 새로고침에 재사용합니다. 보통 더 빠르고 반복 로그인 부담도 줄어듭니다.",
                "短暂保留 SSH 连接，供后续刷新复用。这通常更快，也可减少重复登录的开销。"
            )
        case .newConnectionEachRefresh:
            return language.text(
                "Open a brand-new SSH connection for every refresh. This is slower, but useful for unusual SSH servers.",
                "새로고침마다 완전히 새 SSH 연결을 엽니다. 더 느리지만 특이한 SSH 서버와는 더 잘 맞을 수 있습니다.",
                "每次刷新时都新建 SSH 连接。这样速度较慢，但适用于部分特殊的 SSH 服务器。"
            )
        }
    }

    func helpText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .reuseWhenPossible:
            return language.text(
                "NVBeacon can reuse the SSH connection for a short time instead of logging in again for every poll. No extra software is required on the server. If your server behaves strangely, switch to the fresh-connection mode.",
                "NVBeacon은 수집할 때마다 다시 로그인하지 않고 SSH 연결을 잠시 재사용할 수 있습니다. 서버에 별도 설치가 필요한 기능은 아닙니다. 서버 동작이 이상하면 새 연결 모드로 바꾸세요.",
                "NVBeacon 可以短暂复用 SSH 连接，减少每次轮询的登录开销。服务器无需另外安装软件。若连接异常，可改为每次刷新时新建连接。"
            )
        case .newConnectionEachRefresh:
            return language.text(
                "This disables SSH connection reuse and starts a fresh session on every poll.",
                "SSH 연결 재사용을 끄고 수집할 때마다 새 세션을 시작합니다.",
                "关闭 SSH 连接复用，每次轮询时新建会话。"
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
            return language.text("Not required", "불필요", "无需密码")
        case .missing:
            return language.text("Not saved", "저장 안 됨", "未保存")
        case .locked:
            return language.text("Locked", "잠김", "已锁定")
        case .unlocked:
            return language.text("Unlocked", "해제됨", "已解锁")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .notRequired:
            return language.text(
                "Key-based authentication is active, so no SSH password is needed.",
                "키 기반 인증을 사용 중이라 SSH 비밀번호가 필요하지 않습니다.",
                "当前使用 SSH 密钥认证，无需 SSH 密码。"
            )
        case .missing:
            return language.text(
                "Save an SSH password first. Background polling will stay paused until a password is saved and unlocked.",
                "먼저 SSH 비밀번호를 저장해야 합니다. 저장 후 세션에서 한 번 해제하기 전까지 백그라운드 수집은 멈춘 상태를 유지합니다.",
                "请先保存 SSH 密码。保存并解锁密码后，后台轮询才会开始。"
            )
        case .locked:
            return language.text(
                "A password is saved in Keychain, but this app session has not unlocked it yet. Unlock once to avoid repeated Keychain prompts during polling.",
                "키체인에 저장된 비밀번호는 있지만 현재 앱 세션에서 아직 해제하지 않았습니다. 수집할 때 반복해서 묻지 않도록 한 번만 해제하세요.",
                "当前会话尚未解锁钥匙串中保存的密码。解锁一次即可避免轮询时反复弹出钥匙串提示。"
            )
        case .unlocked:
            return language.text(
                "The saved SSH password is cached in memory for this app session. Background polling will not read Keychain again until the app restarts.",
                "저장된 SSH 비밀번호가 현재 앱 세션 메모리에 캐시되어 있습니다. 앱을 다시 시작하기 전까지 백그라운드 수집은 키체인을 다시 읽지 않습니다.",
                "已将 SSH 密码缓存在当前会话的内存中。应用重启前，后台轮询无需再次读取钥匙串。"
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

extension BusyDetectionMode {
    func title(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .activeProcess:
            return language.text("Active Process", "활성 프로세스", "有运行中的进程")
        case .memoryThreshold:
            return language.text("Memory Threshold", "메모리 기준", "显存阈值")
        case .activeProcessOrMemoryThreshold:
            return language.text("Process or Memory", "프로세스 또는 메모리", "进程或显存阈值")
        case .utilizationThreshold:
            return language.text("Utilization Threshold", "사용률 기준", "使用率阈值")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .activeProcess:
            return language.text(
                "Count a GPU as busy when `nvidia-smi` reports at least one active compute process.",
                "`nvidia-smi`에 실행 중인 연산 프로세스가 하나 이상 보이면 사용 중으로 판단합니다.",
                "当 nvidia-smi 报告至少一个运行中的计算进程时，将 GPU 判为使用中。"
            )
        case .memoryThreshold:
            return language.text(
                "Count a GPU as busy when used memory is above the configured threshold.",
                "사용 중인 메모리가 지정 기준을 넘으면 사용 중으로 판단합니다.",
                "已用显存超过设定阈值时，将 GPU 判为使用中。"
            )
        case .activeProcessOrMemoryThreshold:
            return language.text(
                "Count a GPU as busy when either an active process exists or used memory is above the threshold.",
                "실행 중인 프로세스가 있거나 사용 메모리가 기준을 넘으면 사용 중으로 판단합니다.",
                "有运行中的进程或已用显存超过阈值时，将 GPU 判为使用中。"
            )
        case .utilizationThreshold:
            return language.text(
                "Legacy behavior: count a GPU as busy when utilization is above the configured threshold.",
                "기존 방식입니다. 사용률이 지정 기준을 넘으면 사용 중으로 판단합니다.",
                "沿用旧版规则，GPU 使用率超过设定阈值即判为使用中。"
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
            return language.text("Unavailable", "사용 불가", "不可用")
        case .notDetermined:
            return language.text("Not enabled", "비활성화", "未启用")
        case .denied:
            return language.text("Denied", "거부됨", "已拒绝")
        case .authorized:
            return language.text("Enabled", "활성화", "已启用")
        }
    }

    func detailText(in language: AppInterfaceLanguage) -> String {
        switch self {
        case .unsupported:
            return language.text(
                "macOS notifications are unavailable when running with `swift run`.",
                "개발용 `swift run` 실행에서는 macOS 알림을 사용할 수 없습니다.",
                "通过 swift run 启动时，macOS 通知不可用。"
            )
        case .notDetermined:
            return language.text(
                "Allow macOS notification permission to use process exit alerts.",
                "프로세스 종료 알림을 쓰려면 macOS 알림 권한을 허용해야 합니다.",
                "允许 macOS 通知权限，即可接收进程退出通知。"
            )
        case .denied:
            return language.text(
                "NVBeacon notifications are denied in macOS. Enable them in System Settings.",
                "macOS에서 NVBeacon 알림 권한이 거부된 상태입니다. 시스템 설정에서 허용해야 합니다.",
                "NVBeacon 的通知权限已被 macOS 拒绝。请前往「系统设置」允许通知。"
            )
        case .authorized:
            return language.text(
                "Notifications are ready for process exit and GPU idle alerts.",
                "프로세스 종료 알림과 GPU 유휴 알림을 보낼 준비가 되어 있습니다.",
                "可以接收进程退出通知和 GPU 空闲通知。"
            )
        }
    }
}

struct ServerConfig: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var sshTarget: String
    var sshPort: String
    var sshIdentityFilePath: String
    var sshAuthenticationMode: SSHAuthenticationMode
    var sshConnectionReuseMode: SSHConnectionReuseMode
    var remoteCommand: String
    // Legacy setting/backup compatibility. The UI and collector use hostCommand.
    var memoryCommand: String {
        didSet {
            if hostCommand == RemoteMetricCommands.hostInfo(memoryCommand: oldValue) {
                hostCommand = RemoteMetricCommands.hostInfo(memoryCommand: memoryCommand)
            }
        }
    }
    var hostCommand: String
    var isEnabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String = "",
        sshTarget: String = "",
        sshPort: String = "",
        sshIdentityFilePath: String = "",
        sshAuthenticationMode: SSHAuthenticationMode = .keyBased,
        sshConnectionReuseMode: SSHConnectionReuseMode = .reuseWhenPossible,
        remoteCommand: String = AppSettings.defaultRemoteCommand,
        memoryCommand: String = AppSettings.defaultMemoryCommand,
        hostCommand: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.sshTarget = sshTarget
        self.sshPort = sshPort
        self.sshIdentityFilePath = sshIdentityFilePath
        self.sshAuthenticationMode = sshAuthenticationMode
        self.sshConnectionReuseMode = sshConnectionReuseMode
        self.remoteCommand = remoteCommand
        self.memoryCommand = memoryCommand
        self.hostCommand = RemoteMetricCommands.resolveHostCommand(hostCommand, legacyMemoryCommand: memoryCommand)
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sshTarget, sshPort, sshIdentityFilePath
        case sshAuthenticationMode, sshConnectionReuseMode, remoteCommand, memoryCommand, hostCommand, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            sshTarget: try container.decode(String.self, forKey: .sshTarget),
            sshPort: try container.decode(String.self, forKey: .sshPort),
            sshIdentityFilePath: try container.decode(String.self, forKey: .sshIdentityFilePath),
            sshAuthenticationMode: try container.decode(SSHAuthenticationMode.self, forKey: .sshAuthenticationMode),
            sshConnectionReuseMode: try container.decode(SSHConnectionReuseMode.self, forKey: .sshConnectionReuseMode),
            remoteCommand: try container.decode(String.self, forKey: .remoteCommand),
            memoryCommand: try container.decodeIfPresent(String.self, forKey: .memoryCommand) ?? AppSettings.defaultMemoryCommand,
            hostCommand: try container.decodeIfPresent(String.self, forKey: .hostCommand),
            isEnabled: try container.decode(Bool.self, forKey: .isEnabled)
        )
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }

        return sshTarget.isEmpty ? "Server" : sshTarget
    }

    var isConfigured: Bool {
        !sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isPollable: Bool {
        isEnabled && isConfigured
    }

    var resolvedPort: Int? {
        guard let port = Int(sshPort), (1...65535).contains(port) else {
            return nil
        }

        return port
    }

    var keychainAccount: String {
        "server.\(id)"
    }

    var allowsLegacyPasswordFallback: Bool {
        // Only the migrated single-server record owns the old shared account.
        id == "legacy-primary"
    }

    func normalized() -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sshTarget = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sshPort = sshPort.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sshIdentityFilePath = NSString(string: sshIdentityFilePath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath

        let trimmedCommand = remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCommand.isEmpty || trimmedCommand == AppSettings.legacyDefaultRemoteCommand {
            copy.remoteCommand = AppSettings.defaultRemoteCommand
        } else {
            copy.remoteCommand = trimmedCommand
        }

        let trimmedMemoryCommand = memoryCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.memoryCommand = trimmedMemoryCommand.isEmpty ? AppSettings.defaultMemoryCommand : trimmedMemoryCommand
        copy.hostCommand = RemoteMetricCommands.resolveHostCommand(copy.hostCommand)

        return copy
    }

    /// True when both describe the same connection and commands, ignoring name,
    /// order and the enabled switch.
    func hasSameConnection(as other: ServerConfig) -> Bool {
        sshTarget == other.sshTarget
            && sshPort == other.sshPort
            && sshIdentityFilePath == other.sshIdentityFilePath
            && sshAuthenticationMode == other.sshAuthenticationMode
            && sshConnectionReuseMode == other.sshConnectionReuseMode
            && remoteCommand == other.remoteCommand
            && hostCommand == other.hostCommand
    }

    func connectionSettings(from settings: AppSettings) -> AppSettings {
        var copy = settings
        copy.sshTarget = sshTarget
        copy.sshPort = sshPort
        copy.sshIdentityFilePath = sshIdentityFilePath
        copy.sshAuthenticationMode = sshAuthenticationMode
        copy.sshConnectionReuseMode = sshConnectionReuseMode
        copy.remoteCommand = remoteCommand
        copy.memoryCommand = memoryCommand
        copy.hostCommand = hostCommand
        copy.servers = [self]
        return copy
    }

    func detectedSSHUsername(
        using sshConfigHosts: [SSHConfigHost] = SSHConfigLoader.loadHosts(),
        fallbackLocalUsername: String? = NSUserName()
    ) -> String? {
        if let explicitUsername = Self.normalizedUsername(from: sshTarget.components(separatedBy: "@").first, requiresAtSymbolIn: sshTarget) {
            return explicitUsername
        }

        if let configuredUsername = sshConfigHosts
            .first(where: { $0.alias == sshTarget })?
            .user
            .flatMap({ Self.normalizedUsername(from: $0) }) {
            return configuredUsername
        }

        guard isConfigured else { return nil }
        return Self.normalizedUsername(from: fallbackLocalUsername)
    }

    static func fromLegacySettings(_ settings: AppSettings) -> ServerConfig? {
        guard settings.isLegacyConfigured else { return nil }

        return ServerConfig(
            id: "legacy-primary",
            name: "",
            sshTarget: settings.sshTarget,
            sshPort: settings.sshPort,
            sshIdentityFilePath: settings.sshIdentityFilePath,
            sshAuthenticationMode: settings.sshAuthenticationMode,
            sshConnectionReuseMode: settings.sshConnectionReuseMode,
            remoteCommand: settings.remoteCommand,
            memoryCommand: settings.memoryCommand,
            hostCommand: settings.hostCommand,
            isEnabled: true
        ).normalized()
    }

    private static func normalizedUsername(from value: String?, requiresAtSymbolIn source: String? = nil) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let source, !source.contains("@") {
            return nil
        }

        return trimmed.lowercased()
    }
}

struct ServerRuntimeState: Identifiable, Equatable, Sendable {
    let id: String
    var server: ServerConfig
    var snapshot: GPUSnapshot?
    var networkUsage: NetworkUsage?
    var isRefreshing: Bool
    var lastErrorMessage: String?
    var passwordSessionState: SSHPasswordSessionState
    var detectedSSHUsername: String?
    var detectedSSHUserID: Int?

    init(
        server: ServerConfig,
        snapshot: GPUSnapshot? = nil,
        networkUsage: NetworkUsage? = nil,
        isRefreshing: Bool = false,
        lastErrorMessage: String? = nil,
        passwordSessionState: SSHPasswordSessionState = .notRequired,
        detectedSSHUsername: String? = nil,
        detectedSSHUserID: Int? = nil
    ) {
        self.id = server.id
        self.server = server
        self.snapshot = snapshot
        self.networkUsage = networkUsage
        self.isRefreshing = isRefreshing
        self.lastErrorMessage = lastErrorMessage
        self.passwordSessionState = passwordSessionState
        self.detectedSSHUsername = detectedSSHUsername
        self.detectedSSHUserID = detectedSSHUserID
    }

    /// Applies an edited server configuration. A server that is turned off is no longer
    /// monitored, so its last readings and error leave the menu bar totals and overview.
    mutating func update(to newServer: ServerConfig) {
        if server.isEnabled, !newServer.isEnabled {
            snapshot = nil
            networkUsage = nil
            lastErrorMessage = nil
        }
        server = newServer
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    static let legacyDefaultRemoteCommand = RemoteMetricCommands.legacyGPUCommand
    static let defaultRemoteCommand = RemoteMetricCommands.defaultGPUCommand
    static let defaultMemoryCommand = RemoteMetricCommands.defaultMemoryCommand
    static let defaultHostCommand = RemoteMetricCommands.defaultHostCommand
    static let defaultPopoverWidth = 500
    static let popoverWidthRange = 480...800
    static let defaultPopoverHeight = 600
    static let popoverHeightRange = 320...1100

    var servers: [ServerConfig] = []
    var sshTarget: String = ""
    var sshPort: String = ""
    var sshIdentityFilePath: String = ""
    var sshAuthenticationMode: SSHAuthenticationMode = .keyBased
    var pollIntervalSeconds: Int = 10
    var sshConnectionReuseMode: SSHConnectionReuseMode = .reuseWhenPossible
    var busyDetectionMode: BusyDetectionMode = .activeProcess
    var busyMemoryThresholdMB: Int = 50
    var busyUtilizationThresholdPercent: Int = 10
    var remoteCommand: String = Self.defaultRemoteCommand
    // Preserve old settings without overwriting an edited complete host script.
    var memoryCommand: String = Self.defaultMemoryCommand {
        didSet {
            if hostCommand == RemoteMetricCommands.hostInfo(memoryCommand: oldValue) {
                hostCommand = RemoteMetricCommands.hostInfo(memoryCommand: memoryCommand)
            }
        }
    }
    var hostCommand: String = Self.defaultHostCommand
    var menuBarDisplayMode: MenuBarDisplayMode = .averageAndBusy
    var languagePreference: AppLanguagePreference = .system
    var appearanceMode: AppAppearanceMode = .system
    var showsDockIcon: Bool = false
    var closesPopoverOnOutsideClick: Bool = true
    var popoverWidth: Int = Self.defaultPopoverWidth
    var popoverHeightMode: PopoverHeightMode = .automatic
    var popoverHeight: Int = Self.defaultPopoverHeight
    var displayMode: MonitorDisplayMode = .popover
    var keepsWindowOnTop: Bool = false
    var highlightsMyProcesses: Bool = true
    var recordsGPUHistory: Bool = false
    var collectsHostInfo: Bool = true
    var collectsHostCPU: Bool = true
    var collectsHostMemory: Bool = true
    var showsNetworkUsage: Bool = true
    var idleNotificationSeconds: Int = 300
    var idleMemoryThresholdMB: Int = 50

    init(
        servers: [ServerConfig] = [],
        sshTarget: String = "",
        sshPort: String = "",
        sshIdentityFilePath: String = "",
        sshAuthenticationMode: SSHAuthenticationMode = .keyBased,
        pollIntervalSeconds: Int = 10,
        sshConnectionReuseMode: SSHConnectionReuseMode = .reuseWhenPossible,
        busyDetectionMode: BusyDetectionMode = .activeProcess,
        busyMemoryThresholdMB: Int = 50,
        busyUtilizationThresholdPercent: Int = 10,
        remoteCommand: String = Self.defaultRemoteCommand,
        memoryCommand: String = Self.defaultMemoryCommand,
        hostCommand: String? = nil,
        menuBarDisplayMode: MenuBarDisplayMode = .averageAndBusy,
        languagePreference: AppLanguagePreference = .system,
        appearanceMode: AppAppearanceMode = .system,
        showsDockIcon: Bool = false,
        closesPopoverOnOutsideClick: Bool = true,
        popoverWidth: Int = Self.defaultPopoverWidth,
        popoverHeightMode: PopoverHeightMode = .automatic,
        popoverHeight: Int = Self.defaultPopoverHeight,
        displayMode: MonitorDisplayMode = .popover,
        keepsWindowOnTop: Bool = false,
        highlightsMyProcesses: Bool = true,
        recordsGPUHistory: Bool = false,
        collectsHostInfo: Bool = true,
        collectsHostCPU: Bool = true,
        collectsHostMemory: Bool = true,
        showsNetworkUsage: Bool = true,
        idleNotificationSeconds: Int = 300,
        idleMemoryThresholdMB: Int = 50
    ) {
        self.servers = servers
        self.sshTarget = sshTarget
        self.sshPort = sshPort
        self.sshIdentityFilePath = sshIdentityFilePath
        self.sshAuthenticationMode = sshAuthenticationMode
        self.pollIntervalSeconds = pollIntervalSeconds
        self.sshConnectionReuseMode = sshConnectionReuseMode
        self.busyDetectionMode = busyDetectionMode
        self.busyMemoryThresholdMB = busyMemoryThresholdMB
        self.busyUtilizationThresholdPercent = busyUtilizationThresholdPercent
        self.remoteCommand = remoteCommand
        self.memoryCommand = memoryCommand
        self.hostCommand = RemoteMetricCommands.resolveHostCommand(hostCommand, legacyMemoryCommand: memoryCommand)
        self.menuBarDisplayMode = menuBarDisplayMode
        self.languagePreference = languagePreference
        self.appearanceMode = appearanceMode
        self.showsDockIcon = showsDockIcon
        self.closesPopoverOnOutsideClick = closesPopoverOnOutsideClick
        self.popoverWidth = popoverWidth
        self.popoverHeightMode = popoverHeightMode
        self.popoverHeight = popoverHeight
        self.displayMode = displayMode
        self.keepsWindowOnTop = keepsWindowOnTop
        self.highlightsMyProcesses = highlightsMyProcesses
        self.recordsGPUHistory = recordsGPUHistory
        self.collectsHostInfo = collectsHostInfo
        self.collectsHostCPU = collectsHostCPU
        self.collectsHostMemory = collectsHostMemory
        self.showsNetworkUsage = showsNetworkUsage
        self.idleNotificationSeconds = idleNotificationSeconds
        self.idleMemoryThresholdMB = idleMemoryThresholdMB
    }

    private enum CodingKeys: String, CodingKey {
        case servers
        case sshTarget
        case sshPort
        case sshIdentityFilePath
        case sshAuthenticationMode
        case pollIntervalSeconds
        case sshConnectionReuseMode
        case busyDetectionMode
        case busyMemoryThresholdMB
        case busyUtilizationThresholdPercent
        case remoteCommand
        case memoryCommand
        case hostCommand
        case menuBarDisplayMode
        case languagePreference
        case appearanceMode
        case showsDockIcon
        case closesPopoverOnOutsideClick
        case popoverWidth
        case popoverHeightMode
        case popoverHeight
        case displayMode
        case keepsWindowOnTop
        case highlightsMyProcesses
        case recordsGPUHistory
        case collectsHostInfo
        case collectsHostCPU
        case collectsHostMemory
        case showsNetworkUsage
        case idleNotificationSeconds
        case idleMemoryThresholdMB
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            servers: try container.decodeIfPresent([ServerConfig].self, forKey: .servers) ?? [],
            sshTarget: try container.decodeIfPresent(String.self, forKey: .sshTarget) ?? "",
            sshPort: try container.decodeIfPresent(String.self, forKey: .sshPort) ?? "",
            sshIdentityFilePath: try container.decodeIfPresent(String.self, forKey: .sshIdentityFilePath) ?? "",
            sshAuthenticationMode: try container.decodeIfPresent(SSHAuthenticationMode.self, forKey: .sshAuthenticationMode) ?? .keyBased,
            pollIntervalSeconds: try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 10,
            sshConnectionReuseMode: try container.decodeIfPresent(SSHConnectionReuseMode.self, forKey: .sshConnectionReuseMode) ?? .reuseWhenPossible,
            busyDetectionMode: try container.decodeIfPresent(BusyDetectionMode.self, forKey: .busyDetectionMode) ?? .activeProcess,
            busyMemoryThresholdMB: try container.decodeIfPresent(Int.self, forKey: .busyMemoryThresholdMB) ?? 50,
            busyUtilizationThresholdPercent: try container.decodeIfPresent(Int.self, forKey: .busyUtilizationThresholdPercent) ?? 10,
            remoteCommand: try container.decodeIfPresent(String.self, forKey: .remoteCommand) ?? Self.defaultRemoteCommand,
            memoryCommand: try container.decodeIfPresent(String.self, forKey: .memoryCommand) ?? Self.defaultMemoryCommand,
            hostCommand: try container.decodeIfPresent(String.self, forKey: .hostCommand),
            menuBarDisplayMode: try container.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .averageAndBusy,
            languagePreference: try container.decodeIfPresent(AppLanguagePreference.self, forKey: .languagePreference) ?? .system,
            appearanceMode: try container.decodeIfPresent(AppAppearanceMode.self, forKey: .appearanceMode) ?? .system,
            showsDockIcon: try container.decodeIfPresent(Bool.self, forKey: .showsDockIcon) ?? false,
            closesPopoverOnOutsideClick: try container.decodeIfPresent(Bool.self, forKey: .closesPopoverOnOutsideClick) ?? true,
            popoverWidth: try container.decodeIfPresent(Int.self, forKey: .popoverWidth) ?? Self.defaultPopoverWidth,
            popoverHeightMode: try container.decodeIfPresent(PopoverHeightMode.self, forKey: .popoverHeightMode) ?? .automatic,
            popoverHeight: try container.decodeIfPresent(Int.self, forKey: .popoverHeight) ?? Self.defaultPopoverHeight,
            displayMode: try container.decodeIfPresent(MonitorDisplayMode.self, forKey: .displayMode) ?? .popover,
            keepsWindowOnTop: try container.decodeIfPresent(Bool.self, forKey: .keepsWindowOnTop) ?? false,
            highlightsMyProcesses: try container.decodeIfPresent(Bool.self, forKey: .highlightsMyProcesses) ?? true,
            recordsGPUHistory: try container.decodeIfPresent(Bool.self, forKey: .recordsGPUHistory) ?? false,
            collectsHostInfo: try container.decodeIfPresent(Bool.self, forKey: .collectsHostInfo) ?? true,
            collectsHostCPU: try container.decodeIfPresent(Bool.self, forKey: .collectsHostCPU) ?? true,
            collectsHostMemory: try container.decodeIfPresent(Bool.self, forKey: .collectsHostMemory) ?? true,
            showsNetworkUsage: try container.decodeIfPresent(Bool.self, forKey: .showsNetworkUsage) ?? true,
            idleNotificationSeconds: try container.decodeIfPresent(Int.self, forKey: .idleNotificationSeconds) ?? 300,
            idleMemoryThresholdMB: try container.decodeIfPresent(Int.self, forKey: .idleMemoryThresholdMB) ?? 50
        )
    }

    var hostMetricsOptions: HostMetricsOptions {
        guard collectsHostInfo else { return .none }
        return HostMetricsOptions(cpu: collectsHostCPU, memory: collectsHostMemory, network: showsNetworkUsage)
    }

    var isConfigured: Bool {
        if !servers.isEmpty {
            return servers.contains(where: \.isConfigured)
        }

        return isLegacyConfigured
    }

    var isLegacyConfigured: Bool {
        !sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var configuredServers: [ServerConfig] {
        if !servers.isEmpty {
            return servers.filter(\.isConfigured)
        }

        return ServerConfig.fromLegacySettings(self).map { [$0] } ?? []
    }

    var pollableServers: [ServerConfig] {
        configuredServers.filter(\.isPollable)
    }

    var resolvedPopoverWidth: Int {
        min(max(popoverWidth, Self.popoverWidthRange.lowerBound), Self.popoverWidthRange.upperBound)
    }

    var resolvedPopoverHeight: Int {
        min(max(popoverHeight, Self.popoverHeightRange.lowerBound), Self.popoverHeightRange.upperBound)
    }

    func normalized() -> Self {
        var copy = self
        copy.sshTarget = sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sshPort = sshPort.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.sshIdentityFilePath = NSString(string: sshIdentityFilePath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        copy.pollIntervalSeconds = min(max(pollIntervalSeconds, 1), 300)
        copy.popoverWidth = resolvedPopoverWidth
        copy.popoverHeight = resolvedPopoverHeight
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

        if copy.servers.isEmpty, let legacyServer = ServerConfig.fromLegacySettings(copy) {
            copy.servers = [legacyServer]
        } else {
            copy.servers = copy.servers.map { $0.normalized() }
        }

        if let primaryServer = copy.servers.first(where: \.isConfigured) ?? copy.servers.first {
            copy.sshTarget = primaryServer.sshTarget
            copy.sshPort = primaryServer.sshPort
            copy.sshIdentityFilePath = primaryServer.sshIdentityFilePath
            copy.sshAuthenticationMode = primaryServer.sshAuthenticationMode
            copy.sshConnectionReuseMode = primaryServer.sshConnectionReuseMode
            copy.remoteCommand = primaryServer.remoteCommand
            copy.memoryCommand = primaryServer.memoryCommand
            copy.hostCommand = primaryServer.hostCommand
        } else {
            copy.sshTarget = ""
            copy.sshPort = ""
            copy.sshIdentityFilePath = ""
            copy.remoteCommand = Self.defaultRemoteCommand
            copy.memoryCommand = Self.defaultMemoryCommand
            copy.hostCommand = Self.defaultHostCommand
        }

        return copy
    }

    var resolvedPort: Int? {
        guard let port = Int(sshPort), (1...65535).contains(port) else {
            return nil
        }

        return port
    }

    func detectedSSHUsername(
        using sshConfigHosts: [SSHConfigHost] = SSHConfigLoader.loadHosts(),
        fallbackLocalUsername: String? = NSUserName()
    ) -> String? {
        if let primaryServer = configuredServers.first {
            return primaryServer.detectedSSHUsername(
                using: sshConfigHosts,
                fallbackLocalUsername: fallbackLocalUsername
            )
        }

        if let explicitUsername = Self.normalizedUsername(from: sshTarget.components(separatedBy: "@").first, requiresAtSymbolIn: sshTarget) {
            return explicitUsername
        }

        if let configuredUsername = sshConfigHosts
            .first(where: { $0.alias == sshTarget })?
            .user
            .flatMap({ Self.normalizedUsername(from: $0) }) {
            return configuredUsername
        }

        guard isConfigured else { return nil }
        return Self.normalizedUsername(from: fallbackLocalUsername)
    }

    private static func normalizedUsername(from value: String?, requiresAtSymbolIn source: String? = nil) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let source, !source.contains("@") {
            return nil
        }

        return trimmed.lowercased()
    }
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
        self.init(
            connectionFingerprint: settings.connectionFingerprint,
            connectionLabel: settings.sshTarget,
            gpu: gpu,
            process: process,
            createdAt: createdAt
        )
    }

    init(server: ServerConfig, gpu: GPUReading, process: GPUProcessReading, createdAt: Date = Date()) {
        self.init(
            connectionFingerprint: server.connectionFingerprint,
            connectionLabel: server.displayName,
            gpu: gpu,
            process: process,
            createdAt: createdAt
        )
    }

    private init(
        connectionFingerprint: String,
        connectionLabel: String,
        gpu: GPUReading,
        process: GPUProcessReading,
        createdAt: Date
    ) {
        self.connectionFingerprint = connectionFingerprint
        self.connectionLabel = connectionLabel
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
            language.text("PID \(pid)", "PID \(pid)", "PID \(pid)")
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
        self.init(
            connectionFingerprint: settings.connectionFingerprint,
            connectionLabel: settings.sshTarget,
            gpu: gpu,
            createdAt: createdAt
        )
    }

    init(server: ServerConfig, gpu: GPUReading, createdAt: Date = Date()) {
        self.init(
            connectionFingerprint: server.connectionFingerprint,
            connectionLabel: server.displayName,
            gpu: gpu,
            createdAt: createdAt
        )
    }

    private init(
        connectionFingerprint: String,
        connectionLabel: String,
        gpu: GPUReading,
        createdAt: Date
    ) {
        self.connectionFingerprint = connectionFingerprint
        self.connectionLabel = connectionLabel
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
            return language.text("Permission enabled", "권한 허용", "已允许通知")
        case .permissionDenied:
            return language.text("Permission denied", "권한 거부", "已拒绝通知")
        case .watchAdded:
            return language.text("Process watch enabled", "프로세스 감시 등록", "已开启进程监视")
        case .watchRemoved:
            return language.text("Process watch removed", "프로세스 감시 해제", "已停止进程监视")
        case .idleWatchAdded:
            return language.text("GPU idle watch enabled", "GPU 유휴 감시 등록", "已开启 GPU 空闲监视")
        case .idleWatchRemoved:
            return language.text("GPU idle watch removed", "GPU 유휴 감시 해제", "已停止 GPU 空闲监视")
        case .testNotificationScheduled:
            return language.text("Test notification sent", "테스트 알림 전송", "已发送测试通知")
        case .exitNotificationScheduled:
            return language.text("Process exit notification sent", "프로세스 종료 알림 전송", "已发送进程退出通知")
        case .idleNotificationScheduled:
            return language.text("GPU idle notification sent", "GPU 유휴 알림 전송", "已发送 GPU 空闲通知")
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
