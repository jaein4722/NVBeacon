import Foundation
import NVBeaconCore

/// One monitored server. Field names match the macOS `ServerConfig` so backups
/// and future sharing line up.
public struct ServerSettings: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var sshTarget: String
    public var sshPort: String
    public var sshIdentityFilePath: String
    public var sshAuthenticationMode: SSHAuthenticationMode
    public var sshConnectionReuseMode: SSHConnectionReuseMode
    public var remoteCommand: String
    public var hostCommand: String
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, name: String = "", sshTarget: String = "", sshPort: String = "",
                sshIdentityFilePath: String = "", sshAuthenticationMode: SSHAuthenticationMode = .keyBased,
                sshConnectionReuseMode: SSHConnectionReuseMode = .reuseWhenPossible,
                remoteCommand: String = RemoteMetricCommands.defaultGPUCommand,
                hostCommand: String = RemoteMetricCommands.defaultHostCommand, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.sshTarget = sshTarget
        self.sshPort = sshPort
        self.sshIdentityFilePath = sshIdentityFilePath
        self.sshAuthenticationMode = sshAuthenticationMode
        self.sshConnectionReuseMode = sshConnectionReuseMode
        self.remoteCommand = remoteCommand
        self.hostCommand = hostCommand
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sshTarget, sshPort, sshIdentityFilePath, sshAuthenticationMode, sshConnectionReuseMode
        case remoteCommand, hostCommand, isEnabled
    }

    /// Missing fields take their defaults, so settings saved by older builds still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerSettings()
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? defaults.id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        sshTarget = try container.decodeIfPresent(String.self, forKey: .sshTarget) ?? ""
        sshPort = try container.decodeIfPresent(String.self, forKey: .sshPort) ?? ""
        sshIdentityFilePath = try container.decodeIfPresent(String.self, forKey: .sshIdentityFilePath) ?? ""
        sshAuthenticationMode = try container.decodeIfPresent(SSHAuthenticationMode.self, forKey: .sshAuthenticationMode) ?? .keyBased
        sshConnectionReuseMode = try container.decodeIfPresent(SSHConnectionReuseMode.self, forKey: .sshConnectionReuseMode) ?? .reuseWhenPossible
        remoteCommand = try container.decodeIfPresent(String.self, forKey: .remoteCommand) ?? defaults.remoteCommand
        hostCommand = try container.decodeIfPresent(String.self, forKey: .hostCommand) ?? defaults.hostCommand
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let target = sshTarget.trimmingCharacters(in: .whitespaces)
        return target.isEmpty ? "New Server" : target
    }

    public var trimmedTarget: String { sshTarget.trimmingCharacters(in: .whitespaces) }

    public var resolvedPort: Int? {
        Int(sshPort.trimmingCharacters(in: .whitespaces)).flatMap { (1...65_535).contains($0) ? $0 : nil }
    }

    /// Enabled with a usable target. (A password server also needs a saved password;
    /// the monitor reports that as `ServerState.passwordMissing`.)
    public var isPollable: Bool {
        isEnabled && SSHTransport.isValidTarget(trimmedTarget)
    }

    public var resolvedRemoteCommand: String {
        let trimmed = remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? RemoteMetricCommands.defaultGPUCommand : remoteCommand
    }

    public var resolvedHostCommand: String {
        let trimmed = hostCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? RemoteMetricCommands.defaultHostCommand : hostCommand
    }
}

public enum LanguagePreference: String, Codable, CaseIterable, Sendable { case system, english, korean }
public enum AppearancePreference: String, Codable, CaseIterable, Sendable { case system, light, dark }
/// How the popover is sized: hug the content (macOS behaviour) or a fixed height.
public enum PopoverHeightMode: String, Codable, CaseIterable, Sendable { case automatic, fixed }
/// Popover opens from the tray icon; window stays open as a normal window.
public enum DisplayMode: String, Codable, CaseIterable, Sendable { case popover, window }
/// What the tray icon shows. Same choices and raw values as the macOS menu bar
/// text (`MenuBarDisplayMode`); the tray draws the number into the icon.
public enum TrayIconStyle: String, Codable, CaseIterable, Sendable { case averageAndBusy, averageOnly, busyOnly, iconOnly }

/// The monitor window's last frame in screen pixels.
public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// The Windows app's saved settings (%APPDATA%\NVBeacon\settings.json). Defaults
/// match the macOS `AppSettings`.
public struct WindowsSettings: Codable, Equatable, Sendable {
    public static let popoverWidthRange = 480...800
    public static let popoverHeightRange = 320...1100
    public static let pollIntervalRange = 1...300

