import AppKit
import Combine
import SwiftUI

private struct StatusMenuContainerView: View {
    @ObservedObject var store: GPUUsageStore

    var body: some View {
        StatusMenuView(store: store)
            .preferredColorScheme(colorScheme)
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

    private let store: GPUUsageStore
    private let settingsOpenBridge: SettingsOpenBridge
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    private var localOutsideClickMonitor: Any?
    private lazy var settingsMenuItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    private var settingsRelayHostingView: NSHostingView<SettingsActionRelayView>?

    init(store: GPUUsageStore, settingsOpenBridge: SettingsOpenBridge) {
        self.store = store
        self.settingsOpenBridge = settingsOpenBridge
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configurePopover()
        configureMenu()
        configureStatusItem()
        bindStore()
        updateStatusItemAppearance()
        updatePopoverSize()
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
            togglePopover(sender)
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

    private func configurePopover() {
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: StatusMenuContainerView(store: store))
        updatePopoverAppearance()
    }

    private func configureMenu() {
        settingsMenuItem.target = self

        let quitMenuItem = NSMenuItem(title: "Quit GPUUsage", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.target = self

        menu.items = [
            settingsMenuItem,
            .separator(),
            quitMenuItem,
        ]
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
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAppearance()
                self?.updatePopoverSize()
                self?.updatePopoverAppearance()
                self?.updatePopoverAutoCloseBehavior()
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
            accessibilityDescription: "GPU Usage"
        )
        button.image?.isTemplate = true
        button.imagePosition = iconOnly ? .imageOnly : .imageLeft
        button.toolTip = store.menuBarToolTip
    }

    private func updatePopoverSize() {
        let gpuCount = max(store.snapshot?.gpus.count ?? 0, 1)
        let height = min(CGFloat(820), max(260, CGFloat(110 + gpuCount * 58)))
        popover.contentSize = NSSize(width: 500, height: height)
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
        guard localOutsideClickMonitor == nil else { return }

        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalOutsideClick(event)
        }
    }

    private func removeOutsideClickMonitor() {
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
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

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }
}
