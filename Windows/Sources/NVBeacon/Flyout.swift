import Foundation
import NVBeaconWindowsKit
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
    private let host: WebViewHost
    private var hiddenAt: UInt64 = 0
    private let releaseAfter: UINT
    /// Popover width in logical (96 DPI) pixels; Settings › Appearance.
    var logicalWidth = 500.0 { didSet { if isVisible { position() } } }
    var closesOnOutsideClick = true
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
                                DWORD(WS_POPUP) | DWORD(WS_CLIPCHILDREN), 0, 0, 500, 560, nil, nil, instance, nil)
            }
        }
        guard let created else { return nil }
        window = created
        host = WebViewHost(window: created, page: "index.html")
        var round = DWORD(2)  // DWMWCP_ROUND
        DwmSetWindowAttribute(window, DWORD(DWMWA_WINDOW_CORNER_PREFERENCE.rawValue), &round, DWORD(MemoryLayout<DWORD>.size))
        applyTheme()
        host.onPageReady = { [unowned self] in push() }
        host.onMessage = { [unowned self] message in handle(message) }
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

    func applyTheme() {
        var dark: Int32 = Theme.isDark ? 1 : 0  // a Win32 BOOL
        DwmSetWindowAttribute(window, DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue), &dark, DWORD(MemoryLayout<Int32>.size))
        InvalidateRect(window, nil, true)
    }

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
        Diagnostics.log("flyout shown (view \(host.view == nil ? "absent" : "ready"))")
        if host.view != nil {
            host.setVisible(true)
            host.focus()
            push()
        } else {
            host.create(background: Theme.backgroundColor)
        }
    }

    func hide() {
        guard isVisible else { return }
        ShowWindow(window, SW_HIDE)
        hiddenAt = GetTickCount64()
        host.setVisible(false)
        // Microsoft advises TrySuspend or MemoryUsageTargetLevel, not both; TrySuspend lowers the target itself.
        SetTimer(window, Self.suspendTimer, 5_000, nil)
        if releaseAfter > 0 { SetTimer(window, Self.releaseTimer, releaseAfter, nil) }
        Diagnostics.log("flyout hidden")
    }

    func deactivated() {
        if closesOnOutsideClick { hide() }
    }

    func timerFired(_ id: UINT_PTR) {
        KillTimer(window, id)
        guard !isVisible else { return }
        if id == Self.suspendTimer { host.trySuspend() } else if id == Self.releaseTimer { host.release() }
    }

    func releaseView() { host.release() }

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
        host.resize()
    }

    func resized() { host.resize() }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
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
        guard isVisible else { return }
        host.post(currentState())
    }
}

/// Only touched on the UI thread.
nonisolated(unsafe) var activeFlyout: Flyout?

func flyoutProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if let flyout = activeFlyout, window == flyout.window {
        switch message {
        case UINT(WM_ACTIVATE):
            if (wParam & 0xFFFF) == WPARAM(WA_INACTIVE) { flyout.deactivated() }
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
            paintBackground(window, HDC(bitPattern: UInt(wParam)))
            return 1
        default:
            break
        }
    }
    return DefWindowProcW(window, message, wParam, lParam)
}

func paintBackground(_ window: HWND?, _ dc: HDC?) {
    var rect = RECT()
    GetClientRect(window, &rect)
    let brush = CreateSolidBrush(Theme.backgroundColor)
    FillRect(dc, &rect, brush)
    DeleteObject(brush)
}

enum Theme {
    /// Settings › Appearance › Theme; UI thread only.
    nonisolated(unsafe) static var preference = AppearancePreference.system
    nonisolated(unsafe) static var languagePreference = LanguagePreference.system

    /// Reads the per-user app theme. Microsoft documents UISettings for this; the
    /// registry value is the common Win32 fallback.
    static var systemPrefersDark: Bool {
        var value: DWORD = 1
        var size = DWORD(MemoryLayout<DWORD>.size)
        let status = #"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"#.withCString(encodedAs: UTF16.self) { key in
            "AppsUseLightTheme".withCString(encodedAs: UTF16.self) { name in
                RegGetValueW(HKEY_CURRENT_USER, key, name, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
            }
        }
        return status == ERROR_SUCCESS && value == 0
    }

    static var isDark: Bool {
        switch preference {
        case .system: systemPrefersDark
        case .light: false
        case .dark: true
        }
    }

    /// "light" or "dark", for the pages.
    static var resolvedName: String { isDark ? "dark" : "light" }

    /// Must match the pages' background so nothing flashes while they load.
    static var backgroundColor: COLORREF {
        isDark ? COLORREF(0x1E1E1E) : COLORREF(0xECECEC)  // 0x00BBGGRR, macOS window backgrounds
    }

    /// "ko" or "en": the setting, or the Windows display language for System.
    static var language: String {
        switch languagePreference {
        case .english: "en"
        case .korean: "ko"
        case .system: (GetUserDefaultUILanguage() & 0x3FF) == 0x12 ? "ko" : "en"
        }
    }
}
