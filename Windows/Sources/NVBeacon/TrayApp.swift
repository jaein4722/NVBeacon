import Foundation
import NVBeaconCore
import NVBeaconWindowsKit
import WinSDK

let trayCallbackMessage = UINT(WM_APP) + 1
let stateChangedMessage = UINT(WM_APP) + 2
/// Test hooks, honoured only with --diag.
let diagnosticsMenuMessage = UINT(WM_APP) + 3
let diagnosticsEndMenuMessage = UINT(WM_APP) + 4
let diagnosticsSettingsMessage = UINT(WM_APP) + 5
/// Alerts found by a poll are waiting to be shown on the UI thread.
let notificationsPendingMessage = UINT(WM_APP) + 6
/// A GPU History minute was saved.
let historyChangedMessage = UINT(WM_APP) + 7
/// Work queued for the UI thread by `UIThread.run`.
let uiJobMessage = UINT(WM_APP) + 8

/// Runs closures on the UI thread (the one that owns the windows and WebView2).
enum UIThread {
    private static let jobs = Locked<[@Sendable () -> Void]>([])

    static func run(_ job: @escaping @Sendable () -> Void) {
        jobs.take { $0.append(job) }
        PostMessageW(HWND(bitPattern: trayWindowBits), uiJobMessage, 0, 0)
    }

    static func drain() {
        let pending = jobs.take { list -> [@Sendable () -> Void] in
            defer { list = [] }
            return list
        }
        for job in pending { job() }
    }
}

/// A value shared between the UI thread and polling tasks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func take<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&stored) } }
}

/// Only touched on the UI thread (the window procedure and the message loop).
nonisolated(unsafe) var trayApp: TrayApp?
/// Posting is thread-safe; the monitor uses this to wake the UI thread.
nonisolated(unsafe) var trayWindowBits: Int = 0

func windowProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if let app = trayApp {
        switch message {
        case trayCallbackMessage:
            let event = UINT(truncatingIfNeeded: lParam & 0xFFFF)
            if event == UINT(WM_LBUTTONUP) { app.toggleFlyout() }
            if event == UINT(WM_RBUTTONUP) { app.showMenu() }
            return 0
        case stateChangedMessage:
            app.stateChanged()
            return 0
        case notificationsPendingMessage:
            app.showPendingNotifications()
            return 0
        case historyChangedMessage:
            app.historyChanged()
            return 0
        case uiJobMessage:
            UIThread.drain()
            return 0
        case UINT(WM_COMMAND):
            app.handleCommand(UInt(wParam & 0xFFFF))
            return 0
        case UINT(WM_SETTINGCHANGE):
            app.systemSettingsChanged()   // e.g. the Windows light/dark switch
            return 0
        case UINT(WM_POWERBROADCAST):
            // PBT_APMRESUMESUSPEND / PBT_APMRESUMEAUTOMATIC: woke from sleep.
            if wParam == 0x7 || wParam == 0x12 { app.systemResumed() }
            return 1
        case UINT(WM_CLOSE):
            // The installer and uninstaller close a running copy this way.
            app.quit()
            return 0
        case UINT(WM_ENDSESSION) where wParam != 0:
            app.quit()   // sign-out, shutdown or Restart Manager: save history, drop the icon
            return 0
        case diagnosticsMenuMessage where Diagnostics.enabled:
            app.showMenu(fromFlyout: true)
            return 0
        case diagnosticsEndMenuMessage where Diagnostics.enabled:
            EndMenu()
            return 0
        case diagnosticsSettingsMessage where Diagnostics.enabled:
            app.openSettings()
            return 0
        case UINT(WM_APP) + 9 where Diagnostics.enabled:
            app.openHistory()   // test hook: the popover's chart button
            return 0
        case UINT(WM_DESTROY):
            PostQuitMessage(0)
            return 0
        case app.taskbarCreatedMessage:
            app.addIcon()  // Explorer restarted and dropped every tray icon.
            return 0
        default:
            break
        }
    }
    return DefWindowProcW(window, message, wParam, lParam)
}

/// Owns the settings, the poller, the tray icon, the flyout and the Settings window.
final class TrayApp {
    private enum Command: UInt {
        case refresh = 1, settings, quit, toggleDisplayMode, toggleOnTop, history
    }

