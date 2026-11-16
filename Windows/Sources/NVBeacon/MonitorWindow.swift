import Foundation
import NVBeaconWindowsKit
import WinSDK

/// Window mode: the popover's page (index.html) in a normal, resizable window
/// that stays open, can be kept on top, and remembers its frame.
final class MonitorWindow {
    static let className = "NVBeaconMonitorWindow"
    let window: HWND
    private let host: WebViewHost
    var onMessage: ([String: Any]) -> Void = { _ in }
    var currentState: () -> String = { "{}" }
    /// Called with the new frame after the user moves or resizes the window.
    var onFrameChanged: (WindowFrame) -> Void = { _ in }
    var onClosed: () -> Void = {}

    init?(instance: HINSTANCE?) {
        let created = Self.className.withCString(encodedAs: UTF16.self) { name in
            "NVBeacon".withCString(encodedAs: UTF16.self) { title in
                // No maximize: a monitor panel has no use for full screen. The page draws the
                // title bar (pin, minimize, close); WM_NCCALCSIZE removes the system one.
                CreateWindowExW(0, name, title, (DWORD(WS_OVERLAPPEDWINDOW) & ~DWORD(WS_MAXIMIZEBOX)) | DWORD(WS_CLIPCHILDREN),
                                Int32(bitPattern: 0x8000_0000), 0, 520, 720, nil, nil, instance, nil)  // CW_USEDEFAULT
            }
        }
        guard let created else { return nil }
        window = created
        host = WebViewHost(window: created, page: "index.html")
        host.nonClientRegions = true
        host.onPageReady = { [unowned self] in push() }
        host.onMessage = { [unowned self] message in
            switch message["type"] as? String {
            case "size", "close": break   // the window keeps the size the user gave it
            case "minimizeWindow": ShowWindow(window, SW_MINIMIZE)
            case "closeWindow": closeRequested()
            default: onMessage(message)
            }
        }
        // Recompute the frame now that WM_NCCALCSIZE drops the caption.
        SetWindowPos(window, nil, 0, 0, 0, 0, UINT(SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
    }

    static func registerClass(instance: HINSTANCE?) -> Bool {
        className.withCString(encodedAs: UTF16.self) { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = monitorWindowProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.hIcon = LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.lpszClassName = name
            return RegisterClassExW(&windowClass) != 0
        }
    }

    var isVisible: Bool { IsWindowVisible(window) }
    var isForeground: Bool { GetForegroundWindow() == window }

    func show(frame: WindowFrame?, alwaysOnTop: Bool) {
        applyTheme()
        if !isVisible {
            place(frame)
            ShowWindow(window, SW_SHOW)
        } else if IsIconic(window) {
            ShowWindow(window, SW_RESTORE)
        }
        setAlwaysOnTop(alwaysOnTop)
        SetForegroundWindow(window)
        if host.view == nil { host.create(background: Theme.backgroundColor) } else { host.setVisible(true); host.focus(); push() }
    }

    /// Hides the window and releases WebView2; the app keeps running in the tray.
    func hide() {
        guard isVisible else { return }
        ShowWindow(window, SW_HIDE)
        host.release()
    }

    func setAlwaysOnTop(_ onTop: Bool) {
        let ok = SetWindowPos(window, HWND(bitPattern: onTop ? -1 : -2) /* HWND_TOPMOST : HWND_NOTOPMOST */,
                              0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
        let topmost = (GetWindowLongW(window, GWL_EXSTYLE) & Int32(WS_EX_TOPMOST)) != 0
        Diagnostics.log("setAlwaysOnTop(\(onTop)) ok=\(ok) error=\(ok ? 0 : GetLastError()) topmost=\(topmost)")
    }

    func applyTheme() {
        var dark: Int32 = Theme.isDark ? 1 : 0
        DwmSetWindowAttribute(window, DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue), &dark, DWORD(MemoryLayout<Int32>.size))
        InvalidateRect(window, nil, true)
    }

    func push() {
        guard isVisible, !IsIconic(window) else { return }
        host.post(currentState())
    }

    func resized() { host.resize() }

    /// Restores the saved frame when it is still on a connected monitor, otherwise
    /// opens near the tray at a popover-like size.
    private func place(_ frame: WindowFrame?) {
        if let frame {
            var rect = RECT(left: Int32(frame.x), top: Int32(frame.y),
                            right: Int32(frame.x + frame.width), bottom: Int32(frame.y + frame.height))
            if MonitorFromRect(&rect, DWORD(MONITOR_DEFAULTTONULL)) != nil {
                SetWindowPos(window, nil, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
                return
            }
        }
        var cursor = POINT()
        GetCursorPos(&cursor)
        let monitor = MonitorFromPoint(cursor, DWORD(MONITOR_DEFAULTTONEAREST))
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        GetMonitorInfoW(monitor, &info)
        var dpiX: UINT = 96, dpiY: UINT = 96
        GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY)
        let scale = Double(dpiX) / 96
        let work = info.rcWork
        let width = Int32(520 * scale), height = min(Int32(760 * scale), work.bottom - work.top - Int32(48 * scale))
        let margin = Int32(16 * scale)
        SetWindowPos(window, nil, work.right - width - margin, work.bottom - height - margin, width, height,
                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))
    }

    fileprivate func frameChanged() {
        guard isVisible, !IsIconic(window), !IsZoomed(window) else { return }
        var rect = RECT()
        GetWindowRect(window, &rect)
        onFrameChanged(WindowFrame(x: Int(rect.left), y: Int(rect.top),
                                   width: Int(rect.right - rect.left), height: Int(rect.bottom - rect.top)))
    }

    fileprivate func closeRequested() {
        hide()
        onClosed()
    }
}

/// Only touched on the UI thread.
nonisolated(unsafe) var activeMonitorWindow: MonitorWindow?

func monitorWindowProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    if let monitor = activeMonitorWindow, window == monitor.window {
        switch message {
        case UINT(WM_CLOSE):
            monitor.closeRequested()
            return 0
        case UINT(WM_NCCALCSIZE) where wParam != 0:
            // Keep the system's resize borders on the sides and bottom, but give the
            // caption area to the page, which draws its own title bar.
            guard let params = UnsafeMutablePointer<NCCALCSIZE_PARAMS>(bitPattern: Int(lParam)) else { break }
            let originalTop = params.pointee.rgrc.0.top
            _ = DefWindowProcW(window, message, wParam, lParam)
            params.pointee.rgrc.0.top = originalTop
            return 0
        case UINT(WM_SIZE):
            monitor.resized()
            if wParam == WPARAM(SIZE_RESTORED) { monitor.push() }   // catch up after being minimized
            return 0
        case UINT(WM_EXITSIZEMOVE):
            monitor.frameChanged()
            return 0
        case UINT(WM_GETMINMAXINFO):
            let dpi = Double(GetDpiForWindow(window))
            let scale = dpi > 0 ? dpi / 96 : 1
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) {
                info.pointee.ptMinTrackSize = POINT(x: Int32(420 * scale), y: Int32(320 * scale))
            }
            return 0
        case UINT(WM_ERASEBKGND):
            paintBackground(window, HDC(bitPattern: UInt(wParam)))
            return 1
        case UINT(WM_COMMAND):
            trayApp?.handleCommand(UInt(wParam & 0xFFFF))
            return 0
        default:
            break
        }
    }
    return DefWindowProcW(window, message, wParam, lParam)
}
