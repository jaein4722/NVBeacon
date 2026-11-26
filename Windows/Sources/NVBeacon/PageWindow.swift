import Foundation
import NVBeaconWindowsKit
import WinSDK

/// A normal resizable window showing one HTML page in WebView2: the Settings
/// window and the GPU History window. WebView2 is released when it closes.
final class PageWindow {
    static let className = "NVBeaconPageWindow"
    let window: HWND
    let host: WebViewHost
    /// A key of the shared translation files.
    private let title: String
    private let size: (width: Double, height: Double)
    private let minimumSize: (width: Double, height: Double)
    var onMessage: ([String: Any]) -> Void = { _ in }
    var onPageReady: () -> Void = {}
    var onClosed: () -> Void = {}

    init?(instance: HINSTANCE?, page: String, title: String,
          size: (width: Double, height: Double), minimumSize: (width: Double, height: Double)) {
        self.title = title
        self.size = size
        self.minimumSize = minimumSize
        let created = Self.className.withCString(encodedAs: UTF16.self) { name in
            title.withCString(encodedAs: UTF16.self) { title in
                CreateWindowExW(0, name, title, DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN),
                                Int32(bitPattern: 0x8000_0000), 0, Int32(size.width), Int32(size.height), nil, nil, instance, nil)
            }
        }
        guard let created else { return nil }
        window = created
        host = WebViewHost(window: created, page: page)
        host.onMessage = { [unowned self] in onMessage($0) }
        host.onPageReady = { [unowned self] in onPageReady() }
        // The window procedure finds this object through the window's user data.
        SetWindowLongPtrW(window, GWLP_USERDATA, LONG_PTR(Int(bitPattern: Unmanaged.passUnretained(self).toOpaque())))
    }

    static func registerClass(instance: HINSTANCE?) -> Bool {
        className.withCString(encodedAs: UTF16.self) { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = pageWindowProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            windowClass.hIcon = AppIdentity.icon(small: false)
            windowClass.hIconSm = AppIdentity.icon(small: true)
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
        guard isVisible else { return }
        ShowWindow(window, SW_HIDE)
        host.release()   // opened rarely; don't keep Chromium around
        onClosed()
    }

    func applyTheme() {
        var dark: Int32 = Theme.isDark ? 1 : 0
        DwmSetWindowAttribute(window, DWORD(DWMWA_USE_IMMERSIVE_DARK_MODE.rawValue), &dark, DWORD(MemoryLayout<Int32>.size))
        let title = Theme.interface.text(self.title)
        _ = title.withCString(encodedAs: UTF16.self) { SetWindowTextW(window, $0) }
        InvalidateRect(window, nil, true)
    }

    private func centerOnWorkArea() {
        let dpi = Double(GetDpiForWindow(window))
        let scale = dpi > 0 ? dpi / 96 : 1
        let width = Int32(size.width * scale), height = Int32(size.height * scale)
        var cursor = POINT()
        GetCursorPos(&cursor)
        var info = MONITORINFO()
        info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        GetMonitorInfoW(MonitorFromPoint(cursor, DWORD(MONITOR_DEFAULTTONEAREST)), &info)
        let work = info.rcWork
        let x = work.left + max(0, (work.right - work.left - width) / 2)
        let y = work.top + max(0, (work.bottom - work.top - height) / 2)
        SetWindowPos(window, nil, x, y, width, min(height, work.bottom - work.top), UINT(SWP_NOZORDER))
    }

    fileprivate func minimumTrackSize() -> POINT {
        let dpi = Double(GetDpiForWindow(window))
        let scale = dpi > 0 ? dpi / 96 : 1
        return POINT(x: Int32(minimumSize.width * scale), y: Int32(minimumSize.height * scale))
    }
}

func pageWindowProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    let pointer = UnsafeMutableRawPointer(bitPattern: Int(GetWindowLongPtrW(window, GWLP_USERDATA)))
    if let pointer {
        let page = Unmanaged<PageWindow>.fromOpaque(pointer).takeUnretainedValue()
        switch message {
        case UINT(WM_CLOSE):
            page.close()
            return 0
        case UINT(WM_SIZE):
            page.host.resize()
            return 0
        case UINT(WM_GETMINMAXINFO):
            if let info = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) {
                info.pointee.ptMinTrackSize = page.minimumTrackSize()
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