    let window: HWND
    let taskbarCreatedMessage: UINT
    private(set) var settings: WindowsSettings
    /// Command-line or --demo targets replace the saved server list for this session only.
    private let sessionServers: [ServerSettings]?
    private var monitor: ServerMonitor
    private var icon: HICON?
    private(set) var flyout: Flyout?
    private var monitorWindow: MonitorWindow?
    private var settingsWindow: PageWindow?
    private(set) var historyWindow: PageWindow?
    /// What the GPU History window currently shows: server id, GPU index, hours.
    private var historyQuery: (serverID: String, gpu: Int, hours: Int)?
    /// 24 hours of minute samples per server (%LOCALAPPDATA%\NVBeacon\GPUHistory).
    let history = GPUHistoryArchive(directory: GPUHistoryArchive.defaultDirectory)
    private var pendingImport: ServerSettingsBackup?
    /// The Settings page's latest edits that it has not applied yet.
    private var pendingSettingsDraft: WindowsSettings?
    /// Process-exit and GPU-idle watches and their history (%APPDATA%\NVBeacon\watches.json).
    let watches = WatchStore(fileURL: WatchStore.defaultFileURL)
    /// SSH passwords in Windows Credential Manager.
    let passwordStore = SSHPasswordStore()
    /// Kept for the whole run, so a settings edit does not reconnect every server
    /// or forget that a server refused its saved password.
    private let connectionPool: SSHConnectionPool
    private let rejections: PasswordRejections
    /// What polling tasks read when they evaluate alerts.
    private let alertSettings: Locked<WindowsSettings>
    private let pendingNotifications = Locked<[PendingNotification]>([])
    /// The last status line, shown at the bottom of the popover like macOS's notice.
    private(set) var notice: (text: String, at: Date)?

    init(window: HWND, settings: WindowsSettings, sessionTargets: [String]?) {
        self.window = window
        self.settings = settings
        self.alertSettings = Locked(settings)
        self.sessionServers = sessionTargets.map { $0.map { ServerSettings(sshTarget: $0) } }
        self.taskbarCreatedMessage = "TaskbarCreated".withCString(encodedAs: UTF16.self) { RegisterWindowMessageW($0) }
        Theme.preference = settings.appearanceMode
        Theme.languagePreference = settings.languagePreference
        let connectionPool = SSHConnectionPool(), rejections = PasswordRejections()
        self.connectionPool = connectionPool
        self.rejections = rejections
        self.monitor = Self.makeMonitor(servers: sessionServers ?? settings.servers, settings: settings,
                                        connectionPool: connectionPool, rejections: rejections)
        configureAlerts(monitor)
    }

    /// After every successful poll, off the UI thread: evaluates watches (alerts go
    /// to the UI thread to show) and records GPU History when it is on.
    private func configureAlerts(_ monitor: ServerMonitor) {
        let watches = watches, alertSettings = alertSettings, pending = pendingNotifications, history = history
        monitor.afterPoll = { result in
            let settings = alertSettings.value
            if settings.recordsGPUHistory,
               (try? await history.record(result.snapshot, users: result.userUtilization,
                                          serverID: result.server.id, fingerprint: result.server.connectionFingerprint)) == true {
                PostMessageW(HWND(bitPattern: trayWindowBits), historyChangedMessage, 0, 0)
            }
            let notifications = await watches.evaluate(snapshot: result.snapshot, server: result.server, settings: settings,
                                                       korean: Theme.language == "ko", transport: result.transport)
            guard !notifications.isEmpty else { return }
            pending.take { $0 += notifications }
            PostMessageW(HWND(bitPattern: trayWindowBits), notificationsPendingMessage, 0, 0)
        }
    }

    func showPendingNotifications() {
        let notifications = pendingNotifications.take { list -> [PendingNotification] in
            defer { list = [] }
            return list
        }
        guard !notifications.isEmpty else { return }
        for notification in notifications { Notifier.show(notification, trayWindow: window) }
        let korean = Theme.language == "ko"
        setNotice(notifications.count == 1
            ? (korean ? "알림을 보냈습니다: \(notifications[0].title)" : "Sent an alert: \(notifications[0].title)")
            : (korean ? "알림 \(notifications.count)개를 보냈습니다." : "Sent \(notifications.count) alerts."))
        pushSettings()
    }

    private func setNotice(_ text: String) {
        notice = (text, Date())
        stateChanged()
    }

    private static func makeMonitor(servers: [ServerSettings], settings: WindowsSettings,
                                    connectionPool: SSHConnectionPool, rejections: PasswordRejections,
                                    previous: [ServerState] = []) -> ServerMonitor {
        ServerMonitor(servers: servers, interval: .seconds(settings.pollIntervalSeconds),
                      hostMetrics: settings.hostMetricsOptions,
                      highlightsMyProcesses: settings.highlightsMyProcesses,
                      samplesUserUtilization: settings.recordsGPUHistory,
                      sshConfigHosts: SSHConfigHosts.load(),
                      askPassExecutable: Resources.executablePath,
                      connectionPool: connectionPool, rejections: rejections, previous: previous) {
            PostMessageW(HWND(bitPattern: trayWindowBits), stateChangedMessage, 0, 0)
        }
    }

