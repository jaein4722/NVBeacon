import CWebView2
import Foundation
import WinSDK

/// The popover-style window that opens from the tray icon. Its content is an
/// HTML page in WebView2; the window itself is a borderless Win32 popup.
///
/// Lives entirely on the UI thread. WebView2 is created on first open, hidden
/// and suspended when the flyout closes, and released after `releaseAfter`
/// of being hidden so an idle tray app does not keep Chromium running.
final class Flyout {
    static let className = "NVBeaconFlyout"
    private static let suspendTimer: UINT_PTR = 1
    private static let releaseTimer: UINT_PTR = 2

    let window: HWND
    private let trayWindow: HWND
    private var view: OpaquePointer?
    private var creating = false
    private var pageReady = false
    private var hiddenAt: UInt64 = 0
    private let releaseAfter: UINT
    /// macOS popover default width, in logical (96 DPI) pixels.
    private let logicalWidth = 500.0
    /// Reported by the page so the flyout hugs its content, like the macOS popover.
    private var contentHeight = 560.0
    var onMessage: ([String: Any]) -> Void = { _ in }
    var currentState: () -> String = { "{}" }

    init?(trayWindow: HWND, instance: HINSTANCE?, releaseAfterSeconds: UINT) {
        self.trayWindow = trayWindow
        self.releaseAfter = releaseAfterSeconds * 1000
        let created = Self.className.withCString(encodedAs: UTF16.self) { name in
            "NVBeacon".withCString(encodedAs: UTF16.self) { title in
                CreateWindowExW(DWORD(WS_EX_TOOLWINDOW | WS_EX_TOPMOST), name, title,
                                DWORD(WS_POPUP) | DWORD(WS_CLIPCHILDREN), 0, 0, 380, 560, nil, nil, instance, nil)
            }
        }
        guard let created else { return nil }
        window = created
        var round = DWORD(2)  // DWMWCP_ROUND
        DwmSetWindowAttribute(window, DWORD(DWMWA_WINDOW_CORNER_PREFERENCE.rawValue), &round, DWORD(MemoryLayout<DWORD>.size))
        var dark: Int32 = Theme.prefersDark ? 1 : 0  // a Win32 BOOL
        DwmSetWindowAttribute(window, DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue), &dark, DWORD(MemoryLayout<Int32>.size))
    }

    static func registerClass(instance: HINSTANCE?) -> Bool {
        className.withCString(encodedAs: UTF16.self) { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = flyoutProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))  // IDC_ARROW
            windowClass.lpszClassName = name
            return RegisterClassExW(&windowClass) != 0
        }
    }

    var isVisible: Bool { IsWindowVisible(window) }

    // MARK: Showing and hiding

    func toggle() {
        if isVisible { hide(); return }
        // Clicking the tray icon deactivates an open flyout first; don't reopen it.
        if GetTickCount64() - hiddenAt < 250 { return }
        show()
    }

    func show() {
        KillTimer(window, Self.suspendTimer)
        KillTimer(window, Self.releaseTimer)
        position()
        ShowWindow(window, SW_SHOW)
        SetForegroundWindow(window)
        Diagnostics.log("flyout shown (view \(view == nil ? "absent" : "ready"))")
        if let view {
            NVBWebViewSetVisible(view, true)
            NVBWebViewFocus(view)
            push()
        } else {
            createView()
        }
    }

    func hide() {
        guard isVisible else { return }
        ShowWindow(window, SW_HIDE)
        hiddenAt = GetTickCount64()
        if let view { NVBWebViewSetVisible(view, false) }
        // Microsoft advises TrySuspend or MemoryUsageTargetLevel, not both; TrySuspend lowers the target itself.
        SetTimer(window, Self.suspendTimer, 5_000, nil)
        if releaseAfter > 0 { SetTimer(window, Self.releaseTimer, releaseAfter, nil) }
        Diagnostics.log("flyout hidden")
    }

    func timerFired(_ id: UINT_PTR) {
        KillTimer(window, id)
        guard !isVisible, let view else { return }
        if id == Self.suspendTimer {
            let result = NVBWebViewTrySuspend(view)
            Diagnostics.log("TrySuspend requested hr=0x\(String(UInt32(bitPattern: result), radix: 16))")
        } else if id == Self.releaseTimer {
            releaseView()
        }
    }

    func releaseView() {
        guard let view else { return }
        NVBWebViewClose(view)
        self.view = nil
        pageReady = false
        Diagnostics.log("WebView2 released")
    }

    /// Places the flyout next to the tray icon, inside the monitor's work area.
    private func position() {
        var identifier = NOTIFYICONIDENTIFIER()
        identifier.cbSize = DWORD(MemoryLayout<NOTIFYICONIDENTIFIER>.size)
        identifier.hWnd = trayWindow
        identifier.uID = 1
        var icon = RECT()
        if Shell_NotifyIconGetRect(&identifier, &icon) != S_OK {
            var cursor = POINT()
            GetCursorPos(&cursor)
            icon = RECT(left: cursor.x, top: cursor.y, right: cursor.x, bottom: cursor.y)
        }
        let monitor = MonitorFromRect(&icon, DWORD(MONITOR_DEFAULTTONEAREST))
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        GetMonitorInfoW(monitor, &info)
        let work = info.rcWork

        var dpiX: UINT = 96, dpiY: UINT = 96
        GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY)
        let scale = Double(dpiX) / 96
        let margin = Int32(12 * scale)
        let width = Int32(logicalWidth * scale)
        // Same limits as the macOS popover: 320 pt minimum, at most min(1100, visible height − 96).
        let workHeight = Double(work.bottom - work.top) / scale
        let maximumHeight = max(320, min(1100, workHeight - 96))
        let height = Int32(min(maximumHeight, max(min(320, maximumHeight), contentHeight)) * scale)

        let middle = (icon.left + icon.right) / 2
        let x = min(max(middle - width / 2, work.left + margin), work.right - width - margin)
        let y: Int32
        if icon.top >= work.bottom - 1 {
            y = work.bottom - height - margin          // taskbar at the bottom
        } else if icon.bottom <= work.top + 1 {
            y = work.top + margin                      // taskbar at the top
        } else {
            y = min(max(icon.top - height / 2, work.top + margin), work.bottom - height - margin)
        }
        SetWindowPos(window, HWND(bitPattern: -1) /* HWND_TOPMOST */, x, y, width, height, UINT(SWP_NOACTIVATE))
        resized()
    }

    func resized() {
        guard let view else { return }
        var bounds = RECT()
        GetClientRect(window, &bounds)
        NVBWebViewSetBounds(view, bounds)
    }

    // MARK: WebView2

    private func createView() {
        guard !creating else { return }
        guard let folder = Resources.uiFolder, let loader = Resources.loaderPath else {
            Diagnostics.log("UI folder or WebView2Loader.dll not found")
            return
        }
        let loaded = loader.withCString(encodedAs: UTF16.self) { NVBWebViewLoad($0) }
        guard loaded >= 0 else {
            Diagnostics.log("WebView2Loader.dll failed to load hr=0x\(String(UInt32(bitPattern: loaded), radix: 16))")
            return
        }
        creating = true
        let started = ContinuousClock.now
        createStarted = started
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = Resources.userDataFolder.withCString(encodedAs: UTF16.self) { data in
            "nvbeacon.ui".withCString(encodedAs: UTF16.self) { host in
                folder.withCString(encodedAs: UTF16.self) { content in
                    "https://nvbeacon.ui/index.html".withCString(encodedAs: UTF16.self) { url in
                        NVBWebViewCreate(window, data, host, content, url, Theme.backgroundColor,
                                         Diagnostics.enabled, context, flyoutReady, flyoutMessage)
                    }
                }
            }
        }
        if result < 0 {
            creating = false
            Diagnostics.log("NVBWebViewCreate failed hr=0x\(String(UInt32(bitPattern: result), radix: 16))")
        }
    }

    private var createStarted = ContinuousClock.now

    fileprivate func didCreate(_ created: OpaquePointer?, _ result: HRESULT) {
        creating = false
        guard let created, result >= 0 else {
            Diagnostics.log("WebView2 creation failed hr=0x\(String(UInt32(bitPattern: result), radix: 16))")
            return
        }
        view = created
        Diagnostics.log("WebView2 ready after \(ContinuousClock.now - createStarted), browser pid \(NVBWebViewBrowserProcessID(created))")
        resized()
        NVBWebViewSetVisible(created, isVisible)
        if isVisible { NVBWebViewFocus(created) }
    }

    fileprivate func didReceive(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
            var client = RECT()
            GetClientRect(window, &client)
            Diagnostics.log("page ready after \(ContinuousClock.now - createStarted); page \(message["width"] ?? "?")x\(message["height"] ?? "?") css px at scale \(message["scale"] ?? "?"), window client \(client.right)x\(client.bottom) px, window dpi \(GetDpiForWindow(window))")
            push()
        case "ack":
            if let sentAt = message["sentAt"] as? Double {
                Diagnostics.log("state delivered in \(Int(Date().timeIntervalSince1970 * 1000 - sentAt)) ms")
            }
        case "close":
            hide()
        case "size":
            if let height = message["height"] as? Double, abs(height - contentHeight) >= 1 {
                contentHeight = height
                if isVisible { position() }
            }
        default:
            onMessage(message)
        }
    }

    /// Sends the latest state; skipped while hidden (the page is suspended anyway).
    func push() {
        guard let view, pageReady, isVisible else { return }
        let json = currentState()
        _ = json.withCString(encodedAs: UTF16.self) { NVBWebViewPostJSON(view, $0) }
    }
}

