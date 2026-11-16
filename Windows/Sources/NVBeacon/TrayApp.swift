import Foundation
import NVBeaconCore
import NVBeaconWindowsKit
import WinSDK

let trayCallbackMessage = UINT(WM_APP) + 1
let stateChangedMessage = UINT(WM_APP) + 2

/// Only touched on the UI thread (the window procedure and the message loop).
nonisolated(unsafe) var trayApp: TrayApp?
/// Posting is thread-safe; the monitor uses this to wake the UI thread.
nonisolated(unsafe) var trayWindowBits: Int = 0

func windowProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if let app = trayApp {
        switch message {
        case trayCallbackMessage:
            let event = UINT(truncatingIfNeeded: lParam & 0xFFFF)
            if event == UINT(WM_LBUTTONUP) || event == UINT(WM_RBUTTONUP) { app.showMenu() }
            return 0
        case stateChangedMessage:
            app.updateIcon()
            return 0
        case UINT(WM_COMMAND):
            app.handleCommand(UInt(wParam & 0xFFFF))
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

final class TrayApp {
    private enum Command: UInt {
        case refresh = 1, copyReport, editServers, reloadServers, quit
    }

    let window: HWND
    let taskbarCreatedMessage: UINT
    private var interval: Duration
    private var monitor: ServerMonitor
    private var icon: HICON?

    init(window: HWND, targets: [String], interval: Duration) {
        self.window = window
        self.interval = interval
        self.taskbarCreatedMessage = "TaskbarCreated".withCString(encodedAs: UTF16.self) { RegisterWindowMessageW($0) }
        self.monitor = Self.makeMonitor(targets: targets, interval: interval)
    }

    private static func makeMonitor(targets: [String], interval: Duration) -> ServerMonitor {
        ServerMonitor(targets: targets, interval: interval) {
            PostMessageW(HWND(bitPattern: trayWindowBits), stateChangedMessage, 0, 0)
        }
    }

    func start() {
        addIcon()
        monitor.start()
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
        let states = monitor.snapshot
        let tip = states.isEmpty ? "NVBeacon: no servers" : SummaryFormatter.tooltip(states)
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
        icon = TrayIconRenderer.makeIcon(for: monitor.snapshot)
        return old
    }

    func removeIcon() {
        var data = notifyData()
        Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
        if let icon { DestroyIcon(icon) }
    }

    // MARK: Menu

    func showMenu() {
        guard let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        let states = monitor.snapshot
        if states.isEmpty {
            append(menu, "No servers — add SSH targets to servers.txt", enabled: false)
        }
        for state in states {
            appendServer(state, to: menu)
            AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        }
        append(menu, "Refresh now", command: .refresh)
        append(menu, "Copy report", command: .copyReport)
        append(menu, "Edit servers.txt…", command: .editServers)
        append(menu, "Reload servers", command: .reloadServers)
        AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
        append(menu, "Quit NVBeacon", command: .quit)

        var cursor = POINT()
        GetCursorPos(&cursor)
        // Without this the menu stays open when the user clicks elsewhere.
        SetForegroundWindow(window)
        // The choice arrives as WM_COMMAND (TPM_RETURNCMD's id is lost to the BOOL import).
        TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON) | UINT(TPM_BOTTOMALIGN), cursor.x, cursor.y, 0, window, nil)
        PostMessageW(window, UINT(WM_NULL), 0, 0)
    }

    func handleCommand(_ identifier: UInt) {
        if let command = Command(rawValue: identifier) { run(command) }
    }

    private func appendServer(_ state: ServerState, to menu: HMENU) {
        var header = state.target
        if let attempt = state.lastAttempt {
            header += "   ·   updated " + attempt.formatted(date: .omitted, time: .standard)
        }
        append(menu, header, enabled: false)
        if let error = state.lastError {
            append(menu, "⚠ " + String(error.prefix(120)))
        } else if state.snapshot == nil {
            append(menu, "Connecting…")
        }
        guard let snapshot = state.snapshot else { return }
        if snapshot.gpus.isEmpty { append(menu, "No GPUs reported") }
        for gpu in snapshot.gpus {
            let line = SummaryFormatter.gpuLine(gpu)
            guard !gpu.processes.isEmpty, let submenu = CreatePopupMenu() else {
                append(menu, line)
                continue
            }
            for process in gpu.processes { append(submenu, SummaryFormatter.processLine(process)) }
            // The parent menu owns the submenu and destroys it with itself.
            line.withCString(encodedAs: UTF16.self) {
                _ = AppendMenuW(menu, UINT(MF_POPUP), UINT_PTR(UInt(bitPattern: submenu)), $0)
            }
        }
        if let host = SummaryFormatter.hostLine(state) { append(menu, host) }
    }

    /// Items without a command are informational; choosing one just closes the menu.
    private func append(_ menu: HMENU, _ title: String, command: Command? = nil, enabled: Bool = true) {
        let flags = UINT(MF_STRING) | (enabled ? 0 : UINT(MF_GRAYED))
        title.withCString(encodedAs: UTF16.self) {
            _ = AppendMenuW(menu, flags, UINT_PTR(command?.rawValue ?? 0), $0)
        }
    }

    private func run(_ command: Command) {
        switch command {
        case .refresh:
            monitor.refreshNow()
        case .copyReport:
            let report = monitor.snapshot.map(SummaryFormatter.report).joined(separator: "\n\n")
            copyToClipboard(report)
        case .editServers:
            _ = LaunchOptions.loadServerFile()  // creates the template on first use
            shellOpen(LaunchOptions.serverFile.path)
        case .reloadServers:
            monitor.stop()
            monitor = Self.makeMonitor(targets: LaunchOptions.loadServerFile(), interval: interval)
            updateIcon()
            monitor.start()
        case .quit:
            monitor.stop()
            removeIcon()
            DestroyWindow(window)
        }
    }

    private func shellOpen(_ path: String) {
        "notepad.exe".withCString(encodedAs: UTF16.self) { program in
            WindowsCommandLine.quote(path).withCString(encodedAs: UTF16.self) { argument in
                _ = ShellExecuteW(nil, nil, program, argument, nil, SW_SHOWNORMAL)
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        let units = Array(text.utf16) + [0]
        guard OpenClipboard(window) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        let bytes = units.count * MemoryLayout<UInt16>.size
        guard let memory = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes)) else { return }
        guard let pointer = GlobalLock(memory) else {
            GlobalFree(memory)
            return
        }
        units.withUnsafeBytes { pointer.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        GlobalUnlock(memory)
        if SetClipboardData(UINT(CF_UNICODETEXT), memory) == nil { GlobalFree(memory) }
    }
}
