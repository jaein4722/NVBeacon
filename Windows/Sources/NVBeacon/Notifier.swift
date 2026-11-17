import Foundation
import NVBeaconWindowsKit
import WinSDK

/// Shows alerts as tray balloons (`Shell_NotifyIcon` with `NIF_INFO`). Windows 10
/// and 11 present these as toast notifications and keep them in the notification
/// center, with no app registration and no extra runtime. UI thread only.
enum Notifier {
    /// Returns false when the shell refused the notification.
    @discardableResult
    static func show(_ notification: PendingNotification, trayWindow: HWND) -> Bool {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = trayWindow
        data.uID = 1
        data.uFlags = UINT(NIF_INFO)
        // NIIF_INFO, and stay quiet during Focus assist / presentations.
        data.dwInfoFlags = DWORD(NIIF_INFO) | DWORD(NIIF_RESPECT_QUIET_TIME)
        copy(notification.title, into: &data.szInfoTitle)
        copy(notification.body, into: &data.szInfo)
        let ok = Shell_NotifyIconW(DWORD(NIM_MODIFY), &data)
        Diagnostics.log("notification \(ok ? "shown" : "refused"): \(notification.title)")
        return ok
    }

    /// Writes a NUL-terminated, truncated UTF-16 string into a fixed-size WCHAR field.
    private static func copy<T>(_ text: String, into field: inout T) {
        withUnsafeMutableBytes(of: &field) { buffer in
            let units = buffer.bindMemory(to: UInt16.self)
            var utf16 = Array(text.utf16.prefix(units.count - 1))
            if utf16.count == units.count - 1, text.utf16.count > utf16.count { utf16[utf16.count - 1] = 0x2026 }  // …
            for (index, unit) in utf16.enumerated() { units[index] = unit }
            units[utf16.count] = 0
        }
    }
}