private func flyoutReady(_ context: UnsafeMutableRawPointer?, _ view: OpaquePointer?, _ result: HRESULT) {
    guard let context else { return }
    Unmanaged<Flyout>.fromOpaque(context).takeUnretainedValue().didCreate(view, result)
}

private func flyoutMessage(_ context: UnsafeMutableRawPointer?, _ text: UnsafePointer<wchar_t>?) {
    guard let context, let text else { return }
    let string = String(decodingCString: text, as: UTF16.self)
    Unmanaged<Flyout>.fromOpaque(context).takeUnretainedValue().didReceive(string)
}

/// Only touched on the UI thread.
nonisolated(unsafe) var activeFlyout: Flyout?

func flyoutProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if let flyout = activeFlyout, window == flyout.window {
        switch message {
        case UINT(WM_ACTIVATE):
            if (wParam & 0xFFFF) == WPARAM(WA_INACTIVE) { flyout.hide() }
            return 0
        case UINT(WM_SIZE):
            flyout.resized()
            return 0
        case UINT(WM_TIMER):
            flyout.timerFired(UINT_PTR(wParam))
            return 0
        case UINT(WM_COMMAND):
            // Menus opened from the flyout are owned by it; their commands belong to the tray app.
            trayApp?.handleCommand(UInt(wParam & 0xFFFF))
            return 0
        case UINT(WM_ERASEBKGND):
            var rect = RECT()
            GetClientRect(window, &rect)
            let brush = CreateSolidBrush(Theme.backgroundColor)
            FillRect(HDC(bitPattern: UInt(wParam)), &rect, brush)
            DeleteObject(brush)
            return 1
        default:
            break
        }
    }
    return DefWindowProcW(window, message, wParam, lParam)
}

