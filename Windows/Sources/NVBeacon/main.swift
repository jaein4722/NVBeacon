import Foundation
import NVBeaconWindowsKit
import WinSDK

// Tray client: NVBeacon.exe [--interval SECONDS] [TARGET ...]
// Without targets it reads %APPDATA%\NVBeacon\servers.txt.

func showError(_ text: String) {
    text.withCString(encodedAs: UTF16.self) { body in
        "NVBeacon".withCString(encodedAs: UTF16.self) { title in
            _ = MessageBoxW(nil, body, title, UINT(MB_OK | MB_ICONERROR))
        }
    }
}

let instanceMutex = "Local\\NVBeacon.Tray".withCString(encodedAs: UTF16.self) { CreateMutexW(nil, true, $0) }
if GetLastError() == DWORD(ERROR_ALREADY_EXISTS) {
    showError("NVBeacon is already running. Look for its icon in the notification area.")
    exit(0)
}

// Per-monitor DPI awareness keeps the rendered icon sharp instead of scaled up.
_ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))

var options: LaunchOptions
do {
    options = try LaunchOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    showError("\(error)\n\nUsage: NVBeacon.exe [--interval SECONDS] [TARGET ...]")
    exit(2)
}
if options.targets.isEmpty { options.targets = LaunchOptions.loadServerFile() }

let instance = GetModuleHandleW(nil)
let className = "NVBeaconTrayWindow"
let registered = className.withCString(encodedAs: UTF16.self) { name in
    var windowClass = WNDCLASSEXW()
    windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
    windowClass.lpfnWndProc = windowProcedure
    windowClass.hInstance = instance
    windowClass.lpszClassName = name
    return RegisterClassExW(&windowClass)
}
guard registered != 0 else {
    showError("Could not register the tray window (error \(GetLastError())).")
    exit(1)
}

// A hidden top-level window (not message-only) so the tray menu can take focus.
let window = className.withCString(encodedAs: UTF16.self) { name in
    "NVBeacon".withCString(encodedAs: UTF16.self) { title in
        CreateWindowExW(0, name, title, DWORD(WS_OVERLAPPED), 0, 0, 0, 0, nil, nil, instance, nil)
    }
}
guard let window else {
    showError("Could not create the tray window (error \(GetLastError())).")
    exit(1)
}

trayWindowBits = Int(bitPattern: window)
let app = TrayApp(window: window, targets: options.targets, interval: options.interval)
trayApp = app
app.start()

var message = MSG()
while GetMessageW(&message, nil, 0, 0) {
    TranslateMessage(&message)
    DispatchMessageW(&message)
}
_ = instanceMutex