    func attach(_ flyout: Flyout) {
        self.flyout = flyout
        flyout.logicalWidth = Double(settings.popoverWidth)
        flyout.closesOnOutsideClick = settings.closesPopoverOnOutsideClick
        flyout.fixedHeight = settings.popoverHeightMode == .fixed ? Double(settings.popoverHeight) : nil
        flyout.currentState = { [unowned self] in FlyoutState(states: monitor.snapshot, settings: settings, watches: watches, notice: notice).json() }
        flyout.onMessage = { [unowned self] in handlePageMessage($0) }
    }

    func attach(_ monitorWindow: MonitorWindow) {
        self.monitorWindow = monitorWindow
        monitorWindow.currentState = { [unowned self] in FlyoutState(states: monitor.snapshot, settings: settings, watches: watches, notice: notice).json() }
        monitorWindow.onMessage = { [unowned self] in handlePageMessage($0) }
        monitorWindow.onFrameChanged = { [unowned self] frame in
            settings.windowFrame = frame
            save()
        }
    }

    func attach(settings settingsWindow: PageWindow) {
        self.settingsWindow = settingsWindow
        settingsWindow.onPageReady = { [unowned self] in pushSettings() }
        settingsWindow.onMessage = { [unowned self] in handleSettingsMessage($0) }
        settingsWindow.onClosed = { [unowned self] in
            // Edits the page had not applied yet, such as a field still being typed in.
            if let draft = pendingSettingsDraft {
                pendingSettingsDraft = nil
                apply(draft)
            }
        }
    }

    private static func decodeSettings(_ object: Any?) -> WindowsSettings? {
        guard let object, let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(WindowsSettings.self, from: data)
    }

    func attach(history historyWindow: PageWindow) {
        self.historyWindow = historyWindow
        historyWindow.onPageReady = { [unowned self] in pushHistoryServers() }
        historyWindow.onClosed = { [unowned self] in historyQuery = nil }
        historyWindow.onMessage = { [unowned self] message in
            switch message["type"] as? String {
            case "query":
                guard let id = message["serverId"] as? String, let gpu = message["gpu"] as? Int,
                      let hours = message["hours"] as? Int else { return }
                historyQuery = (id, gpu, hours)
                pushHistoryData()
            case "close": historyWindow.close()
            default: break
            }
        }
    }

    // MARK: GPU History

    func openHistory() {
        if settings.displayMode == .popover { flyout?.hide() }
        historyWindow?.show()
        pushHistoryServers()
    }

    /// Servers and their GPU indexes for the pickers, as macOS's history window lists them.
    private func pushHistoryServers() {
        guard let historyWindow, historyWindow.isVisible else { return }
        struct Entry: Encodable { let id: String; let name: String; let gpus: [Int] }
        struct Message: Encodable { let type = "servers"; let servers: [Entry]; let language: String; let theme: String; let recording: Bool }
        let states = monitor.snapshot, history = history
        let language = Theme.language, theme = Theme.resolvedName, recording = settings.recordsGPUHistory
        Task.detached {
            var servers: [Entry] = []
            for state in states {
                let stored = await history.samples(serverID: state.id, fingerprint: state.server.connectionFingerprint)
                let current = state.snapshot?.gpus.map(\.index) ?? []
                servers.append(Entry(id: state.id, name: state.displayName,
                                     gpus: current.isEmpty ? Set(stored.map(\.gpuIndex)).sorted() : current.sorted()))
            }
            guard let data = try? JSONEncoder().encode(Message(servers: servers, language: language, theme: theme, recording: recording)) else { return }
            let json = String(decoding: data, as: UTF8.self)
            UIThread.run { trayApp?.historyWindow?.host.post(json) }
        }
    }

    /// Prepares the chart for the current query (macOS GPUHistoryRenderData) and sends it.
    private func pushHistoryData() {
        guard let historyWindow, historyWindow.isVisible, let query = historyQuery,
              let state = monitor.snapshot.first(where: { $0.id == query.serverID }) else { return }
        struct Message: Encodable { let type = "history"; let serverId: String; let gpu: Int; let hours: Int; let data: GPUHistoryRenderData }
        let history = history, pollInterval = settings.pollIntervalSeconds
        let uuid = state.snapshot?.gpus.first { $0.index == query.gpu }?.uuid
        Task.detached {
            let all = await history.samples(serverID: state.id, fingerprint: state.server.connectionFingerprint)
            let samples = all.filter { $0.gpuIndex == query.gpu && (uuid == nil || $0.gpuUUID == uuid) }
            let render = GPUHistoryRenderData(samples: samples, hours: query.hours, now: Date(), pollInterval: pollInterval)
            guard let data = try? JSONEncoder().encode(Message(serverId: query.serverID, gpu: query.gpu, hours: query.hours, data: render)) else { return }
            let json = String(decoding: data, as: UTF8.self)
            UIThread.run { trayApp?.historyWindow?.host.post(json) }
        }
    }