    public var servers: [ServerSettings] = []
    public var pollIntervalSeconds = 10
    public var busyDetectionMode = BusyDetectionMode.activeProcess
    public var busyMemoryThresholdMB = 50
    public var busyUtilizationThresholdPercent = 10
    public var collectsHostInfo = true
    public var collectsHostCPU = true
    public var collectsHostMemory = true
    public var showsNetworkUsage = true
    public var languagePreference = LanguagePreference.system
    public var appearanceMode = AppearancePreference.system
    public var popoverWidth = 500
    public var closesPopoverOnOutsideClick = true
    public var highlightsMyProcesses = true
    /// GPU idle alerts: how long a starred GPU must stay idle, and the memory it may still use.
    /// GPU History: keep 24 hours of per-user GPU utilization on this PC (off by default, as on macOS).
    public var recordsGPUHistory = false
    public var idleNotificationSeconds = 300
    public var idleMemoryThresholdMB = 50
    public var popoverHeightMode = PopoverHeightMode.automatic
    public var popoverHeight = 600
    public var displayMode = DisplayMode.popover
    public var windowAlwaysOnTop = false
    public var trayIconStyle = TrayIconStyle.averageAndBusy
    /// Windows only: tint the tray badge by load (green, amber, red) instead of plain text.
    public var trayIconUsesColor = true
    /// Saved by the app when the window moves; the Settings page never edits it.
    public var windowFrame: WindowFrame?

    public init() {}

    public init(from decoder: Decoder) throws {
        // Every field is optional so older or hand-edited files still load.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WindowsSettings()
        servers = try container.decodeIfPresent([ServerSettings].self, forKey: .servers) ?? defaults.servers
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? defaults.pollIntervalSeconds
        busyDetectionMode = try container.decodeIfPresent(BusyDetectionMode.self, forKey: .busyDetectionMode) ?? defaults.busyDetectionMode
        busyMemoryThresholdMB = try container.decodeIfPresent(Int.self, forKey: .busyMemoryThresholdMB) ?? defaults.busyMemoryThresholdMB
        busyUtilizationThresholdPercent = try container.decodeIfPresent(Int.self, forKey: .busyUtilizationThresholdPercent) ?? defaults.busyUtilizationThresholdPercent
        collectsHostInfo = try container.decodeIfPresent(Bool.self, forKey: .collectsHostInfo) ?? defaults.collectsHostInfo
        collectsHostCPU = try container.decodeIfPresent(Bool.self, forKey: .collectsHostCPU) ?? defaults.collectsHostCPU
        collectsHostMemory = try container.decodeIfPresent(Bool.self, forKey: .collectsHostMemory) ?? defaults.collectsHostMemory
        showsNetworkUsage = try container.decodeIfPresent(Bool.self, forKey: .showsNetworkUsage) ?? defaults.showsNetworkUsage
        languagePreference = try container.decodeIfPresent(LanguagePreference.self, forKey: .languagePreference) ?? defaults.languagePreference
        appearanceMode = try container.decodeIfPresent(AppearancePreference.self, forKey: .appearanceMode) ?? defaults.appearanceMode
        popoverWidth = try container.decodeIfPresent(Int.self, forKey: .popoverWidth) ?? defaults.popoverWidth
        closesPopoverOnOutsideClick = try container.decodeIfPresent(Bool.self, forKey: .closesPopoverOnOutsideClick) ?? defaults.closesPopoverOnOutsideClick
        highlightsMyProcesses = try container.decodeIfPresent(Bool.self, forKey: .highlightsMyProcesses) ?? defaults.highlightsMyProcesses
        recordsGPUHistory = try container.decodeIfPresent(Bool.self, forKey: .recordsGPUHistory) ?? defaults.recordsGPUHistory
        idleNotificationSeconds = try container.decodeIfPresent(Int.self, forKey: .idleNotificationSeconds) ?? defaults.idleNotificationSeconds
        idleMemoryThresholdMB = try container.decodeIfPresent(Int.self, forKey: .idleMemoryThresholdMB) ?? defaults.idleMemoryThresholdMB
        popoverHeightMode = try container.decodeIfPresent(PopoverHeightMode.self, forKey: .popoverHeightMode) ?? defaults.popoverHeightMode
        popoverHeight = try container.decodeIfPresent(Int.self, forKey: .popoverHeight) ?? defaults.popoverHeight
        displayMode = try container.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? defaults.displayMode
        windowAlwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .windowAlwaysOnTop) ?? defaults.windowAlwaysOnTop
        trayIconStyle = try container.decodeIfPresent(TrayIconStyle.self, forKey: .trayIconStyle) ?? defaults.trayIconStyle
        trayIconUsesColor = try container.decodeIfPresent(Bool.self, forKey: .trayIconUsesColor) ?? defaults.trayIconUsesColor
        windowFrame = try container.decodeIfPresent(WindowFrame.self, forKey: .windowFrame)
    }

    /// Clamps numbers into their ranges and drops duplicate server ids.
    public func sanitized() -> WindowsSettings {
        var copy = self
        copy.pollIntervalSeconds = min(max(pollIntervalSeconds, Self.pollIntervalRange.lowerBound), Self.pollIntervalRange.upperBound)
        copy.busyMemoryThresholdMB = min(max(busyMemoryThresholdMB, 0), 10_240)
        copy.busyUtilizationThresholdPercent = min(max(busyUtilizationThresholdPercent, 0), 100)
        copy.popoverWidth = min(max(popoverWidth, Self.popoverWidthRange.lowerBound), Self.popoverWidthRange.upperBound)
        copy.popoverHeight = min(max(popoverHeight, Self.popoverHeightRange.lowerBound), Self.popoverHeightRange.upperBound)
        copy.idleNotificationSeconds = min(max(idleNotificationSeconds, 1), 3_600)
        copy.idleMemoryThresholdMB = min(max(idleMemoryThresholdMB, 0), 10_240)
        var seen = Set<String>()
        copy.servers = servers.filter { seen.insert($0.id).inserted }
        return copy
    }

    public var hostMetricsOptions: HostMetricsOptions {
        HostMetricsOptions(cpu: collectsHostInfo && collectsHostCPU,
                           memory: collectsHostInfo && collectsHostMemory,
                           network: collectsHostInfo && showsNetworkUsage)
    }

    public func isBusy(_ gpu: GPUReading) -> Bool {
        gpu.isBusy(mode: busyDetectionMode, memoryThresholdMB: busyMemoryThresholdMB,
                   utilizationThreshold: busyUtilizationThresholdPercent)
    }

    // MARK: Backups (Core format v2, shared with macOS)

    public func backup() -> ServerSettingsBackup {
        ServerSettingsBackup(servers: servers.filter { !$0.trimmedTarget.isEmpty }.map { server in
            ServerSettingsBackup.Entry(name: server.name, sshTarget: server.sshTarget, sshPort: server.sshPort,
                                       sshIdentityFilePath: server.sshIdentityFilePath,
                                       sshAuthenticationMode: server.sshAuthenticationMode,
                                       sshConnectionReuseMode: server.sshConnectionReuseMode,
                                       remoteCommand: server.remoteCommand,
                                       memoryCommand: RemoteMetricCommands.defaultMemoryCommand,
                                       hostCommand: server.hostCommand)
        })
    }

    /// Imported servers are added disabled, never replacing existing ones (macOS behaviour).
    public mutating func importServers(from backup: ServerSettingsBackup) {
        servers += backup.servers.map { entry in
            ServerSettings(name: entry.name, sshTarget: entry.sshTarget, sshPort: entry.sshPort,
                           sshIdentityFilePath: entry.sshIdentityFilePath,
                           sshAuthenticationMode: entry.sshAuthenticationMode,
                           sshConnectionReuseMode: entry.sshConnectionReuseMode,
                           remoteCommand: entry.remoteCommand, hostCommand: entry.hostCommand, isEnabled: false)
        }
    }
}

