import CWebView2
import Foundation
import NVBeaconWindowsKit
import WinSDK

/// Hosts one WebView2 page inside a Win32 window: creation, JSON messages both
/// ways, visibility, suspension and release. UI thread only.
final class WebViewHost {
    let window: HWND
    let page: String
    /// Lets `app-region: drag` areas of the page move the window (a custom title bar).
    var nonClientRegions = false
    private(set) var view: OpaquePointer?
    private(set) var pageReady = false
    /// The language of the strings table the page has (see strings.js).
    private var stringsLanguage: String?
    private var creating = false
    private var createStarted = ContinuousClock.now
    /// Called with each message the page sends, after `ready` has been handled.
    var onMessage: ([String: Any]) -> Void = { _ in }
    /// Called when the page has loaded and sent `ready`.
    var onPageReady: () -> Void = {}

    init(window: HWND, page: String) {
        self.window = window
        self.page = page
    }

    /// The message is shown once per run; later attempts (every click on the tray
    /// icon tries again) are only logged.
    nonisolated(unsafe) private static var failureShown = false

    /// HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND): no WebView2 Runtime is installed.
    private static func meansRuntimeMissing(_ result: HRESULT) -> Bool { UInt32(bitPattern: result) == 0x8007_0002 }

    private enum Failure { case missingFiles, runtimeMissing, startFailed }

    /// Logs to diag.log (also without --diag) and tells the user why the window stays empty.
    private static func failed(_ detail: String, kind: Failure) {
        Diagnostics.logError(detail)
        guard !failureShown else { return }
        failureShown = true
        let language = Theme.interface
        var text = language.text("NVBeacon cannot open its windows.") + " "
        switch kind {
        case .missingFiles:
            text += language.text("Some installed files are missing. Install NVBeacon again.")
        case .runtimeMissing:
            text += language.text("The Microsoft Edge WebView2 Runtime is not installed on this PC.")
        case .startFailed:
            text += language.text("Microsoft Edge WebView2 could not be started.")
        }
        text += "\n\n" + language.text("Error: %@\nLog: %@", detail, Diagnostics.logURL.windowsPath)
        let offersDownload = kind != .missingFiles
        if offersDownload {
            text += "\n\n" + language.text("Open the WebView2 Runtime download page? Install or repair it, then start NVBeacon again. The tray icon and alerts keep working.")
        }
        let answer = text.withCString(encodedAs: UTF16.self) { body in
            "NVBeacon".withCString(encodedAs: UTF16.self) { title in
                MessageBoxW(nil, body, title, UINT(offersDownload ? MB_YESNO | MB_ICONWARNING : MB_OK | MB_ICONWARNING))
            }
        }
        if offersDownload, answer == IDYES { Shell.openWebPage(Shell.webView2DownloadPage) }
    }

    var exists: Bool { view != nil || creating }

    func create(background: COLORREF) {
        guard view == nil, !creating else { return }
        guard let folder = Resources.uiFolder, let loader = Resources.loaderPath else {
            Self.failed("UI folder or WebView2Loader.dll not found next to NVBeacon.exe", kind: .missingFiles)
            return
        }
        let loaded = loader.withCString(encodedAs: UTF16.self) { NVBWebViewLoad($0) }
        guard loaded >= 0 else {
            Self.failed("WebView2Loader.dll failed to load hr=\(hex(loaded))", kind: .missingFiles)
            return
        }
        creating = true
        createStarted = .now
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = Resources.userDataFolder.withCString(encodedAs: UTF16.self) { data in
            "nvbeacon.ui".withCString(encodedAs: UTF16.self) { host in
                folder.withCString(encodedAs: UTF16.self) { content in
                    "https://nvbeacon.ui/\(page)".withCString(encodedAs: UTF16.self) { url in
                        NVBWebViewCreate(window, data, host, content, url, background,
                                         Diagnostics.enabled, nonClientRegions, context, webViewReady, webViewMessage)
                    }
                }
            }
        }
        if result < 0 {
            creating = false
            Self.failed("NVBWebViewCreate(\(page)) failed hr=\(hex(result))", kind: Self.meansRuntimeMissing(result) ? .runtimeMissing : .startFailed)
        }
    }