enum Theme {
    /// Reads the per-user app theme. Microsoft documents UISettings for this; the
    /// registry value is the common Win32 fallback and is enough for the prototype.
    static var prefersDark: Bool {
        var value: DWORD = 1
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = #"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"#.withCString(encodedAs: UTF16.self) { key in
            "AppsUseLightTheme".withCString(encodedAs: UTF16.self) { name in
                RegGetValueW(HKEY_CURRENT_USER, key, name, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
            }
        }
        return status == ERROR_SUCCESS && value == 0
    }

    /// Must match the page's background so nothing flashes while it loads.
    static var backgroundColor: COLORREF {
        prefersDark ? COLORREF(0x1E1E1E) : COLORREF(0xECECEC)  // 0x00BBGGRR, macOS window backgrounds
    }
}

enum Resources {
    private static var executableFolder: URL {
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        return URL(fileURLWithPath: String(decoding: buffer[0..<Int(length)], as: UTF16.self)).deletingLastPathComponent()
    }

    /// Source tree fallback for development builds.
    private static var packageFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var uiFolder: String? {
        let candidates = [
            executableFolder.appendingPathComponent("NVBeaconWindows_NVBeacon.resources").appendingPathComponent("UI"),
            executableFolder.appendingPathComponent("UI"),
            packageFolder.appendingPathComponent("Sources/NVBeacon/UI"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
            .map { $0.path.replacingOccurrences(of: "/", with: "\\") }
    }

    static var loaderPath: String? {
        let candidates = [
            executableFolder.appendingPathComponent("WebView2Loader.dll"),
            packageFolder.appendingPathComponent("ThirdParty/webview2/pkg/build/native/x64/WebView2Loader.dll"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            .map { $0.path.replacingOccurrences(of: "/", with: "\\") }
    }

    static var userDataFolder: String {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? NSTemporaryDirectory()
        return base + #"\NVBeacon\WebView2"#
    }
}
