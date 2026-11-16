import Dispatch
import Foundation
import NVBeaconWindowsKit
import WinSDK

// Tray client: NVBeacon.exe [--interval SECONDS] [--demo] [--diag] [--release-after SECONDS] [TARGET ...]
// Without targets it reads %APPDATA%\NVBeacon\servers.txt.
//
// Threads: all windows, the tray icon and WebView2 live on one STA UI thread with
// its own message loop. Polling runs on Swift's global executor and reaches the UI
// thread only through PostMessage. The main thread runs dispatchMain() so any work
// queued on the main queue still runs, independent of the UI thread's modal loops.
// The Windows client does not use @MainActor.

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

// Per-monitor DPI awareness keeps the rendered icon and the flyout sharp.
_ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))

var arguments = Array(CommandLine.arguments.dropFirst())
// Recreating WebView2 takes about 0.3 s, while keeping it hidden holds ~150 MB of
// Chromium memory (measured on the dev PC), so release it soon after the flyout closes.
var releaseAfterSeconds: UINT = 60
if let index = arguments.firstIndex(of: "--diag") {
    Diagnostics.enabled = true
    arguments.remove(at: index)
}
if let index = arguments.firstIndex(of: "--release-after"), index + 1 < arguments.count,
   let seconds = UINT(arguments[index + 1]) {
    releaseAfterSeconds = seconds
    arguments.removeSubrange(index...index + 1)
}

var options: LaunchOptions
do {
    options = try LaunchOptions.parse(arguments)
} catch {
    showError("\(error)\n\nUsage: NVBeacon.exe [--interval SECONDS] [--demo] [TARGET ...]")
    exit(2)
}
var savedSettings = SettingsStore.load()
// --interval without targets still applies for this session.
if arguments.contains("--interval") { savedSettings.pollIntervalSeconds = Int(options.interval.components.seconds) }
let launchSettings = savedSettings
// Command-line or --demo targets replace the saved servers for this session only.
let sessionTargets: [String]? = options.targets.isEmpty ? nil : options.targets
let releaseAfter = releaseAfterSeconds
Diagnostics.log("launch: \(sessionTargets?.count ?? launchSettings.servers.count) servers, release after \(releaseAfter) s")

func runUIThread() {
    CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))  // WebView2 requires an STA thread
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
    guard registered != 0, Flyout.registerClass(instance: instance), SettingsWindow.registerClass(instance: instance) else {
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
    let app = TrayApp(window: window, settings: launchSettings, sessionTargets: sessionTargets)
    trayApp = app
    if let flyout = Flyout(trayWindow: window, instance: instance, releaseAfterSeconds: releaseAfter) {
        activeFlyout = flyout
        app.attach(flyout)
    }
    if let settingsWindow = SettingsWindow(instance: instance) {
        activeSettingsWindow = settingsWindow
        app.attach(settingsWindow)
    }
    app.start()

    var message = MSG()
    while GetMessageW(&message, nil, 0, 0) {
        TranslateMessage(&message)
        DispatchMessageW(&message)
    }
    Diagnostics.log("UI thread finished")
    CoUninitialize()
    exit(0)
}

let uiThread = Thread { runUIThread() }
uiThread.stackSize = 4 * 1024 * 1024
uiThread.start()
_ = instanceMutex
dispatchMain()
