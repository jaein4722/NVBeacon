import AppKit

/// Window mode: the popover's content in a normal, resizable window that stays
/// open, can be kept on top and remembers its frame. Closing it only hides it;
/// the display mode stays `.window` until the user switches back to the popover.
@MainActor
final class MonitorWindowController: NSObject, NSWindowDelegate {
    private static let frameAutosaveName = "NVBeaconMonitorWindow"

    private let store: NVBeaconStore
    private let makeContent: () -> NSViewController
    private var window: NSWindow?

    init(store: NVBeaconStore, makeContent: @escaping () -> NSViewController) {
        self.store = store
        self.makeContent = makeContent
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    /// Brings the window to the front, creating it next to `anchor` (the status
    /// item's frame in screen coordinates) the first time.
    func show(anchor: NSRect?) {
        let window = window ?? makeWindow(anchor: anchor)
        self.window = window

        if window.contentViewController == nil {
            // Assigning a content view controller resizes the window to the
            // content's fitting size, so keep the saved frame.
            let frame = window.frame
            window.contentViewController = makeContent()
            window.setFrame(frame, display: false)
        }

        applyKeepOnTop()
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Hides the window and releases its content so nothing renders while hidden.
    func hide() {
        guard let window, window.isVisible || window.isMiniaturized else { return }
        window.orderOut(nil)
        window.contentViewController = nil
    }

    /// Menu bar click in window mode: bring the window forward, or hide it when it
    /// is already the frontmost window.
    func toggle(anchor: NSRect?) {
        if let window, window.isVisible, window.isKeyWindow, !window.isMiniaturized, NSApp.isActive {
            hide()
        } else {
            show(anchor: anchor)
        }
    }

    func applyKeepOnTop() {
        guard let window else { return }
        if store.settings.keepsWindowOnTop {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            window.level = .normal
            window.collectionBehavior = [.fullScreenNone]
        }
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
    }

    private func makeWindow(anchor: NSRect?) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: CGFloat(store.settings.resolvedPopoverWidth), height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NVBeacon"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(
            width: CGFloat(AppSettings.popoverWidthRange.lowerBound),
            height: CGFloat(AppSettings.popoverHeightRange.lowerBound)
        )
        window.delegate = self

        let restored = window.setFrameUsingName(Self.frameAutosaveName)
        if !restored || !Self.isOnConnectedScreen(window.frame) {
            place(window, anchor: anchor)
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        return window
    }

    /// Without a usable saved frame, open under the menu bar item at popover size.
    private func place(_ window: NSWindow, anchor: NSRect?) {
        let screen = anchor.flatMap { anchor in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let width = min(CGFloat(store.settings.resolvedPopoverWidth), visible.width - 16)
        let height = min(CGFloat(760), visible.height - 48)
        // Without an anchor, the menu bar's status items sit on the right.
        let preferredX = anchor.map { $0.midX - width / 2 } ?? visible.maxX - width - 16
        let x = min(max(preferredX, visible.minX + 8), visible.maxX - width - 8)
        let y = visible.maxY - 8 - height
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }

    private static func isOnConnectedScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }
}
