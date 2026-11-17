import AppKit
import Combine
import SwiftUI

/// Whether the popover is open. Its hosting controller lives on while it is
/// closed, so the content is built only while it is shown; otherwise every
/// server refresh would recompute a view nobody can see.
@MainActor
private final class PopoverPresence: ObservableObject {
    @Published var isShown: Bool

    init(isShown: Bool) {
        self.isShown = isShown
    }
}

private struct StatusMenuContainerView: View {
    @ObservedObject var store: NVBeaconStore
    @ObservedObject var presence: PopoverPresence
    let onContentHeightChange: (CGFloat) -> Void
    let onOpenHistory: () -> Void
    var onOpenSettings: () -> Void = {}
    var presentation: MonitorDisplayMode = .popover

    var body: some View {
        if presence.isShown {
            StatusMenuView(
                store: store,
                onContentHeightChange: onContentHeightChange,
                onOpenHistory: onOpenHistory,
                onOpenSettings: onOpenSettings,
                presentation: presentation
            )
            .preferredColorScheme(colorScheme)
        } else {
            Color.clear
        }
    }

    private var colorScheme: ColorScheme? {
        switch store.settings.appearanceMode {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    var showSettingsAction: (() -> Void)?
    var showHistoryAction: (() -> Void)?
    var checkForUpdatesAction: (() -> Void)?
    var canCheckForUpdates: () -> Bool = { false }

    private let store: NVBeaconStore
    private let settingsOpenBridge: SettingsOpenBridge
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var localOutsideClickMonitor: Any?
    private var globalOutsideClickMonitor: Any?
    private lazy var settingsMenuItem = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: ",")
    private lazy var quitMenuItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
    private lazy var refreshMenuItem = NSMenuItem(title: "", action: #selector(refreshNow), keyEquivalent: "r")
    private lazy var historyMenuItem = NSMenuItem(title: "", action: #selector(openHistory), keyEquivalent: "")
    private lazy var checkForUpdatesMenuItem = NSMenuItem(title: "", action: #selector(checkForUpdates), keyEquivalent: "")
    private lazy var displayModeMenuItem = NSMenuItem(title: "", action: #selector(toggleDisplayMode), keyEquivalent: "")
    private lazy var keepOnTopMenuItem = NSMenuItem(title: "", action: #selector(toggleKeepOnTop), keyEquivalent: "")
    private lazy var monitorWindowController = MonitorWindowController(store: store) { [unowned self] in
        NSHostingController(
            rootView: StatusMenuContainerView(
                store: store,
                presence: PopoverPresence(isShown: true),
                onContentHeightChange: { _ in },
                onOpenHistory: { [weak self] in self?.showHistoryAction?() },
                onOpenSettings: { [weak self] in self?.showSettingsAction?() },
                presentation: .window
            )
        )
    }
    private var appliedDisplayMode: MonitorDisplayMode
    private let popoverPresence = PopoverPresence(isShown: false)
    private var settingsRelayHostingView: NSHostingView<SettingsActionRelayView>?
    private var measuredContentHeight: CGFloat = 0

    init(store: NVBeaconStore, settingsOpenBridge: SettingsOpenBridge) {
        self.store = store
        self.settingsOpenBridge = settingsOpenBridge
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.appliedDisplayMode = store.settings.displayMode
        super.init()

        configurePopover()
        configureMenu()
        configureStatusItem()
        bindStore()
        updateStatusItemAppearance()
        updatePopoverSize()

        // Window mode is a saved choice: reopen the window after a relaunch.
        if appliedDisplayMode == .window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                monitorWindowController.show(anchor: statusItemScreenFrame)
            }
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }

        switch event.type {
        case .rightMouseUp:
            showContextMenu()
        case .leftMouseUp:
            if store.settings.displayMode == .window {
                monitorWindowController.toggle(anchor: statusItemScreenFrame)
            } else {
                togglePopover(sender)
            }
        default:
            break
        }
    }

    @objc private func openSettings() {
        popover.performClose(nil)
        showSettingsAction?()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func refreshNow() {
        store.refreshNow()
    }

    @objc private func openHistory() {
        popover.performClose(nil)
        showHistoryAction?()
    }

    @objc private func checkForUpdates() {
        popover.performClose(nil)
        checkForUpdatesAction?()
    }

    @objc private func toggleDisplayMode() {
        store.setDisplayMode(store.settings.displayMode == .window ? .popover : .window)
    }

    @objc private func toggleKeepOnTop() {
        store.setKeepsWindowOnTop(!store.settings.keepsWindowOnTop)
    }

    /// Nil until the menu bar has placed the item.
    private var statusItemScreenFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        // An item the menu bar has not placed (or has hidden) has a zero-height
        // window at the screen origin.
        guard window.frame.height > 0, window.frame.minY > 0, frame.width > 0,
              NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }) else { return nil }
        return frame
    }

    /// Applies a display mode change from any source (header button, menu, Settings).
    private func applyDisplayModeIfNeeded() {
        let mode = store.settings.displayMode
        guard mode != appliedDisplayMode else { return }
        appliedDisplayMode = mode
        switch mode {
        case .window:
            popover.performClose(nil)
            monitorWindowController.show(anchor: statusItemScreenFrame)
        case .popover:
            monitorWindowController.hide()
            // Open the popover right away so it is clear where the content went.
            if let button = statusItem.button, !popover.isShown {
                togglePopover(button)
            }
        }
    }

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: StatusMenuContainerView(
                store: store,
                presence: popoverPresence,
                onContentHeightChange: { [weak self] height in
                    self?.updateMeasuredContentHeight(height)
                },
                onOpenHistory: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.showHistoryAction?()
                },
                onOpenSettings: { [weak self] in
                    self?.openSettings()
                }
            )
        )
        updatePopoverAppearance()
    }

    private func configureMenu() {
        settingsMenuItem.target = self
        quitMenuItem.target = self
        displayModeMenuItem.target = self
        keepOnTopMenuItem.target = self
        refreshMenuItem.target = self
        historyMenuItem.target = self
        checkForUpdatesMenuItem.target = self
        // Refresh and update checks set isEnabled themselves.
        menu.autoenablesItems = false
        menu.items = [
            refreshMenuItem,
            historyMenuItem,
            .separator(),
            displayModeMenuItem,
            keepOnTopMenuItem,
            .separator(),
            checkForUpdatesMenuItem,
            settingsMenuItem,
            .separator(),
            quitMenuItem,
        ]
        updateMenuTitles()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeft

        let relayHostingView = NSHostingView(rootView: SettingsActionRelayView(bridge: settingsOpenBridge))
        relayHostingView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(relayHostingView)

        NSLayoutConstraint.activate([
            relayHostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            relayHostingView.topAnchor.constraint(equalTo: button.topAnchor),
            relayHostingView.widthAnchor.constraint(equalToConstant: 1),
            relayHostingView.heightAnchor.constraint(equalToConstant: 1),
        ])

        settingsRelayHostingView = relayHostingView
    }

    private func bindStore() {
        // One store change often publishes several properties in a row; handle the
        // burst once instead of once per property.
        store.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAppearance()
                self?.updatePopoverSize()
                self?.updatePopoverAppearance()
                self?.updatePopoverAutoCloseBehavior()
            }
            .store(in: &cancellables)
        // The menu is rebuilt when it opens (showContextMenu), not on every refresh.
        // objectWillChange fires before the value changes; read settings after it.
        store.$settings
            .map { ($0.displayMode, $0.keepsWindowOnTop) }
            .removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                applyDisplayModeIfNeeded()
                monitorWindowController.applyKeepOnTop()
                updateMenuTitles()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.closePopoverForOutsideInteraction()
            }
            .store(in: &cancellables)
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            updatePopoverSize()
            updatePopoverAppearance()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            updatePopoverAppearance()
            popover.contentViewController?.view.window?.becomeKey()
            updatePopoverAutoCloseBehavior()
        }
    }

    private func showContextMenu() {
        popover.performClose(nil)
        updateMenuTitles()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }
        let iconOnly = store.settings.menuBarDisplayMode == .iconOnly

        statusItem.length = iconOnly ? NSStatusItem.squareLength : NSStatusItem.variableLength
        button.title = store.menuBarTitle
        button.image = NSImage(
            systemSymbolName: store.menuBarSymbolName,
            accessibilityDescription: store.settings.resolvedLanguage.text("GPU Usage", "GPU 사용량")
        )
        button.image?.isTemplate = true
        button.imagePosition = iconOnly ? .imageOnly : .imageLeft
        button.toolTip = store.menuBarToolTip
    }

    private func updateMenuTitles() {
        let language = store.settings.resolvedLanguage
        settingsMenuItem.title = language.text("Settings…", "설정…")
        quitMenuItem.title = language.text("Quit NVBeacon", "NVBeacon 종료")
        let windowMode = store.settings.displayMode == .window
        displayModeMenuItem.title = windowMode
            ? language.text("Show as Popover", "팝오버로 보기")
            : language.text("Show as Window", "창으로 보기")
        keepOnTopMenuItem.title = language.text("Keep Window on Top", "항상 위에 표시")
        keepOnTopMenuItem.state = store.settings.keepsWindowOnTop ? .on : .off
        keepOnTopMenuItem.isHidden = !windowMode
        refreshMenuItem.title = language.text("Refresh Now", "지금 새로고침")
        refreshMenuItem.isEnabled = store.settings.isConfigured
        historyMenuItem.title = language.text("GPU History…", "GPU 기록…")
        historyMenuItem.isHidden = !store.settings.recordsGPUHistory
        checkForUpdatesMenuItem.title = language.text("Check for Updates…", "업데이트 확인…")
        checkForUpdatesMenuItem.isEnabled = canCheckForUpdates()
    }

    private func updatePopoverSize() {
        let gpuCount = max(store.totalGPUCount, 1)
        let serverCount = max(store.configuredServerCount, 1)
        let fallbackHeight = CGFloat(150 + min(gpuCount, 8) * 84 + min(serverCount, 4) * 42)
        let contentHeight = measuredContentHeight > 0 ? measuredContentHeight : fallbackHeight
        let maxHeight = maxPopoverHeight()
        let minHeight = min(CGFloat(320), maxHeight)
        let height = switch store.settings.popoverHeightMode {
        case .automatic:
            min(maxHeight, max(minHeight, contentHeight))
        case .fixed:
            min(maxHeight, CGFloat(store.settings.resolvedPopoverHeight))
        }
        let size = NSSize(width: CGFloat(store.settings.resolvedPopoverWidth), height: height)
        if popover.contentSize != size {
            popover.contentSize = size
        }
    }

    private func maxPopoverHeight() -> CGFloat {
        let visibleFrameHeight = statusItem.button?.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 920
        let verticalMargin: CGFloat = 96
        return max(320, min(1100, visibleFrameHeight - verticalMargin))
    }

    private func updateMeasuredContentHeight(_ height: CGFloat) {
        guard abs(measuredContentHeight - height) > 1 else { return }
        measuredContentHeight = height
        updatePopoverSize()
    }

    private func updatePopoverAppearance() {
        let appearance: NSAppearance? = switch store.settings.appearanceMode {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }

        popover.appearance = appearance
        popover.contentViewController?.view.appearance = appearance
        popover.contentViewController?.view.window?.appearance = appearance
    }

    private func updatePopoverAutoCloseBehavior() {
        guard popover.isShown else {
            removeOutsideClickMonitor()
            return
        }

        if store.settings.closesPopoverOnOutsideClick {
            installOutsideClickMonitorIfNeeded()
        } else {
            removeOutsideClickMonitor()
        }
    }

    private func installOutsideClickMonitorIfNeeded() {
        if localOutsideClickMonitor == nil {
            localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handleLocalOutsideClick(event)
            }
        }

        if globalOutsideClickMonitor == nil {
            globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.closePopoverForOutsideInteraction()
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }

        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }
    }

    private func handleLocalOutsideClick(_ event: NSEvent) -> NSEvent? {
        guard popover.isShown, store.settings.closesPopoverOnOutsideClick else {
            return event
        }

        if isClickInsidePopover(event) || isClickOnStatusButton(event) {
            return event
        }

        popover.performClose(nil)
        return event
    }

    private func isClickInsidePopover(_ event: NSEvent) -> Bool {
        event.window === popover.contentViewController?.view.window
    }

    private func isClickOnStatusButton(_ event: NSEvent) -> Bool {
        event.window === statusItem.button?.window
    }

    private func closePopoverForOutsideInteraction() {
        guard popover.isShown, store.settings.closesPopoverOnOutsideClick else { return }
        popover.performClose(nil)
    }

    func popoverWillShow(_ notification: Notification) {
        popoverPresence.isShown = true
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        popoverPresence.isShown = false
    }
}
