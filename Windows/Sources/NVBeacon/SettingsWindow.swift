import Foundation
import NVBeaconWindowsKit
import WinSDK

/// The Settings window: a normal resizable Win32 window whose content is
/// settings.html in WebView2. WebView2 is released when the window closes.
final class SettingsWindow {
    static let className = "NVBeaconSettings"
    let window: HWND
    let host: WebViewHost
    var onMessage: ([String: Any]) -> Void = { _ in }
    var onPageReady: () -> Void = {}

    init?(instance: HINSTANCE?) {
        let created = Self.className.withCString(encodedAs: UTF16.self) { name in
            "NVBeacon Settings".withCString(encodedAs: UTF16.self) { title in
                CreateWindowExW(0, name, title, DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN),
                                Int32(bitPattern: 0x8000_0000), 0, 760, 600, nil, nil, instance, nil)  // CW_USEDEFAULT
            }
        }
        guard let created else { return nil }
        window = created
        host = WebViewHost(window: created, page: "settings.html")
        host.onMessage = { [unowned self] in onMessage($0) }
        host.onPageReady = { [unowned self] in onPageReady() }
    }

    static func registerClass(instance: HINSTANCE?) -> Bool {
        className.withCString(encodedAs: UTF16.self) { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = settingsProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.hIcon = LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))  // IDI_APPLICATION
            windowClass.lpszClassName = name
            return RegisterClassExW(&windowClass) != 0
        }
    }

    var isVisible: Bool { IsWindowVisible(window) }

    func show() {
        applyTheme()
        if !isVisible {
            centerOnWorkArea()
            ShowWindow(window, SW_SHOW)
        } else if IsIconic(window) {
            ShowWindow(window, SW_RESTORE)
        }
        SetForegroundWindow(window)
        if host.view == nil { host.create(background: Theme.backgroundColor) } else { host.setVisible(true); host.focus() }
    }

    func close() {
        ShowWindow(window, SW_HIDE)
        host.release()   // settings are opened rarely; don't keep Chromium around
    }

    func applyTheme() {
        var dark: Int32 = Theme.isDark ? 1 : 0
        DwmSetWindowAttribute(window, DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue), &dark, DWORD(MemoryLayout<Int32>.size))
        let title = Theme.language == "ko" ? "NVBeacon 설정" : "NVBeacon Settings"
        _ = title.withCString(encodedAs: UTF16.self) { SetWindowTextW(window, $0) }
        InvalidateRect(window, nil, true)
    }

    private func centerOnWorkArea() {
        let dpi = Double(GetDpiForWindow(window))
        let scale = dpi > 0 ? dpi / 96 : 1
        let width = Int32(760 * scale), height = Int32(620 * scale)
        var cursor = POINT()
        GetCursorPos(&cursor)
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        GetMonitorInfoW(MonitorFromPoint(cursor, DWORD(MONITOR_DEFAULTTONEAREST)), &info)
        let work = info.rcWork
        let x = work.left + max(0, (work.right - work.left - width) / 2)
        let y = work.top + max(0, (work.bottom - work.top - height) / 2)
        SetWindowPos(window, nil, x, y, width, height, UINT(SWP_NOZORDER))
    }
}

/// Only touched on the UI thread.
nonisolated(unsafe) var activeSettingsWindow: SettingsWindow?

func settingsProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if let settings = activeSettingsWindow, window == settings.window {
        switch message {
        case UINT(WM_CLOSE):
            settings.close()
            return 0
        case UINT(WM_SIZE):
            settings.host.resize()
            return 0
        case UINT(WM_GETMINMAXINFO):
            let dpi = Double(GetDpiForWindow(window))
            let scale = dpi > 0 ? dpi / 96 : 1
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) {
                info.pointee.ptMinTrackSize = POINT(x: Int32(620 * scale), y: Int32(460 * scale))
            }
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