    fileprivate func didCreate(_ created: OpaquePointer?, _ result: HRESULT) {
        creating = false
        guard let created, result >= 0 else {
            Self.failed("WebView2 creation for \(page) failed hr=\(hex(result))", kind: Self.meansRuntimeMissing(result) ? .runtimeMissing : .startFailed)
            return
        }
        view = created
        Diagnostics.log("WebView2 for \(page) ready after \(ContinuousClock.now - createStarted)")
        resize()
        setVisible(IsWindowVisible(window))
        if IsWindowVisible(window) { focus() }
    }

    fileprivate func didReceive(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String else { return }
        if type == "ready" {
            pageReady = true
            stringsLanguage = nil
            var client = RECT()
            GetClientRect(window, &client)
            Diagnostics.log("\(page) ready after \(ContinuousClock.now - createStarted); page \(message["width"] ?? "?")x\(message["height"] ?? "?") css px at scale \(message["scale"] ?? "?"), client \(client.right)x\(client.bottom) px")
            onPageReady()
            return
        }
        if type == "ack", let sentAt = message["sentAt"] as? Double {
            Diagnostics.log("\(page) state delivered in \(Int(Date().timeIntervalSince1970 * 1000 - sentAt)) ms")
            return
        }
        onMessage(message)
    }

    func post(_ json: String) {
        guard let view, pageReady else { return }
        postStringsIfNeeded(to: view)
        _ = json.withCString(encodedAs: UTF16.self) { NVBWebViewPostJSON(view, $0) }
    }

    /// Before the first message, and after the language changes, the page gets the
    /// interface strings in the current language (English where a text is missing).
    private func postStringsIfNeeded(to view: OpaquePointer) {
        let language = Theme.language
        guard language != stringsLanguage else { return }
        stringsLanguage = language
        let message: [String: Any] = [
            "type": "strings", "language": language,
            "strings": InterfaceLanguage.translations.resolvedStrings(for: language),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        _ = String(decoding: data, as: UTF8.self).withCString(encodedAs: UTF16.self) { NVBWebViewPostJSON(view, $0) }
    }

    func post(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        post(String(decoding: data, as: UTF8.self))
    }

    func resize() {
        guard let view else { return }
        var bounds = RECT()
        GetClientRect(window, &bounds)
        NVBWebViewSetBounds(view, bounds)
    }

    func setVisible(_ visible: Bool) {
        if let view { NVBWebViewSetVisible(view, visible) }
    }

    func focus() {
        if let view { NVBWebViewFocus(view) }
    }

    func trySuspend() {
        guard let view else { return }
        Diagnostics.log("\(page) TrySuspend hr=\(hex(NVBWebViewTrySuspend(view)))")
    }

    func release() {
        guard let view else { return }
        NVBWebViewClose(view)
        self.view = nil
        pageReady = false
        stringsLanguage = nil
        Diagnostics.log("WebView2 for \(page) released")
    }

    var browserProcessID: UInt32 { view.map { NVBWebViewBrowserProcessID($0) } ?? 0 }
}

func hex(_ result: HRESULT) -> String { "0x" + String(UInt32(bitPattern: result), radix: 16) }

private func webViewReady(_ context: UnsafeMutableRawPointer?, _ view: OpaquePointer?, _ result: HRESULT) {
    guard let context else { return }
    Unmanaged<WebViewHost>.fromOpaque(context).takeUnretainedValue().didCreate(view, result)
}

private func webViewMessage(_ context: UnsafeMutableRawPointer?, _ text: UnsafePointer<wchar_t>?) {
    guard let context, let text else { return }
    Unmanaged<WebViewHost>.fromOpaque(context).takeUnretainedValue().didReceive(String(decodingCString: text, as: UTF16.self))
}

enum Resources {
    private static var executableFolder: URL {
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        return URL(fileURLWithPath: String(decoding: buffer[0..<Int(length)], as: UTF16.self)).deletingLastPathComponent()
    }

    static var executablePath: String {
        var buffer = [WCHAR](repeating: 0, count: 32_768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        return String(decoding: buffer[0..<Int(length)], as: UTF16.self)
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

    /// The open source license notices installed next to NVBeacon.exe.
    static var noticesPath: String? {
        let candidates = [
            executableFolder.appendingPathComponent("THIRD-PARTY-NOTICES.txt"),
            packageFolder.appendingPathComponent("packaging/THIRD-PARTY-NOTICES.txt"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
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