/// Loads and saves settings, migrating the prototype's servers.txt once.
public enum SettingsStore {
    public static var folder: URL {
        let appData = ProcessInfo.processInfo.environment["APPDATA"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AppData/Roaming").path
        return URL(fileURLWithPath: appData).appendingPathComponent("NVBeacon")
    }

    public static var fileURL: URL { folder.appendingPathComponent("settings.json") }

    public static func load(from url: URL = fileURL, legacyServerFile: URL = LaunchOptions.serverFile) -> WindowsSettings {
        loadResult(from: url, legacyServerFile: legacyServerFile).settings
    }

    public struct LoadResult: Sendable {
        public var settings: WindowsSettings
        /// The settings file existed but could not be read. The defaults are used, and
        /// the file was copied here first so the next save does not destroy it
        /// (nil when even the copy failed).
        public var unreadable: Bool = false
        public var preservedCopy: URL?
    }

    public static func loadResult(from url: URL = fileURL, legacyServerFile: URL = LaunchOptions.serverFile,
                                  now: Date = Date()) -> LoadResult {
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(WindowsSettings.self, from: data) {
                return LoadResult(settings: settings.sanitized())
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let copy = url.deletingLastPathComponent()
                .appendingPathComponent("settings-unreadable-\(formatter.string(from: now)).json")
            let preserved = (try? FileManager.default.copyItem(at: url, to: copy)) != nil
            return LoadResult(settings: WindowsSettings(), unreadable: true, preservedCopy: preserved ? copy : nil)
        }
        var settings = WindowsSettings()
        if let text = try? String(contentsOf: legacyServerFile, encoding: .utf8) {
            settings.servers = LaunchOptions.targets(fromServerFile: text).map { ServerSettings(sshTarget: $0) }
        }
        return LoadResult(settings: settings)
    }

    public static func save(_ settings: WindowsSettings, to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings.sanitized()).writeReliably(to: url)
    }

    public static func clear(at url: URL = fileURL) {
        try? FileManager.default.removeItem(at: url)
    }
}