    func historyChanged() { pushHistoryData() }

    func start() {
        addIcon()
        monitor.start()
        if settings.displayMode == .window { showMonitorWindow() }
    }

    /// Messages from the popover and window pages (the same index.html).
    private func handlePageMessage(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "refresh": monitor.refreshNow()
        case "refreshServer":
            if let id = message["id"] as? String { monitor.refresh(serverID: id) }
        case "loadProcessDetails":
            if let id = message["serverId"] as? String, let gpu = message["gpu"] as? Int {
                monitor.loadProcessDetails(serverID: id, gpuIndex: gpu)
            }
        case "setDisplayMode":
            if let mode = (message["mode"] as? String).flatMap(DisplayMode.init(rawValue:)) { setDisplayMode(mode) }
        case "togglePin":
            setAlwaysOnTop(!settings.windowAlwaysOnTop)
        case "toggleIdleWatch":
            guard let id = message["serverId"] as? String, let index = message["gpu"] as? Int,
                  let state = monitor.snapshot.first(where: { $0.id == id }),
                  let gpu = state.snapshot?.gpus.first(where: { $0.index == index }) else { return }
            let on = watches.toggleIdleWatch(gpu: gpu, server: state.server, snapshotTakenAt: state.snapshot?.takenAt,
                                             idleSeconds: settings.idleNotificationSeconds, memoryThresholdMB: settings.idleMemoryThresholdMB)
            let korean = Theme.language == "ko"
            setNotice(on ? (korean ? "GPU idle 알림을 등록했습니다." : "GPU idle alert enabled.")
                         : (korean ? "GPU idle 알림을 해제했습니다." : "GPU idle alert disabled."))
            pushSettings()
        case "toggleExitWatch":
            guard let id = message["serverId"] as? String, let index = message["gpu"] as? Int, let pid = message["pid"] as? Int,
                  let state = monitor.snapshot.first(where: { $0.id == id }),
                  let gpu = state.snapshot?.gpus.first(where: { $0.index == index }),
                  let process = gpu.processes.first(where: { $0.pid == pid }) else { return }
            let on = watches.toggleExitWatch(process: process, gpu: gpu, server: state.server)
            let korean = Theme.language == "ko"
            setNotice(on ? (korean ? "프로세스 종료 알림을 등록했습니다." : "Process exit alert enabled.")
                         : (korean ? "프로세스 종료 알림을 해제했습니다." : "Process exit alert disabled."))
            pushSettings()
        case "settings": openSettings()
        case "openHistory": openHistory()
        default: break
        }
    }

    /// Tray click: the popover toggles; the window comes to the front, or hides
    /// when it already is in front.
    func toggleFlyout() {
        if settings.displayMode == .window, let monitorWindow {
            if monitorWindow.isVisible, monitorWindow.isForeground, !IsIconic(monitorWindow.window) {
                monitorWindow.hide()
            } else {
                showMonitorWindow()
            }
            return
        }
        guard let flyout else { showMenu(); return }
        flyout.toggle()
    }

    private func showMonitorWindow() {
        monitorWindow?.show(frame: settings.windowFrame, alwaysOnTop: settings.windowAlwaysOnTop)
    }

    func setDisplayMode(_ mode: DisplayMode) {
        guard settings.displayMode != mode else { return }
        settings.displayMode = mode
        save()
        applyDisplayMode()
        pushSettings()
    }

    private func applyDisplayMode() {
        switch settings.displayMode {
        case .window:
            flyout?.hide()
            flyout?.releaseView()
            showMonitorWindow()
        case .popover:
            monitorWindow?.hide()
            flyout?.show()   // open it right away so it is clear where the content went
        }
    }

    func setAlwaysOnTop(_ onTop: Bool) {
        settings.windowAlwaysOnTop = onTop
        save()
        monitorWindow?.setAlwaysOnTop(onTop)
        monitorWindow?.push()
        pushSettings()
    }

    private func save() {
        do { try SettingsStore.save(settings) } catch { Diagnostics.log("saving settings failed: \(error)") }
    }

    func stateChanged() {
        updateIcon()
        flyout?.push()
        monitorWindow?.push()
        if settingsWindow?.isVisible == true { pushRuntime() }
    }

    /// After sleep: idle alerts time their stretch again (macOS 0.9) and every server refreshes.
    func systemResumed() {
        watches.restartIdleTiming()
        monitor.refreshNow()
    }

    func systemSettingsChanged() {
        updateIcon()   // the taskbar theme sets the plain tray number's color
        guard settings.appearanceMode == .system else { return }
        applyAppearance()
    }

    // MARK: Tray icon

    private func notifyData() -> NOTIFYICONDATAW {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = window
        data.uID = 1
        data.uFlags = UINT(NIF_MESSAGE | NIF_ICON | NIF_TIP)
        data.uCallbackMessage = trayCallbackMessage
        data.hIcon = icon
        let tip = trayTooltip()
        withUnsafeMutableBytes(of: &data.szTip) { buffer in
            let units = buffer.bindMemory(to: UInt16.self)
            let text = Array(tip.utf16.prefix(units.count - 1))
            for (index, unit) in text.enumerated() { units[index] = unit }
            units[text.count] = 0
        }
        return data
    }

    func addIcon() {
        replaceIcon()
        var data = notifyData()
        Shell_NotifyIconW(DWORD(NIM_ADD), &data)
    }

    func updateIcon() {
        let old = replaceIcon()
        var data = notifyData()
        Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
        if let old { DestroyIcon(old) }
    }

    @discardableResult
    private func replaceIcon() -> HICON? {
        let old = icon
        let summary = TrayIconRenderer.summary(for: monitor.snapshot.filter { $0.server.isPollable }, settings: settings)
        icon = TrayIconRenderer.makeIcon(summary: summary, style: settings.trayIconStyle, usesColor: settings.trayIconUsesColor)
        return old
    }

    /// First line: the macOS menu bar text for every style; then one line per server.
    private func trayTooltip() -> String {
        let states = monitor.snapshot.filter { $0.server.isPollable }
        guard !states.isEmpty else { return "NVBeacon" }
        let summary = TrayIconRenderer.summary(for: states, settings: settings)
        let korean = Theme.language == "ko"
        let headline = summary.average.map { average in
            korean ? "평균 \(average)% · 사용 중 \(summary.busy)/\(summary.total)"
                   : "Average \(average)% · Busy \(summary.busy)/\(summary.total)"
        } ?? (korean ? "데이터를 기다리는 중" : "Waiting for data")
        let text = (["NVBeacon — " + headline] + states.map(SummaryFormatter.compactLine)).joined(separator: "\n")
        return text.count <= 127 ? text : String(text.prefix(126)) + "…"
    }

    func removeIcon() {
        var data = notifyData()
        Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
        if let icon { DestroyIcon(icon) }
    }

    // MARK: Menu

    /// The right-click menu: Settings… and Quit, as on macOS.
    func showMenu(fromFlyout: Bool = false) {
        guard let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        let owner = fromFlyout ? (flyout?.window ?? window) : window
        let korean = Theme.language == "ko"
        append(menu, korean ? "지금 새로고침" : "Refresh Now", command: .refresh)
        if settings.displayMode == .window {
            append(menu, korean ? "팝오버로 보기" : "Show as Popover", command: .toggleDisplayMode)
            append(menu, korean ? "항상 위에 표시" : "Keep Window on Top", command: .toggleOnTop, checked: settings.windowAlwaysOnTop)
        } else {
            append(menu, korean ? "창으로 보기" : "Show as Window", command: .toggleDisplayMode)
        }
        if settings.recordsGPUHistory {
            append(menu, korean ? "GPU 기록…" : "GPU History…", command: .history)
        }
        append(menu, korean ? "설정…" : "Settings…", command: .settings)
        AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        append(menu, korean ? "NVBeacon 종료" : "Quit NVBeacon", command: .quit)

        var cursor = POINT()
        GetCursorPos(&cursor)
        // Without this the menu stays open when the user clicks elsewhere.
        SetForegroundWindow(owner)
        Diagnostics.log("menu opened")
        // The choice arrives as WM_COMMAND (TPM_RETURNCMD's id is lost to the BOOL import).
        // TrackPopupMenu runs its own modal message loop until the menu closes.
        TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON) | UINT(TPM_BOTTOMALIGN), cursor.x, cursor.y, 0, owner, nil)
        Diagnostics.log("menu closed")
        PostMessageW(owner, UINT(WM_NULL), 0, 0)
    }

    func handleCommand(_ identifier: UInt) {
        guard let command = Command(rawValue: identifier) else { return }
        switch command {
        case .refresh: monitor.refreshNow()
        case .settings: openSettings()
        case .quit: quit()
        case .toggleDisplayMode: setDisplayMode(settings.displayMode == .window ? .popover : .window)
        case .toggleOnTop: setAlwaysOnTop(!settings.windowAlwaysOnTop)
        case .history: openHistory()
        }
    }

    private func append(_ menu: HMENU, _ title: String, command: Command, checked: Bool = false) {
        title.withCString(encodedAs: UTF16.self) {
            _ = AppendMenuW(menu, UINT(MF_STRING) | (checked ? UINT(MF_CHECKED) : 0), UINT_PTR(command.rawValue), $0)
        }
    }

    func quit() {
        Diagnostics.log("Quit")
        monitor.stop()
        // Save the partial GPU History minute so a normal quit loses nothing (as on macOS).
        let saved = DispatchSemaphore(value: 0)
        let history = history
        Task.detached {
            await history.flush()
            saved.signal()
        }
        _ = saved.wait(timeout: .now() + 2)
        flyout?.releaseView()
        monitorWindow?.hide()
        settingsWindow?.close()
        historyWindow?.close()
        removeIcon()
        DestroyWindow(window)
    }

    // MARK: Settings

    func openSettings() {
        flyout?.hide()
        settingsWindow?.show()
        pushSettings()
    }

    /// Saves, then applies whatever changed: polling restarts only when servers,
    /// interval or collected host data change, like the macOS app.
    private func apply(_ incoming: WindowsSettings) {
        pendingSettingsDraft = nil   // superseded, e.g. by Clear Settings or an import
        var newSettings = incoming.sanitized()
        newSettings.windowFrame = settings.windowFrame   // owned by the window, not the Settings page
        guard newSettings != settings else { return }
        let old = settings
        settings = newSettings
        alertSettings.value = newSettings
        save()
        // A removed server's saved password goes with it, as on macOS.
        let remaining = Set(newSettings.servers.map(\.id))
        for server in old.servers where !remaining.contains(server.id) { passwordStore.delete(for: server.id) }

        flyout?.logicalWidth = Double(newSettings.popoverWidth)
        flyout?.closesOnOutsideClick = newSettings.closesPopoverOnOutsideClick
        if old.popoverHeightMode != newSettings.popoverHeightMode || old.popoverHeight != newSettings.popoverHeight {
            flyout?.fixedHeight = newSettings.popoverHeightMode == .fixed ? Double(newSettings.popoverHeight) : nil
        }
        if old.displayMode != newSettings.displayMode { applyDisplayMode() }
        if old.windowAlwaysOnTop != newSettings.windowAlwaysOnTop { monitorWindow?.setAlwaysOnTop(newSettings.windowAlwaysOnTop) }
        if old.appearanceMode != newSettings.appearanceMode || old.languagePreference != newSettings.languagePreference {
            Theme.preference = newSettings.appearanceMode
            Theme.languagePreference = newSettings.languagePreference
            applyAppearance()
        }
        let pollingChanged = old.servers != newSettings.servers || old.pollIntervalSeconds != newSettings.pollIntervalSeconds
            || old.hostMetricsOptions != newSettings.hostMetricsOptions
            || old.highlightsMyProcesses != newSettings.highlightsMyProcesses
            || old.recordsGPUHistory != newSettings.recordsGPUHistory
        if pollingChanged, sessionServers == nil {
            let previous = monitor.snapshot
            monitor.stop(closingConnections: false)
            // Kept connections stay open for servers that still use them; a server that now
            // connects differently gets a new one from the pool.
            for server in old.servers {
                let current = newSettings.servers.first { $0.id == server.id }
                if current == nil || current?.isPollable == false || current?.sshConnectionReuseMode == .newConnectionEachRefresh {
                    connectionPool.close(serverID: server.id)
                }
            }
            monitor = Self.makeMonitor(servers: newSettings.servers, settings: newSettings,
                                       connectionPool: connectionPool, rejections: rejections, previous: previous)
            configureAlerts(monitor)
            monitor.start()
        }
        stateChanged()
    }

    private func applyAppearance() {
        flyout?.applyTheme()
        monitorWindow?.applyTheme()
        settingsWindow?.applyTheme()
        flyout?.push()
        monitorWindow?.push()
        pushSettings()
    }

    private func pushSettings() {
        guard let settingsWindow, settingsWindow.isVisible else { return }
        guard let settingsData = try? JSONEncoder().encode(settings),
              let settingsObject = try? JSONSerialization.jsonObject(with: settingsData),
              let hostsData = try? JSONEncoder().encode(SSHConfigHosts.load()),
              let hostsObject = try? JSONSerialization.jsonObject(with: hostsData) else { return }
        settingsWindow.host.post([
            "type": "settings",
            "settings": settingsObject,
            "sshConfigHosts": hostsObject,
            "sshConfigPath": SSHConfigHosts.configFile.path,
            "sessionOverride": sessionServers != nil,
            "language": Theme.language,
            "theme": Theme.resolvedName,
            "launchAtLogin": LaunchAtLogin.status.rawValue,
            "defaults": [
                "gpuCommand": RemoteMetricCommands.defaultGPUCommand,
                "hostCommand": RemoteMetricCommands.defaultHostCommand,
            ],
            "about": ["version": DiagnosticsReport.appVersion,
                      "settingsFile": SettingsStore.fileURL.path],
            "notifications": notificationsPayload(),
            "savedPasswords": Array(passwordStore.savedServerIDs()),
        ])
        pushRuntime()
    }

    /// Settings › Notifications: active watches and the last 24 hours, as on macOS.
    private func notificationsPayload() -> [String: Any] {
        [
            "processWatches": watches.processWatches.map { watch in
                ["id": watch.id, "title": watch.displayProcessName, "user": watch.user ?? "--",
                 "pid": watch.pid, "gpu": watch.gpuIndex, "connection": watch.connectionLabel] as [String: Any]
            },
            "idleWatches": watches.idleWatches.map { watch in
                ["id": watch.id, "title": watch.title, "subtitle": watch.subtitle] as [String: Any]
            },
            "history": watches.recentHistory().map { entry in
                ["kind": entry.kind.rawValue, "subtitle": entry.subtitle,
                 "time": entry.timestamp.timeIntervalSince1970 * 1000] as [String: Any]
            },
        ]
    }

    private func pushRuntime() {
        let states = monitor.snapshot
        let active = states.filter { $0.server.isPollable }
        let gpus = active.flatMap { $0.snapshot?.gpus ?? [] }
        settingsWindow?.host.post([
            "type": "runtime",
            "servers": states.count,
            "enabledServers": states.filter { $0.server.isEnabled }.count,
            "loaded": active.contains { $0.snapshot != nil },
            "visibleGPUs": gpus.count,
            "busyGPUs": gpus.filter(settings.isBusy).count,
            "processes": gpus.reduce(0) { $0 + $1.processes.count },
            "averageUtilization": gpus.isEmpty ? 0 : gpus.reduce(0) { $0 + $1.utilization } / gpus.count,
            "serverErrors": active.filter { $0.lastError != nil }.count,
        ])
    }

    private func handleSettingsMessage(_ message: [String: Any]) {
        guard let settingsWindow else { return }
        let owner = settingsWindow.window
        switch message["type"] as? String {
        case "draft":
            // Applied if the window closes first (the page applies after a pause or when a field is left).
            pendingSettingsDraft = Self.decodeSettings(message["settings"])
        case "apply":
            pendingSettingsDraft = nil
            guard let decoded = Self.decodeSettings(message["settings"]) else { return }
            apply(decoded)
        case "browseIdentity":
            let folder = (ProcessInfo.processInfo.environment["USERPROFILE"] ?? "") + #"\.ssh"#
            if let path = FileDialog.open(owner: owner, title: Theme.language == "ko" ? "Identity 파일 선택" : "Choose Identity File",
                                          filter: [("All files", "*.*")], initialFolder: folder) {
                settingsWindow.host.post(["type": "identityPicked", "serverId": message["serverId"] as? String ?? "", "path": path])
            }
        case "reloadHosts":
            pushSettings()
        case "testConnection":
            guard let serverID = message["serverId"] as? String,
                  let server = settings.servers.first(where: { $0.id == serverID }) else { return }
            let korean = Theme.language == "ko"
            Task.detached {
                let result = await ServerMonitor.testConnection(server, askPassExecutable: Resources.executablePath)
                let ok: Bool, text: String
                switch result {
                case .success(let count, let seconds):
                    ok = true
                    let time = String(format: "%.1f", seconds)
                    text = korean ? "연결됨 · GPU \(count)개 · \(time)초" : "Connected · \(count) GPU\(count == 1 ? "" : "s") · \(time) s"
                case .passwordMissing:
                    ok = false
                    text = korean ? "비밀번호를 먼저 저장하세요." : "Save the password first."
                case .failure(let message):
                    ok = false
                    let category = DiagnosticsReport.errorCategory(message)
                    text = (korean ? DiagnosticsReport.koreanCategory(category) : category) + " — " + message
                }
                UIThread.run { trayApp?.postToSettings(["type": "testResult", "serverId": serverID, "ok": ok, "text": text]) }
            }
        case "deleteHistory":
            let history = history, korean = Theme.language == "ko"
            Task.detached {
                await history.deleteAll()
                UIThread.run {
                    trayApp?.postToSettings(["type": "notice", "text": korean ? "GPU 기록을 삭제했습니다." : "Deleted the GPU history."])
                    trayApp?.historyChanged()
                }
            }
        case "savePassword", "forgetPassword":
            guard let serverID = message["serverId"] as? String, !serverID.isEmpty else { return }
            let korean = Theme.language == "ko"
            let saving = message["type"] as? String == "savePassword"
            let saved = saving ? passwordStore.save(message["password"] as? String ?? "", for: serverID)
                               : passwordStore.delete(for: serverID)
            if saved {
                monitor.passwordChanged(serverID: serverID)
                settingsToast(saving ? (korean ? "비밀번호를 저장했습니다." : "Saved the password.")
                                     : (korean ? "저장된 비밀번호를 삭제했습니다." : "Removed the saved password."))
            } else {
                failure(korean ? "Windows 자격 증명 관리자에 저장하지 못했습니다." : "Could not update Windows Credential Manager.")
            }
            pushSettings()
        case "setLaunchAtLogin":
            let error = LaunchAtLogin.setEnabled(message["enabled"] as? Bool ?? false)
            settingsWindow.host.post(["type": "launchAtLogin", "status": LaunchAtLogin.status.rawValue, "error": error ?? NSNull()])
        case "exportServers":
            exportServers(owner: owner)
        case "importServers":
            chooseImport(owner: owner)
        case "confirmImport":
            if let backup = pendingImport {
                var updated = settings
                updated.importServers(from: backup)
                apply(updated)
                pendingImport = nil
                settingsToast(Theme.language == "ko" ? "비활성 서버 \(backup.servers.count)개를 추가했습니다." : "Added \(backup.servers.count) disabled servers.")
                pushSettings()
            }
        case "cancelImport":
            pendingImport = nil
        case "diagnostics":
            settingsWindow.host.post(["type": "diagnostics", "report": DiagnosticsReport.make(settings: settings, states: monitor.snapshot)])
        case "copyText":
            Shell.copyToClipboard(message["text"] as? String ?? "", owner: owner)
        case "reload":
            settings = SettingsStore.load()
            pushSettings()
        case "clearSettings":
            // Like macOS: servers, saved passwords, alerts and notification history all go.
            for serverID in passwordStore.savedServerIDs() { passwordStore.delete(for: serverID) }
            SettingsStore.clear()
            watches.clear()
            apply(WindowsSettings())
            pushSettings()
        case "removeWatch":
            if let id = message["id"] as? String { watches.removeWatch(id: id) }
            stateChanged()
            pushSettings()
        case "testNotification":
            let korean = Theme.language == "ko"
            let shown = Notifier.show(PendingNotification(
                title: korean ? "NVBeacon 테스트 알림" : "NVBeacon test notification",
                body: korean ? "프로세스 종료 알림과 GPU idle 알림이 정상적으로 표시됩니다." : "Process exit and GPU idle alerts are working normally."),
                trayWindow: window)
            if shown { watches.record(NotificationHistoryEntry(kind: .testNotificationScheduled)) }
            pushSettings()
        case "openURL":
            Shell.openWebPage(message["url"] as? String ?? "")
        case "openSettingsFile":
            try? SettingsStore.save(settings)
            Shell.openInNotepad(SettingsStore.fileURL.path)
        case "openLicenses":
            if let path = Resources.noticesPath { Shell.openInNotepad(path) }
        case "close":
            settingsWindow.close()
        default:
            break
        }
    }

    func postToSettings(_ message: [String: Any]) {
        settingsWindow?.host.post(message)
    }

    private func settingsToast(_ text: String) {
        settingsWindow?.host.post(["type": "notice", "text": text])
    }

    private func failure(_ text: String) {
        settingsWindow?.host.post(["type": "error", "text": text])
    }

    private func exportServers(owner: HWND) {
        do {
            let data = try settings.backup().encoded()
            guard let path = FileDialog.save(owner: owner, title: Theme.language == "ko" ? "서버 내보내기" : "Export Servers",
                                             filter: [("JSON", "*.json")], fileName: "NVBeacon-servers.json",
                                             defaultExtension: "json") else { return }
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            settingsToast(Theme.language == "ko" ? "서버 설정을 내보냈습니다." : "Server settings exported.")
        } catch {
            failure(error.localizedDescription)
        }
    }

    private func chooseImport(owner: HWND) {
        guard let path = FileDialog.open(owner: owner, title: Theme.language == "ko" ? "서버 가져오기" : "Import Servers",
                                         filter: [("JSON", "*.json")]) else { return }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let backup = try ServerSettingsBackup.decode(data)
            try backup.validate()
            pendingImport = backup
            settingsWindow?.host.post([
                "type": "importPreview",
                "fileName": URL(fileURLWithPath: path).lastPathComponent,
                "existing": settings.servers.count,
                "servers": backup.servers.map { ["name": $0.displayName, "target": $0.sshTarget] },
            ])
        } catch {
            failure(error.localizedDescription)
        }
    }
}
