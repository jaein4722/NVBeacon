import CWebView2
import Foundation
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

    var exists: Bool { view != nil || creating }

    func create(background: COLORREF) {
        guard view == nil, !creating else { return }
        guard let folder = Resources.uiFolder, let loader = Resources.loaderPath else {
            Diagnostics.log("UI folder or WebView2Loader.dll not found")
            return
        }
        let loaded = loader.withCString(encodedAs: UTF16.self) { NVBWebViewLoad($0) }
        guard loaded >= 0 else {
            Diagnostics.log("WebView2Loader.dll failed to load hr=\(hex(loaded))")
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
            Diagnostics.log("NVBWebViewCreate(\(page)) failed hr=\(hex(result))")
        }
    }

    fileprivate func didCreate(_ created: OpaquePointer?, _ result: HRESULT) {
        creating = false
        guard let created, result >= 0 else {
            Diagnostics.log("WebView2 creation for \(page) failed hr=\(hex(result))")
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
        _ = json.withCString(encodedAs: UTF16.self) { NVBWebViewPostJSON(view, $0) }
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
